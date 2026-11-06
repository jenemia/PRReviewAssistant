import Foundation

/// Result of the pre-PR UnitTest step (generate → validate → commit/push).
/// It is tied to the commit that was verified, so a later commit invalidates it.
struct UnitTestVerification: Hashable, Codable, Sendable {
    enum Outcome: String, Codable, Sendable { case passed, notApplicable, failed }

    struct FileResult: Hashable, Codable, Sendable, Identifiable {
        enum Status: String, Codable, Sendable { case passed, failed, skipped }
        var sourcePath: String
        var testPath: String?
        var status: Status
        var detail: String
        var id: String { sourcePath }
    }

    var outcome: Outcome
    /// Full SHA of the branch head that was verified.
    var verifiedSHA: String
    /// Full SHA of the branch after the step; differs from `verifiedSHA` when tests were pushed.
    var resultSHA: String
    var pushed: Bool
    var summary: String
    var files: [FileResult]
    var verifiedAt = Date()

    /// The PR gate: nothing failed, and the result still describes the branch head.
    func satisfies(branchSHA: String) -> Bool {
        guard outcome != .failed, !branchSHA.isEmpty else { return false }
        return resultSHA.hasPrefix(branchSHA) || branchSHA.hasPrefix(resultSHA)
    }
}

/// The agent's answer for one source file. The app never trusts it: every file
/// goes through `UnitTestVerifier.violations` before anything is written.
struct UnitTestProposal: Decodable, Sendable {
    struct File: Decodable, Hashable, Sendable {
        let path: String
        let content: String
    }

    let status: String
    let reason: String
    let files: [File]
    let dependencies: [String]?

    static let generated = "generated"

    private enum CodingKeys: String, CodingKey { case status, reason, files, dependencies }

    init(status: String, reason: String = "", files: [File] = [], dependencies: [String]? = nil) {
        self.status = status
        self.reason = reason
        self.files = files
        self.dependencies = dependencies
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? Self.generated
        reason = try container.decodeIfPresent(String.self, forKey: .reason) ?? ""
        files = try container.decodeIfPresent([File].self, forKey: .files) ?? []
        dependencies = try container.decodeIfPresent([String].self, forKey: .dependencies)
    }

    /// Reads the first `{` to the last `}` so code fences or a sentence around the JSON are tolerated.
    static func parse(_ output: String) throws -> UnitTestProposal {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.firstIndex(of: "{"), let last = trimmed.lastIndex(of: "}"), first <= last else {
            throw CommandError.failed(.init(output: output, error: "Agent가 UnitTest 제안을 JSON으로 반환하지 않았습니다.", status: 1))
        }
        do {
            return try JSONDecoder().decode(UnitTestProposal.self, from: Data(trimmed[first...last].utf8))
        } catch {
            throw CommandError.failed(.init(output: output, error: "Agent UnitTest 제안 형식이 올바르지 않습니다: \(error.localizedDescription)", status: 1))
        }
    }
}
