import Foundation

/// On-device behavioral learning: which senders the user OPENS vs. ignores.
/// Drives a ranking nudge (surface what you read, sink what you skip) and
/// "you keep ignoring X — mute it?" suggestions. Privacy: counts only, in
/// UserDefaults; nothing leaves the Mac.
enum LearnStore {
    private static let opensKey = "learn.opens"
    private static let seenKey = "learn.seen"

    private static func load(_ key: String) -> [String: Int] {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: Int]) ?? [:]
    }
    private static func save(_ d: [String: Int], _ key: String) {
        UserDefaults.standard.set(d, forKey: key)
    }

    private static func norm(_ s: String?) -> String? {
        guard let s = s?.lowercased(), !s.isEmpty else { return nil }
        return s
    }

    /// The user opened mail from this sender — a strong "I care" signal.
    static func recordOpen(_ sender: String?) {
        guard let s = norm(sender) else { return }
        var o = load(opensKey); o[s, default: 0] += 1; save(o, opensKey)
    }

    /// These senders were shown in the briefing/recent (so we can tell
    /// "shown a lot but never opened" from "never shown").
    static func recordSeen(_ senders: [String]) {
        guard !senders.isEmpty else { return }
        var seen = load(seenKey)
        for s in senders { if let n = norm(s) { seen[n, default: 0] += 1 } }
        save(seen, seenKey)
    }

    static func opens(_ sender: String?) -> Int { norm(sender).flatMap { load(opensKey)[$0] } ?? 0 }
    static func seen(_ sender: String?) -> Int { norm(sender).flatMap { load(seenKey)[$0] } ?? 0 }

    /// Ranking nudge: boost senders the user actually opens; gently sink senders
    /// shown often but never opened. Pure-ish (reads UserDefaults). VIP/Mute
    /// still override; this is a soft signal on top.
    static func affinity(_ sender: String?) -> Int {
        guard let s = norm(sender) else { return 0 }
        let o = load(opensKey)[s] ?? 0
        let n = load(seenKey)[s] ?? 0
        if o >= 2 { return min(35, 10 + o * 5) }    // you open this → surface it
        if n >= 6 && o == 0 { return -15 }           // shown a lot, never opened → sink
        return 0
    }

    /// Senders the user has clearly been ignoring — candidates to suggest muting.
    static func ignoredSuggestions(minSeen: Int = 8, limit: Int = 5) -> [String] {
        let opens = load(opensKey), seen = load(seenKey)
        return seen
            .filter { $0.value >= minSeen && (opens[$0.key] ?? 0) == 0 && !MuteStore.isMuted($0.key) }
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map(\.key)
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: opensKey)
        UserDefaults.standard.removeObject(forKey: seenKey)
    }
}
