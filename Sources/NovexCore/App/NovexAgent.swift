import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// What the agent decided to do. Pure (no model / no FoundationModels), so the
/// caller (BriefingService, on the main actor) can execute it and it stays testable.
enum AgentOutcome: Equatable {
    /// Just talk back to the user.
    case answer(String)
    /// Draft a reply to a specific message (shown for the user to send - never auto-sent).
    case draft(messageID: String, intent: String)
    /// Mark messages as done / dismiss them (reversible).
    case markDone(messageIDs: [String], senderNames: [String])
}

/// Agentic on-device chat.
///
/// A small tool-use (ReAct) loop over the plain on-device model. The model can:
///   SEARCH: <keywords>       look things up in the inbox (numbered results)
///   ANSWER: <reply>          talk to the user
///   DRAFT: <#> | <intent>    draft a reply to search result <#> (user still sends it)
///   DONE: <#>[, <#>]         mark result(s) as done / dismiss (reversible)
/// It always sees a deterministic "what needs you" plate, so planning is grounded.
///
/// Actions are grounded on NUMBERED search results (the model must SEARCH first),
/// so it can only act on real, identified emails. Drafting never sends; dismissing
/// is reversible. Search is read-only and local. The model call is injected, so the
/// whole loop is deterministically testable with a scripted mock.
@available(macOS 26.0, *)
struct NovexAgent {
    let messages: [MailMessage]
    let mine: Set<String>
    /// Deterministic "what actually needs the user" summary (from the engine).
    let plate: String

    enum AgentError: Error { case unavailable }

    /// Live entry point. Throws if the on-device model is unavailable so the caller
    /// can fall back to the plain retrieval path.
    func answer(_ question: String) async throws -> AgentOutcome {
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
    /// reply (live: a stateful LanguageModelSession; tests: a scripted mock).
    func run(question: String, maxSteps: Int = 4,
             respond: (String) async throws -> String) async rethrows -> AgentOutcome {
        var prompt = Self.firstPrompt(question: question)
        var lastHits: [MailMessage] = []   // the latest NUMBERED search results
        for _ in 0..<maxSteps {
            let out = try await respond(prompt)

            if let query = Self.extractSearch(out) {
                let found = InboxSearch.search(query: query, messages: messages, mine: mine)
                lastHits = found.hits
                prompt = Self.resultsPrompt(query: query, results: found.text)
                continue
            }
            // Actions reference the numbered results; resolve against lastHits.
            if let draft = Self.extractDraft(out) {
                if draft.index >= 1, draft.index <= lastHits.count,
                   let mid = lastHits[draft.index - 1].messageID {
                    return .draft(messageID: mid, intent: draft.intent)
                }
                prompt = Self.recoverPrompt   // referenced an email it hasn't found
                continue
            }
            if let idxs = Self.extractDone(out) {
                let valid = idxs.filter { $0 >= 1 && $0 <= lastHits.count }
                let mids = valid.compactMap { lastHits[$0 - 1].messageID }
                if !mids.isEmpty {
                    let names = valid.map { lastHits[$0 - 1].senderDisplay }
                    return .markDone(messageIDs: mids, senderNames: names)
                }
                prompt = Self.recoverPrompt
                continue
            }
            if let answer = Self.extractAnswer(out) { return .answer(answer) }
            return .answer(out)   // model didn't follow the protocol; use its text
        }
        // Out of budget - force a final answer.
        let final = try await respond("Answer the user now in 1-2 short sentences from what you found. Start with ANSWER:")
        return .answer(Self.extractAnswer(final) ?? final)
    }

    // MARK: - Prompts

    static func instructions(plate: String) -> String {
        """
        You are Novex, the user's warm, concise on-device email assistant.

        You work in a loop. Reply in exactly ONE of these formats and nothing else:
          SEARCH: <keywords>          look up emails (I reply with NUMBERED matches)
          ANSWER: <1-2 sentences>     talk to the user
          DRAFT: <#> | <what to say>  draft a reply to numbered email <#> (I show it; the USER sends it)
          DONE: <#>                   mark numbered email <#> as done / dismiss it (you may list several: DONE: 1, 3)

        Rules:
        - For ANY request about their email, SEARCH first (use the key nouns). Results are numbered [1], [2], ... Only ever use a number that appeared in the LATEST search results.
        - To answer a question: SEARCH, then ANSWER from the matches. If a search returns "No matching emails", ANSWER that you don't see anything about it. NEVER answer from unrelated mail or invent anything.
        - To reply for the user ("reply to X that ..."): SEARCH for it, then DRAFT: <#> | <the point to make>. Drafting only PREPARES a reply for the user to review and send - it never sends on its own.
        - To clear/dismiss ("mark X done", "clear the Y notifications"): SEARCH for it, then DONE: <#>. Dismissing is reversible.
        - ANSWER in your own words, 1-2 sentences, like a friend who skimmed their inbox. No pasting email text, no bullet points, headers, greetings, or asterisks. Use the REAL sender names and subjects; never a name not in the data.
        - A login/security code, a "password changed" notice, receipts, and newsletters are FYI - never say the user must act on those.

        What actually needs the user right now, from a reliable check already done for you:
        \(PromptSafety.fence(plate))
        If they ask what needs them or what to do, ANSWER from that list; if it says nothing needs them, say so.

        \(PromptSafety.securityClause)
        """
    }

    static func firstPrompt(question: String) -> String {
        """
        The user (trusted) asks: \(question)

        Reply with SEARCH:, ANSWER:, DRAFT:, or DONE: as the rules describe.
        """
    }

    static func resultsPrompt(query: String, results: String) -> String {
        """
        Numbered search results for "\(query)":
        \(PromptSafety.fence(results))

        Now reply with SEARCH:, ANSWER:, DRAFT: <#> | ..., or DONE: <#>.
        """
    }

    static let recoverPrompt = """
    You referenced an email number that isn't in the latest results. SEARCH first with good keywords, then act on a number that appears. Reply with SEARCH: <keywords>.
    """

    // MARK: - Protocol parsing (pure, testable)

    static func extractSearch(_ s: String) -> String? { directive("SEARCH:", in: s) }
    static func extractAnswer(_ s: String) -> String? {
        guard let r = s.range(of: "ANSWER:", options: .caseInsensitive) else { return nil }
        let a = s[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return a.isEmpty ? nil : a
    }

    /// `DRAFT: <#> | <intent>` -> (index, intent). Intent optional.
    static func extractDraft(_ s: String) -> (index: Int, intent: String)? {
        guard let line = directive("DRAFT:", in: s), let idx = firstInt(line) else { return nil }
        let intent: String
        if let bar = line.firstIndex(of: "|") {
            intent = String(line[line.index(after: bar)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            intent = ""
        }
        return (idx, intent)
    }

    /// `DONE: 1, 3` -> [1, 3].
    static func extractDone(_ s: String) -> [Int]? {
        guard let line = directive("DONE:", in: s) else { return nil }
        let nums = line.split { !$0.isNumber }.compactMap { Int($0) }
        return nums.isEmpty ? nil : nums
    }

    /// The first non-empty line after a `TAG:` directive, or nil.
    private static func directive(_ tag: String, in s: String) -> String? {
        guard let r = s.range(of: tag, options: .caseInsensitive) else { return nil }
        let after = s[r.upperBound...]
        let line = after.split(whereSeparator: \.isNewline).first.map(String.init) ?? String(after)
        let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private static func firstInt(_ s: String) -> Int? {
        let digits = s.drop(while: { !$0.isNumber }).prefix(while: { $0.isNumber })
        return Int(digits)
    }
}

/// A clear action the user asked for in plain language. Detected deterministically
/// (below) rather than hoping the small on-device model emits the right directive -
/// the 3B model reliably WRITES a draft but often skips a "DRAFT: <#>" directive.
enum ActionIntent: Equatable {
    case draft(targetHint: String, intent: String)   // "reply to X saying Y"
    case dismiss(targetHint: String)                 // "clear the X notifications"
}

/// High-precision classifier for action requests. Returns nil for anything that
/// isn't clearly an action, so ordinary questions still flow to the agentic Q&A.
/// Pure + testable.
enum ActionParser {
    static func classify(_ q: String) -> ActionIntent? {
        let lower = q.lowercased().trimmingCharacters(in: .whitespaces)

        // DRAFT: "reply to X saying Y", "respond to X", "write back to X", ...
        let draftVerbs = ["draft a reply to ", "draft a response to ", "write a reply to ",
                          "reply to ", "respond to ", "write back to ", "get back to "]
        for v in draftVerbs {
            guard let r = lower.range(of: v) else { continue }
            let (target, intent) = splitTargetIntent(String(lower[r.upperBound...]))
            let hint = cleanTarget(target)
            if !hint.isEmpty { return .draft(targetHint: hint, intent: intent) }
        }

        // DISMISS: must START with a clearing verb AND refer to mail (high precision,
        // so "clear up what the meeting is" is NOT read as a dismiss).
        let dismissVerbs = ["mark ", "clear ", "dismiss ", "archive ", "get rid of ", "delete "]
        for v in dismissVerbs where lower.hasPrefix(v) || lower.hasPrefix("please " + v) {
            let mailish = ["email", "mail", "notification", "message", "done", "read",
                           "inbox", "newsletter", "from ", "alert"].contains { lower.contains($0) }
            guard mailish else { continue }
            let start = lower.hasPrefix("please ") ? "please " + v : v
            guard let r = lower.range(of: start) else { continue }
            let hint = cleanTarget(dismissClean(String(lower[r.upperBound...])))
            if !hint.isEmpty { return .dismiss(targetHint: hint) }
        }
        return nil
    }

    /// Split "X saying Y" (and variants) into target X and intent Y.
    static func splitTargetIntent(_ s: String) -> (target: String, intent: String) {
        let delims = [" saying ", " to say ", " telling them ", " telling ",
                      " that i ", " that we ", " that i'll ", ", say ", " and say ", ": "]
        for d in delims {
            if let r = s.range(of: d) {
                let intent = String(s[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                // Keep the natural leading word for "that i / that we" splits.
                let prefix = d.contains("that") ? String(d.dropFirst().dropLast()) + " " : ""
                return (String(s[..<r.lowerBound]), prefix + intent)
            }
        }
        return (s, "")
    }

    /// Strip articles and trailing "email/message/notification(s)" so the remainder
    /// is good search keywords.
    static func cleanTarget(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        for a in ["the ", "my ", "that ", "this ", "an ", "a "] where t.hasPrefix(a) { t = String(t.dropFirst(a.count)) }
        for n in [" emails", " email", " messages", " message", " mail", " threads", " thread",
                  " notifications", " notification", " alerts", " alert", " one", " ones"] where t.hasSuffix(n) {
            t = String(t.dropLast(n.count))
        }
        return t.trimmingCharacters(in: .whitespaces)
    }

    static func dismissClean(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        for suffix in [" as done", " as read", " done", " read"] where t.hasSuffix(suffix) {
            t = String(t.dropLast(suffix.count))
        }
        return t.trimmingCharacters(in: .whitespaces)
    }
}

/// Read-only inbox search shared by the agent (and directly unit-testable). Pure,
/// no model and no FoundationModels dependency.
enum InboxSearch {
    /// Rank the inbox for `query`, returning both the NUMBERED rendering for the
    /// model and the ordered messages (so the agent can map a result number back to
    /// a message for actions). Honest: if the query has real terms but nothing
    /// matches (rank fell back to recent), returns "No matching emails." + [].
    static func search(query: String, messages: [MailMessage], mine: Set<String>, limit: Int = 10)
        -> (text: String, hits: [MailMessage]) {
        let ranked = MailRetrieval.rank(question: query, messages: messages, limit: limit)
        let terms = queryTerms(query)
        let realMatch = terms.isEmpty || ranked.contains { m in
            let hay = (m.subject + " " + (m.snippet ?? "") + " " + m.senderDisplay).lowercased()
            return terms.contains { hay.contains($0) }
        }
        guard !ranked.isEmpty, realMatch else { return ("No matching emails.", []) }

        let hits = ranked.sorted { $0.dateReceived > $1.dateReceived }
        let now = Date()
        let rel = RelativeDateTimeFormatter()
        let text = hits.enumerated().map { i, m -> String in
            let when = rel.localizedString(for: m.dateReceived, relativeTo: now)
            let read = m.isRead ? "" : " UNREAD"
            let sender = PromptSafety.sanitize(m.senderDisplay, maxChars: 48)
            let subject = PromptSafety.sanitize(String(m.subject.prefix(90)), maxChars: 90)
            let snip = PromptSafety.sanitize(String((m.snippet ?? "").prefix(120)), maxChars: 120)
            return "[\(i + 1)] (\(when))\(read)\(kind(of: m, mine: mine)) \(sender): \(subject)" + (snip.isEmpty ? "" : " - \(snip)")
        }.joined(separator: "\n")
        return (text, hits)
    }

    /// Text-only rendering (used by tests and any non-action caller).
    static func results(query: String, messages: [MailMessage], mine: Set<String>, limit: Int = 10) -> String {
        search(query: query, messages: messages, mine: mine, limit: limit).text
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
