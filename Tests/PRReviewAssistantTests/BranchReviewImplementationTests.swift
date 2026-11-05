import Foundation
import Testing
@testable import PRReviewAssistant

@Suite("Branch review implementation")
struct BranchReviewImplementationTests {
    @Test("구현 대상은 검토 커밋과 체크아웃 브랜치 및 원격 추적 ref가 모두 같아야 한다")
    func validatesReviewedWorkspace() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = ProcessRunner()
        func git(_ args: [String]) throws -> String {
            try runner.run("git", arguments: args, workingDirectory: directory.path).output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        _ = try git(["init", "-b", "feature"])
        _ = try git(["config", "user.name", "Test"])
        _ = try git(["config", "user.email", "test@example.com"])
        _ = try git(["commit", "--allow-empty", "-m", "reviewed"])
        let reviewed = try git(["rev-parse", "HEAD"])
        _ = try git(["update-ref", "refs/remotes/origin/feature", reviewed])
        let branch = RepositoryBranch(repositoryID: UUID(), repositoryName: "test/repo", name: "feature", reference: "origin/feature", sha: String(reviewed.prefix(12)), subject: "reviewed", updatedAt: nil, isCurrent: true, isRemote: true)
        let workspace = WorkspaceManager()
        #expect(try workspace.validateBranchReviewWorkspace(at: directory.path, branch: branch, reviewedSHA: String(reviewed.prefix(12))) == reviewed)
        #expect(throws: (any Error).self) {
            try workspace.validateBranchReviewWorkspace(at: directory.path, branch: branch, reviewedSHA: "")
        }

        _ = try git(["switch", "-c", "other"])
        #expect(throws: (any Error).self) {
            try workspace.validateBranchReviewWorkspace(at: directory.path, branch: branch, reviewedSHA: reviewed)
        }
        _ = try git(["switch", "feature"])
        _ = try git(["commit", "--allow-empty", "-m", "after review"])
        let changed = try git(["rev-parse", "HEAD"])
        #expect(throws: (any Error).self) {
            try workspace.validateBranchReviewWorkspace(at: directory.path, branch: branch, reviewedSHA: reviewed)
        }
        _ = try git(["update-ref", "refs/remotes/origin/feature", changed])
        #expect(throws: (any Error).self) {
            try workspace.validateBranchReviewWorkspace(at: directory.path, branch: branch, reviewedSHA: reviewed)
        }
        _ = try git(["update-ref", "refs/heads/feature", reviewed])
        #expect(throws: (any Error).self) {
            try workspace.validateBranchReviewWorkspace(at: directory.path, branch: branch, reviewedSHA: reviewed)
        }
        #expect(try git(["rev-parse", "HEAD"]) == reviewed)
        #expect(try git(["branch", "--show-current"]) == "feature")
    }

    @Test("구현 요청은 시간순 사용자 제약과 최신 판단을 유지한다")
    @MainActor
    func preservesInstructionsAndLatestJudgment() {
        var card = BranchReviewCard(category: .concern, title: "초기화 오류", summary: "요약", details: "원문: 새로운 전역 리스너 추가")
        card.messages = [
            .init(role: .agent, body: "과거 판단: 리스너 추가"),
            .init(role: .user, body: "전역 리스너는 추가하지 마세요"),
            .init(role: .agent, body: "중간 판단"),
            .init(role: .user, body: "이번에는 스펙 문서만 수정"),
            .init(role: .agent, body: "최신 판단: 코드는 보류하고 문서만 수정")
        ]
        let request = ReviewStore.branchImplementationRequest(card: card)
        #expect(request.contains("전역 리스너는 추가하지 마세요"))
        #expect(request.contains("이번에는 스펙 문서만 수정"))
        #expect(request.range(of: "전역 리스너는 추가하지 마세요")!.lowerBound < request.range(of: "이번에는 스펙 문서만 수정")!.lowerBound)
        #expect(request.contains("최신 판단: 코드는 보류하고 문서만 수정"))
        #expect(!request.contains("과거 판단: 리스너 추가"))
        #expect(request.contains("원문: 새로운 전역 리스너 추가"))
        #expect(request.contains("나중 요청이 우선"))
    }
}
