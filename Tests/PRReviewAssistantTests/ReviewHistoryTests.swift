import Foundation
import Testing
@testable import PRReviewAssistant

@Suite struct ReviewHistoryTests {
    @Test func historyPersistsAndOldStateDecodes() throws {
        let old = try JSONDecoder().decode(PersistedState.self, from: Data("{\"hiddenReviewCommentIDsByPullRequest\":{\"repo#1\":[\"old\"]}}".utf8))
        #expect(old.reviewHistoryRoundsByPullRequest.isEmpty)
        #expect(old.hiddenReviewCommentIDsByPullRequest["repo#1"] == ["old"])
        let state = PersistedState(hiddenReviewCommentIDsByPullRequest: ["repo#1": ["old", "new"]], reviewHistoryRoundsByPullRequest: ["repo#1": [["new"]]])
        let restored = try JSONDecoder().decode(PersistedState.self, from: JSONEncoder().encode(state))
        #expect(restored.reviewHistoryRoundsByPullRequest["repo#1"] == [["new"]])
    }

    @Test @MainActor func historySeparatesRoundsAndKeepsLegacyCards() {
        let pr = PullRequest.samples[0]
        func card(_ id: String) -> AgentReviewCard {
            AgentReviewCard(repository: pr.repository, pullRequestNumber: pr.number, commentID: id, commentAuthor: "reviewer", commentBody: id, title: id)
        }
        let rounds = ReviewStore.previousAgentCardRounds(for: pr, cards: [card("old"), card("first"), card("second"), card("current")], hidden: ["old", "first", "second"], rounds: [["first"], ["second"]])
        #expect(rounds.map { $0.map(\.commentID) } == [["second"], ["first"], ["old"]])
    }
    @Test @MainActor func cardsFollowReviewerRequestsAndReviewSubmissionTime() {
        let pr = PullRequest.samples[0]
        func card(_ id: String) -> AgentReviewCard {
            AgentReviewCard(repository: pr.repository, pullRequestNumber: pr.number, commentID: id, commentAuthor: "lars", commentBody: id, title: id)
        }
        func comment(_ id: String, reviewer: String?, submitted: TimeInterval?) -> ReviewComment {
            ReviewComment(id: id, author: "lars", body: id, path: nil, line: nil, createdAt: Date(timeIntervalSince1970: 1), kind: .review, reviewState: nil, parentID: nil, reviewAuthor: reviewer, reviewSubmittedAt: submitted.map { Date(timeIntervalSince1970: $0) })
        }
        let requests = [ReviewRequestEvent(id: 1, reviewer: "Lars", createdAt: Date(timeIntervalSince1970: 10)), ReviewRequestEvent(id: 2, reviewer: "Lars", createdAt: Date(timeIntervalSince1970: 20)), ReviewRequestEvent(id: 3, reviewer: "Other", createdAt: Date(timeIntervalSince1970: 21))]
        let comments = [comment("old", reviewer: "lars", submitted: 15), comment("new", reviewer: "lars", submitted: 25), comment("line", reviewer: "lars", submitted: 25), comment("general", reviewer: nil, submitted: nil), comment("before", reviewer: "lars", submitted: 5)]
        let groups = PullRequestDetailView.groupedReviewRounds(comments.map { card($0.id) }, comments: comments, requests: requests)
        #expect(groups.map(\.id) == ["request-2", "request-1", "unassigned"])
        #expect(groups.map(\.number) == [2, 1, nil])
        #expect(groups.map { $0.cards.map(\.commentID) } == [["new", "line"], ["old"], ["general", "before"]])
    }
    @Test @MainActor func workPlansFollowLinkedCardsWithoutDuplication() {
        let pr = PullRequest.samples[0]
        func card(_ id: String, reviewID: String) -> AgentReviewCard {
            AgentReviewCard(reviewID: reviewID, repository: pr.repository, pullRequestNumber: pr.number, commentID: id, commentAuthor: "lars", commentBody: id, title: id)
        }
        let old = card("old", reviewID: "review-old")
        let new = card("new", reviewID: "review-new")
        func comment(_ id: String, _ date: TimeInterval) -> ReviewComment {
            ReviewComment(id: id, author: "lars", body: id, path: nil, line: nil, createdAt: Date(timeIntervalSince1970: date), kind: .review, reviewState: nil, parentID: nil, reviewAuthor: "lars", reviewSubmittedAt: Date(timeIntervalSince1970: date))
        }
        func plan(_ title: String, ids: [UUID] = [], reviews: [String]? = nil) -> ImplementationPlan {
            ImplementationPlan(repository: pr.repository, pullRequestNumber: pr.number, content: title, sourceCardIDs: ids, sourceReviewIDs: reviews)
        }
        let plans = [plan("old", ids: [old.id]), plan("new", reviews: ["review-new"]), plan("mixed", ids: [old.id, new.id]), plan("missing")]
        let requests = [ReviewRequestEvent(id: 1, reviewer: "lars", createdAt: Date(timeIntervalSince1970: 10)), ReviewRequestEvent(id: 2, reviewer: "lars", createdAt: Date(timeIntervalSince1970: 20))]
        let groups = PullRequestDetailView.groupedWorkRounds(plans, cards: [old, new], comments: [comment("old", 15), comment("new", 25)], requests: requests)
        #expect(groups.map(\.id) == ["request-2", "request-1", "unassigned"])
        #expect(groups.map { $0.plans.map(\.content) } == [["new"], ["old"], ["mixed", "missing"]])
    }
}
