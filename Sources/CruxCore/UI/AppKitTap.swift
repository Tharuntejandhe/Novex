import SwiftUI
import AppKit

/// Tap handling backed by an AppKit NSView instead of SwiftUI's `Button`.
///
/// SwiftUI `Button` routes its tap through `_ButtonGesture` →
/// `MainActor.assumeIsolated`, which traps with "Incorrect actor executor
/// assumption" on every tap in this accessory/agent app on Swift 6.2+/macOS 26
/// — a confirmed Swift bug where `assumeIsolated` crashes even though the code
/// is genuinely on the main thread. AppKit's mouse handling never goes through
/// that gesture path, so taps run cleanly. Use `someView.appKitTap { ... }` in
/// place of `Button { ... } label: { someView }`.
struct AppKitTapView: NSViewRepresentable {
    var action: () -> Void

    func makeNSView(context: Context) -> NSView {
        let v = TapNSView()
        v.onTap = action
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? TapNSView)?.onTap = action
    }

    final class TapNSView: NSView {
        var onTap: (() -> Void)?

        // Receive the very first click even when our (desktop-level, non-key)
        // window isn't active — essential for a desktop widget.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? {
            let local = convert(point, from: superview)
            return bounds.contains(local) ? self : nil
        }

        override func mouseUp(with event: NSEvent) {
            let p = convert(event.locationInWindow, from: nil)
            if bounds.contains(p) { onTap?() }
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .pointingHand)
        }
    }
}

extension View {
    /// Tap via AppKit (avoids the SwiftUI `_ButtonGesture` MainActor crash).
    /// The receiver stays the visual; only click handling is AppKit.
    func appKitTap(_ action: @escaping () -> Void) -> some View {
        self.contentShape(Rectangle()).overlay(AppKitTapView(action: action))
    }
}
