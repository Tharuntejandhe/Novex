import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Wraps Apple's on-device language model (Apple Intelligence).
/// Zero network, zero cost, requires macOS 26+ and Apple Intelligence enabled.
@available(macOS 26.0, *)
final class FoundationModelsClient {
    enum LLMError: Error, LocalizedError {
        case unavailable(String)
        case generationFailed(String)

        var errorDescription: String? {
            switch self {
            case .unavailable(let msg):  return "On-device model unavailable: \(msg)"
            case .generationFailed(let msg): return "Generation failed: \(msg)"
            }
        }
    }

    var isAvailable: Bool {
        #if canImport(FoundationModels)
        return SystemLanguageModel.default.availability == .available
        #else
        return false
        #endif
    }

    var unavailableReason: String? {
        #if canImport(FoundationModels)
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.deviceNotEligible):
            return "This Mac doesn't support Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Enable Apple Intelligence in System Settings → Apple Intelligence & Siri."
        case .unavailable(.modelNotReady):
            return "Apple Intelligence model is still downloading. Try again later."
        case .unavailable(let other):
            return "Model unavailable: \(other)"
        }
        #else
        return "FoundationModels framework not available in this SDK."
        #endif
    }

    /// Single-shot prompt. Returns the model's text response.
    func respond(to prompt: String, instructions: String? = nil) async throws -> String {
        #if canImport(FoundationModels)
        guard isAvailable else {
            throw LLMError.unavailable(unavailableReason ?? "unknown")
        }
        do {
            let session: LanguageModelSession
            if let instructions {
                session = LanguageModelSession(instructions: instructions)
            } else {
                session = LanguageModelSession()
            }
            let response = try await session.respond(to: prompt)
            return response.content
        } catch {
            throw LLMError.generationFailed(String(describing: error))
        }
        #else
        throw LLMError.unavailable("FoundationModels framework missing.")
        #endif
    }

    /// Ask the model for JSON matching a Decodable type. Strips markdown
    /// fences if the model adds them. Robust enough for small JSON schemas.
    func generateJSON<T: Decodable>(
        _ type: T.Type,
        prompt: String,
        schemaHint: String,
        instructions: String? = nil
    ) async throws -> T {
        let fullPrompt = """
        \(prompt)

        Respond with ONLY a single valid JSON object matching this schema:
        \(schemaHint)
        No prose, no explanation, no markdown code fences. Just the JSON object.
        """
        let raw = try await respond(to: fullPrompt, instructions: instructions)
        let cleaned = raw
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = cleaned.data(using: .utf8) else {
            throw LLMError.generationFailed("Could not encode model output as UTF-8")
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw LLMError.generationFailed("JSON parse failed: \(error). Raw: \(cleaned.prefix(200))")
        }
    }
}
