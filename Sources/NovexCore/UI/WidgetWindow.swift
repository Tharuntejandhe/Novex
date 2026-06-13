import SwiftUI
import AppKit

/// Public root view for the desktop widget, hosted by a SwiftUI `Window` scene
/// in the app target (see `NovexApp`).
///
/// WHY a real SwiftUI scene instead of a hand-built NSWindow: SwiftUI `Button`
/// taps run through `MainActor.assumeIsolated` → `swift_task_isCurrentExecutor`.
/// When SwiftUI is hosted in a manually-created `NSWindow` via
/// `NSHostingController`, the main thread is not recognized as the MainActor's
/// serial executor, so that check traps with "Incorrect actor executor
/// assumption" (EXC_BREAKPOINT) on every button tap. The
/// `SWIFT_IS_CURRENT_EXECUTOR_LEGACY_MODE_OVERRIDE=legacy` env var used to mask
/// this but is a no-op on Swift 6.2+, so the crash returned. Letting a SwiftUI
/// `Window` scene own the window wires the executor correctly — the same reason
/// ordinary SwiftUI apps never hit this. `WidgetWindowConfigurator` then
/// re-applies the desktop-widget look to the scene's underlying NSWindow.
public struct NovexWidgetRoot: View {
    public init() {}

    public var body: some View {
        WidgetView()
            // Size the window to the widget's intrinsic content (paired with
            // `.windowResizability(.contentSize)` on the scene).
            .fixedSize()
            .background(WidgetWindowConfigurator())
    }
}

/// Bridges to the SwiftUI scene's underlying NSWindow and styles it as a
/// borderless, transparent, desktop-level widget. Configuration runs exactly
/// once, the first time the hosting view acquires a window.
struct WidgetWindowConfigurator: NSViewRepresentable {
    private static let originDefaultsKey = "widgetOrigin"

    func makeNSView(context: Context) -> NSView {
        let probe = NSView(frame: .zero)
        // The window isn't attached yet inside makeNSView; defer to the next
        // runloop tick when `probe.window` is available.
        DispatchQueue.main.async { [weak probe] in
            guard let window = probe?.window else { return }
            context.coordinator.configure(window)
        }
        return probe
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, NSWindowDelegate {
        private var configured = false

        func configure(_ window: NSWindow) {
            guard !configured else { return }
            configured = true

            // Keep the window `.titled` (so it can become key and the Q&A
            // TextField accepts typing) but hide the titlebar + traffic-light
            // buttons and draw content edge-to-edge, which reads as borderless.
            window.styleMask.insert(.fullSizeContentView)
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.standardWindowButton(.closeButton)?.isHidden = true
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true

            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            window.isMovableByWindowBackground = true

            // Sit just above the desktop icons, on every Space, and stay put.
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

            window.delegate = self
            restoreOrigin(window)
            window.orderFrontRegardless()
        }

        // MARK: - Position persistence (origin only; size is content-driven)

        func windowDidMove(_ notification: Notification) {
            guard let window = notification.object as? NSWindow else { return }
            UserDefaults.standard.set(NSStringFromPoint(window.frame.origin),
                                      forKey: WidgetWindowConfigurator.originDefaultsKey)
        }

        private func restoreOrigin(_ window: NSWindow) {
            if let saved = UserDefaults.standard.string(forKey: WidgetWindowConfigurator.originDefaultsKey) {
                let point = NSPointFromString(saved)
                let onScreen = NSScreen.screens.contains { screen in
                    screen.visibleFrame.contains(point)
                        || screen.visibleFrame.contains(NSPoint(x: point.x + 20, y: point.y + 20))
                }
                if onScreen { window.setFrameOrigin(point); return }
            }
            if let screen = NSScreen.main {
                let v = screen.visibleFrame
                window.setFrameOrigin(NSPoint(x: v.minX + 24, y: v.maxY - 480))
            }
        }
    }
}
