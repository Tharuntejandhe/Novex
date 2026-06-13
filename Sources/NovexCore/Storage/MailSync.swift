import Foundation
import AppKit
import os

/// Keeps mail flowing into Mail.app's local store without ever bothering the
/// user. Mail.app fetches new mail on its own schedule whenever it's running,
/// so all we need is for Mail to be running — we do NOT poke it with Apple
/// Events (an ad-hoc-signed background agent can't reliably get the Automation
/// prompt, and launching an app needs no permission at all).
///
/// Politeness rules:
/// - We only ever launch Mail if it isn't already running, and we launch it
///   in the background (no focus steal) then hide it.
/// - We NEVER hide or alter a Mail that's already running — if the user opened
///   it themselves, it's theirs. Novex never fights for the window.
enum MailSync {
    static let mailBundleID = "com.apple.mail"

    @MainActor
    static var runningMail: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: mailBundleID).first
    }

    @MainActor
    static var isMailRunning: Bool { runningMail != nil }

    /// Operational logging via the unified logging system. View with Console.app
    /// or `log stream --predicate 'subsystem == "com.tarun.novex"'`. No files on
    /// disk (the old world-readable /tmp/novex-sync.log is gone), privacy-aware,
    /// and ~free when nobody is listening.
    private static let logger = Logger(subsystem: "com.tarun.novex", category: "sync")
    static func log(_ message: String) {
        logger.debug("\(message, privacy: .public)")
    }

    /// If Mail isn't running, launch it hidden so it can sync in the
    /// background. Returns true if we launched it (caller may then allow a
    /// grace period for the first sync). No-op — and no side effects — if Mail
    /// is already running.
    @MainActor
    @discardableResult
    static func launchMailHiddenIfNeeded() async -> Bool {
        guard runningMail == nil else {
            log("launchMailHiddenIfNeeded: Mail already running, no-op")
            return false
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: mailBundleID) else {
            log("launchMailHiddenIfNeeded: could NOT resolve Mail app URL")
            return false
        }
        log("launchMailHiddenIfNeeded: launching Mail at \(url.path)")

        let config = NSWorkspace.OpenConfiguration()
        config.activates = false          // launch in the background, don't steal focus
        config.addsToRecentItems = false

        let launched: NSRunningApplication? = await withCheckedContinuation { cont in
            NSWorkspace.shared.openApplication(at: url, configuration: config) { app, _ in
                cont.resume(returning: app)
            }
        }

        // Tuck the freshly-launched instance away so its window never lingers
        // on screen. We hide twice because the window can appear a beat after
        // launch completes.
        if let launched {
            log("launchMailHiddenIfNeeded: launched OK (pid \(launched.processIdentifier)), hiding")
            launched.hide()
            try? await Task.sleep(nanoseconds: 600_000_000)
            launched.hide()
            return true
        }
        log("launchMailHiddenIfNeeded: openApplication returned nil app")
        return false
    }
}
