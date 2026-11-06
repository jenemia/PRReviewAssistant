import Foundation
import Testing
@testable import PRReviewAssistant

@Suite("UnitTest verification")
struct UnitTestVerifierTests {
    @Test("기존 테스트 경로와 일반 소스 경로를 구분한다")
    func classifiesPaths() {
        #expect(UnitTestVerifier.isTestPath("Tests/Demo.Tests/ItemPriceTests.cs"))
        #expect(UnitTestVerifier.isTestPath("Assets/Scripts/ItemPriceTests.cs"))
        #expect(!UnitTestVerifier.isTestPath("Assets/Scripts/Item/ItemPrice.cs"))
    }

    @Test("선택 브랜치와 같은 sprint 아래 unittest 브랜치 이름을 만든다")
    func namesUnitTestBranch() {
        #expect(UnitTestVerifier.unitTestBranchName(for: "sprint/s29/feature/christmas2026") == "sprint/s29/unittest/christmas2026")
        #expect(UnitTestVerifier.unitTestBranchName(for: "feature/x") == "unittest/x")
        #expect(UnitTestVerifier.unitTestBranchName(for: "main") == "unittest/main")
    }

    @Test("patch guard가 테스트 경로 밖 파일·덮어쓰기·금지 토큰을 거부한다")
    func guardsProposal() {
        let ok = UnitTestProposal.File(path: "Tests/Shop/PriceTests.cs", content: "class PriceTests {}")
        #expect(UnitTestVerifier.violations(of: [ok], existingPaths: []).isEmpty)
        #expect(UnitTestVerifier.violations(of: [], existingPaths: []) == ["생성 파일 없음"])

        let production = UnitTestProposal.File(path: "Assets/Scripts/Price.cs", content: "class Price {}")
        #expect(!UnitTestVerifier.violations(of: [production], existingPaths: []).isEmpty)
        let escaping = UnitTestProposal.File(path: "Tests/../Assets/PriceTests.cs", content: "")
        #expect(!UnitTestVerifier.violations(of: [escaping], existingPaths: []).isEmpty)
        #expect(!UnitTestVerifier.violations(of: [ok], existingPaths: [ok.path]).isEmpty)
        let unity = UnitTestProposal.File(path: "Tests/PriceTests.cs", content: "using UnityEngine;")
        #expect(!UnitTestVerifier.violations(of: [unity], existingPaths: []).isEmpty)
    }

    @Test("정책에 맞고 기존 테스트와 충돌하지 않는 경로를 제안한다")
    func suggestsPathAndDetectsExistingTests() {
        let tests = ["Tests/Demo.Tests/Item/ItemPriceTests.cs", "Tests/Demo.Tests/Inventory/InventorySlotsTests.cs"]
        #expect(UnitTestVerifier.suggestedTestPath(for: "Assets/Scripts/Shop/ShopDiscount.cs", testFiles: []) == "Tests/ShopDiscountTests.cs")
        #expect(UnitTestVerifier.suggestedTestPath(for: "Assets/Scripts/Item/ItemPrice.cs", testFiles: tests).hasSuffix("ItemPriceDiffTests.cs"))
        #expect(UnitTestVerifier.suggestedTestPath(for: "Assets/Scripts/Shop/ShopDiscount.cs", testFiles: ["Assets/Editor/ViewTests.cs"]) == "Tests/ShopDiscountTests.cs")
    }

    @Test("dotnet 결과 요약과 검증 프로젝트를 만든다")
    func parsesCountsAndBuildsProject() {
        let trx = #"<ResultSummary outcome="Completed"><Counters total="4" executed="3" passed="3" error="0" failed="1" timeout="0" notExecuted="1" /></ResultSummary>"#
        let counts = UnitTestVerifier.testCounts(inTRX: trx)
        #expect(counts?.failed == 1 && counts?.passed == 3 && counts?.skipped == 1)
        #expect(UnitTestVerifier.testCounts(inTRX: "error CS0246: type not found") == nil)

        let project = UnitTestVerifier.validationProject(sourceFiles: ["Source/A&B.cs"], testFiles: ["Tests/0_ATests.cs"], framework: "net10.0")
        #expect(project.contains("<TargetFramework>net10.0</TargetFramework>"))
        #expect(project.contains("Source/A&amp;B.cs"))
        #expect(project.contains("NUnit\" Version=\"3.14.0\""))
    }

    @Test("Agent JSON 제안을 파싱하고 JSON이 없으면 거부한다")
    func parsesProposal() throws {
        let proposal = try UnitTestProposal.parse("""
        ```json
        {"status":"generated","reason":"ok","files":[{"path":"Tests/ATests.cs","content":"x"}]}
        ```
        """)
        #expect(proposal.status == "generated" && proposal.files.count == 1)
        let skipped = try UnitTestProposal.parse(#"{"status":"needs_source_change","reason":"public API 없음","files":[]}"#)
        #expect(skipped.status == "needs_source_change")
        #expect(throws: UnitTestProposal.ParseError.missingJSON) { try UnitTestProposal.parse("테스트를 만들 수 없습니다.") }
        #expect(throws: UnitTestProposal.ParseError.invalidProposal) {
            try UnitTestProposal.parse(#"{"status":"generated|needs_source_change|unity_dependent","reason":"","files":[]}"#)
        }
        #expect(throws: UnitTestProposal.ParseError.invalidProposal) { try UnitTestProposal.parse("{}") }
    }

    @Test("Cursor 스트림에서 최종 JSON만 제안으로 읽는다")
    func parsesFinalStreamProposal() throws {
        let content = "using NUnit.Framework;\n[TestFixture] public class ATests { }"
        let json = try JSONSerialization.data(withJSONObject: [
            "status": "generated", "reason": "ok",
            "files": [["path": "Tests/ATests.cs", "content": content]]
        ])
        let event = try JSONSerialization.data(withJSONObject: [
            "type": "result", "subtype": "success", "is_error": false,
            "result": String(decoding: json, as: UTF8.self)
        ])
        let stream = #"{"type":"assistant","message":{"content":[{"text":"생성 중"}]}}"# + "\n" + String(decoding: event, as: UTF8.self)
        let final = try CursorAgent.streamResult(.init(output: stream, error: "", status: 0))
        let proposal = try UnitTestProposal.parse(final.text)
        #expect(proposal.files.first?.content == content)
    }

    @Test("검증 결과는 같은 커밋이고 실패가 아닐 때만 PR 게이트를 통과한다")
    func gatesOnCommit() {
        func result(_ outcome: UnitTestVerification.Outcome, sha: String = "abc1234567") -> UnitTestVerification {
            .init(outcome: outcome, verifiedSHA: sha, resultSHA: sha, pushed: false, summary: "", files: [])
        }
        #expect(result(.passed).satisfies(branchSHA: "abc1234"))
        #expect(result(.notApplicable).satisfies(branchSHA: "abc1234"))
        #expect(!result(.failed).satisfies(branchSHA: "abc1234"))
        #expect(!result(.passed).satisfies(branchSHA: "def5678"))
    }

    @Test("프롬프트에 규칙·소스·이전 오류를 담는다")
    func buildsPrompt() {
        let target = UnitTestVerifier.Target(sourcePath: "Assets/Price.cs", source: "class Price {}", diff: "", suggestedTestPath: "Tests/PriceTests.cs", stylePath: nil, styleSample: nil)
        let prompt = CursorAgent.unitTestPrompt(for: .init(target: target, previousError: "error CS1002"))
        #expect(prompt.contains("NUnit 3"))
        #expect(prompt.contains("class Price {}"))
        #expect(prompt.contains("error CS1002"))
        #expect(prompt.contains("Tests/PriceTests.cs"))
    }
}

@Suite("UnitTest verification workflow")
struct UnitTestWorkflowTests {
    private struct Fixture {
        let root: URL
        let repository: RegisteredRepository
        let branch: RepositoryBranch
        let head: String
        let runner = ProcessRunner()

        func remoteHead() throws -> String {
            try runner.run("git", arguments: ["--git-dir", root.appending(path: "remote.git").path, "rev-parse", "feature/x"])
                .output.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        func remoteFiles(_ ref: String = "feature/x") throws -> [String] {
            try runner.run("git", arguments: ["--git-dir", root.appending(path: "remote.git").path, "ls-tree", "-r", "--name-only", ref])
                .output.split(whereSeparator: \.isNewline).map(String.init)
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    private func makeFixture() throws -> Fixture {
        let runner = ProcessRunner()
        let root = FileManager.default.temporaryDirectory.appending(path: "UnitTestWorkflow-\(UUID().uuidString)", directoryHint: .isDirectory)
        let remote = root.appending(path: "remote.git"), work = root.appending(path: "work")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        func git(_ arguments: [String], at path: String? = nil) throws {
            _ = try runner.run("git", arguments: arguments, workingDirectory: path ?? work.path)
        }
        _ = try runner.run("git", arguments: ["init", "--bare", remote.path])
        _ = try runner.run("git", arguments: ["init", "-b", "main", work.path])
        try git(["config", "user.name", "Tester"]); try git(["config", "user.email", "tester@example.invalid"])
        func write(_ path: String, _ text: String) throws {
            let url = work.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        try write("Tests/Demo.Tests/Item/ItemPriceTests.cs", "class ItemPriceTests {}")
        try git(["add", "."]); try git(["commit", "-m", "base"])
        try git(["remote", "add", "origin", remote.path]); try git(["push", "-u", "origin", "main"])
        try git(["switch", "-c", "feature/x"])
        try write("Assets/Scripts/Shop/DiscountRules.cs", "namespace Demo { public static class DiscountRules { public const int Minimum = 0; } }")
        try write("Assets/Scripts/Shop/ShopDiscount.cs", "namespace Demo { public static class ShopDiscount { public static int Apply(int p) => p; } }")
        try write("Assets/Scripts/Shop/ShopView.cs", "using UnityEngine;\nclass ShopView : MonoBehaviour {}")
        try write("Assets/Scripts/Item/ItemPrice.cs", "namespace Demo { public static class ItemPrice {} }")
        try git(["add", "."]); try git(["commit", "-m", "feature"]); try git(["push", "-u", "origin", "feature/x"])
        let head = try runner.run("git", arguments: ["rev-parse", "HEAD"], workingDirectory: work.path).output.trimmingCharacters(in: .whitespacesAndNewlines)
        let repository = RegisteredRepository(localPath: work.path, fullName: "local/test", defaultBranch: "main", monitoringEnabled: false)
        let branch = RepositoryBranch(repositoryID: repository.id, repositoryName: "local/test", name: "feature/x", reference: "origin/feature/x", sha: String(head.prefix(7)), subject: "feature", updatedAt: nil, isCurrent: true, isRemote: true)
        return Fixture(root: root, repository: repository, branch: branch, head: head)
    }

    private static func selectShopDiscount(_ workspace: String, _ comparisonBase: String, _ changes: [UnitTestVerifier.Change]) -> [UnitTestVerifier.Candidate] {
        changes.filter { $0.sourcePath.hasSuffix("/ShopDiscount.cs") }.map {
            .init(sourcePath: $0.sourcePath, behavior: "가격 계산 규칙", priority: 3)
        }
    }

    private let proposal = UnitTestProposal(status: "generated", files: [
        .init(path: "Tests/Demo.Tests/Shop/ShopDiscountTests.cs", content: "class ShopDiscountTests {}")
    ])

    @Test("병합된 로컬 브랜치의 병합 전 변경 범위를 검증하고 새 원격 브랜치에 푸시한다")
    func verifiesMergedLocalBranch() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let path = fixture.repository.localPath
        _ = try fixture.runner.run("git", arguments: ["switch", "main"], workingDirectory: path)
        _ = try fixture.runner.run("git", arguments: ["merge", "--no-ff", "feature/x", "-m", "merge feature"], workingDirectory: path)
        _ = try fixture.runner.run("git", arguments: ["push", "origin", "main"], workingDirectory: path)
        var branch = fixture.branch
        branch.reference = "refs/heads/feature/x"
        branch.isRemote = false
        let verifier = UnitTestVerifier { _, _, _ in .init(success: true, log: "Passed!") }
        let result = try verifier.verify(
            repository: fixture.repository, branch: branch, baseReference: "origin/main", developerName: "테스터",
            select: Self.selectShopDiscount,
            generate: { _ in proposal }, progress: { _ in }
        )
        #expect(result.outcome == .passed && result.pushed)
        #expect(result.verifiedSHA == fixture.head)
        #expect(try fixture.remoteHead() == fixture.head)
        #expect(try fixture.remoteFiles(result.resultSHA).contains("Tests/Demo.Tests/Shop/ShopDiscountTests.cs"))
    }

    @Test("병합 전 범위를 특정할 수 없으면 테스트를 생성하거나 푸시하지 않는다")
    func rejectsAmbiguousMergedRange() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let path = fixture.repository.localPath
        _ = try fixture.runner.run("git", arguments: ["switch", "main"], workingDirectory: path)
        _ = try fixture.runner.run("git", arguments: ["merge", "--ff-only", "feature/x"], workingDirectory: path)
        _ = try fixture.runner.run("git", arguments: ["push", "origin", "main"], workingDirectory: path)
        let verifier = UnitTestVerifier { _, _, _ in .init(success: true, log: "") }
        #expect(throws: CommandError.self) {
            try verifier.verify(repository: fixture.repository, branch: fixture.branch, baseReference: "origin/main", developerName: "테스터", select: Self.selectShopDiscount, generate: { _ in proposal }, progress: { _ in })
        }
        #expect(try fixture.remoteHead() == fixture.head)
        let refs = try fixture.runner.run("git", arguments: ["--git-dir", fixture.root.appending(path: "remote.git").path, "for-each-ref", "refs/heads/unittest/"]).output
        #expect(refs.isEmpty)
    }

    @Test("선택 커밋을 임시 브랜치에 체크아웃해 선별하고 검증 통과 파일만 푸시한다")
    func pushesPassingTestsWithoutTouchingWorkFolder() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let runner = fixture.runner
        let path = fixture.repository.localPath
        _ = try runner.run("git", arguments: ["switch", "main"], workingDirectory: path)
        let originalHead = try runner.run("git", arguments: ["rev-parse", "HEAD"], workingDirectory: path).output
        let dependency = "Assets/Scripts/Shop/DiscountRules.cs"
        let verifier = UnitTestVerifier { folder, sources, _ in
            #expect(sources.count == 2)
            let relative = try #require(sources.last)
            let content = try String(contentsOfFile: (folder as NSString).appendingPathComponent(relative), encoding: .utf8)
            #expect(content.contains("class DiscountRules"))
            return .init(success: true, log: "Passed!")
        }

        let result = try verifier.verify(
            repository: fixture.repository, branch: fixture.branch, baseReference: "origin/main", developerName: "테스터",
            select: { workspace, comparisonBase, changes in
                #expect(workspace != path)
                #expect(changes.count == 4)
                #expect(changes.contains { $0.sourcePath.hasSuffix("/ShopDiscount.cs") && $0.diff.contains("+namespace Demo") })
                let checkout = try runner.run("git", arguments: ["rev-parse", "HEAD"], workingDirectory: workspace)
                #expect(checkout.output.trimmingCharacters(in: .whitespacesAndNewlines) == fixture.head)
                return Self.selectShopDiscount(workspace, comparisonBase, changes)
            },
            generate: { request in
                let checkedOut = try runner.run("git", arguments: ["branch", "--show-current"], workingDirectory: request.workspace)
                #expect(checkedOut.output.hasPrefix("unittest/"))
                #expect(request.target.behavior == "가격 계산 규칙")
                return .init(status: "generated", files: proposal.files, dependencies: [dependency])
            },
            progress: { _ in }
        )

        #expect(result.outcome == .passed && result.pushed)
        #expect(result.verifiedSHA == fixture.head && result.resultSHA != fixture.head)
        #expect(try fixture.remoteHead() == fixture.head)
        #expect(try fixture.remoteFiles(result.resultSHA).contains("Tests/Demo.Tests/Shop/ShopDiscountTests.cs"))
        let refs = try runner.run("git", arguments: ["--git-dir", fixture.root.appending(path: "remote.git").path, "for-each-ref", "--format=%(objectname)", "refs/heads/unittest/"]).output
        #expect(refs.contains(result.resultSHA))
        #expect(result.files.map(\.sourcePath) == ["Assets/Scripts/Shop/ShopDiscount.cs"])
        #expect(result.summary.contains("범위 밖 3개"))

        #expect(try runner.run("git", arguments: ["rev-parse", "HEAD"], workingDirectory: path).output == originalHead)
        #expect(try runner.run("git", arguments: ["status", "--porcelain"], workingDirectory: path).output.isEmpty)
        #expect(try runner.run("git", arguments: ["branch", "--list", "unittest/*"], workingDirectory: path).output.isEmpty)
        #expect(try runner.run("git", arguments: ["worktree", "list", "--porcelain"], workingDirectory: path).output.components(separatedBy: "worktree ").count == 2)
        #expect(try runner.run("git", arguments: ["log", "-1", "--format=%s", result.resultSHA], workingDirectory: path).output.hasPrefix("[개발 - 테스터] UnitTest 추가: ShopDiscountTests"))
    }

    @Test("같은 UnitTest 브랜치가 있으면 체크아웃해 선택 커밋을 병합하고 기존 테스트를 수정·삭제한다")
    func continuesExistingUnitTestBranch() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let runner = fixture.runner
        let path = fixture.repository.localPath
        let remote = fixture.root.appending(path: "remote.git").path
        let testPath = "Tests/Demo.Tests/Shop/ShopDiscountTests.cs"
        let verifier = UnitTestVerifier { _, _, _ in .init(success: true, log: "Passed!") }
        let first = try verifier.verify(repository: fixture.repository, branch: fixture.branch, baseReference: "origin/main", developerName: "테스터", select: Self.selectShopDiscount, generate: { _ in proposal }, progress: { _ in })
        #expect(first.pushed)

        try "namespace Demo { public static class ShopDiscount { public static int Apply(int p) => p / 2; } }"
            .write(toFile: (path as NSString).appendingPathComponent("Assets/Scripts/Shop/ShopDiscount.cs"), atomically: true, encoding: .utf8)
        _ = try runner.run("git", arguments: ["commit", "-am", "discount"], workingDirectory: path)
        _ = try runner.run("git", arguments: ["push", "origin", "feature/x"], workingDirectory: path)
        var branch = fixture.branch
        let newHead = try runner.run("git", arguments: ["rev-parse", "HEAD"], workingDirectory: path).output.trimmingCharacters(in: .whitespacesAndNewlines)
        branch.sha = String(newHead.prefix(7))

        let second = try verifier.verify(
            repository: fixture.repository, branch: branch, baseReference: "origin/main", developerName: "테스터", select: Self.selectShopDiscount,
            generate: { request in
                let current = try runner.run("git", arguments: ["branch", "--show-current"], workingDirectory: request.workspace).output
                #expect(current.trimmingCharacters(in: .whitespacesAndNewlines) == "unittest/x")
                #expect(FileManager.default.fileExists(atPath: (request.workspace as NSString).appendingPathComponent(testPath)))
                #expect(request.target.existingTests == [testPath])
                return .init(status: "generated", files: [.init(path: testPath, content: "class ShopDiscountTests { /* half */ }")])
            },
            progress: { _ in }
        )
        #expect(second.pushed && second.outcome == .passed)
        #expect(try runner.run("git", arguments: ["--git-dir", remote, "rev-parse", "unittest/x"]).output.trimmingCharacters(in: .whitespacesAndNewlines) == second.resultSHA)
        #expect(try runner.run("git", arguments: ["merge-base", "--is-ancestor", first.resultSHA, second.resultSHA], workingDirectory: path).status == 0)
        #expect(try runner.run("git", arguments: ["merge-base", "--is-ancestor", newHead, second.resultSHA], workingDirectory: path).status == 0)
        #expect(try runner.run("git", arguments: ["show", "\(second.resultSHA):\(testPath)"], workingDirectory: path).output.contains("half"))
        #expect(try runner.run("git", arguments: ["log", "-1", "--format=%s", second.resultSHA], workingDirectory: path).output.hasPrefix("[개발 - 테스터] UnitTest 갱신: ShopDiscountTests"))

        let third = try verifier.verify(
            repository: fixture.repository, branch: branch, baseReference: "origin/main", developerName: "테스터", select: Self.selectShopDiscount,
            generate: { _ in .init(status: "generated", reason: "동작 제거", deletions: [testPath]) }, progress: { _ in }
        )
        #expect(third.pushed)
        #expect(!(try fixture.remoteFiles(third.resultSHA)).contains(testPath))
        #expect(try runner.run("git", arguments: ["branch", "--list", "unittest/*"], workingDirectory: path).output.isEmpty)
    }

    @Test("이 UnitTest 브랜치가 만들지 않은 테스트는 삭제할 수 없다")
    func rejectsDeletingForeignTests() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let verifier = UnitTestVerifier { _, _, _ in .init(success: true, log: "") }
        let result = try verifier.verify(
            repository: fixture.repository, branch: fixture.branch, baseReference: "origin/main", developerName: "테스터", select: Self.selectShopDiscount,
            generate: { _ in .init(status: "generated", deletions: ["Tests/Demo.Tests/Item/ItemPriceTests.cs"]) }, progress: { _ in }
        )
        #expect(result.outcome == .failed && !result.pushed)
    }

    @Test("diff에 없는 경로가 선별되면 생성을 중단하고 임시 브랜치를 정리한다")
    func rejectsSelectionOutsideDiff() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let verifier = UnitTestVerifier { _, _, _ in .init(success: true, log: "") }
        #expect(throws: CommandError.self) {
            try verifier.verify(
                repository: fixture.repository, branch: fixture.branch, baseReference: "origin/main", developerName: "테스터",
                select: { _, _, _ in [.init(sourcePath: "Unchanged.cs", behavior: "변경되지 않은 규칙", priority: 3)] },
                generate: { _ in
                    Issue.record("유효하지 않은 분류 결과로 생성을 호출했습니다.")
                    return proposal
                },
                progress: { _ in }
            )
        }
        let refs = try fixture.runner.run("git", arguments: ["branch", "--list", "unittest/*"], workingDirectory: fixture.repository.localPath)
        #expect(refs.output.isEmpty)
    }

    @Test("검증이 계속 실패하면 재시도 후 실패로 기록하고 푸시하지 않는다")
    func doesNotPushFailingTests() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let attempts = Counter()
        let verifier = UnitTestVerifier { _, _, _ in .init(success: false, log: "error CS0103") }

        let result = try verifier.verify(
            repository: fixture.repository, branch: fixture.branch, baseReference: "origin/main", developerName: "테스터",
            select: Self.selectShopDiscount,
            generate: { _ in attempts.increment(); return proposal }, progress: { _ in }
        )

        #expect(result.outcome == .failed && !result.pushed)
        #expect(attempts.value == UnitTestVerifier.maxAttempts)
        #expect(try fixture.remoteHead() == fixture.head)
        #expect(!result.satisfies(branchSHA: fixture.branch.sha))
    }

    @Test("테스트 경로 밖 파일을 제안하면 즉시 폐기한다")
    func rejectsProductionPatch() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let verifier = UnitTestVerifier { _, _, _ in .init(success: true, log: "") }
        let production = UnitTestProposal(status: "generated", files: [.init(path: "Assets/Scripts/Shop/ShopDiscount.cs", content: "x")])

        let result = try verifier.verify(
            repository: fixture.repository, branch: fixture.branch, baseReference: "origin/main", developerName: "테스터",
            select: Self.selectShopDiscount,
            generate: { _ in production }, progress: { _ in }
        )

        #expect(result.outcome == .failed && !result.pushed)
        #expect(try fixture.remoteHead() == fixture.head)
    }

    @Test("JSON 형식 오류를 재시도하고 계속 실패하면 푸시하지 않는다", arguments: [true, false])
    func retriesInvalidProposal(recovers: Bool) throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let attempts = Counter()
        let validations = Counter()
        let verifier = UnitTestVerifier { _, _, _ in
            validations.increment()
            return .init(success: true, log: "")
        }

        let result = try verifier.verify(
            repository: fixture.repository, branch: fixture.branch, baseReference: "origin/main", developerName: "테스터",
            select: Self.selectShopDiscount,
            generate: { request in
                attempts.increment()
                if attempts.value == 1 {
                    #expect(request.previousError == nil)
                } else {
                    #expect(request.previousError == UnitTestProposal.ParseError.missingJSON.localizedDescription)
                    if recovers { return proposal }
                }
                return try UnitTestProposal.parse("테스트 생성 계획입니다.")
            },
            progress: { _ in }
        )

        #expect(attempts.value == (recovers ? 2 : UnitTestVerifier.maxAttempts))
        #expect(validations.value == (recovers ? 1 : 0))
        #expect(result.outcome == (recovers ? .passed : .failed))
        #expect(result.pushed == recovers)
        #expect(try fixture.remoteHead() == fixture.head)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}

@Suite("Skill files")
struct SkillFileStoreTests {
    private static let defaults: @Sendable (String) -> URL? = { name in
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/PRReviewAssistant/Resources/UnitTestSkills/\(name).md")
    }

    private func makeStore() throws -> (SkillFileStore, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "Skills-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root.appending(path: "agents"), withIntermediateDirectories: true)
        try "역할".write(to: root.appending(path: "agents/code-reviewer.md"), atomically: true, encoding: .utf8)
        try "other".write(to: root.appending(path: "agents/pm.md"), atomically: true, encoding: .utf8)
        return (SkillFileStore(cursorDirectory: root), root)
    }

    @Test("리뷰 역할 파일과 기본 UnitTest 스킬을 목록에 보여준다")
    func listsAndInstallsDefaults() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(store.list().map(\.name) == ["code-reviewer"])

        #expect(try store.installDefaultUnitTestSkills(defaultFile: Self.defaults) == SkillFileStore.defaultUnitTestSkills.count)
        #expect(store.list().filter { $0.group == .unitTest }.count == SkillFileStore.defaultUnitTestSkills.count)
        #expect(try store.installDefaultUnitTestSkills(defaultFile: Self.defaults) == 0)
    }

    @Test("수정한 내용을 저장하고 빈 내용·목록 밖 파일은 거부하며 재설치해도 덮어쓰지 않는다")
    func savesSafely() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try store.installDefaultUnitTestSkills(defaultFile: Self.defaults)
        let skill = try #require(store.list().first { $0.name == "unittest-csharp-base" })

        try store.write("수정됨", to: skill)
        #expect(try store.read(skill) == "수정됨")
        _ = try store.installDefaultUnitTestSkills(defaultFile: Self.defaults)
        #expect(try store.read(skill) == "수정됨")

        #expect(throws: (any Error).self) { try store.write("  \n", to: skill) }
        let outside = EditableSkill(name: "pm", url: root.appending(path: "agents/pm.md"), group: .review)
        #expect(throws: (any Error).self) { try store.write("x", to: outside) }
    }
}
