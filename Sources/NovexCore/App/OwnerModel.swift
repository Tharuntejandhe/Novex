import Foundation

/// Novex's evolving model of its OWNER — what you actually care about — learned
/// DETERMINISTICALLY from your behavior (mail you open in Novex + mail you star),
/// never from an LLM guess. It accumulates interest "tokens" (robotics, vision,
/// invoice, landlord…) and uses them to (a) nudge ranking toward what you care
/// about and (b) tell you what it's learned. On-device, counts only.
enum OwnerModel {
    private static let interestsKey = "owner.interests"   // token → weight
    private static let learnedKey = "owner.learnedIDs"    // messages already counted

    // MARK: - Token extraction

    /// The few meaningful tokens of a message (subject + snippet), stopwords and
    /// bare numbers dropped, deduped, capped.
    static func tokens(of m: MailMessage) -> [String] {
        let raw = MailRetrieval.tokens(m.subject + " " + (m.snippet ?? ""))
        var seen = Set<String>(); var out: [String] = []
        for t in raw where !t.allSatisfy(\.isNumber) {
            if seen.insert(t).inserted { out.append(t) }
            if out.count >= 8 { break }
        }
        return out
    }

    // MARK: - Learning

    /// You opened this in Novex — a strong "I care" signal.
    static func learnOpened(_ m: MailMessage) {
        addTokens(tokens(of: m), weight: 3)
        markLearned(m.messageID ?? "rid\(m.id)")
    }

    /// You starred/flagged these — learn from each one once (deduped by id).
    static func learnFlagged(_ messages: [MailMessage]) {
        let already = Set(learnedIDs())
        var fresh: [String] = []
        for m in messages where m.isFlagged {
            let id = m.messageID ?? "rid\(m.id)"
            guard !already.contains(id), !fresh.contains(id) else { continue }
            addTokens(tokens(of: m), weight: 2)
            fresh.append(id)
        }
        if !fresh.isEmpty { markLearned(fresh) }
    }

    /// Seed interests from a setup/Settings field (e.g. "robotics, computer
    /// vision, startups"). Weighted so they count immediately for Discover +
    /// ranking, without waiting for behavior to accumulate.
    static func seedInterests(_ phrase: String) {
        let toks = MailRetrieval.tokens(phrase).filter { !$0.allSatisfy(\.isNumber) }
        addTokens(Array(toks.prefix(20)), weight: 4)
    }

    // MARK: - Using it

    /// The owner's profile — top interest tokens, strongest first.
    static func interests(top: Int = 8, minWeight: Int = 3) -> [String] {
        interestMap()
            .filter { $0.value >= minWeight }
            .sorted { $0.value > $1.value }
            .prefix(top).map(\.key)
    }

    /// How well a message matches the owner's interests → a small ranking bonus.
    static func score(_ m: MailMessage) -> Int {
        let profile = Set(interests(top: 24, minWeight: 2))
        guard !profile.isEmpty else { return 0 }
        let overlap = Set(tokens(of: m)).intersection(profile).count
        return min(20, overlap * 5)
    }

    static func matches(_ m: MailMessage) -> Bool { score(m) >= 10 }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: interestsKey)
        UserDefaults.standard.removeObject(forKey: learnedKey)
    }

    // MARK: - Storage

    private static func interestMap() -> [String: Int] {
        (UserDefaults.standard.dictionary(forKey: interestsKey) as? [String: Int]) ?? [:]
    }
    private static func learnedIDs() -> [String] {
        UserDefaults.standard.stringArray(forKey: learnedKey) ?? []
    }
    private static func addTokens(_ ts: [String], weight: Int) {
        guard !ts.isEmpty else { return }
        var m = interestMap()
        for t in ts { m[t, default: 0] += weight }
        if m.count > 220 {   // prune so it can't grow unbounded
            m = Dictionary(uniqueKeysWithValues:
                m.sorted { $0.value > $1.value }.prefix(160).map { ($0.key, $0.value) })
        }
        UserDefaults.standard.set(m, forKey: interestsKey)
    }
    private static func markLearned(_ id: String) { markLearned([id]) }
    private static func markLearned(_ ids: [String]) {
        var all = learnedIDs()
        for id in ids where !all.contains(id) { all.append(id) }
        if all.count > 700 { all = Array(all.suffix(700)) }
        UserDefaults.standard.set(all, forKey: learnedKey)
    }
}
