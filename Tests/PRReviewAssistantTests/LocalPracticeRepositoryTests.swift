import Foundation
import Testing
@testable import PRReviewAssistant

@Suite(.serialized)
struct LocalPracticeRepositoryTests {
    @Test("로컬 연습 PR은 GitHub 없이 로컬 bare 원격에만 생성된다")
    func createsDisposableLocalOnlyFixture() throws {
        let practice = LocalPracticeRepository()
        let fixture = try practice.create()
        defer { try? practice.remove(at: fixture.repository.localPath) }

        #expect(fixture.repository.isLocalPractice == true)
        #expect(fixture.repository.fullName == LocalPracticeRepository.fullName)
        #expect(fixture.pullRequest.headBranch == "review-practice/empty-name")
        #expect(fixture.comments.count == 1)

        let remote = try ProcessRunner()
            .run("git", arguments: ["remote", "get-url", "origin"], workingDirectory: fixture.repository.localPath)
            .output.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(remote.hasPrefix("/tmp/PRReviewAssistant-LocalPractice/remote.git"))

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
        let practice = LocalPracticeRepository()
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

    @Test("저장된 PR SHA가 오래되어도 현재 원격 브랜치로 작업 폴더를 준비한다")
    func preparesCurrentBranchWhenStoredPRSHAIsStale() throws {
        let practice = LocalPracticeRepository()
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
        let practice = LocalPracticeRepository()
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
