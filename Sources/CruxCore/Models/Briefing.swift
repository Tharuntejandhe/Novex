import Foundation

struct MailMessage: Identifiable, Hashable, Sendable {
    let id: Int64
    let dateReceived: Date
    let isRead: Bool
    let isFlagged: Bool
    let subject: String
    let senderName: String?
    let senderAddress: String?
    let mailbox: String?
    /// RFC 2822 Message-ID (with or without angle brackets); nil if the
    /// Envelope Index didn't expose one. Used to deep-link into Mail.app.
    let messageID: String?

    // --- Real content + Apple's own signals (macOS 26+; defaults keep older
    //     callers and tests working) ---

    /// Short body preview from Mail's `summaries` table — REAL content, not just
    /// the subject. This is what lets the assistant actually understand an email.
    /// nil when unavailable (older macOS / not yet summarized).
    var snippet: String? = nil
    /// Apple's own "this needs attention" flag.
    var isUrgent: Bool = false
    /// Apple's automated-conversation classification (0 = human-written; higher =
    /// bulk/automated/no-reply). Used to deprioritize newsletter/robot noise.
    var automatedType: Int = 0
    /// >0 when Mail detected an unsubscribe header (i.e. a newsletter/promo).
    var unsubscribeType: Int = 0

    // --- Apple's own ML analysis (message_global_data, macOS 26+) ---

    /// Apple Intelligence flagged this as a high-impact message.
    var isHighImpact: Bool = false
    /// Apple detected this needs a follow-up / reply from you.
    var needsFollowUp: Bool = false
    /// Apple's email category (Primary/Transactions/Updates/Promotions — raw int).
    var category: Int = 0

    /// Mail's conversation/thread id — groups a back-and-forth into one thread.
    /// nil on schemas without it (then Follow-up Radar falls back to subject).
    var conversationID: Int64? = nil

    var senderDisplay: String {
        if let name = senderName, !name.isEmpty { return name }
        return senderAddress ?? "Unknown"
    }

    /// Deterministic importance score — the rules engine. This is the "what
    /// matters" logic that runs in CODE (never the model), built on Apple's own
    /// ML signals plus the obvious cues. Higher = more likely to need you.
    var importanceScore: Int {
        var s = 0
        if isUrgent       { s += 100 }
        if isHighImpact   { s += 80 }
        if needsFollowUp  { s += 60 }
        if !isRead        { s += 40 }
        if isFlagged      { s += 30 }
        // Automated / bulk / newsletter mail is NOISE, not signal. Penalize it
        // hard enough that an unread newsletter (+40 for unread) still lands
        // NEGATIVE — otherwise the briefing fills with job-alert blasts and
        // "you missed something" newsletters and looks dumb. A genuinely
        // high-impact automated mail (bank alert, 2FA) still surfaces via its
        // +80 high-impact bump.
        if automatedType >= 2 { s -= 45 }   // clearly automated / no-reply / bulk
        if unsubscribeType > 0 { s -= 35 }  // newsletter / promo (has List-Unsubscribe)
        // no-reply / 2FA / "via Slack" notifications — Apple's automated flag
        // misses many of these (Fiverr tax doc, Vercel sign-in), so catch them
        // by sender. They are NEVER "needs you".
        if isNotificationSender { s -= 50 }
        return s
    }

    /// A no-reply / notification / bot sender (Fiverr `noreply@`, Vercel 2FA,
    /// "X via Slack/LinkedIn", mailer-daemon…). You can't meaningfully reply to
    /// these, and they should NEVER be featured as "needs you". Single source of
    /// truth used by ranking, the reply gate, and follow-ups.
    var isNotificationSender: Bool {
        let addr = (senderAddress ?? "").lowercased()
        let name = (senderName ?? "").lowercased()
        if name.contains("via slack") || name.contains("via linkedin")
            || name.contains("via facebook") || name.contains("via teams")
            || name.contains("notification") { return true }
        let needles = [
            "noreply", "no-reply", "no_reply", "no.reply", "noreply-",
            "donotreply", "do-not-reply", "do_not_reply",
            "notifications", "notification", "notify@", "notify-",
            "mailer-daemon", "mailerdaemon", "bounce", "postmaster",
            "automated", "auto-confirm", "auto_confirm",
            "security@", "alerts@", "alert@", "@alerts.", "no-reply@",
        ]
        return needles.contains { addr.contains($0) }
    }

    /// Can the user actually write a human reply to this? (Real person, not a bot.)
    var isReplyable: Bool { !isNotificationSender }

    /// Whether this mail is worth FEATURING in the briefing (vs. de-emphasizing
    /// as "recent" noise). Human mail, flagged, urgent, or Apple-flagged
    /// high-impact clears the bar; automated newsletters/alerts/notifications don't.
    var isImportant: Bool { importanceScore >= 30 }

    /// Subject + body snippet, for feeding the model real content. Falls back to
    /// just the subject when no snippet is available.
    var contentForModel: String {
        guard let s = snippet?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else {
            return subject
        }
        return "\(subject) — \(s.prefix(280))"
    }
}

struct BriefingItem: Identifiable, Hashable {
    let id: UUID
    let icon: String
    let title: String
    let detail: String
    let action: AIAction
    let isNew: Bool
    let messageID: String?

    init(
        id: UUID = UUID(),
        icon: String,
        title: String,
        detail: String,
        action: AIAction = .none,
        isNew: Bool = false,
        messageID: String? = nil
    ) {
        self.id = id
        self.icon = icon
        self.title = title
        self.detail = detail
        self.action = action
        self.isNew = isNew
        self.messageID = messageID
    }

    /// A `message://` URL that opens this exact message in Mail.app, or nil if
    /// we don't have a usable Message-ID. Mail marks the message read when it
    /// opens, so tapping doubles as "mark read".
    var mailURL: URL? {
        guard let messageID else { return nil }
        let core = messageID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !core.isEmpty,
              let encoded = core.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        else { return nil }
        // Angle brackets are encoded as %3C / %3E per the message: scheme.
        return URL(string: "message://%3C\(encoded)%3E")
    }
}

struct Briefing: Equatable {
    let generatedAt: Date
    let items: [BriefingItem]
    let totalUnread: Int
    let summary: String?
    /// How many messages were genuinely important (worth featuring). 0 means the
    /// inbox is just noise → show the calm "caught up" state, not fake analysis.
    var importantCount: Int = 0

    static let empty = Briefing(generatedAt: .distantPast, items: [], totalUnread: 0, summary: nil)
}
