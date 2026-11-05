import Foundation
import Testing
@testable import PRReviewAssistant

@Suite("Refresh and app-posted comments")
struct AppPostedCommentTests {
    private func pullRequest() -> PullRequest {
        PullRequest(id: UUID(), repository: "owner/repo", number: 7, title: "제목", author: "author", headBranch: "feature", baseBranch: "main", headSHA: "abc", reviewer: "리뷰 대기", commentCount: 0, updatedAt: .now, reviewState: .commented, analysisStatus: .needsAnalysis, summary: "기본", files: [])
    }

    private func comment(_ id: String) -> ReviewComment {
        ReviewComment(id: id, author: "someone", body: "본문 \(id)", path: nil, line: nil, createdAt: .now, kind: .general, reviewState: nil, parentID: nil)
    }

    @Test("앱이 올린 코멘트는 검토 카드를 만들지 않고 저장 후에도 유지한다")
    @MainActor
    func skipsCommentsPostedByApp() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let persistence = AppPersistence(url: url)
        var state = PersistedState()
        state.appPostedCommentIDs = ["issue-1"]
        persistence.save(state)

        let store = ReviewStore(persistence: persistence, startsBackgroundTasks: false)
        let pr = pullRequest()
        store.comments["owner/repo#7"] = [comment("issue-1"), comment("issue-2")]
        store.rebuildAutomaticReviewCards(for: pr)

        #expect(store.agentCards(for: pr).map(\.commentID) == ["issue-2"])
        #expect(persistence.load().appPostedCommentIDs == ["issue-1"])
    }

    @Test("등록 응답에서 코멘트 ID를 읽고 읽지 못해도 오류로 처리하지 않는다")
    func readsPostedCommentID() {
        #expect(GitHubClient.postedCommentID(from: #"{"id":123,"body":"x"}"#) == "issue-123")
        #expect(GitHubClient.postedCommentID(from: "not json") == nil)
    }

    @Test("코멘트 조회에 실패한 PR은 마지막 리뷰 정보를 유지한다")
    @MainActor
    func keepsReviewDetailsWhenCommentsFail() {
        var previous = pullRequest()
        previous.commentCount = 3
        previous.reviewer = "reviewer"
        previous.summary = "마지막 리뷰"
        var latest = pullRequest()
        latest.title = "새 제목"

        let merged = ReviewStore.pullRequest(latest, keepingReviewDetailsFrom: previous)

        #expect(merged.title == "새 제목")
        #expect(merged.commentCount == 3)
        #expect(merged.reviewer == "reviewer")
        #expect(merged.summary == "마지막 리뷰")
        #expect(ReviewStore.pullRequest(latest, keepingReviewDetailsFrom: nil).summary == "기본")
    }

    @Test("리뷰 정보는 같은 PR 버전에서만 잠시 재사용한다")
    @MainActor
    func invalidatesReviewDetailsWhenRemoteRevisionChanges() {
        let fetchedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let original = pullRequest()
        let stamp = ReviewStore.ReviewDetailsStamp(original, fetchedAt: fetchedAt)
        let nextPoll = fetchedAt.addingTimeInterval(60)

        #expect(stamp.canReuse(for: original, now: nextPoll))
        #expect(!stamp.canReuse(for: original, now: fetchedAt.addingTimeInterval(600)))

        var updated = original
        updated.updatedAt += 1
        #expect(!stamp.canReuse(for: updated, now: nextPoll))
        updated = original
        updated.headSHA = "def"
        #expect(!stamp.canReuse(for: updated, now: nextPoll))
        updated = original
        updated.reviewState = .approved
        #expect(!stamp.canReuse(for: updated, now: nextPoll))
    }
}
