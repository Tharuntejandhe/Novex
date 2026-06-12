import Foundation

/// Reads dev-time secrets from ~/.config/desktop-agent/secrets.env.
/// Phase 2 will migrate to macOS Keychain via a settings dialog.
enum Secrets {
    static let configDir = ("~/.config/desktop-agent" as NSString).expandingTildeInPath
    static let envPath = configDir + "/secrets.env"

    private static let values: [String: String] = {
        guard let raw = try? String(contentsOfFile: envPath, encoding: .utf8) else { return [:] }
        var map: [String: String] = [:]
        for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            map[key] = value
        }
        return map
    }()

    static subscript(key: String) -> String? { values[key] }

    // Optional: only used if a power user wants to swap the Mail.app bridge
    // for direct Gmail API access in a future advanced mode.
    static var googleClientID: String?     { values["GOOGLE_CLIENT_ID"] }
    static var googleClientSecret: String? { values["GOOGLE_CLIENT_SECRET"] }

    /// LLM is on-device (Foundation Models, no key). Mail comes from local
    /// Mail.app store (no key). So the baseline app needs no secrets at all.
    static var isConfigured: Bool { true }
}
