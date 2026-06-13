import Foundation

/// Local list of VIP senders — the inverse of `MuteStore`. VIP mail jumps to the
/// top of the briefing and always notifies, even on a busy day. On-device only.
enum VIPStore {
    private static let key = "vipSenders"

    static func all() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    static func isVIP(_ address: String?) -> Bool {
        guard let a = address?.lowercased(), !a.isEmpty else { return false }
        return all().contains(a)
    }

    static func add(_ address: String) {
        let a = address.lowercased()
        guard !a.isEmpty else { return }
        var s = all(); s.insert(a)
        UserDefaults.standard.set(Array(s), forKey: key)
    }

    static func remove(_ address: String) {
        var s = all(); s.remove(address.lowercased())
        UserDefaults.standard.set(Array(s), forKey: key)
    }

    /// The score bump a VIP sender gets in the briefing ranking — large enough to
    /// out-rank any combination of the normal importance signals.
    static let scoreBonus = 1000
}
