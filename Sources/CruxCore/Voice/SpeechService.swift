import Foundation
import AVFoundation
import Observation
import AppKit

/// On-device text-to-speech so Crux can READ you the briefing aloud — the
/// assistant literally talking. Uses the best installed English voice. Free,
/// on-device (AVSpeechSynthesizer), no permission, nothing leaves the Mac.
@MainActor
@Observable
final class SpeechService {
    static let shared = SpeechService()

    private let synth = AVSpeechSynthesizer()
    private let delegate = SpeechDelegate()
    private(set) var isSpeaking = false

    private init() {
        delegate.onStopped = { [weak self] in
            Task { @MainActor in self?.isSpeaking = false }
        }
        synth.delegate = delegate
    }

    /// Toggle: speak the text, or stop if already speaking.
    func toggle(_ text: String) {
        if isSpeaking { stop() } else { speak(text) }
    }

    func speak(_ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        synth.stopSpeaking(at: .immediate)
        let u = AVSpeechUtterance(string: clean)
        // Natural cadence: a touch slower, neutral pitch, a small lead-in so it
        // doesn't clip the first word.
        u.rate = AVSpeechUtteranceDefaultSpeechRate * 0.94
        u.pitchMultiplier = 1.0
        u.preUtteranceDelay = 0.05
        u.prefersAssistiveTechnologySettings = false
        u.voice = Self.bestVoice()
        isSpeaking = true
        synth.speak(u)
    }

    func stop() {
        synth.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    /// True only if a genuinely natural (enhanced/premium) English voice is
    /// installed. When false the system has only the robotic "compact" voice and
    /// the user should download a Premium voice (see `openVoiceSettings`).
    static var hasNaturalVoice: Bool {
        AVSpeechSynthesisVoice.speechVoices().contains {
            $0.language.hasPrefix("en") && $0.quality != .default
        }
    }

    /// Pick the most human-sounding installed English voice: highest quality
    /// first (premium ≫ enhanced ≫ compact), then the warmest known names.
    private static func bestVoice() -> AVSpeechSynthesisVoice? {
        let en = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
        let preferred = ["ava", "zoe", "evan", "nathan", "joelle", "samantha",
                         "allison", "serena", "susan", "tom", "daniel"]
        func score(_ v: AVSpeechSynthesisVoice) -> Int {
            let q = v.quality == .premium ? 300 : (v.quality == .enhanced ? 200 : 100)
            let n = preferred.firstIndex { v.name.lowercased().contains($0) }
                .map { preferred.count - $0 } ?? 0
            return q + n
        }
        return en.max { score($0) < score($1) } ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    /// Open System Settings to where the user downloads a free Premium English
    /// voice — the real fix for a robotic voice (the compact one can't sound human).
    static func openVoiceSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.universalaccess?SpokenContent")
            ?? URL(string: "x-apple.systempreferences:com.apple.preference.universalaccess")!
        NSWorkspace.shared.open(url)
    }
}

/// Separate NSObject delegate (an @Observable class can't cleanly be an
/// NSObject), bridging "finished/cancelled" back to the service.
private final class SpeechDelegate: NSObject, AVSpeechSynthesizerDelegate {
    var onStopped: (() -> Void)?
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) { onStopped?() }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) { onStopped?() }
}
