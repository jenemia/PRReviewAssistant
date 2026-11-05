import Foundation

/// A review role or UnitTest skill file that the agents read at run time.
struct EditableSkill: Identifiable, Hashable, Sendable {
    enum Group: String, Sendable { case review = "리뷰 에이전트", unitTest = "UnitTest 스킬" }
    let name: String
    let url: URL
    let group: Group
    var id: String { url.path }
}

/// Lists, reads and saves the files behind the review workflow (`~/.cursor/agents/<role>.md`)
/// and the UnitTest skills (`~/.cursor/skills/unittest-*/SKILL.md`). Only files found by
/// `list()` can be read or written, so the editor never touches arbitrary paths.
struct SkillFileStore: Sendable {
    /// Roles `CursorReviewWorkflow` loads for a branch review.
    static let reviewRoles = ["spec-search-agent", "structure-agent", "code-reviewer", "maintenance-reviewer", "scope-guard", "risk-guard"]
    static let unitTestPrefix = "unittest-"
    static let defaultUnitTestSkills = ["unittest-csharp-base", "unittest-unity-base", "unittest-domain-currency", "unittest-domain-time-season", "unittest-writer"]

    let agentsDirectory: URL
    let skillsDirectory: URL

    init(
        cursorDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cursor")
    ) {
        agentsDirectory = cursorDirectory.appendingPathComponent("agents")
        skillsDirectory = cursorDirectory.appendingPathComponent("skills")
    }

    func list() -> [EditableSkill] {
        let review = Self.reviewRoles.compactMap { role -> EditableSkill? in
            let url = agentsDirectory.appendingPathComponent("\(role).md")
            return FileManager.default.fileExists(atPath: url.path) ? EditableSkill(name: role, url: url, group: .review) : nil
        }
        let folders = (try? FileManager.default.contentsOfDirectory(atPath: skillsDirectory.path)) ?? []
        let unitTest = folders.filter { $0.hasPrefix(Self.unitTestPrefix) }.sorted().compactMap { folder -> EditableSkill? in
            let url = skillsDirectory.appendingPathComponent(folder).appendingPathComponent("SKILL.md")
            return FileManager.default.fileExists(atPath: url.path) ? EditableSkill(name: folder, url: url, group: .unitTest) : nil
        }
        return review + unitTest
    }

    func read(_ skill: EditableSkill) throws -> String {
        try String(contentsOf: try validated(skill), encoding: .utf8)
    }

    /// Empty text is refused: the review workflow rejects empty role files.
    func write(_ text: String, to skill: EditableSkill) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CommandError.failed(.init(output: "", error: "내용이 비어 있어 저장하지 않았습니다.", status: 1))
        }
        try text.write(to: try validated(skill), atomically: true, encoding: .utf8)
    }

    /// `scripts/package-app.sh` copies the defaults into the app's `Contents/Resources`.
    static let bundledDefault: @Sendable (String) -> URL? = { Bundle.main.url(forResource: $0, withExtension: "md") }

    /// Copies the bundled defaults that are missing. Existing (possibly edited) files are never overwritten.
    @discardableResult
    func installDefaultUnitTestSkills(defaultFile: @Sendable (String) -> URL? = SkillFileStore.bundledDefault) throws -> Int {
        var installed = 0
        for name in Self.defaultUnitTestSkills {
            let folder = skillsDirectory.appendingPathComponent(name)
            let target = folder.appendingPathComponent("SKILL.md")
            if FileManager.default.fileExists(atPath: target.path) { continue }
            guard let source = defaultFile(name) else {
                throw CommandError.failed(.init(output: "", error: "앱에 포함된 기본 스킬 '\(name)'을 찾을 수 없습니다.", status: 1))
            }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: target)
            installed += 1
        }
        return installed
    }

    private func validated(_ skill: EditableSkill) throws -> URL {
        guard list().contains(skill) else {
            throw CommandError.failed(.init(output: "", error: "편집할 수 있는 스킬 파일이 아닙니다.", status: 1))
        }
        return skill.url
    }
}
