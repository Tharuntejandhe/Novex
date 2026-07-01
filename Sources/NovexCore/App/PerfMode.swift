import Foundation
import IOKit.ps

/// How hard Novex works in the background. NOTE: the on-device AI runs on Apple's
/// Neural Engine and the framework hides device placement, so an app can't route
/// it to "GPU vs CPU". What we CAN control — and what actually matters for battery
/// — is how aggressively we poll, summarize, and pre-draft. This scales that to
/// the Mac's class + live power state, with a manual override.
enum PerfMode: String, CaseIterable {
    case auto, full, saver

    static let key = "novex.perfMode"
    static var current: PerfMode {
        PerfMode(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .auto
    }
    static func set(_ m: PerfMode) { UserDefaults.standard.set(m.rawValue, forKey: key) }

    var label: String {
        switch self {
        case .auto:  return "Auto"
        case .full:  return "Full"
        case .saver: return "Saver"
        }
    }
    var detail: String {
        switch self {
        case .auto:  return "Adapts to your Mac and battery"
        case .full:  return "Fastest updates, more background work"
        case .saver: return "Gentlest on battery, slower updates"
        }
    }
}

/// Resolved cadences + whether background AI may run — computed from the chosen
/// mode AND the live device/power state, so a laptop on battery quietly backs off
/// while an M-series desktop on power goes full tilt.
struct PerfProfile {
    let heartbeat: TimeInterval    // closed-panel new-mail check
    let poll: TimeInterval         // open-panel refresh loop
    let allowBackgroundLLM: Bool   // may we pre-draft replies off the main open?

    static func resolve(_ mode: PerfMode = .current) -> PerfProfile {
        let info = ProcessInfo.processInfo
        let lowPower = info.isLowPowerModeEnabled
        let hot = info.thermalState == .serious || info.thermalState == .critical
        let cores = info.activeProcessorCount
        let battery = onBattery

        let effective: Kind
        switch mode {
        case .full:  effective = .full
        case .saver: effective = .saver
        case .auto:
            if lowPower || hot { effective = .saver }               // respect the user's battery
            else if !battery { effective = .full }                  // plugged in / desktop → go
            else if cores >= 10 { effective = .balanced }           // strong laptop on battery
            else { effective = .saver }                             // small laptop on battery
        }

        switch effective {
        case .full:     return PerfProfile(heartbeat: 20, poll: 180, allowBackgroundLLM: true)
        case .balanced: return PerfProfile(heartbeat: 30, poll: 300, allowBackgroundLLM: true)
        case .saver:    return PerfProfile(heartbeat: 60, poll: 600, allowBackgroundLLM: !lowPower)
        }
    }

    private enum Kind { case full, balanced, saver }

    /// True when running on battery power (false on desktops with no battery).
    static var onBattery: Bool {
        guard let snap = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(snap)?.takeRetainedValue() as? [CFTypeRef]
        else { return false }
        for src in list {
            guard let desc = IOPSGetPowerSourceDescription(snap, src)?.takeUnretainedValue()
                as? [String: Any] else { continue }
            if let state = desc[kIOPSPowerSourceStateKey] as? String {
                return state == kIOPSBatteryPowerValue
            }
        }
        return false
    }
}
