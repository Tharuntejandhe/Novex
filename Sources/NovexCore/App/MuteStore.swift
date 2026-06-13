import Foundation

/// A local, on-device list of senders the user has muted. Novex can't (and won't)
/// touch the Mail store, so "mute" means: stop surfacing this sender in Novex's
/// own views (briefing, follow-ups, declutter). Persisted in UserDefaults.
enum MuteStore {
    private static let key = "mutedSenders"

    static func all() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    static func isMuted(_ address: String?) -> Bool {
        guard let a = address?.lowercased(), !a.isEmpty else { return false }
        return all().contains(a)
    }

    static func mute(_ address: String) {
        let a = address.lowercased()
        guard !a.isEmpty else { return }
        var s = all(); s.insert(a)
        UserDefaults.standard.set(Array(s), forKey: key)
    }

    static func unmute(_ address: String) {
        var s = all(); s.remove(address.lowercased())
        UserDefaults.standard.set(Array(s), forKey: key)
    }
}
