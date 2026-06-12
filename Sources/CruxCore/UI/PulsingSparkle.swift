import SwiftUI

/// Sparkle shown in the "analyzing" / loading states.
///
/// NOTE: this used to pulse (scale + shadow + opacity on a `repeatForever`
/// animation). Inside a `MenuBarExtra(.window)` panel, that continuous animation
/// caused the panel window to re-measure and visibly bounce/open-close in a loop
/// on a fresh launch (while the brief was still loading). It's now static — no
/// animation, fixed frame — so there's nothing for the panel to oscillate over.
struct PulsingSparkle: View {
    var body: some View {
        Image(systemName: "sparkle")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white.opacity(0.85))
            .frame(width: 22, height: 22)
    }
}
