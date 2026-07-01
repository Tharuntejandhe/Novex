import Foundation
import ServiceManagement

/// Start-at-login, the modern Apple way (`SMAppService`, macOS 13+). No shell
/// scripts, no LaunchAgent plist for the end user — a single in-app toggle that
/// registers the app itself as a login item. Zero network, nothing to trust.
enum LoginItem {
    /// Is the app currently set to launch at login?
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// The macOS approval flow can leave it `.requiresApproval` (user must flip it
    /// on in System Settings > General > Login Items). Surface that to the UI.
    static var needsApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    /// Register / unregister the app as a login item. Returns false on failure
    /// (e.g. the user hasn't approved it in System Settings yet).
    @discardableResult
    static func setEnabled(_ on: Bool) -> Bool {
        do {
            let service = SMAppService.mainApp
            if on {
                if service.status != .enabled { try service.register() }
            } else {
                if service.status == .enabled { try service.unregister() }
            }
            return true
        } catch {
            NSLog("[Novex] LoginItem \(on ? "register" : "unregister") failed: \(error.localizedDescription)")
            return false
        }
    }
}
