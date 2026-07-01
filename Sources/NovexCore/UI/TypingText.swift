import SwiftUI

/// Reveals text one character at a time — the "assistant is typing" feel for
/// Novex's answers. Types only when the string actually changes (never on a plain
/// re-render), cancels cleanly if a new answer arrives mid-type, and reveals long
/// answers instantly so it never feels sluggish.
struct TypingText: View {
    let text: String
    var font: Font = .system(size: 12.5)
    var color: Color = .white.opacity(0.92)
    var perChar: Double = 0.010

    @State private var shown = ""
    @State private var typed = ""
    @State private var task: Task<Void, Never>?

    var body: some View {
        Text(shown)
            .font(font)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onAppear { animate(to: text) }
            .onChange(of: text) { _, new in animate(to: new) }
            .onDisappear { task?.cancel() }
    }

    private func animate(to full: String) {
        guard full != typed else { shown = full; return }
        typed = full
        task?.cancel()
        if full.count > 400 { shown = full; return }   // long answer: no crawl
        shown = ""
        task = Task { @MainActor in
            var acc = ""
            for ch in full {
                if Task.isCancelled { return }
                acc.append(ch); shown = acc
                try? await Task.sleep(nanoseconds: UInt64(perChar * 1_000_000_000))
            }
        }
    }
}

/// Three pulsing dots — a live "thinking" indicator while the on-device model runs.
struct TypingDots: View {
    @State private var phase = 0
    private let timer = Timer.publish(every: 0.32, on: .main, in: .common).autoconnect()
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color.white.opacity(phase == i ? 0.75 : 0.22))
                    .frame(width: 4, height: 4)
            }
        }
        .onReceive(timer) { _ in phase = (phase + 1) % 3 }
    }
}
