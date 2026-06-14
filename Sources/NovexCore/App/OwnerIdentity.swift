import Foundation

/// The user's own email addresses — so Novex knows when mail is FROM you (a note
/// to yourself, never a conversation that "needs a reply", never a draft back to
/// yourself). Sourced from (1) an address set in onboarding/Settings and
/// (2) addresses auto-learned from your Sent mailbox. Persisted, merge-only.
enum OwnerIdentity {
    private static let key = "novex.ownerEmails"

    static var addresses: Set<String> {
        Set((UserDefaults.standard.stringArray(forKey: key) ?? []).map { $0.lowercased() })
    }

    /// Merge newly-discovered/declared addresses into the persisted set.
    static func learn<S: Sequence>(_ addrs: S) where S.Element == String {
        let incoming = Set(addrs
            .map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
            .filter { $0.contains("@") && $0.count <= 254 })
        guard !incoming.isEmpty else { return }
        let merged = addresses.union(incoming)
        if merged != addresses {
            UserDefaults.standard.set(Array(merged).sorted(), forKey: key)
        }
    }

    static func isSelf(_ address: String?) -> Bool {
        guard let a = address?.lowercased() else { return false }
        return addresses.contains(a)
    }
}
