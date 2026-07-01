import Foundation

/// A sender that's piling up newsletter/promo mail in the inbox.
struct NewsletterSender: Identifiable, Equatable, Sendable {
    let id: String                // lowercased address (stable key)
    let name: String              // display name (or address)
    let address: String
    let count: Int                // how many in the scan window
    var unsubscribeURL: URL?      // from List-Unsubscribe, when we could read it
    let latestMessageID: String?  // deep-link to the latest one
    let latestRowID: Int64        // newest message (for the deep-link)
    let unsubscribeRowID: Int64?  // newest message that ACTUALLY carries a List-Unsubscribe header
}

/// Result Declutter binds to.
struct DeclutterReport: Equatable, Sendable {
    let senders: [NewsletterSender]
    let totalCount: Int           // total newsletter emails across all senders
    let generatedAt: Date

    static let empty = DeclutterReport(senders: [], totalCount: 0, generatedAt: .distantPast)
    var isEmpty: Bool { senders.isEmpty }
}
