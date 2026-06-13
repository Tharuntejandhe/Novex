import SwiftUI
import NovexCore

/// SwiftUI App entry point.
///
/// The menu bar item + brief popover are built in `AppDelegate` with AppKit
/// (`NSStatusItem` + `NSPopover`), NOT SwiftUI's `MenuBarExtra`. `MenuBarExtra(.window)`
/// auto-sizes to its SwiftUI content and, on a fresh launch (while the brief is
/// still loading and its height changes), it re-presents in a loop — the panel
/// visibly bounces / opens-and-closes. An `NSPopover` with a fixed `contentSize`
/// physically cannot resize or flicker, so the loop is impossible by construction.
///
/// This scene is just an empty placeholder so the App has a Scene; `LSUIElement`
/// + `.accessory` keep us out of the Dock. All interactive controls are AppKit
/// taps (AppKitTap.swift), so hosting SwiftUI in an NSHostingController here does
/// NOT reintroduce the old `_ButtonGesture` MainActor crash.
@main
struct NovexApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}
