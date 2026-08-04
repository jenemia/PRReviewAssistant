import Testing
@testable import PRReviewAssistant

@Suite("Cursor agent connection")
struct CursorAgentTests {
    @Test("로그인 성공 문구에서 계정을 추출한다")
    func parsesLoggedInAccount() {
        let output = "✓ Logged in as taid@supercent.io\n"

        #expect(CursorAgent.isLoggedIn(output))
        #expect(CursorAgent.accountName(output) == "taid@supercent.io")
        #expect(!CursorAgent.requiresLogin(output))
    }

    @Test("인증 만료 문구를 로그인 필요로 분류한다")
    func detectsExpiredLogin() {
        #expect(CursorAgent.requiresLogin("Authentication required. Please log in."))
    }

    @Test("사용 가능한 모델 행만 센다")
    func countsModels() {
        let output = """
        Available models

        auto - Auto (default)
        gpt-5.3-codex - Codex 5.3
        """

        #expect(CursorAgent.modelCount(output) == 2)
    }
}
