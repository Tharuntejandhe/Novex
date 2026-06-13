import SwiftUI
import AppKit

/// The notification card view. Normally invisible; when a peek arrives a clean,
/// self-contained rounded card (Dynamic-Island style) drops in just below the
/// menu bar, shows the notification, then collapses. It does NOT depend on the
/// notch, so it looks identical on every display. Purely visual; only the card
/// itself takes clicks.
struct NotchView: View {
    @State private var model = NotchModel.shared
    let panelSize: CGSize
    /// Gap from the top of the screen (clears the menu bar) — passed in so it
    /// adapts to each display.
    let topGap: CGFloat

    private var shape: some Shape {
        RoundedRectangle(cornerRadius: PeekLayout.corner, style: .continuous)
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0).frame(height: topGap)
            if let p = model.peek {
                card(p)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer(minLength: 0)
        }
        .frame(width: panelSize.width, height: panelSize.height, alignment: .top)
        .animation(.spring(response: 0.36, dampingFraction: 0.82), value: model.peek != nil)
    }

    private func card(_ p: NotchModel.PeekItem) -> some View {
        peekRow(p)
            .padding(.horizontal, 16)
            .frame(width: PeekLayout.cardWidth, height: PeekLayout.cardHeight, alignment: .leading)
            .background(shape.fill(Color.black))
            .overlay(shape.stroke(Color.white.opacity(0.08), lineWidth: 0.5))   // subtle rim
            .clipShape(shape)
            .shadow(color: .black.opacity(0.42), radius: 13, y: 6)
            .contentShape(shape)
            .appKitTap { model.trigger() }   // tap → transform into the flying dot
    }

    private func peekRow(_ p: NotchModel.PeekItem) -> some View {
        HStack(spacing: 11) {
            ZStack {
                Circle().fill(Color.cyan.opacity(0.16)).frame(width: 32, height: 32)
                Image(systemName: p.icon).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.cyan.opacity(0.95))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(p.title).font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white).lineLimit(1)
                Text(p.subtitle).font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.62)).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }
}
