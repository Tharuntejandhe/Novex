import Foundation

/// A coarse, DETERMINISTIC category for a message — used by the assistant's
/// casual summary, the "Catch me up" digest, and learning. No LLM, so it can't
/// be "dumb"; it reads sender + Apple's unsubscribe flag + obvious subject cues.
enum MailCategory: String, Sendable, CaseIterable {
    case job, newsletter, social, update, personal

    var label: String {
        switch self {
        case .job:        return "Job alerts"
        case .newsletter: return "Newsletters"
        case .social:     return "Social"
        case .update:     return "Updates"
        case .personal:   return "Personal"
        }
    }

    var icon: String {
        switch self {
        case .job:        return "briefcase"
        case .newsletter: return "newspaper"
        case .social:     return "person.2"
        case .update:     return "bell"
        case .personal:   return "person.crop.circle"
        }
    }

    /// Singular/plural noun for prose ("a job alert" / "a few job alerts").
    var noun: (one: String, many: String) {
        switch self {
        case .job:        return ("job alert", "job alerts")
        case .newsletter: return ("newsletter", "newsletters")
        case .social:     return ("social ping", "social pings")
        case .update:     return ("update", "updates")
        case .personal:   return ("message", "messages")
        }
    }

    static func of(_ m: MailMessage) -> MailCategory {
        let from = (m.senderAddress ?? "").lowercased()
        let subj = m.subject.lowercased()

        if from.contains("naukri") || from.contains("indeed") || from.contains("jobs-listings")
            || from.contains("glassdoor") || from.contains("hirist") || from.contains("instahyre")
            || subj.contains("hiring") || subj.contains("job opportun") || subj.contains("are hiring")
            || subj.contains("new role") || subj.contains("apply now") {
            return .job
        }
        if from.contains("facebook") || from.contains("invitations@linkedin")
            || from.contains("instagram") || subj.contains("wants to connect")
            || subj.contains("friend suggestion") || subj.contains("new connection")
            || subj.contains("started following") || subj.contains("mentioned you") {
            return .social
        }
        if m.unsubscribeType > 0 || from.contains("beehiiv") || from.contains("substack")
            || from.contains("newsletter") || from.contains("mailchimp") || from.contains("noreply")
            || subj.contains("newsletter") || subj.contains("digest") || subj.contains("weekly") {
            return .newsletter
        }
        // Automated-but-uncategorized (GitHub, receipts, app notifications).
        if m.automatedType >= 2 { return .update }
        // Human, non-automated mail.
        return .personal
    }
}
