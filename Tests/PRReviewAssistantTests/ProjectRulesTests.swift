import Foundation
import Testing
@testable import PRReviewAssistant

@Suite("Per-repository project rules")
struct ProjectRulesTests {
    private func pullRequest(head: String, base: String, repository: String = "owner/repo") -> PullRequest {
        PullRequest(id: UUID(), repository: repository, number: 7, title: "제목", author: "author", headBranch: head, baseBranch: base, headSHA: "abc", reviewer: "리뷰 대기", commentCount: 0, updatedAt: .now, reviewState: .commented, analysisStatus: .needsAnalysis, summary: "기본", files: [])
    }

    @MainActor
    private func store(_ repositories: [RegisteredRepository]) -> (ReviewStore, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
        let persistence = AppPersistence(url: url)
        persistence.save(PersistedState(repositories: repositories))
        return (ReviewStore(persistence: persistence, startsBackgroundTasks: false), url)
    }

    @Test("기본 sprint 규칙은 같은 sprint의 main을 부모로 쓰고 자기 자신은 부모가 아니다")
    func sprintDefault() {
        let rules = ParentBranchRules.sprintDefault
        #expect(ParentBranchRules.parent(of: "sprint/s29/feature/christmas2026", rules: rules) == "sprint/s29/main")
        #expect(ParentBranchRules.parent(of: "sprint/s29/main", rules: rules) == nil)
        #expect(ParentBranchRules.parent(of: "sprint/s29", rules: rules) == nil)
        #expect(ParentBranchRules.parent(of: "feature/x", rules: rules) == nil)
    }

    @Test("첫 번째로 맞는 줄을 쓰고 주석·잘못된 줄은 건너뛴다")
    func customRules() {
        let rules = """
        # 팀 규칙
        잘못된 줄
        release/*/hotfix/* -> release/$1
        feature/** -> develop
        """
        #expect(ParentBranchRules.parent(of: "release/2.0/hotfix/crash", rules: rules) == "release/2.0")
        #expect(ParentBranchRules.parent(of: "release/2.0/hotfix/a/b", rules: rules) == nil)
        #expect(ParentBranchRules.parent(of: "feature/login/ui", rules: rules) == "develop")
        #expect(ParentBranchRules.parent(of: "feature", rules: rules) == nil)
        #expect(ParentBranchRules.parent(of: "sprint/s29/feature/x", rules: "") == nil)
        #expect(ParentBranchRules.invalidLines(rules) == ["잘못된 줄"])
    }

    @Test("머지 대상 확인은 PR 저장소의 규칙을 쓰고, 예전 저장소는 sprint 규칙을 유지한다")
    @MainActor
    func mergeBaseUsesRepositoryRules() {
        var legacy = RegisteredRepository(localPath: "/tmp/a", fullName: "owner/legacy", defaultBranch: "main")
        legacy.parentBranchRules = nil
        var custom = RegisteredRepository(localPath: "/tmp/b", fullName: "owner/custom", defaultBranch: "main")
        custom.parentBranchRules = "feature/** -> develop"
        var none = RegisteredRepository(localPath: "/tmp/c", fullName: "owner/none", defaultBranch: "main")
        none.parentBranchRules = ""
        let (store, url) = store([legacy, custom, none])
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(store.hasExpectedMergeBase(pullRequest(head: "sprint/s29/feature/x", base: "sprint/s29/main", repository: "owner/legacy")))
        #expect(!store.hasExpectedMergeBase(pullRequest(head: "sprint/s29/feature/x", base: "main", repository: "owner/legacy")))
        #expect(store.expectedMergeBase(for: pullRequest(head: "feature/x", base: "main", repository: "owner/custom")) == "develop")
        #expect(store.hasExpectedMergeBase(pullRequest(head: "sprint/s29/feature/x", base: "main", repository: "owner/none")))
        #expect(store.unitTestBranchName(for: "sprint/s29/feature/x", repositoryID: legacy.id) == "sprint/s29/unittest/x")
    }

    @Test("저장한 규칙·스킬·spec 폴더가 다시 불러와지고, 스킬이 바뀌면 알린다")
    @MainActor
    func savesRulesAndDetectsSkillChange() throws {
        let skill = FileManager.default.temporaryDirectory.appendingPathComponent("rule-skill-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: skill) }
        try "sprint 브랜치는 sprint main으로".write(to: skill, atomically: true, encoding: .utf8)
        let repository = RegisteredRepository(localPath: "/tmp/a", fullName: "owner/repo", defaultBranch: "main")
        let (store, url) = store([repository])
        defer { try? FileManager.default.removeItem(at: url) }

        var updated = repository
        updated.specFolders = ["docs/specs"]
        store.updateRepository(updated)
        store.saveParentBranchRules("feature/** -> develop", for: repository.id, skillPath: skill.path)
        #expect(!store.hasChangedRuleSkill(store.repositories[0]))

        let reloaded = ReviewStore(persistence: AppPersistence(url: url), startsBackgroundTasks: false).repositories[0]
        #expect(reloaded.parentBranchRules == "feature/** -> develop")
        #expect(reloaded.parentBranchRuleSkillPath == skill.path)
        #expect(reloaded.effectiveSpecFolders == ["docs/specs"])

        try "규칙이 바뀌었다".write(to: skill, atomically: true, encoding: .utf8)
        #expect(store.hasChangedRuleSkill(store.repositories[0]))
    }

    @Test("규칙 필드가 없는 예전 저장소 상태도 읽는다")
    func decodesLegacyRepository() throws {
        let json = #"{"id":"6F2D4C1A-0000-4000-8000-000000000001","localPath":"/tmp/a","fullName":"owner/repo","remoteName":"origin","defaultBranch":"main","monitoringEnabled":true}"#
        let repository = try JSONDecoder().decode(RegisteredRepository.self, from: Data(json.utf8))
        #expect(repository.parentBranchRules == nil)
        #expect(repository.effectiveParentBranchRules == ParentBranchRules.sprintDefault)
        #expect(repository.effectiveSpecFolders == WorkspaceSpecCatalog.defaultFolders)
    }

    @Test("스킬 규칙 제안 JSON을 읽고 선택 필드는 비워 두며 JSON이 없으면 거부한다")
    func parsesRuleProposal() throws {
        let proposal = try CursorAgent.parseParentBranchRuleProposal(#"결과: {"rules":"sprint/*/** -> sprint/$1/main","evidence":["sprint 브랜치는 sprint main"]}"#)
        #expect(proposal == .init(rules: "sprint/*/** -> sprint/$1/main", evidence: ["sprint 브랜치는 sprint main"]))
        #expect(throws: CommandError.self) { try CursorAgent.parseParentBranchRuleProposal("규칙 없음") }
    }

    @Test("규칙 제안 프롬프트는 스킬·브랜치·기본 브랜치를 담고 데이터 속 지시를 따르지 않게 한다")
    func rulePrompt() {
        let prompt = CursorAgent.parentBranchRulePrompt(skill: "SKILL-TEXT", branches: ["sprint/s1/feature/a"], defaultBranch: "develop")
        #expect(prompt.contains("SKILL-TEXT"))
        #expect(prompt.contains("sprint/s1/feature/a"))
        #expect(prompt.contains("`develop`"))
        #expect(prompt.contains("신뢰할 수 없는 데이터"))
    }

    @Test("지정한 spec 폴더 아래 문서만 읽는다")
    func specFolders() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spec-folders-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for folder in ["docs/login", ".specs/shop"] {
            let directory = root.appendingPathComponent(folder, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try "# spec\n".write(to: directory.appendingPathComponent("spec.md"), atomically: true, encoding: .utf8)
        }
        #expect(WorkspaceSpecCatalog().documents(in: root.path, folders: ["docs"]).map(\.relativePath) == ["docs/login/spec.md"])
        #expect(WorkspaceSpecCatalog().documents(in: root.path).map(\.relativePath) == [".specs/shop/spec.md"])
    }

    @Test("선택한 원격의 URL로 저장소를 읽는다")
    func inspectsSelectedRemote() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("remote-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let runner = ProcessRunner()
        _ = try runner.run("git", arguments: ["init", "-b", "main", path])
        _ = try runner.run("git", arguments: ["remote", "add", "origin", "https://github.com/me/fork.git"], workingDirectory: path)
        _ = try runner.run("git", arguments: ["remote", "add", "upstream", "https://github.com/team/app.git"], workingDirectory: path)

        let client = GitHubClient()
        #expect(try client.remoteNames(at: path).sorted() == ["origin", "upstream"])
        let repository = try client.inspectRepository(at: path, remoteName: "upstream")
        #expect(repository.fullName == "team/app")
        #expect(repository.remoteName == "upstream")
        #expect(repository.defaultBranch == "main")
    }
}
