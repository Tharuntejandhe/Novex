import Foundation

/// LLM-curated briefing. We ask the on-device model to return JSON in this
/// shape so we get categorized, prioritized items instead of raw subjects.
struct AIBriefing: Codable, Equatable {
    var headline: String
    var items: [AIBriefingItem]
}

struct AIBriefingItem: Codable, Equatable {
    /// 1-based index of the email this item refers to, from the numbered list
    /// we hand the model. Lets us map an AI item back to the EXACT source
    /// message (for the deep-link / "new" flag) instead of assuming the model
    /// preserved input order. Optional so a model that omits it degrades to
    /// "drop this item" rather than failing the whole decode.
    var sourceIndex: Int?
    var title: String
    var detail: String
    var category: AICategory
    var priority: AIPriority
    var action: AIAction

    enum CodingKeys: String, CodingKey {
        case sourceIndex = "index"
        case title, detail, category, priority, action
    }
}

enum AICategory: String, Codable, Equatable {
    case work, finance, social, promo, personal, security, calendar, other
}

enum AIPriority: String, Codable, Equatable {
    case high, medium, low
}

enum AIAction: String, Codable, Equatable {
    case reply, pay, confirm, read, review, ignore, none

    var displayLabel: String {
        switch self {
        case .reply:   return "Reply"
        case .pay:     return "Pay"
        case .confirm: return "Confirm"
        case .read:    return "Read"
        case .review:  return "Review"
        case .ignore:  return "Ignore"
        case .none:    return ""
        }
    }

    var isActionable: Bool { self != .none && self != .ignore }

    /// Whether to show an action pill — only genuinely actionable verbs. "read"
    /// is just "informational" and was cluttering every row with a "Read" tag.
    var showsPill: Bool { [.reply, .pay, .confirm, .review].contains(self) }
}
