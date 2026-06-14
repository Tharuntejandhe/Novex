import Foundation

/// Items the user has explicitly marked "done" / dismissed from the briefing.
/// Lets you clear something you've already handled OUTSIDE of mail (e.g. you set
/// up GitHub 2FA on the site without ever opening the email, so "read" can't tell
/// it's done). Persisted by Message-ID; the item stays searchable in Q&A, it just
/// stops being featured as "needs you".
enum DismissStore {
    private static let key = "novex.dismissedMessageIDs"
    private static let cap = 500   // keep the list bounded

    static func dismissed() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    static func isDismissed(_ id: String?) -> Bool {
        guard let id else { return false }
        return dismissed().contains(id)
    }

    static func dismiss(_ id: String?) {
        guard let id, !id.isEmpty else { return }
        var arr = UserDefaults.standard.stringArray(forKey: key) ?? []
        guard !arr.contains(id) else { return }
        arr.append(id)
        if arr.count > cap { arr.removeFirst(arr.count - cap) }
        UserDefaults.standard.set(arr, forKey: key)
    }

    static func restore(_ id: String?) {
        guard let id else { return }
        let arr = (UserDefaults.standard.stringArray(forKey: key) ?? []).filter { $0 != id }
        UserDefaults.standard.set(arr, forKey: key)
    }
}
