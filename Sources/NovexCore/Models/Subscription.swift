import Foundation

/// How often a subscription bills. `.unknown` when we can't tell yet.
public enum BillingCycle: String, Codable, Equatable, Sendable {
    case weekly, monthly, quarterly, yearly, unknown

    /// Multiplier to convert one charge at this cycle into a yearly figure.
    var perYear: Double {
        switch self {
        case .weekly:    return 52
        case .monthly:   return 12
        case .quarterly: return 4
        case .yearly:    return 1
        case .unknown:   return 12   // assume monthly when unsure (conservative-ish)
        }
    }

    var label: String {
        switch self {
        case .weekly:    return "weekly"
        case .monthly:   return "monthly"
        case .quarterly: return "quarterly"
        case .yearly:    return "yearly"
        case .unknown:   return "monthly?"
        }
    }
}

/// Where a subscription's amount came from — drives the UI's confidence cue
/// and whether we show "est." next to the price.
public enum AmountSource: String, Codable, Equatable, Sendable {
    case parsedFromEmail   // a real number we read out of the subject/body
    case estimatedFromCatalog // a typical price from the built-in merchant catalog
    case unknown
}

/// One detected recurring service. Built purely from local mail metadata —
/// nothing here ever required a bank connection or the network.
public struct Subscription: Identifiable, Equatable, Sendable {
    public var id: String { merchantKey }

    /// Stable key for dedup/grouping (normalized service identity).
    public let merchantKey: String
    public let displayName: String
    public let category: SubscriptionCategory

    /// Amount per `cycle`, in `currencyCode`. nil when totally unknown.
    public let amount: Double?
    public let currencyCode: String
    public let amountSource: AmountSource
    public let cycle: BillingCycle

    /// Most recent related message date (for "last seen" / sorting).
    public let lastSeen: Date
    /// Number of related emails we collapsed into this subscription.
    public let messageCount: Int

    /// Trial that will convert to paid — the highest-value "act now" signal.
    public let isTrialConverting: Bool
    /// Parsed upcoming renewal/charge date, when we found one.
    public let nextRenewal: Date?

    /// Message-ID of the most relevant source email, for "open in Mail".
    public let sourceMessageID: String?

    public init(
        merchantKey: String,
        displayName: String,
        category: SubscriptionCategory,
        amount: Double?,
        currencyCode: String,
        amountSource: AmountSource,
        cycle: BillingCycle,
        lastSeen: Date,
        messageCount: Int,
        isTrialConverting: Bool,
        nextRenewal: Date?,
        sourceMessageID: String?
    ) {
        self.merchantKey = merchantKey
        self.displayName = displayName
        self.category = category
        self.amount = amount
        self.currencyCode = currencyCode
        self.amountSource = amountSource
        self.cycle = cycle
        self.lastSeen = lastSeen
        self.messageCount = messageCount
        self.isTrialConverting = isTrialConverting
        self.nextRenewal = nextRenewal
        self.sourceMessageID = sourceMessageID
    }

    /// Yearly cost of this single subscription (0 when amount unknown).
    public var yearlyCost: Double {
        guard let amount else { return 0 }
        return amount * cycle.perYear
    }
}

public enum SubscriptionCategory: String, Codable, Equatable, Sendable, CaseIterable {
    case streaming      // Netflix, Spotify, YouTube…
    case software       // Adobe, Microsoft 365, 1Password…
    case ai             // ChatGPT, Claude, Copilot…
    case news           // NYTimes, Substack, Medium…
    case shopping       // Prime, Walmart+, DashPass…
    case gaming         // Game Pass, PS Plus…
    case fitness        // Strava, Calm, Peloton…
    case cloud          // iCloud+, Google One, Dropbox…
    case finance        // paid finance tools
    case other

    var sfSymbol: String {
        switch self {
        case .streaming: return "play.tv"
        case .software:  return "app.badge"
        case .ai:        return "sparkles"
        case .news:      return "newspaper"
        case .shopping:  return "cart"
        case .gaming:    return "gamecontroller"
        case .fitness:   return "figure.run"
        case .cloud:     return "icloud"
        case .finance:   return "creditcard"
        case .other:     return "repeat.circle"
        }
    }
}

/// The aggregate result the UI binds to.
public struct MoneyRadarReport: Equatable, Sendable {
    public let subscriptions: [Subscription]
    public let generatedAt: Date

    public init(subscriptions: [Subscription], generatedAt: Date) {
        self.subscriptions = subscriptions
        self.generatedAt = generatedAt
    }

    public static let empty = MoneyRadarReport(subscriptions: [], generatedAt: .distantPast)

    /// Total estimated yearly spend — ONLY in `primaryCurrency`. Summing ₹ and
    /// $ into one number is meaningless (it once read "$23,37,900/yr" because a
    /// rupee amount was added to a dollar total). Other-currency subscriptions
    /// still show their own price per-row; they're just not in this headline.
    public var totalYearly: Double {
        let cur = primaryCurrency
        return subscriptions
            .filter { $0.currencyCode == cur }
            .reduce(0) { $0 + $1.yearlyCost }
    }

    /// Subscriptions whose free trial is about to convert to paid.
    public var convertingTrials: [Subscription] {
        subscriptions.filter(\.isTrialConverting)
    }

    /// Currency for the headline total — the one MOST of your subscriptions use.
    /// (Must NOT compare raw cross-currency sums: ₹3,588 > $186 numerically would
    /// wrongly pick INR and drop the bigger real spend. Count is FX-free and safe.)
    /// Ties broken by higher total. Defaults to USD.
    public var primaryCurrency: String {
        let priced = subscriptions.filter { $0.yearlyCost > 0 }
        let byCurrency = Dictionary(grouping: priced, by: \.currencyCode)
        return byCurrency.max(by: { a, b in
            if a.value.count != b.value.count { return a.value.count < b.value.count }
            return a.value.reduce(0){$0+$1.yearlyCost} < b.value.reduce(0){$0+$1.yearlyCost}
        })?.key ?? "USD"
    }

    /// True when subscriptions span more than one currency — the headline total
    /// then covers only `primaryCurrency`, and the UI says so.
    public var hasMixedCurrencies: Bool {
        Set(subscriptions.filter { $0.yearlyCost > 0 }.map(\.currencyCode)).count > 1
    }
}
