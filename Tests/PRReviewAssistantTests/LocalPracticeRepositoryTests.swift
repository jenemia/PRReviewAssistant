import Foundation
import Testing
@testable import PRReviewAssistant

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
    }

    @Test("PR 요청 브랜치 목록은 origin 추적 브랜치만 읽고 체크아웃하지 않는다")
    func readsOriginBranchesForPullRequestRequests() throws {
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
}
