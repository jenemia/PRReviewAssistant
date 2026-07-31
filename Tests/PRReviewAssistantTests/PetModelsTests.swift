import Foundation
import Testing
@testable import PRReviewAssistant

@Suite("Desktop pet")
struct PetModelsTests {
    @Test("최근 PR 제목을 말풍선에 표시한다")
    func latestBubbleUsesMostRecentlyUpdatedPullRequest() {
        let older = pullRequest(number: 20, title: "이전 PR", updatedAt: .now.addingTimeInterval(-100))
        let latest = pullRequest(number: 21, title: "최근 PR", updatedAt: .now)

        let content = PetBubbleContent.latest(in: [older, latest])
        #expect(content.subtitle == "example/repository #21")
        #expect(content.body == "최근 PR · 코멘트")
    }

    @Test("PR이 없으면 빈 Inbox 안내를 표시한다")
    func emptyBubbleExplainsThereIsNoRecentContent() {
        #expect(PetBubbleContent.latest(in: []).title == "새로운 PR 또는 리뷰가 없습니다")
    }

    @Test("작업, 새 리뷰, 완료 상태의 우선순위를 적용한다")
    func petStatePrioritizesWorkThenAttentionThenCompletion() {
        var working = pullRequest(number: 1, title: "분석", updatedAt: .now)
        working.analysisStatus = .analyzing
        #expect(PetState.resolve(pullRequests: [working], unreadCount: 1) == .working)

        let attention = pullRequest(number: 2, title: "리뷰", updatedAt: .now)
        #expect(PetState.resolve(pullRequests: [attention], unreadCount: 1) == .attention)

        var completed = pullRequest(number: 3, title: "완료", updatedAt: .now)
        completed.reviewState = .approved
        #expect(PetState.resolve(pullRequests: [completed], unreadCount: 0) == .completed)
    }

    @Test("새 리뷰 알림과 펫 말풍선은 같은 내용을 사용한다")
    func newReviewContentMatchesNotificationText() {
        let pullRequest = pullRequest(number: 42, title: "로그인 오류 수정", updatedAt: .now)
        let content = PetBubbleContent.newReview(for: pullRequest, count: 2)

        #expect(content.title == "새 리뷰가 도착했습니다")
        #expect(content.subtitle == "example/repository #42")
        #expect(content.body == "로그인 오류 수정 · 새 코멘트 2개")
        #expect(content.sourceAuthor == "reviewer")
    }

    private func pullRequest(number: Int, title: String, updatedAt: Date) -> PullRequest {
        PullRequest(
            id: UUID(), repository: "example/repository", number: number, title: title,
            author: "reviewer", headBranch: "feature/pet", baseBranch: "main", headSHA: "abc123",
            reviewer: "reviewer", commentCount: 0, updatedAt: updatedAt, reviewState: .commented,
            analysisStatus: .needsAnalysis, summary: "", files: []
        )
    }
}
