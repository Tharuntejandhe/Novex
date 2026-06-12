import Foundation
import SQLite3

/// Reads from macOS Mail.app's local Envelope Index (SQLite) without ever
/// touching the network. Requires Full Disk Access for the host app.
///
/// Safe to use off the main actor: it holds no mutable shared state — every
/// read opens, uses, and closes its own SQLite handle entirely within the call.
final class MailReader: @unchecked Sendable {
    enum ReadError: Error {
        case noFullDiskAccess
        case mailNotConfigured
        case databaseUnavailable
        case query(String)
    }

    private let fileManager = FileManager.default
    private var mailRoot: URL? { resolveMailRoot() }

    /// Probe Full Disk Access by attempting to list the Mail directory.
    /// `Operation not permitted` ⇒ FDA not granted yet.
    var hasFullDiskAccess: Bool {
        let url = ("~/Library/Mail" as NSString).expandingTildeInPath
        return (try? fileManager.contentsOfDirectory(atPath: url)) != nil
    }

    /// True if the user has at least one Mail account configured.
    var mailIsConfigured: Bool {
        guard let root = mailRoot else { return false }
        let envelope = root.appendingPathComponent("MailData/Envelope Index")
        return fileManager.fileExists(atPath: envelope.path)
    }

    /// Most recent messages across all accounts/mailboxes.
    /// - Parameters:
    ///   - since: only messages received after this date
    ///   - limit: hard cap on rows returned
    func recentMessages(since: Date, limit: Int = 50, includeBodies: Bool = false) throws -> [MailMessage] {
        guard hasFullDiskAccess else { throw ReadError.noFullDiskAccess }
        guard let root = mailRoot else { throw ReadError.mailNotConfigured }

        let dbURL = root.appendingPathComponent("MailData/Envelope Index")
        guard fileManager.fileExists(atPath: dbURL.path) else {
            throw ReadError.databaseUnavailable
        }

        // Mail writes new mail into the Envelope Index's `-wal` sidecar and only
        // folds it into the main db file on an occasional checkpoint. Opening
        // with `immutable=1` (the old approach) IGNORES the `-wal`, so we'd read
        // whatever the last checkpoint left behind — which can be DAYS stale
        // even while Mail is showing brand-new mail (this is what made the
        // briefing say "no recent mail" for days). `openFreshDatabase` instead
        // reads *through* the WAL so the briefing reflects mail that just landed.
        let opened = try openFreshDatabase(dbURL)
        let db = opened.db
        defer {
            sqlite3_close(db)
            if let tmp = opened.tempDir { try? fileManager.removeItem(at: tmp) }
        }

        // Apple stores date_received as Mac-absolute time (seconds since 2001)
        // on older macOS, but as a Unix timestamp (seconds since 1970) on macOS
        // 26+. Detect which from the magnitude of the newest value (a modern
        // Unix timestamp is > 1.2e9 — year 2008+ — which Mac-absolute time won't
        // reach until ~2039) and use matching units for the cutoff and for each
        // row's date. Getting this wrong makes the 24h window meaningless and
        // shows absurd dates.
        let newestRaw = Self.maxDateReceived(db)
        let usesUnixEpoch = newestRaw > 1_200_000_000
        let cutoff = usesUnixEpoch ? since.timeIntervalSince1970
                                   : since.timeIntervalSinceReferenceDate
        func dateFromRaw(_ raw: Double) -> Date {
            usesUnixEpoch ? Date(timeIntervalSince1970: raw)
                          : Date(timeIntervalSinceReferenceDate: raw)
        }

        // Apple's schema has evolved; these column names cover macOS 14–26.
        // `read` and `flagged` are bits inside the `flags` integer on some
        // versions and standalone columns on others. We coalesce defensively.
        // `message_id` (the RFC 2822 Message-ID used by the message:// URL
        // scheme) is present on every version we've seen, but we still probe
        // for it so an unexpected schema degrades to "no deep link" rather
        // than failing the whole query.
        let columns = tableColumns(db, "messages")
        let messageIDExpr = columns.contains("message_id") ? "m.message_id" : "NULL"

        // COALESCE only guards NULL *values* — referencing a column that
        // doesn't exist makes the whole statement fail to PREPARE, which would
        // blank the entire briefing. Since `read`/`flagged` are standalone
        // columns on some schema versions and packed bits inside `flags` on
        // others, pick the expression from the columns actually present (the
        // same defensive probe we already use for message_id), falling back to
        // 0 = "unread / unflagged" if neither source exists.
        let hasRead = columns.contains("read")
        let hasFlagged = columns.contains("flagged")
        let hasFlags = columns.contains("flags")
        let readExpr: String
        switch (hasRead, hasFlags) {
        case (true, true):   readExpr = "COALESCE(m.read, (m.flags & 1))"
        case (true, false):  readExpr = "m.read"
        case (false, true):  readExpr = "(m.flags & 1)"
        case (false, false): readExpr = "0"
        }
        let flaggedExpr: String
        switch (hasFlagged, hasFlags) {
        case (true, true):   flaggedExpr = "COALESCE(m.flagged, ((m.flags >> 1) & 1))"
        case (true, false):  flaggedExpr = "m.flagged"
        case (false, true):  flaggedExpr = "((m.flags >> 1) & 1)"
        case (false, false): flaggedExpr = "0"
        }

        // macOS 26 stores a body PREVIEW in the `summaries` table, referenced by
        // an integer FK in `messages.summary` — this is what lets the assistant
        // read real content, not just subjects. It also exposes its own urgency /
        // automated / unsubscribe signals. All are probed so older schemas (which
        // lack them) degrade to "no snippet / no signal" rather than failing.
        let hasSnippet = columns.contains("summary")
        let snippetExpr = hasSnippet ? "su.summary" : "NULL"
        let summaryJoin = hasSnippet ? "LEFT JOIN summaries su ON m.summary = su.ROWID" : ""
        let urgentExpr = columns.contains("is_urgent") ? "m.is_urgent" : "0"
        let automatedExpr = columns.contains("automated_conversation") ? "m.automated_conversation" : "0"
        let unsubExpr = columns.contains("unsubscribe_type") ? "m.unsubscribe_type" : "0"

        // macOS 26 ran its OWN ML over every message and parked the verdicts in
        // `message_global_data` (joined on the global message id): is it
        // high-impact, urgent, does it need a follow-up reply, what category.
        // This is Apple-grade "what matters" we get for free — the foundation of
        // our importance ranking. Probe defensively; older schemas just skip it.
        // Join key is messages.message_id (an integer global id on macOS 26, NOT
        // the RFC string) == message_global_data.message_id — verified to match
        // every recent row. `model_high_impact` is populated (Apple flags ~7% of
        // mail high-impact); `urgent`/`follow_up` are empty on current macOS so we
        // don't bother reading them (importanceScore just won't get those bumps).
        let gdCols = tableColumns(db, "message_global_data")
        let hasGD = columns.contains("message_id") && !gdCols.isEmpty
        func gdExpr(_ col: String) -> String {
            (hasGD && gdCols.contains(col)) ? "gd.\(col)" : "NULL"
        }
        let highImpactExpr = gdExpr("model_high_impact")
        let gdUrgentExpr = gdExpr("urgent")
        let followUpExpr = gdExpr("follow_up_end_date")
        let categoryExpr = gdExpr("model_category")
        // The REAL RFC Message-ID (for the message:// deep link) lives here on
        // macOS 26 — `messages.message_id` is an integer hash there, which made
        // the old deep link build a bogus URL that opened nothing.
        let rfcMsgidExpr = gdExpr("message_id_header")
        let gdJoin = hasGD ? "LEFT JOIN message_global_data gd ON m.message_id = gd.message_id" : ""

        let sql = """
        SELECT
            m.ROWID,
            m.date_received,
            \(readExpr) AS read_flag,
            \(flaggedExpr) AS flagged_flag,
            s.subject,
            a.address,
            a.comment,
            mb.url,
            \(messageIDExpr) AS message_id,
            \(snippetExpr) AS body_snippet,
            \(urgentExpr) AS is_urgent,
            \(automatedExpr) AS automated_type,
            \(unsubExpr) AS unsubscribe_type,
            \(highImpactExpr) AS high_impact,
            \(gdUrgentExpr) AS gd_urgent,
            \(followUpExpr) AS follow_up_end,
            \(categoryExpr) AS category,
            \(rfcMsgidExpr) AS rfc_msgid
        FROM messages m
        LEFT JOIN subjects  s  ON m.subject = s.ROWID
        LEFT JOIN addresses a  ON m.sender  = a.ROWID
        LEFT JOIN mailboxes mb ON m.mailbox = mb.ROWID
        \(summaryJoin)
        \(gdJoin)
        WHERE m.date_received >= ?
        ORDER BY m.date_received DESC
        LIMIT ?;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw ReadError.query("prepare failed: \(msg)")
        }
        defer { sqlite3_finalize(stmt) }

        // Over-fetch: we filter out non-inbox mailboxes (Sent/Spam/Trash/…) in
        // Swift and then cap at `limit`. Without this, on a busy day the newest
        // `limit` rows could be all promos/sent mail and bury unread inbox
        // items. The 24h WHERE clause already bounds the raw set, so the
        // over-fetch stays cheap.
        let rawCap = min(500, max(limit * 8, 200))
        sqlite3_bind_double(stmt, 1, cutoff)
        sqlite3_bind_int(stmt, 2, Int32(rawCap))

        var out: [MailMessage] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let rowid = sqlite3_column_int64(stmt, 0)
            let dateRecv = sqlite3_column_double(stmt, 1)
            let read = sqlite3_column_int(stmt, 2) != 0
            let flagged = sqlite3_column_int(stmt, 3) != 0
            let subject = columnText(stmt, 4) ?? "(no subject)"
            let address = columnText(stmt, 5)
            let comment = columnText(stmt, 6)
            let mailbox = columnText(stmt, 7)
            // Deep-link id: prefer the RFC Message-ID from message_id_header;
            // fall back to messages.message_id ONLY if it looks like a real
            // Message-ID (older schemas) — never the macOS-26 integer hash,
            // which would build a dead message:// URL.
            let rawMsgID = columnText(stmt, 8)
            let rfcMsgID = columnText(stmt, 17)
            let messageID: String? = {
                if let rfc = rfcMsgID, rfc.contains("@") { return rfc }
                if let raw = rawMsgID, raw.contains("@") { return raw }
                return nil
            }()
            let snippet = columnText(stmt, 9)
            let msgUrgent = sqlite3_column_int(stmt, 10) != 0
            let automatedType = Int(sqlite3_column_int(stmt, 11))
            let unsubscribeType = Int(sqlite3_column_int(stmt, 12))
            // Apple's ML verdicts (NULL when not analyzed / older macOS).
            let highImpact = sqlite3_column_int(stmt, 13) != 0
            let gdUrgent = sqlite3_column_int(stmt, 14) != 0
            let needsFollowUp = sqlite3_column_type(stmt, 15) != SQLITE_NULL
                && sqlite3_column_double(stmt, 15) > 0
            let category = Int(sqlite3_column_int(stmt, 16))

            out.append(MailMessage(
                id: rowid,
                dateReceived: dateFromRaw(dateRecv),
                isRead: read,
                isFlagged: flagged,
                subject: subject,
                senderName: comment,
                senderAddress: address,
                mailbox: mailbox,
                messageID: messageID,
                snippet: snippet,
                isUrgent: msgUrgent || gdUrgent,
                automatedType: automatedType,
                unsubscribeType: unsubscribeType,
                isHighImpact: highImpact,
                needsFollowUp: needsFollowUp,
                category: category
            ))
        }
        // Keep only inbox-like mail — drop Sent/Drafts/Junk/Spam/Trash/Archive/
        // "All Mail" so the briefing, unread count, and change-signature
        // reflect real incoming mail rather than the user's own sent items or
        // spam. nil/unknown mailboxes are kept (better to include than to hide).
        let inbox = out.filter { Self.isInboxMailbox($0.mailbox) }
        var result = Array(inbox.prefix(limit))

        // Read REAL body text from the .emlx files for the messages we return
        // (briefing only — not the 1500-msg Money Radar scan). The body becomes
        // the message's snippet, which flows into `contentForModel`, so the LLM
        // summarizes/answers from actual content instead of subjects.
        if includeBodies {
            let dirs = BodyReader.dataDirs(mailRoot: root)
            result = result.map { msg in
                var m = msg
                if let body = BodyReader.bodySnippet(for: m.id, in: dirs) {
                    m.snippet = body
                }
                return m
            }
        }
        return result
    }

    /// Read messages across ALL mailboxes (incl. Sent) with their thread id, for
    /// Follow-up Radar. Unlike `recentMessages` this does NOT filter to the inbox
    /// (we need the user's sent mail to tell thread direction) and carries
    /// `conversationID` so a back-and-forth collapses into one thread. Metadata
    /// only — no body files (this can touch ~1000 rows).
    func threadMessages(since: Date, limit: Int = 1000) throws -> [MailMessage] {
        guard hasFullDiskAccess else { throw ReadError.noFullDiskAccess }
        guard let root = mailRoot else { throw ReadError.mailNotConfigured }
        let dbURL = root.appendingPathComponent("MailData/Envelope Index")
        guard fileManager.fileExists(atPath: dbURL.path) else { throw ReadError.databaseUnavailable }

        let opened = try openFreshDatabase(dbURL)
        let db = opened.db
        defer {
            sqlite3_close(db)
            if let tmp = opened.tempDir { try? fileManager.removeItem(at: tmp) }
        }

        let newestRaw = Self.maxDateReceived(db)
        let usesUnixEpoch = newestRaw > 1_200_000_000
        let cutoff = usesUnixEpoch ? since.timeIntervalSince1970 : since.timeIntervalSinceReferenceDate
        func dateFromRaw(_ raw: Double) -> Date {
            usesUnixEpoch ? Date(timeIntervalSince1970: raw) : Date(timeIntervalSinceReferenceDate: raw)
        }

        let columns = tableColumns(db, "messages")
        let readExpr = columns.contains("read") ? "m.read"
            : (columns.contains("flags") ? "(m.flags & 1)" : "0")
        let convExpr = columns.contains("conversation_id") ? "m.conversation_id" : "NULL"
        let automatedExpr = columns.contains("automated_conversation") ? "m.automated_conversation" : "0"
        let unsubExpr = columns.contains("unsubscribe_type") ? "m.unsubscribe_type" : "0"

        let gdCols = tableColumns(db, "message_global_data")
        let hasGD = columns.contains("message_id") && !gdCols.isEmpty
        func gdExpr(_ col: String) -> String { (hasGD && gdCols.contains(col)) ? "gd.\(col)" : "NULL" }
        let highImpactExpr = gdExpr("model_high_impact")
        let followUpExpr = gdExpr("follow_up_end_date")
        let categoryExpr = gdExpr("model_category")
        let rfcMsgidExpr = gdExpr("message_id_header")
        let gdJoin = hasGD ? "LEFT JOIN message_global_data gd ON m.message_id = gd.message_id" : ""

        let sql = """
        SELECT
            m.ROWID, m.date_received, \(readExpr) AS read_flag,
            s.subject, a.address, a.comment, mb.url,
            \(convExpr) AS conversation_id,
            \(automatedExpr) AS automated_type,
            \(unsubExpr) AS unsubscribe_type,
            \(highImpactExpr) AS high_impact,
            \(followUpExpr) AS follow_up_end,
            \(categoryExpr) AS category,
            \(rfcMsgidExpr) AS rfc_msgid
        FROM messages m
        LEFT JOIN subjects  s  ON m.subject = s.ROWID
        LEFT JOIN addresses a  ON m.sender  = a.ROWID
        LEFT JOIN mailboxes mb ON m.mailbox = mb.ROWID
        \(gdJoin)
        WHERE m.date_received >= ?
        ORDER BY m.date_received DESC
        LIMIT ?;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw ReadError.query("threadMessages prepare failed: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, cutoff)
        sqlite3_bind_int(stmt, 2, Int32(max(100, min(limit, 2000))))

        var out: [MailMessage] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let convID = sqlite3_column_type(stmt, 7) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 7)
            let rfcMsgID = columnText(stmt, 13)
            let messageID: String? = (rfcMsgID?.contains("@") == true) ? rfcMsgID : nil
            out.append(MailMessage(
                id: sqlite3_column_int64(stmt, 0),
                dateReceived: dateFromRaw(sqlite3_column_double(stmt, 1)),
                isRead: sqlite3_column_int(stmt, 2) != 0,
                isFlagged: false,
                subject: columnText(stmt, 3) ?? "(no subject)",
                senderName: columnText(stmt, 5),
                senderAddress: columnText(stmt, 4),
                mailbox: columnText(stmt, 6),
                messageID: messageID,
                snippet: nil,
                isUrgent: false,
                automatedType: Int(sqlite3_column_int(stmt, 8)),
                unsubscribeType: Int(sqlite3_column_int(stmt, 9)),
                isHighImpact: sqlite3_column_int(stmt, 10) != 0,
                needsFollowUp: sqlite3_column_type(stmt, 11) != SQLITE_NULL && sqlite3_column_double(stmt, 11) > 0,
                category: Int(sqlite3_column_int(stmt, 12)),
                conversationID: convID
            ))
        }
        return out
    }

    /// Attach real body text (as `snippet`) to a SPECIFIC set of messages — used
    /// by Money Radar to read the actual charged amount from receipt bodies for
    /// just the subscription candidates, instead of fetching all 1500 scanned
    /// messages' files.
    func attachBodies(to messages: [MailMessage], maxChars: Int = 1200) -> [MailMessage] {
        guard hasFullDiskAccess, let root = mailRoot else { return messages }
        let dirs = BodyReader.dataDirs(mailRoot: root)
        guard !dirs.isEmpty else { return messages }
        return messages.map { msg in
            var m = msg
            if let body = BodyReader.bodySnippet(for: m.id, in: dirs, maxChars: maxChars) {
                m.snippet = body
            }
            return m
        }
    }

    /// Resolve the `List-Unsubscribe` target for a set of message rowids by
    /// reading their `.emlx` headers. Used by Declutter for one-tap unsubscribe.
    func resolveUnsubscribeURLs(rowids: [Int64]) -> [Int64: URL] {
        guard hasFullDiskAccess, let root = mailRoot else { return [:] }
        let dirs = BodyReader.dataDirs(mailRoot: root)
        guard !dirs.isEmpty else { return [:] }
        var out: [Int64: URL] = [:]
        for id in rowids {
            if let u = BodyReader.unsubscribeURL(for: id, in: dirs) { out[id] = u }
        }
        return out
    }

    // MARK: - Helpers

    /// Whether a mailbox URL looks like real incoming mail (vs Sent, Drafts,
    /// Junk/Spam, Trash, Archive, or Gmail's "All Mail"). Matches on the last
    /// path component so it works across Gmail (`[Gmail]/Spam`), iCloud
    /// (`Deleted Messages`), Exchange, etc. A nil/empty URL is treated as inbox.
    static func isInboxMailbox(_ url: String?) -> Bool {
        guard let url, !url.isEmpty else { return true }
        let rawLeaf = url.split(separator: "/").last.map(String.init) ?? ""
        let leaf = (rawLeaf.removingPercentEncoding ?? rawLeaf)
            .trimmingCharacters(in: .whitespaces)
            .lowercased()

        // Exact leaf names that are never inbox (avoids false hits like a user
        // folder named "Presentations" matching "sent").
        //
        // CRITICAL: "All Mail" is deliberately NOT excluded. Gmail (IMAP) stores
        // every message — including the inbox — under "[Gmail]/All Mail"; its
        // INBOX is just a label view, so the local Envelope Index tags incoming
        // mail with the "All Mail" mailbox. Excluding it (as an earlier build
        // did) threw away the ENTIRE Gmail inbox → "no recent mail" for days.
        // We still drop Sent/Spam/Trash/Drafts by their own leaf names (Gmail
        // localises Trash as "Bin"). Trade-off: a few Gmail Sent items can slip
        // in (they're also under All Mail), but they're "read" so unread-first
        // prioritisation sinks them — far better than hiding the whole inbox.
        let excludedExact: Set<String> = [
            "junk", "spam", "junk e-mail", "junk email", "bulk mail",
            "trash", "bin", "deleted messages", "deleted items", "deleted",
            "sent", "sent messages", "sent mail", "sent items",
            "drafts", "draft",
            "archive", "outbox",
        ]
        if excludedExact.contains(leaf) { return false }

        // Unambiguous tokens that are safe to match as substrings.
        for token in ["junk", "spam", "trash"] where leaf.contains(token) {
            return false
        }
        return true
    }

    /// Whether a mailbox URL is a Sent folder. Used by Follow-up Radar to learn
    /// the user's OWN addresses (senders of Sent mail) so it can tell which
    /// thread messages are outgoing vs incoming.
    static func isSentMailbox(_ url: String?) -> Bool {
        guard let url, !url.isEmpty else { return false }
        let rawLeaf = url.split(separator: "/").last.map(String.init) ?? ""
        let leaf = (rawLeaf.removingPercentEncoding ?? rawLeaf)
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        return ["sent", "sent messages", "sent mail", "sent items"].contains(leaf)
    }

    // MARK: - Fresh (WAL-aware) database open

    /// Open the Envelope Index read-only with FRESH data, reading through Mail's
    /// `-wal`. The old `immutable=1` open ignored the `-wal` and returned a
    /// stale snapshot — Mail can go days between checkpoints, which made the
    /// briefing miss all recent mail. Strategy:
    ///  1. A normal read-only connection reads through the `-wal` via the live
    ///     `-shm` index Mail keeps open — cheap and fresh while Mail is running
    ///     (the usual case). A probe query confirms the WAL is actually readable
    ///     (a `mode=ro` open of a WAL db fails the read rather than silently
    ///     serving stale data, so this can't regress to the old behaviour).
    ///  2. If that can't open/read (e.g. Mail isn't running, so there's no live
    ///     `-shm`), copy the db + `-wal` + `-shm` into a temp dir and open the
    ///     copy read-write, which replays the WAL into a fresh, consistent
    ///     snapshot without touching Mail's files. Caller deletes `tempDir`.
    private func openFreshDatabase(_ dbURL: URL) throws -> (db: OpaquePointer, tempDir: URL?) {
        var db: OpaquePointer?

        // 1. Live read-only through the WAL.
        let live = "file:\(dbURL.path)?mode=ro"
        if sqlite3_open_v2(live, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK,
           let handle = db, Self.canQueryMessages(handle) {
            return (handle, nil)
        }
        if db != nil { sqlite3_close(db); db = nil }

        // 2. Snapshot-copy fallback (Mail not running / WAL not live-readable).
        let tempDir = try copyDatabaseBundle(dbURL)
        let copyPath = tempDir.appendingPathComponent(dbURL.lastPathComponent).path
        if sqlite3_open_v2(copyPath, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
           let handle = db, Self.canQueryMessages(handle) {
            return (handle, tempDir)
        }
        if db != nil { sqlite3_close(db) }
        try? fileManager.removeItem(at: tempDir)
        throw ReadError.query("could not open Envelope Index (live read-only and snapshot copy both failed)")
    }

    /// Newest `date_received` in the store (raw, units undetermined) — used to
    /// detect whether the column is Mac-absolute or Unix epoch.
    private static func maxDateReceived(_ db: OpaquePointer) -> Double {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT COALESCE(MAX(date_received),0) FROM messages", -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return sqlite3_column_double(stmt, 0)
    }

    /// Probe that the `messages` table is actually readable — catches an open
    /// that "succeeds" but can't read the WAL.
    private static func canQueryMessages(_ db: OpaquePointer) -> Bool {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM messages LIMIT 1", -1, &stmt, nil) == SQLITE_OK else {
            return false
        }
        let rc = sqlite3_step(stmt)
        return rc == SQLITE_ROW || rc == SQLITE_DONE
    }

    /// Copy the Envelope Index and its `-wal`/`-shm` sidecars into a fresh temp
    /// directory so we can open a consistent, checkpointable snapshot without
    /// touching Mail's live files. Returns the temp dir (caller deletes it).
    private func copyDatabaseBundle(_ dbURL: URL) throws -> URL {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("crux-mail-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let base = dbURL.lastPathComponent
        let dir = dbURL.deletingLastPathComponent()
        for suffix in ["", "-wal", "-shm"] {
            let src = dir.appendingPathComponent(base + suffix)
            guard fileManager.fileExists(atPath: src.path) else { continue }
            try? fileManager.copyItem(at: src, to: tempDir.appendingPathComponent(base + suffix))
        }
        guard fileManager.fileExists(atPath: tempDir.appendingPathComponent(base).path) else {
            try? fileManager.removeItem(at: tempDir)
            throw ReadError.query("failed to copy Envelope Index for snapshot read")
        }
        return tempDir
    }

    private func resolveMailRoot() -> URL? {
        let base = URL(fileURLWithPath: ("~/Library/Mail" as NSString).expandingTildeInPath)
        guard let entries = try? fileManager.contentsOfDirectory(atPath: base.path) else {
            return nil
        }
        // Pick the newest "V{N}" directory — Apple bumps N across major OS versions.
        let versions = entries
            .filter { $0.hasPrefix("V") }
            .compactMap { name -> (Int, String)? in
                guard let n = Int(name.dropFirst()) else { return nil }
                return (n, name)
            }
            .sorted { $0.0 > $1.0 }
        guard let newest = versions.first else { return nil }
        return base.appendingPathComponent(newest.1)
    }

    private func columnText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let raw = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: raw)
    }

    /// Column names of a table, via PRAGMA. Used to keep the SELECT resilient
    /// to schema differences across macOS versions.
    private func tableColumns(_ db: OpaquePointer?, _ table: String) -> Set<String> {
        var names = Set<String>()
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table));", -1, &stmt, nil) == SQLITE_OK else {
            return names
        }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let raw = sqlite3_column_text(stmt, 1) {
                names.insert(String(cString: raw))
            }
        }
        return names
    }
}
