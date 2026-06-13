import Foundation
import Observation
import CoreGraphics

/// Layout for the notification card. It's a self-contained rounded rectangle
/// (Dynamic-Island style) — NOT shaped to the notch — so it looks identical on
/// notched and non-notched displays.
enum PeekLayout {
    static let cardWidth: CGFloat = 384
    static let cardHeight: CGFloat = 62
    static let corner: CGFloat = 22
}

/// State for the notch — a NOTIFICATION surface only. It shows a brief "peek"
/// (e.g. new mail) under the notch that auto-dismisses. No hover, no expanding
/// panel: the full assistant lives in the menu-bar popover. Observed by `NotchView`.
@MainActor
@Observable
final class NotchModel {
    static let shared = NotchModel()
    private init() {}

    /// The notification currently dropping down under the notch; nil when none.
    var peek: PeekItem? = nil

    struct PeekItem: Equatable, Sendable {
        let icon: String
        let title: String
        let subtitle: String
        let messageID: String?
    }

    /// Fires the "fly to Novex" handoff (collapse peek → dot → travel). Set by AppDelegate.
    @ObservationIgnored var onTap: ((PeekItem) -> Void)?

    private var dismissTask: Task<Void, Never>?

    /// Show a new-mail notification under the notch. It WAITS for you to click it
    /// — clicking transforms it into the flying dot. If ignored, it just quietly
    /// collapses after a while (no fly).
    func showPeek(icon: String, title: String, subtitle: String, messageID: String? = nil, linger: Double = 8) {
        dismissTask?.cancel()
        peek = PeekItem(icon: icon, title: title, subtitle: subtitle, messageID: messageID)
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(linger * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.peek = nil          // collapse silently — never flies unless tapped
            self?.dismissTask = nil
        }
    }

    /// Hand the peek off to the flight — fired only when you TAP it. Idempotent.
    func trigger() {
        dismissTask?.cancel(); dismissTask = nil
        guard let p = peek else { return }
        peek = nil                 // the panel collapses as the dot takes over
        onTap?(p)
    }
}
