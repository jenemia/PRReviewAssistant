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
}
