import SwiftUI
import AppKit

/// "Catch me up" — a full-panel, grouped digest of recent mail. Deterministic
/// (no LLM), so it's fast and never "dumb". Tap a row to open it in Mail.
struct DigestView: View {
    let digest: Digest
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if digest.isEmpty {
                empty
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(digest.sections) { section in
                            sectionView(section)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.line.first.and.arrowtriangle.forward")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.cyan.opacity(0.85))
            Text("Catch me up")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.95))
            Text("· last 24h")
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.4))
            Spacer()
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
                .appKitTap(onClose)
        }
    }

    private func sectionView(_ section: DigestSection) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: section.category.icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                Text(section.category.label.uppercased())
                    .font(.system(size: 9, weight: .bold)).tracking(0.6)
                    .foregroundStyle(.white.opacity(0.45))
                Text("\(section.total)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.cyan.opacity(0.75))
            }
            ForEach(section.items) { item in
                row(item)
            }
            if section.total > section.items.count {
                Text("+\(section.total - section.items.count) more")
                    .font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.35))
                    .padding(.leading, 2)
            }
        }
    }

    private func row(_ item: DigestItem) -> some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                Text(item.sub)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if item.matches {
                Text("★ for you")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(.cyan.opacity(0.95))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Capsule().fill(Color.cyan.opacity(0.14)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .appKitTap {
            if let url = mailURL(item.messageID) { NSWorkspace.shared.open(url) }
        }
    }

    private var empty: some View {
        Text("Nothing recent to catch up on.")
            .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
            .padding(.top, 8)
    }

    private func mailURL(_ messageID: String?) -> URL? {
        guard let mid = messageID else { return nil }
        let core = mid.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
        guard !core.isEmpty,
              let enc = core.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        else { return nil }
        return URL(string: "message://%3C\(enc)%3E")
    }
}
