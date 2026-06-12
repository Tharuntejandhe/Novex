import Foundation
import Observation

/// Declutter — finds the newsletters/promos piling up in the inbox, grouped by
/// sender, with a one-tap unsubscribe (from the List-Unsubscribe header) and a
/// local "mute" (hide this sender across Crux). Fully on-device.
@MainActor
@Observable
final class DeclutterService {
    enum State: Equatable {
        case idle, scanning, ready, needsFullDiskAccess, error(String)
    }

    private(set) var state: State = .idle
    private(set) var report: DeclutterReport = .empty

    private let reader = MailReader()
    private var lastScan: Date = .distantPast

    func scanIfNeeded(maxAge: TimeInterval = 300) async {
        if state == .ready, Date().timeIntervalSince(lastScan) < maxAge { return }
        await scan()
    }

    func scan() async {
        guard reader.hasFullDiskAccess else { state = .needsFullDiskAccess; return }
        if state != .ready { state = .scanning }

        let reader = self.reader
        let now = Date()
        let since = now.addingTimeInterval(-Self.windowDays * 86_400)
        let messages: [MailMessage]
        do {
            messages = try await Task.detached(priority: .utility) {
                try reader.threadMessages(since: since)
            }.value
        } catch {
            state = .error(String(describing: error)); return
        }

        var senders = Self.groupNewsletters(from: messages, muted: MuteStore.all())
        let total = senders.reduce(0) { $0 + $1.count }
        let top = Array(senders.prefix(Self.maxSenders))

        // Read the List-Unsubscribe header from each top sender's latest .emlx
        // (file I/O — off the main actor).
        let rowids = top.map(\.latestRowID)
        let urls: [Int64: URL] = await Task.detached(priority: .utility) {
            reader.resolveUnsubscribeURLs(rowids: rowids)
        }.value
        senders = top.map { s in
            var s = s
            s.unsubscribeURL = urls[s.latestRowID]
            return s
        }

        report = DeclutterReport(senders: senders, totalCount: total, generatedAt: now)
        lastScan = now
        state = .ready
    }

    /// Mute a sender (hide across Crux) and drop it from the current report.
    func mute(_ sender: NewsletterSender) {
        MuteStore.mute(sender.address)
        report = DeclutterReport(
            senders: report.senders.filter { $0.id != sender.id },
            totalCount: max(0, report.totalCount - sender.count),
            generatedAt: report.generatedAt
        )
    }

    // MARK: - Pure classification (testable)

    static let windowDays: Double = 30
    static let maxSenders = 15

    /// Whether a message is newsletter/promo/bulk mail — i.e. clutter we can
    /// offer to unsubscribe from or mute. Uses Mail's own signals.
    nonisolated static func isNewsletter(_ m: MailMessage) -> Bool {
        if m.unsubscribeType > 0 { return true }   // Mail saw a List-Unsubscribe header
        if m.automatedType >= 2 { return true }     // automated/bulk conversation
        return false
    }

    /// Group inbox newsletter mail by sender, newest name wins, deduped by
    /// Message-ID (Gmail stores a copy under both INBOX and All Mail). Sorted by
    /// volume. Muted senders are excluded. Pure — no I/O.
    nonisolated static func groupNewsletters(from messages: [MailMessage], muted: Set<String>) -> [NewsletterSender] {
        var seen = Set<String>()
        var byAddr: [String: (name: String, count: Int, latest: MailMessage)] = [:]
        for m in messages {
            guard MailReader.isInboxMailbox(m.mailbox), isNewsletter(m) else { continue }
            guard let addr = m.senderAddress?.lowercased(), !addr.isEmpty else { continue }
            if muted.contains(addr) { continue }
            let dedupKey = m.messageID ?? "rid\(m.id)"
            if !seen.insert(dedupKey).inserted { continue }
            if let e = byAddr[addr] {
                let newer = m.dateReceived > e.latest.dateReceived
                byAddr[addr] = (newer ? m.senderDisplay : e.name, e.count + 1, newer ? m : e.latest)
            } else {
                byAddr[addr] = (m.senderDisplay, 1, m)
            }
        }
        return byAddr.map { addr, v in
            NewsletterSender(id: addr, name: v.name, address: addr, count: v.count,
                             unsubscribeURL: nil, latestMessageID: v.latest.messageID,
                             latestRowID: v.latest.id)
        }
        .sorted { $0.count > $1.count }
    }
}
