import Foundation
import Observation

/// Builds the Money Radar report from the local mail store. Runs detection
/// off the main actor; caches the last report; refreshes lazily.
///
/// Privacy: like the rest of Crux this only ever reads the local Mail store.
/// No bank connection, no network — the entire reason the product exists.
@MainActor
@Observable
public final class MoneyRadarService {
    public enum State: Equatable {
        case idle
        case scanning
        case ready
        case needsFullDiskAccess
        case empty            // scanned, found nothing
        case error(String)
    }

    public private(set) var state: State = .idle
    public private(set) var report: MoneyRadarReport = .empty

    private let mailReader = MailReader()
    /// How far back to look. A wide window improves billing-cycle inference
    /// (we can see ~monthly receipts repeat). 400 days ≈ 13 months catches
    /// yearly renewals too.
    private let lookbackDays: Double = 400
    private let maxMessages = 1500

    public init() {}

    /// Scan if we have no report yet, or if `force` is set.
    /// Realistic fake subscriptions for marketing screenshots (CRUX_DEMO_MODE).
    static func demoReport() -> MoneyRadarReport {
        let now = Date()
        func d(_ days: Int) -> Date { now.addingTimeInterval(Double(days) * 86_400) }
        func sub(_ key: String, _ name: String, _ cat: SubscriptionCategory, _ amt: Double,
                 _ cycle: BillingCycle, trial: Bool = false, renew: Int) -> Subscription {
            Subscription(merchantKey: key, displayName: name, category: cat, amount: amt,
                         currencyCode: "USD", amountSource: .parsedFromEmail, cycle: cycle,
                         lastSeen: now, messageCount: trial ? 1 : 2, isTrialConverting: trial,
                         nextRenewal: d(renew), sourceMessageID: nil)
        }
        return MoneyRadarReport(subscriptions: [
            sub("notion-ai", "Notion AI", .ai, 10, .monthly, trial: true, renew: 2),
            sub("chatgpt", "ChatGPT Plus", .ai, 20, .monthly, renew: 9),
            sub("netflix", "Netflix", .streaming, 15.49, .monthly, renew: 6),
            sub("adobe-cc", "Adobe Creative Cloud", .software, 59.99, .monthly, renew: 14),
            sub("spotify", "Spotify Premium", .streaming, 11.99, .monthly, renew: 21),
            sub("icloud", "iCloud+", .cloud, 2.99, .monthly, renew: 4),
        ], generatedAt: now)
    }

    public func scanIfNeeded(force: Bool = false) async {
        if case .scanning = state { return }
        if !force, case .ready = state { return }
        await scan()
    }

    public func scan() async {
        // Demo mode (screenshots only): realistic fake subscriptions, real UI.
        if UserDefaults.standard.bool(forKey: "CRUX_DEMO_MODE") {
            report = Self.demoReport(); state = .ready; return
        }
        guard mailReader.hasFullDiskAccess, mailReader.mailIsConfigured else {
            state = .needsFullDiskAccess
            return
        }
        state = .scanning

        let reader = mailReader
        let cutoff = Date().addingTimeInterval(-lookbackDays * 86_400)
        let cap = maxMessages
        let now = Date()

        let subs: [Subscription]
        do {
            subs = try await Task.detached(priority: .utility) {
                let messages = try reader.recentMessages(since: cutoff, limit: cap)
                // v2: pre-filter to plausible billing emails (subject/sender only),
                // then fetch ONLY their bodies — we can't open 1500 files — so the
                // detector reads the REAL charged amount from the receipt instead
                // of a catalog estimate.
                let candidates = messages.filter { SubscriptionDetector.isLikelyCandidate($0) }
                let withBodies = reader.attachBodies(to: candidates)
                return SubscriptionDetector.detect(from: withBodies, now: now)
            }.value
        } catch {
            state = .error(String(describing: error))
            return
        }

        report = MoneyRadarReport(subscriptions: subs, generatedAt: now)
        state = subs.isEmpty ? .empty : .ready
    }
}
