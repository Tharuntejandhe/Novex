import SwiftUI
import AppKit

/// The panel shown when the menu-bar icon is clicked — the morning brief itself.
/// Reuses the existing briefing UI (`WidgetView`), which also gates first-run
/// onboarding and hosts the voice/text Q&A bar.
///
/// IMPORTANT: a `MenuBarExtra(.window)` panel auto-sizes to its content. If the
/// content's height is ambiguous — which it is, because `WidgetView` contains a
/// flexible `ScrollView` — the window endlessly re-measures and visibly bounces
/// up and down. So we pin a DEFINITE size here; the window then has nothing to
/// oscillate over, and the inner ScrollView simply scrolls within it. (Height
/// fits the one-time onboarding card; the daily brief scrolls inside.)
public struct CruxMenuBarPanel: View {
    public init() {}
    public var body: some View {
        WidgetView()
            .frame(width: 320, height: 470)
    }
}
