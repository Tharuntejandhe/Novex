import SwiftUI
import AppKit

/// Full-panel Smart Reply composer. Drafts a reply to a briefing item entirely
/// on-device, lets the user edit it and re-roll the tone, then hands the result
/// to Mail (a `mailto:` compose window) or the clipboard. Presented as an
/// overlay over the briefing — never a separate window — so it inherits the
/// panel's surface and dismissal.
struct ReplyComposer: View {
    let message: MailMessage
    let service: BriefingService
    let onClose: () -> Void

    @State private var draft: ReplyDraft?
    @State private var bodyText: String = ""
    @State private var isDrafting = true
    @State private var tone: ReplyTone = .balanced
    @State private var copied = false

    /// `message://` deep link to open the original in Mail, if we have a real id.
    private var originalURL: URL? {
        guard let mid = message.messageID else { return nil }
        let core = mid.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
        guard !core.isEmpty,
              let enc = core.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        else { return nil }
        return URL(string: "message://%3C\(enc)%3E")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            subjectLine
            if isDrafting {
                draftingState
                Spacer(minLength: 0)
            } else {
                editor
                toneRow
                Spacer(minLength: 0)
                actions
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .task { await generate(.balanced) }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrowshape.turn.up.left.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.green.opacity(0.85))
            Text("Reply to \(message.senderDisplay)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.95))
                .lineLimit(1)
            Spacer()
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
                .appKitTap(onClose)
                .help("Close")
        }
    }

    private var subjectLine: some View {
        HStack(spacing: 8) {
            Text(draft?.replySubject ?? "Re: \(message.subject)")
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1)
            Spacer(minLength: 4)
            if let url = originalURL {
                Text("View original")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.cyan.opacity(0.8))
                    .appKitTap { NSWorkspace.shared.open(url) }
                    .help("Open the original email in Mail")
            }
        }
    }

    // MARK: - Drafting / editor

    private var draftingState: some View {
        HStack(spacing: 12) {
            PulsingSparkle()
            VStack(alignment: .leading, spacing: 3) {
                Text("Writing your reply…")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                Text("On-device · nothing leaves your Mac")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
            }
            Spacer()
        }
        .padding(.top, 16)
    }

    private var editor: some View {
        TextEditor(text: $bodyText)
            .font(.system(size: 12.5))
            .foregroundStyle(.white.opacity(0.95))
            .scrollContentBackground(.hidden)
            .padding(8)
            .frame(height: 210)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
            )
            .overlay(alignment: .topLeading) {
                if bodyText.isEmpty {
                    Text("Write your reply…")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.white.opacity(0.3))
                        .padding(.horizontal, 13)
                        .padding(.top, 14)
                        .allowsHitTesting(false)
                }
            }
    }

    private var toneRow: some View {
        HStack(spacing: 6) {
            ForEach(ReplyTone.allCases, id: \.self) { t in
                toneChip(t)
            }
            Spacer()
        }
    }

    private func toneChip(_ t: ReplyTone) -> some View {
        let selected = tone == t
        return Text(t.label)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white.opacity(selected ? 0.95 : 0.55))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(selected ? 0.16 : 0.06))
            )
            .appKitTap { if tone != t { Task { await generate(t) } } }
            .help("Rewrite \(t.label.lowercased())")
    }

    // MARK: - Actions

    private var actions: some View {
        HStack(spacing: 8) {
            Text("Use draft")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.black.opacity(0.85))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.green.opacity(0.85))
                )
                .appKitTap(useInMail)
                .help("Open this reply in Mail, ready to send")
            Text(copied ? "Copied ✓" : "Copy")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.white.opacity(0.10))
                )
                .appKitTap(copyDraft)
            Spacer()
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
                .padding(7)
                .background(Circle().fill(Color.white.opacity(0.08)))
                .appKitTap { Task { await generate(tone) } }
                .help("Re-draft")
        }
    }

    // MARK: - Logic

    private func generate(_ newTone: ReplyTone) async {
        tone = newTone
        copied = false
        isDrafting = true
        let d = await service.draftReply(for: message, tone: newTone)
        draft = d
        bodyText = d.body
        isDrafting = false
    }

    private func useInMail() {
        guard let d = draft else { return }
        var comps = URLComponents()
        comps.scheme = "mailto"
        comps.path = d.recipientEmail ?? ""
        comps.queryItems = [
            URLQueryItem(name: "subject", value: d.replySubject),
            URLQueryItem(name: "body", value: bodyText),
        ]
        if let url = comps.url { NSWorkspace.shared.open(url) }
        onClose()
    }

    private func copyDraft() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(bodyText, forType: .string)
        copied = true
    }
}
