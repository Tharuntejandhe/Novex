import Foundation

/// Which side of a stalled thread the user is on.
enum FollowUpKind: Sendable, Equatable {
    case needsReply   // someone emailed; the user hasn't replied (ball is theirs)
    case waitingOn    // the user replied last; no answer yet (ball is the other side's)
}

/// One stalled thread surfaced by Follow-up Radar. Carries the latest message so
/// the row can deep-link to Mail and (for `needsReply`) feed Smart Reply.
struct FollowUpItem: Identifiable, Equatable, Sendable {
    /// The anchor message: for `needsReply` it's their latest (what you reply
    /// to); for `waitingOn` it's your last sent message.
    let message: MailMessage
    /// The human on the other side of the thread.
    let counterpartName: String
    let kind: FollowUpKind

    var id: String { message.messageID ?? "rid\(message.id)" }
    var subject: String { message.subject }
    var lastDate: Date { message.dateReceived }
}

/// A short "catch me up" summary of a thread, produced on-device.
struct ThreadDigest: Codable, Equatable, Sendable {
    var bullets: [String]
}

/// Result Follow-up Radar binds to: two short lists of stalled threads.
struct FollowUpReport: Equatable, Sendable {
    let needsReply: [FollowUpItem]
    let waitingOn: [FollowUpItem]
    let generatedAt: Date

    static let empty = FollowUpReport(needsReply: [], waitingOn: [], generatedAt: .distantPast)
    var isEmpty: Bool { needsReply.isEmpty && waitingOn.isEmpty }
    var total: Int { needsReply.count + waitingOn.count }
}
