import Foundation

/// A repository's parent-branch rule text: lines of `head pattern -> parent`.
/// The first matching line wins and `#` lines are comments. In the pattern `*` matches one
/// path segment (captured as `$1`, `$2`, …) and a trailing `**` matches one or more segments.
enum ParentBranchRules {
    /// Kept for repositories registered before rules were set per repository.
    static let sprintDefault = "sprint/*/** -> sprint/$1/main"

    struct Match: Equatable {
        let parent: String
        /// Number of leading segments before `**`, when the pattern has one.
        let prefixCount: Int?
    }

    static func match(_ name: String, rules: String) -> Match? {
        let parts = name.split(separator: "/").map(String.init)
        for rule in lines(of: rules) {
            let sides = rule.components(separatedBy: "->").map { $0.trimmingCharacters(in: .whitespaces) }
            guard sides.count == 2, !sides[1].isEmpty else { continue }
            let pattern = sides[0].split(separator: "/").map(String.init)
            guard let captures = captures(of: pattern, in: parts) else { continue }
            var parent = sides[1]
            for (index, value) in captures.enumerated().reversed() {
                parent = parent.replacingOccurrences(of: "$\(index + 1)", with: value)
            }
            return Match(parent: parent, prefixCount: pattern.last == "**" ? pattern.count - 1 : nil)
        }
        return nil
    }

    /// A branch whose parent is itself has no parent.
    static func parent(of name: String, rules: String) -> String? {
        guard let parent = match(name, rules: rules)?.parent, parent != name else { return nil }
        return parent
    }

    /// Keeps the matched rule's prefix before `**` and replaces the next segment with `unittest`:
    /// `sprint/s29/feature/x` → `sprint/s29/unittest/x`, `feature/x` → `unittest/x`.
    static func unitTestBranchName(for name: String, rules: String) -> String {
        let parts = name.split(separator: "/").map(String.init)
        let prefixCount = match(name, rules: rules)?.prefixCount ?? 0
        let prefix = Array(parts.prefix(prefixCount))
        let rest = Array(parts.dropFirst(prefixCount))
        return (prefix + ["unittest"] + (rest.count > 1 ? Array(rest.dropFirst()) : rest)).joined(separator: "/")
    }

    static func invalidLines(_ rules: String) -> [String] {
        lines(of: rules).filter { line in
            let sides = line.components(separatedBy: "->").map { $0.trimmingCharacters(in: .whitespaces) }
            return sides.count != 2 || sides.contains(where: \.isEmpty)
        }
    }

    private static func lines(of rules: String) -> [String] {
        rules.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    private static func captures(of pattern: [String], in parts: [String]) -> [String]? {
        guard !pattern.isEmpty else { return nil }
        var captures: [String] = []
        for (index, segment) in pattern.enumerated() {
            if segment == "**" { return index == pattern.count - 1 && parts.count > index ? captures : nil }
            guard index < parts.count, segment == "*" || segment == parts[index] else { return nil }
            if segment == "*" { captures.append(parts[index]) }
        }
        return parts.count == pattern.count ? captures : nil
    }
}

/// What the agent derived from a branch-rule skill. The user approves it before it is saved.
struct ParentBranchRuleProposal: Decodable, Equatable, Sendable {
    var rules: String
    var evidence: [String] = []
    var unsupported: [String] = []

    private enum CodingKeys: String, CodingKey { case rules, evidence, unsupported }

    init(rules: String, evidence: [String] = [], unsupported: [String] = []) {
        self.rules = rules
        self.evidence = evidence
        self.unsupported = unsupported
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rules = try container.decode(String.self, forKey: .rules)
        evidence = try container.decodeIfPresent([String].self, forKey: .evidence) ?? []
        unsupported = try container.decodeIfPresent([String].self, forKey: .unsupported) ?? []
    }
}
