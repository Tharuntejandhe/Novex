import Foundation

/// Tiny on-device retrieval for "Ask Crux". Instead of feeding the model only
/// the newest few emails, we score the whole recent pool against the question
/// and hand the model the most RELEVANT messages — so "when did the bank email
/// about the loan?" finds the right mail even if it's weeks old. Pure + testable.
enum MailRetrieval {
    /// Words too common to carry meaning — dropped from the query and the haystack.
    static let stopwords: Set<String> = [
        "the", "a", "an", "is", "are", "was", "were", "be", "been", "being",
        "what", "when", "who", "whom", "where", "why", "how", "which",
        "did", "do", "does", "done", "has", "have", "had",
        "my", "me", "i", "we", "us", "our", "you", "your", "they", "them",
        "to", "of", "in", "on", "at", "for", "about", "from", "with", "by",
        "and", "or", "but", "that", "this", "these", "those", "it", "its",
        "any", "some", "all", "can", "could", "would", "should", "will",
        "tell", "show", "find", "get", "say", "said", "email", "emails", "mail",
        "message", "messages", "inbox", "anything",
    ]

    /// Lowercase, split on non-alphanumerics, drop stopwords and 1-char tokens.
    static func tokens(_ s: String) -> [String] {
        s.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 2 && !stopwords.contains($0) }
    }

    /// Rank `messages` by relevance to `question`, returning the top `limit`.
    /// Scoring favors how many DISTINCT query terms a message matches (coverage),
    /// then total hits, with a small recency tiebreaker. When the question has no
    /// content words (e.g. "what's my recent mail?"), or nothing matches, falls
    /// back to recency so those queries still work.
    static func rank(question: String, messages: [MailMessage], limit: Int) -> [MailMessage] {
        let qTerms = Set(tokens(question))
        let byRecency = messages.sorted { $0.dateReceived > $1.dateReceived }
        guard !qTerms.isEmpty else { return Array(byRecency.prefix(limit)) }

        func haystack(_ m: MailMessage) -> [String] {
            tokens(m.subject + " " + (m.senderName ?? "") + " "
                   + (m.senderAddress ?? "") + " " + (m.snippet ?? ""))
        }

        let scored: [(m: MailMessage, score: Int)] = messages.map { m in
            let hay = haystack(m)
            guard !hay.isEmpty else { return (m, 0) }
            let haySet = Set(hay)
            let coverage = haySet.intersection(qTerms).count        // distinct terms matched
            let hits = hay.filter { qTerms.contains($0) }.count     // total occurrences
            return (m, coverage * 10 + hits)
        }

        let matched = scored.filter { $0.score > 0 }
            .sorted { ($0.score, $0.m.dateReceived) > ($1.score, $1.m.dateReceived) }
        if matched.isEmpty { return Array(byRecency.prefix(limit)) }
        return matched.prefix(limit).map(\.m)
    }
}
