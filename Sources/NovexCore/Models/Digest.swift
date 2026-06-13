import Foundation

/// "Catch me up" — a deterministic, grouped digest of recent mail. Turns the
/// flood (job alerts, newsletters…) into something readable instead of a flat
/// list. For jobs it best-effort extracts the role + company from the subject.
struct DigestItem: Identifiable, Equatable, Sendable {
    let label: String        // the useful bit (role, or cleaned subject)
    let sub: String          // company / sender
    let messageID: String?
    var matches: Bool = false // matches the owner's learned interests
    var id: String { messageID ?? "\(label)|\(sub)" }
}

struct DigestSection: Identifiable, Equatable, Sendable {
    let category: MailCategory
    let items: [DigestItem]
    let total: Int           // before per-section capping
    var id: String { category.rawValue }
}

struct Digest: Equatable, Sendable {
    let sections: [DigestSection]
    let total: Int
    var isEmpty: Bool { sections.isEmpty }

    /// Build from collapsed recent mail. Pure + deterministic (no LLM).
    static func build(from groups: [BriefingService.MessageGroup], maxPerSection: Int = 5) -> Digest {
        var byCat: [MailCategory: [DigestItem]] = [:]
        var totals: [MailCategory: Int] = [:]
        for g in groups.prefix(60) {
            let cat = MailCategory.of(g.message)
            totals[cat, default: 0] += 1
            guard (byCat[cat]?.count ?? 0) < maxPerSection else { continue }
            byCat[cat, default: []].append(item(for: g.message, category: cat))
        }
        // A sensible reading order.
        let order: [MailCategory] = [.personal, .job, .social, .update, .newsletter]
        let sections = order.compactMap { cat -> DigestSection? in
            guard let items = byCat[cat], !items.isEmpty else { return nil }
            return DigestSection(category: cat, items: items, total: totals[cat] ?? items.count)
        }
        return Digest(sections: sections, total: groups.count)
    }

    private static func item(for m: MailMessage, category: MailCategory) -> DigestItem {
        let match = OwnerModel.matches(m)
        if category == .job, let role = extractRole(m.subject) {
            return DigestItem(label: role,
                              sub: extractCompany(m.subject) ?? m.senderDisplay,
                              messageID: m.messageID, matches: match)
        }
        return DigestItem(label: cleanSubject(m.subject), sub: m.senderDisplay,
                          messageID: m.messageID, matches: match)
    }

    // MARK: - Best-effort extraction (pure)

    static func extractRole(_ subject: String) -> String? {
        for marker in ["hiring a ", "hiring an ", "hiring for ", "is hiring ", "hiring "] {
            guard let r = subject.range(of: marker, options: .caseInsensitive) else { continue }
            var role = String(subject[r.upperBound...])
            for delim in ["–", "—", " - ", "(", "|", " at ", ",", " in "] {
                if let d = role.range(of: delim) { role = String(role[..<d.lowerBound]) }
            }
            role = role.trimmingCharacters(in: .whitespaces)
            if role.count >= 4 { return String(role.prefix(42)) }
        }
        return nil
    }

    static func extractCompany(_ subject: String) -> String? {
        guard let r = subject.range(of: " is hiring", options: .caseInsensitive) else { return nil }
        let c = String(subject[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
        return c.count >= 2 ? String(c.prefix(40)) : nil
    }

    static func cleanSubject(_ subject: String) -> String {
        var s = subject
        while let r = s.range(of: #"^\s*(re|fwd|fw)\s*:\s*"#, options: [.regularExpression, .caseInsensitive]) {
            s.removeSubrange(r)
        }
        return String(s.trimmingCharacters(in: .whitespaces).prefix(64))
    }
}
