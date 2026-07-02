import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Agentic on-device chat.
///
/// The plain Q&A path stuffs one fixed slice of retrieved emails into a prompt and
/// hopes the right one was picked. This agent instead lets the model DECIDE to look
/// things up: it runs a small tool-use loop where the model can emit `SEARCH: ...`
/// to query the inbox (its own keywords, more than once) before it answers - the
/// way a person would ("did the recruiter reply?" -> search "recruiter", then
/// "interview"). It also always sees a deterministic "what needs you" summary so it
/// can never sell an FYI (a login code, a receipt) as a to-do.
///
/// Everything is on-device. The one capability - inbox search - is READ-ONLY local
/// lookup (no network, no mutations), so the prompt-injection blast radius stays
/// tiny: the worst an injected email can do is make the model search for odd words,
/// which changes nothing.
///
/// The model call is injected (`run(question:respond:)`), so the whole loop is
/// deterministically testable with a scripted mock - no live model required.
@available(macOS 26.0, *)
struct NovexAgent {
    let messages: [MailMessage]
    let mine: Set<String>
    /// Deterministic "what actually needs the user" summary (from the engine, not
    /// the model's guess), injected so planning answers are grounded.
    let plate: String

    enum AgentError: Error { case unavailable }

    /// Live entry point. Throws if the on-device model is unavailable so the caller
    /// can fall back to the plain retrieval path.
    func answer(_ question: String) async throws -> String {
        #if canImport(FoundationModels)
        guard SystemLanguageModel.default.availability == .available else { throw AgentError.unavailable }
        let session = LanguageModelSession(instructions: Self.instructions(plate: plate))
        return try await run(question: question) { prompt in
            try await session.respond(to: prompt).content
        }
        #else
        throw AgentError.unavailable
        #endif
    }

    /// The tool-use loop, model-agnostic. `respond` maps a prompt to the model's
    /// reply (live: a LanguageModelSession; tests: a scripted mock). The session is
    /// stateful across turns, so each turn sends only the new information.
    func run(question: String, maxSteps: Int = 3,
             respond: (String) async throws -> String) async rethrows -> String {
        var prompt = Self.firstPrompt(question: question)
        for _ in 0..<maxSteps {
            let out = try await respond(prompt)
            // Prefer a search if the model asked for one (even if it also rambled).
            if let query = Self.extractSearch(out) {
                let results = InboxSearch.results(query: query, messages: messages, mine: mine)
                prompt = Self.resultsPrompt(query: query, results: results)
                continue
            }
            if let answer = Self.extractAnswer(out) { return answer }
            return out   // model didn't follow the protocol; use its text as-is
        }
        // Out of search budget - force a final answer from what it has gathered.
        let final = try await respond("Answer the user now in 1-2 short sentences from what you found. Start with ANSWER:")
        return Self.extractAnswer(final) ?? final
    }

    // MARK: - Prompts

    static func instructions(plate: String) -> String {
        """
        You are Novex, the user's warm, concise on-device email assistant.

        You can look things up in their inbox. Reply in ONE of these two formats and nothing else:
          SEARCH: <keywords>       when you need to find emails (I reply with the matches)
          ANSWER: <1-2 sentences>  your final reply to the user

        Rules:
        - For ANY question about their email, SEARCH first (use the key nouns), then ANSWER from the matches. You may SEARCH again with different words if the first misses.
        - If a search returns "No matching emails", ANSWER that you don't see anything about that in their recent mail. NEVER answer from unrelated mail and NEVER make things up.
        - ANSWER in your own words, like a friend who skimmed their inbox. No pasting or quoting email text, no bullet points, headers, greetings, or asterisks. Don't invent senders, subjects, amounts, or dates.
        - When you ANSWER, describe things in ONE or TWO flowing sentences using the REAL sender names and subjects you were given. Never repeat the list format above or its [bracketed labels], and never use any name or company not present in the data - if the list says nothing needs them, say exactly that.
        - If several emails match, mention the main ones together (up to about three) in one natural sentence rather than only one, and lead with anything important (a reply owed, a bill, an action) over routine notifications.
        - A login/security code, a "password changed" notice, receipts, and newsletters are FYI - never tell the user they must act on those.

        What actually needs the user right now, from a reliable check already done for you:
        \(PromptSafety.fence(plate))
        If they ask what needs them or what to do, ANSWER from that list; if it says nothing needs them, say so plainly.

        \(PromptSafety.securityClause)
        """
    }

    static func firstPrompt(question: String) -> String {
        """
        The user (trusted) asks: \(question)

        Reply with SEARCH: <keywords> or ANSWER: <reply>.
        """
    }

    static func resultsPrompt(query: String, results: String) -> String {
        """
        Search results for "\(query)":
        \(PromptSafety.fence(results))

        Now reply with SEARCH: <new keywords> or ANSWER: <reply>.
        """
    }

    // MARK: - Protocol parsing (pure, testable)

    /// Keywords from a `SEARCH: ...` directive anywhere in the model's reply, or nil.
    static func extractSearch(_ s: String) -> String? {
        guard let r = s.range(of: "SEARCH:", options: .caseInsensitive) else { return nil }
        let after = s[r.upperBound...]
        let line = after.split(whereSeparator: \.isNewline).first.map(String.init) ?? String(after)
        let q = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return q.isEmpty ? nil : q
    }

    /// The reply from an `ANSWER: ...` directive, or nil.
    static func extractAnswer(_ s: String) -> String? {
        guard let r = s.range(of: "ANSWER:", options: .caseInsensitive) else { return nil }
        let a = s[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return a.isEmpty ? nil : a
    }
}

/// Read-only inbox search shared by the agent (and directly unit-testable). Pure,
/// no model and no FoundationModels dependency.
enum InboxSearch {
    /// Rank the inbox for `query` and render the matches for the model. Honest: if
    /// the query has real terms but nothing matches (rank just fell back to recent),
    /// returns "No matching emails." so the model won't answer from unrelated mail.
    static func results(query: String, messages: [MailMessage], mine: Set<String>, limit: Int = 10) -> String {
        let hits = MailRetrieval.rank(question: query, messages: messages, limit: limit)
        let terms = queryTerms(query)
        let realMatch = terms.isEmpty || hits.contains { m in
            let hay = (m.subject + " " + (m.snippet ?? "") + " " + m.senderDisplay).lowercased()
            return terms.contains { hay.contains($0) }
        }
        guard !hits.isEmpty, realMatch else { return "No matching emails." }

        let now = Date()
        let rel = RelativeDateTimeFormatter()
        return hits.sorted { $0.dateReceived > $1.dateReceived }.map { m -> String in
            let when = rel.localizedString(for: m.dateReceived, relativeTo: now)
            let read = m.isRead ? "" : " UNREAD"
            let sender = PromptSafety.sanitize(m.senderDisplay, maxChars: 48)
            let subject = PromptSafety.sanitize(String(m.subject.prefix(90)), maxChars: 90)
            let snip = PromptSafety.sanitize(String((m.snippet ?? "").prefix(120)), maxChars: 120)
            let kind = kind(of: m, mine: mine)
            return "- (\(when))\(read)\(kind) \(sender): \(subject)" + (snip.isEmpty ? "" : " - \(snip)")
        }.joined(separator: "\n")
    }

    /// The SAME classification the briefing uses, so the model knows a code /
    /// receipt / newsletter is FYI, not a to-do.
    static func kind(of m: MailMessage, mine: Set<String>) -> String {
        if m.isFromSelf(mine) { return " [your own note]" }
        if m.isEphemeralNotification { return " [FYI]" }
        switch m.deterministicAction(mine: mine, deadline: m.detectedDeadline) {
        case .reply:   return " [needs a reply]"
        case .pay:     return " [bill to pay]"
        case .confirm: return " [action needed]"
        case .review:  return " [to review]"
        default:       return m.unsubscribeType > 0 ? " [newsletter]" : ""
        }
    }

    private static let stop: Set<String> = ["the","and","for","you","your","did","does","what","when",
        "where","who","how","why","any","email","emails","mail","inbox","about","from",
        "have","has","was","were","there","that","this","with","are","get","got"]

    static func queryTerms(_ q: String) -> Set<String> {
        Set(q.lowercased()
            .split { !$0.isLetter && !$0.isNumber }.map(String.init)
            .filter { $0.count >= 3 && !stop.contains($0) })
    }
}
