import Foundation
import Testing
@testable import PRReviewAssistant

extension LocalPracticeRepository {
    /// Parallel tests must not delete each other's fixture, so each one gets its own root.
    static func isolatedForTesting() -> LocalPracticeRepository {
        LocalPracticeRepository(root: FileManager.default.temporaryDirectory.appending(
            path: "LocalPractice-\(UUID().uuidString)",
            directoryHint: .isDirectory
        ))
    }
}

@Suite(.serialized)
struct LocalPracticeRepositoryTests {
    @Test("로컬 연습 PR은 GitHub 없이 로컬 bare 원격에만 생성된다")
    func createsDisposableLocalOnlyFixture() throws {
        let practice = LocalPracticeRepository.isolatedForTesting()
        let fixture = try practice.create()
        defer { try? practice.remove(at: fixture.repository.localPath) }

        #expect(fixture.repository.isLocalPractice == true)
        #expect(fixture.repository.fullName == LocalPracticeRepository.fullName)
        #expect(fixture.pullRequest.headBranch == "review-practice/empty-name")
        #expect(fixture.comments.count == 1)

        let remote = try ProcessRunner()
            .run("git", arguments: ["remote", "get-url", "origin"], workingDirectory: fixture.repository.localPath)
            .output.trimmingCharacters(in: .whitespacesAndNewlines)
        let practiceRoot = URL(fileURLWithPath: fixture.repository.localPath).deletingLastPathComponent()
        #expect(remote == practiceRoot.appending(path: "remote.git").path)

        let checkoutHead = try ProcessRunner()
            .run("git", arguments: ["rev-parse", "--verify", "HEAD"], workingDirectory: fixture.repository.localPath)
            .output.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(checkoutHead.hasPrefix(fixture.pullRequest.headSHA) == false)
        #expect(!checkoutHead.isEmpty)

        let reloaded = try practice.load(from: fixture.repository)
        #expect(reloaded.pullRequest.headSHA == fixture.pullRequest.headSHA)
    }

    @Test("작업 카드 커밋은 지정된 파일만 포함하고 다른 변경은 남긴다")
    func commitsOnlySpecifiedWorkCardFiles() throws {
        let practice = LocalPracticeRepository.isolatedForTesting()
        let fixture = try practice.create()
        defer { try? practice.remove(at: fixture.repository.localPath) }

        let workspace = WorkspaceManager()
        let path = try workspace.prepareRepositoryWorkspace(repository: fixture.repository, pullRequest: fixture.pullRequest)
        try "카드 작업\n".write(toFile: "\(path)/card-work.txt", atomically: true, encoding: .utf8)
        try "다른 카드 작업\n".write(toFile: "\(path)/other-work.txt", atomically: true, encoding: .utf8)

        _ = try workspace.commit(
            at: path,
            message: "test: card scoped commit",
            files: ["card-work.txt"],
            branch: fixture.pullRequest.headBranch,
            expectedSHA: fixture.pullRequest.headSHA
        )

        let runner = ProcessRunner()
        let committedFiles = try runner.run("git", arguments: ["show", "--format=", "--name-only", "HEAD"], workingDirectory: path).output
        let remainingChanges = try runner.run("git", arguments: ["status", "--porcelain=v1"], workingDirectory: path).output

        #expect(committedFiles.contains("card-work.txt"))
        #expect(!committedFiles.contains("other-work.txt"))
        #expect(remainingChanges.contains("other-work.txt"))

        let verifiedSHA = try workspace.verifiedHead(
            path,
            expectedSHA: fixture.pullRequest.headSHA,
            expectedBranch: fixture.pullRequest.headBranch
        )
        #expect(!verifiedSHA.hasPrefix(fixture.pullRequest.headSHA))
    }

    @Test("작업 카드 커밋은 실행 전후 달라진 내용만 포함하고 같은 파일의 다른 변경은 남긴다")
    func commitsOnlyContentChangedDuringCardRun() throws {
        let practice = LocalPracticeRepository.isolatedForTesting()
        let fixture = try practice.create()
        defer { try? practice.remove(at: fixture.repository.localPath) }

        let workspace = WorkspaceManager()
        let runner = ProcessRunner()
        let branch = fixture.pullRequest.headBranch
        let sha = fixture.pullRequest.headSHA
        let path = try workspace.prepareRepositoryWorkspace(repository: fixture.repository, pullRequest: fixture.pullRequest)
        func git(_ arguments: String...) throws -> String {
            try runner.run("git", arguments: arguments, workingDirectory: path).output
        }
        func write(_ content: String, to file: String) throws {
            try content.write(toFile: "\(path)/\(file)", atomically: true, encoding: .utf8)
        }
        var lines = (1...30).map { "line \($0)" }
        func writeShared() throws { try write(lines.joined(separator: "\n") + "\n", to: "shared.txt") }

        try writeShared()
        try write("지울 파일\n", to: "removed.txt")
        _ = try workspace.commit(at: path, message: "test: base", files: ["shared.txt", "removed.txt"], branch: branch, expectedSHA: sha)

        // Work that exists before the card, including something already staged.
        lines[0] = "user edit before run"
        try writeShared()
        try write("다른 작업\n", to: "unrelated.txt")
        try write("스테이징된 작업\n", to: "staged.txt")
        _ = try git("add", "--", "staged.txt")
        let baselineTree = try workspace.snapshotTree(at: path)

        // The agent's run: another part of a dirty file, a new file and a deletion.
        lines[29] = "agent edit"
        try writeShared()
        try write("에이전트 작업\n", to: "카드 작업.txt")
        try FileManager.default.removeItem(atPath: "\(path)/removed.txt")
        let resultTree = try workspace.snapshotTree(at: path)

        let files = try workspace.changedFiles(at: path, from: baselineTree, to: resultTree)
        #expect(files == ["removed.txt", "shared.txt", "카드 작업.txt"])

        // A user edit after the run must not ride along either.
        lines[14] = "user edit after run"
        try writeShared()

        _ = try workspace.commit(at: path, message: "test: card", baselineTree: baselineTree, resultTree: resultTree, branch: branch, expectedSHA: sha)

        let committed = try git("-c", "core.quotepath=off", "show", "--format=", "--name-only", "HEAD")
            .split(whereSeparator: \.isNewline).map(String.init).sorted()
        #expect(committed == files)
        let committedShared = try git("show", "HEAD:shared.txt")
        #expect(committedShared.contains("agent edit"))
        #expect(!committedShared.contains("user edit before run"))
        #expect(!committedShared.contains("user edit after run"))

        // Everything else stays exactly as it was in the working tree.
        let working = try String(contentsOfFile: "\(path)/shared.txt", encoding: .utf8)
        #expect(working.contains("user edit before run") && working.contains("agent edit") && working.contains("user edit after run"))
        let status = try git("-c", "core.quotepath=off", "status", "--porcelain=v1")
            .split(whereSeparator: \.isNewline).map(String.init).sorted()
        #expect(status == [" M shared.txt", "?? unrelated.txt", "A  staged.txt"].sorted())
    }

    @Test("같은 부분을 고친 카드는 먼저 커밋할 수 없고 선행 카드 커밋 후에는 커밋된다")
    func overlappingCardCommitsAreOrderedWithoutPartialCommit() throws {
        let practice = LocalPracticeRepository.isolatedForTesting()
        let fixture = try practice.create()
        defer { try? practice.remove(at: fixture.repository.localPath) }

        let workspace = WorkspaceManager()
        let branch = fixture.pullRequest.headBranch
        let sha = fixture.pullRequest.headSHA
        let path = try workspace.prepareRepositoryWorkspace(repository: fixture.repository, pullRequest: fixture.pullRequest)
        func head() throws -> String {
            try ProcessRunner().run("git", arguments: ["rev-parse", "HEAD"], workingDirectory: path).output
        }
        func write(_ content: String) throws { try content.write(toFile: "\(path)/shared.txt", atomically: true, encoding: .utf8) }

        try write("원본\n")
        _ = try workspace.commit(at: path, message: "test: base", files: ["shared.txt"], branch: branch, expectedSHA: sha)

        let start = try workspace.snapshotTree(at: path)
        try write("카드 A\n")
        let afterA = try workspace.snapshotTree(at: path)
        try write("카드 B\n")
        let afterB = try workspace.snapshotTree(at: path)

        let before = try head()
        #expect(throws: (any Error).self) {
            try workspace.commit(at: path, message: "test: B", baselineTree: afterA, resultTree: afterB, branch: branch, expectedSHA: sha)
        }
        #expect(try head() == before)

        _ = try workspace.commit(at: path, message: "test: A", baselineTree: start, resultTree: afterA, branch: branch, expectedSHA: sha)
        _ = try workspace.commit(at: path, message: "test: B", baselineTree: afterA, resultTree: afterB, branch: branch, expectedSHA: sha)
        let status = try ProcessRunner().run("git", arguments: ["status", "--porcelain=v1"], workingDirectory: path).output
        #expect(status.isEmpty)
    }

    @Test("저장된 PR SHA가 오래되어도 현재 원격 브랜치로 작업 폴더를 준비한다")
    func preparesCurrentBranchWhenStoredPRSHAIsStale() throws {
        let practice = LocalPracticeRepository.isolatedForTesting()
        let fixture = try practice.create()
        defer { try? practice.remove(at: fixture.repository.localPath) }

        var stalePullRequest = fixture.pullRequest
        stalePullRequest.headSHA = "000000000000"
        let workspace = WorkspaceManager()
        let path = try workspace.prepareRepositoryWorkspace(repository: fixture.repository, pullRequest: stalePullRequest)
        let currentSHA = try workspace.verifiedHead(
            path,
            expectedSHA: stalePullRequest.headSHA,
            expectedBranch: stalePullRequest.headBranch
        )

        #expect(!currentSHA.hasPrefix(stalePullRequest.headSHA))
    }

    @Test("PR 요청 브랜치 목록은 origin 추적 브랜치만 읽고 체크아웃하지 않는다")
    func readsOriginBranchesForPullRequestRequests() async throws {
        let practice = LocalPracticeRepository.isolatedForTesting()
        let fixture = try practice.create()
        defer { try? practice.remove(at: fixture.repository.localPath) }

        let before = try ProcessRunner()
            .run("git", arguments: ["branch", "--show-current"], workingDirectory: fixture.repository.localPath)
            .output.trimmingCharacters(in: .whitespacesAndNewlines)
        let branches = try WorkspaceManager().branches(in: fixture.repository)
        let after = try ProcessRunner()
            .run("git", arguments: ["branch", "--show-current"], workingDirectory: fixture.repository.localPath)
            .output.trimmingCharacters(in: .whitespacesAndNewlines)

        #expect(branches.contains { $0.name == fixture.pullRequest.headBranch })
        #expect(branches.allSatisfy { $0.isRemote && $0.reference.hasPrefix("origin/") })
        #expect(before == after)
    }
    @Test("재리뷰 커밋 조회는 PR 기준 이후 본문을 시간순으로 읽고 다른 브랜치와 미커밋 작업을 제외한다")
    func readsReviewCommitMessages() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = ProcessRunner()
        func git(_ arguments: [String]) throws -> String {
            try runner.run("git", arguments: arguments, workingDirectory: directory.path).output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        _ = try git(["init", "-b", "review"])
        _ = try git(["config", "user.name", "Test"])
        _ = try git(["config", "user.email", "test@example.com"])
        _ = try git(["commit", "--allow-empty", "-m", "초기 PR"])
        let base = try git(["rev-parse", "HEAD"])
        _ = try git(["switch", "-c", "unrelated"])
        _ = try git(["commit", "--allow-empty", "-m", "무관한 커밋"])
        let unrelated = try git(["rev-parse", "HEAD"])
        _ = try git(["switch", "review"])
        _ = try git(["commit", "--allow-empty", "-m", "W2 반영\n\n작업내용: spec 문서만 갱신"])
        let first = try git(["rev-parse", "HEAD"])
        _ = try git(["commit", "--allow-empty", "-m", "W2 보완\n\n이유: 초기화 조건 명시"])
        let last = try git(["rev-parse", "HEAD"])
        try "미커밋 작업".write(to: directory.appendingPathComponent("draft.txt"), atomically: true, encoding: .utf8)
        let workspace = WorkspaceManager()
        let commits = try workspace.reviewCommits(at: directory.path, branch: "review", baseSHA: base, committedSHA: last)
        #expect(commits.map(\.sha) == [first, last])
        #expect(commits[0].message == "W2 반영\n\n작업내용: spec 문서만 갱신")
        #expect(!commits.map(\.message).joined().contains("무관한 커밋"))
        #expect(try git(["rev-parse", "HEAD"]) == last)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("draft.txt").path))
        #expect(throws: (any Error).self) {
            try workspace.reviewCommits(at: directory.path, branch: "review", baseSHA: base, committedSHA: first)
        }
        #expect(throws: (any Error).self) {
            try workspace.reviewCommits(at: directory.path, branch: "review", baseSHA: unrelated, committedSHA: last)
        }
        #expect(try workspace.reviewCommits(at: directory.path, branch: "review", baseSHA: last, committedSHA: last).isEmpty)
    }

}
