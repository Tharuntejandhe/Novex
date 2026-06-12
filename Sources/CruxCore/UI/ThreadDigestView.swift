import SwiftUI
import AppKit

/// "Catch me up" — an on-device TL;DR of a whole thread, with a Reply shortcut
/// for threads that need one. Shown inside the Follow-ups tab when a thread is
/// tapped; summarization runs on the local model.
struct ThreadDigestView: View {
    let item: FollowUpItem
    let thread: [MailMessage]
    let userAddresses: Set<String>
    let onReply: (MailMessage) -> Void
    let onClose: () -> Void

    @State private var bullets: [String] = []
    @State private var loading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            metaLine
            if loading {
                loadingCard
            } else {
                bulletList
                Spacer(minLength: 0)
                actions
            }
        }
        .task { await load() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.cyan.opacity(0.85))
            Text("Catch me up · \(item.counterpartName)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.95))
                .lineLimit(1)
            Spacer()
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
                .appKitTap(onClose)
                .help("Back")
        }
    }

    private var metaLine: some View {
        Text("\(thread.count) email\(thread.count == 1 ? "" : "s") · \(item.subject)")
            .font(.system(size: 10.5))
            .foregroundStyle(.white.opacity(0.5))
            .lineLimit(1)
    }

    private var loadingCard: some View {
        HStack(spacing: 12) {
            PulsingSparkle()
            VStack(alignment: .leading, spacing: 3) {
                Text("Reading the thread…")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                Text("On-device · nothing leaves your Mac")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
            }
            Spacer()
        }
        .padding(.top, 12)
    }

    private var bulletList: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(bullets.enumerated()), id: \.offset) { _, b in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 4))
                        .foregroundStyle(.cyan.opacity(0.7))
                        .padding(.top, 6)
                    Text(b)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.white.opacity(0.92))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.top, 4)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if item.kind == .needsReply {
                HStack(spacing: 4) {
                    Image(systemName: "arrowshape.turn.up.left.fill").font(.system(size: 9, weight: .bold))
                    Text("Reply").font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(.black.opacity(0.85))
                .padding(.horizontal, 13).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.green.opacity(0.85)))
                .appKitTap { onReply(item.message); onClose() }
            }
            if let url = mailURL {
                Text("Open in Mail")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.10)))
                    .appKitTap { NSWorkspace.shared.open(url) }
            }
            Spacer()
        }
    }

    private var mailURL: URL? {
        guard let mid = item.message.messageID else { return nil }
        let core = mid.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
        guard !core.isEmpty,
              let enc = core.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        else { return nil }
        return URL(string: "message://%3C\(enc)%3E")
    }

    private func load() async {
        bullets = await BriefingService.shared.summarizeThread(thread, userAddresses: userAddresses)
        loading = false
    }
}
