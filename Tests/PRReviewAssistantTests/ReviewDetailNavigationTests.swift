import Foundation
import Testing
@testable import PRReviewAssistant

@Suite("PR detail side-panel navigation")
struct ReviewDetailNavigationTests {
    @Test("사람 리뷰를 열면 보고 있던 에이전트 리뷰를 교체한다")
    func openingCommentsReplacesAgentReview() {
        var navigation = ReviewDetailNavigation()
        let agentCardID = UUID()

        navigation.showAgent(agentCardID)
        navigation.showComments()

        #expect(navigation.isShowingComments)
        #expect(navigation.selectedAgentCardID == nil)
    }

    @Test("사람 리뷰에서 에이전트 리뷰를 열면 사람 리뷰를 교체한다")
    func openingAgentReviewReplacesComments() {
        var navigation = ReviewDetailNavigation()
        let agentCardID = UUID()

        navigation.showComments()
        navigation.showAgent(agentCardID)

        #expect(!navigation.isShowingComments)
        #expect(navigation.selectedAgentCardID == agentCardID)
    }

    @Test("작업 카드를 본 뒤에도 사람 리뷰와 에이전트 검토로 전환할 수 있다")
    func openingAnotherPanelReplacesWorkCard() {
        var navigation = ReviewDetailNavigation()
        let workCardID = UUID()
        let agentCardID = UUID()

        navigation.showWork(workCardID)
        navigation.showComments()

        #expect(navigation.selectedWorkCardID == nil)
        #expect(navigation.isShowingComments)

        navigation.showAgent(agentCardID)
        #expect(navigation.selectedWorkCardID == nil)
        #expect(!navigation.isShowingComments)
        #expect(navigation.selectedAgentCardID == agentCardID)
    }
}
