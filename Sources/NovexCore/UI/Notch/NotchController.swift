import AppKit
import SwiftUI
import Observation

/// Owns the notch notification window. A borderless, all-Spaces panel pinned to
/// the top-center of the notched screen, hosting `NotchView`. It's click-through
/// EXCEPT over a live peek (which you tap to fly the notification to Novex).
@MainActor
public final class NotchController {
    private var panel: NSPanel?
    private var container: PassthroughView?
    /// Pending "order the notch window off screen" after a card collapses —
    /// delayed so the fade-out finishes (no lingering shadow), cancellable if a
    /// new peek arrives first.
    private var hideWork: DispatchWorkItem?
    private let model = NotchModel.shared
    private var geometry: NotchGeometry
    private let panelSize: CGSize
    /// Gap from the screen top down to the card — clears the menu bar on ANY
    /// display (computed, not tied to the notch).
    private let topGap: CGFloat

    public init() {
        geometry = Self.detect()
        let menuBar = max(0, geometry.screen.frame.maxY - geometry.screen.visibleFrame.maxY)
        topGap = menuBar + 4
        panelSize = CGSize(width: PeekLayout.cardWidth + 44,
                           height: topGap + PeekLayout.cardHeight + 30)
    }

    /// Center of the notification card, in SCREEN coordinates — where the flying
    /// dot launches from.
    public var notchAnchor: CGPoint {
        CGPoint(x: geometry.screen.frame.midX,
                y: geometry.screen.frame.maxY - topGap - PeekLayout.cardHeight / 2)
    }

    public func install() {
        let screen = geometry.screen
        let w = panelSize.width, h = panelSize.height
        let frame = NSRect(x: screen.frame.midX - w / 2, y: screen.frame.maxY - h, width: w, height: h)

        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.ignoresMouseEvents = false   // a live peek is tappable

        let host = NSHostingView(rootView: NotchView(panelSize: panelSize, topGap: topGap))
        host.frame = NSRect(origin: .zero, size: frame.size)
        host.autoresizingMask = [.width, .height]
        let container = PassthroughView(frame: NSRect(origin: .zero, size: frame.size))
        container.addSubview(host)
        panel.contentView = container
        self.container = container
        // Assign `self.panel` BEFORE updateActiveRect(): that method toggles
        // `self.panel?.ignoresMouseEvents`, so if the panel isn't stored yet the
        // toggle is a silent no-op and the panel keeps its creation-time value
        // (ignoresMouseEvents = false) — swallowing every click in the top-center
        // region until the first peek fires. (Bug: dead click-zone under the notch.)
        self.panel = panel
        observePeek()
        // peek == nil at launch → updateActiveRect keeps the window OFF screen
        // until a real card arrives (so it never blocks clicks while idle).
        updateActiveRect()
    }

    /// Only the visible peek claims clicks; everything else passes through so the
    /// notch never blocks the apps beneath it.
    private func observePeek() {
        withObservationTracking { _ = model.peek } onChange: { [weak self] in
            Task { @MainActor in self?.updateActiveRect(); self?.observePeek() }
        }
    }

    private func updateActiveRect() {
        guard let c = container, let panel else { return }
        // Any pending "order off screen" is stale now — cancel it.
        hideWork?.cancel(); hideWork = nil
        if model.peek != nil {
            // A card is on screen → make the window interactive + visible.
            panel.ignoresMouseEvents = false
            panel.alphaValue = 1
            let w = panelSize.width, h = panelSize.height
            let cw = PeekLayout.cardWidth, ch = PeekLayout.cardHeight
            c.activeRect = CGRect(x: (w - cw) / 2, y: h - topGap - ch, width: cw, height: ch)
            panel.orderFrontRegardless()
        } else {
            // Card is collapsing. Stop intercepting clicks IMMEDIATELY — this is
            // what actually kills the "dead click-zone under the notch": an empty
            // activeRect makes PassthroughView.hitTest return nil, and
            // ignoresMouseEvents=true is a second guard, so the window cannot
            // catch a click even while still on screen.
            c.activeRect = .zero
            panel.ignoresMouseEvents = true
            // Do NOT orderOut yet: pulling the window off screen mid-fade leaves
            // the card's drop-shadow as window-server residue (it only clears on
            // the next composite — e.g. when the flight dot lands and the popover
            // opens). Let the SwiftUI collapse animation redraw the card away
            // first, THEN order off screen. (Cancelled above if a new peek lands.)
            let work = DispatchWorkItem { [weak panel] in panel?.orderOut(nil) }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        }
    }

    // MARK: - Geometry

    struct NotchGeometry {
        let screen: NSScreen
        let notchSize: CGSize
        let hasNotch: Bool
    }

    static func detect() -> NotchGeometry {
        if let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) {
            let topInset = screen.safeAreaInsets.top
            let lw = screen.auxiliaryTopLeftArea?.width ?? 0
            let rw = screen.auxiliaryTopRightArea?.width ?? 0
            let notchW = max(150, screen.frame.width - lw - rw)
            return NotchGeometry(screen: screen, notchSize: CGSize(width: notchW, height: topInset), hasNotch: true)
        }
        let screen = NSScreen.main ?? NSScreen.screens.first!
        return NotchGeometry(screen: screen, notchSize: CGSize(width: 210, height: 32), hasNotch: false)
    }
}

/// Hosts the SwiftUI content but only claims clicks inside `activeRect`.
final class PassthroughView: NSView {
    var activeRect: CGRect = .zero
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard activeRect.contains(local) else { return nil }
        return super.hitTest(point)
    }
}
