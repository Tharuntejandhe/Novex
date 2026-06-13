import SwiftUI
import AppKit

/// Full-panel "snooze until?" picker — four presets that hide an item from Novex
/// and resurface it later. Presented as an overlay, like the reply composer.
struct SnoozePicker: View {
    let item: BriefingItem
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "clock.badge")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.purple.opacity(0.85))
                Text("Snooze until…")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
                Spacer()
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                    .appKitTap(onClose)
            }
            Text(item.title)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 8) {
                ForEach(SnoozePreset.allCases, id: \.self) { preset in
                    presetRow(preset)
                }
            }
            .padding(.top, 4)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private func presetRow(_ preset: SnoozePreset) -> some View {
        let wake = preset.wakeDate(from: Date())
        return HStack(spacing: 10) {
            Image(systemName: preset.icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 22)
            Text(preset.label)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
            Spacer()
            Text(wakeLabel(wake))
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.45))
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 11)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.06)))
        .contentShape(Rectangle())
        .appKitTap { snooze(until: wake) }
    }

    private func snooze(until wake: Date) {
        if let id = item.messageID {
            SnoozeStore.snooze(messageID: id, title: item.title, until: wake)
        }
        onClose()
    }

    private func wakeLabel(_ date: Date) -> String {
        let cal = Calendar.current
        let t = date.formatted(.dateTime.hour().minute())
        if cal.isDateInToday(date) { return t }
        if cal.isDateInTomorrow(date) { return "Tmrw \(t)" }
        return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}
