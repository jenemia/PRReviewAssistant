import Foundation
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
    @Test("후속 질문은 최신 판단을 갱신하고 오래된 사용자 제한도 유지한다")
    func followUpUpdatesLatestJudgment() {
        var card = reviewCard()
        card.messages = [.init(role: .agent, body: "오래된 판단: 코드 구현"),
                         .init(role: .user, body: "리뷰반영을 하지 않고 spec문서만 갱신")]
        for index in 0..<10 {
            card.messages.append(.init(role: .agent, body: "중간 검토 \(index)"))
        }
        card.messages.append(.init(role: .agent, body: "최신 판단: 문서만 갱신하고 코드는 보류"))

        let prompt = CursorAgent.followUpPrompt(card: card, question: "전역 리스너 도입은 비허용. 기존 구조 유지")

        #expect(prompt.contains("최신 판단: 문서만 갱신하고 코드는 보류"))
        #expect(prompt.contains("리뷰반영을 하지 않고 spec문서만 갱신"))
        #expect(prompt.contains("전역 리스너 도입은 비허용. 기존 구조 유지"))
        #expect(!prompt.contains("오래된 판단: 코드 구현"))
        #expect(!prompt.contains(card.commentBody))
        #expect(prompt.contains("## 현재 동작과 이유"))
        #expect(prompt.contains("코드 원문과 코드 블록은 기본적으로 표시하지 마라"))
    }

    @Test("실패 안내는 판단으로 쓰지 않고 리뷰 원문에서 다시 시작한다")
    func followUpIgnoresFailureNotice() {
        var card = reviewCard()
        card.messages = [.init(role: .agent, body: "에이전트 응답을 가져오지 못했습니다.", isFailure: true)]

        let prompt = CursorAgent.followUpPrompt(card: card, question: "다시 봐줘")

        #expect(!prompt.contains("에이전트 응답을 가져오지 못했습니다."))
        #expect(prompt.contains(card.sectionBody ?? card.commentBody))
        #expect(card.latestAgentJudgment == nil)
    }

    @Test("실패 뒤에도 직전의 정상 판단을 유지한다")
    func followUpKeepsLastRealJudgment() {
        var card = reviewCard()
        card.messages = [.init(role: .agent, body: "정상 판단"),
                         .init(role: .agent, body: "실패 안내", isFailure: true)]
        let prompt = CursorAgent.followUpPrompt(card: card, question: "다시 봐줘")
        #expect(prompt.contains("정상 판단"))
        #expect(!prompt.contains("실패 안내"))
    }

    @Test("현재 요청을 이전 요청에 중복해 보내지 않는다")
    func followUpDoesNotRepeatCurrentRequest() {
        var card = reviewCard()
        card.messages = [.init(role: .user, body: "이전 요청"), .init(role: .user, body: "현재 요청")]
        let prompt = CursorAgent.followUpPrompt(card: card, question: "현재 요청")
        #expect(prompt.contains("이전 요청"))
        #expect(prompt.components(separatedBy: "현재 요청\n").count == 2 || prompt.components(separatedBy: "\n현재 요청").count == 2)
    }

    @Test("isFailure가 없는 이전 저장 메시지도 읽는다")
    func decodesMessageWithoutFailureFlag() throws {
        let original = AgentChatMessage(role: .agent, body: "기존 메시지")
        let data = try JSONEncoder().encode(original)
        #expect(!String(decoding: data, as: UTF8.self).contains("isFailure"))
        #expect(try JSONDecoder().decode(AgentChatMessage.self, from: data).isFailure == nil)
    }

    @Test("빈 응답은 완료로 처리하지 않고 stderr 안내를 보존한다")
    func emptyTextResponseIsNotSuccess() throws {
        let ok = try CursorAgent.validatedTextResult(.init(output: "답변", error: "warning", status: 0))
        #expect(ok.output == "답변")
        #expect(throws: CommandError.self) {
            _ = try CursorAgent.validatedTextResult(.init(output: " \n", error: "", status: 0))
        }
        do {
            _ = try CursorAgent.validatedTextResult(.init(output: "", error: "Workspace Trust Required", status: 0))
            Issue.record("오류가 발생해야 합니다")
        } catch {
            #expect(error.localizedDescription == "Workspace Trust Required")
        }
    }

    @Test("작업 요청은 최신 판단과 사용자 제한을 최종 구현 프롬프트까지 전달한다")
    @MainActor
    func workRequestPreservesUserConstraints() {
        var card = reviewCard()
        card.messages = [.init(role: .agent, body: "원래 제안: 리스너 구현"),
                         .init(role: .user, body: "리뷰반영을 하지 않고 spec문서만 갱신"),
                         .init(role: .agent, body: "최신 판단: spec 문서만 갱신")]
        let content = ReviewStore.implementationPlanContent(for: card, pullRequestNumber: 42)
        let plan = ImplementationPlan(
            repository: card.repository, pullRequestNumber: 42, content: "이전 작업 계획",
            implementationRequest: content + "\n\n## 개발자 추가 메모\nTODO도 갱신", sourceCardIDs: [card.id]
        )
        let pullRequest = PullRequest(
            id: UUID(), repository: card.repository, number: 42, title: "리뷰",
            author: "author", headBranch: "feature", baseBranch: "main", headSHA: "abc",
            reviewer: "reviewer", commentCount: 1, updatedAt: .now,
            reviewState: .commented, analysisStatus: .needsAnalysis, summary: "", files: []
        )

        let prompt = CursorAgent.implementationPrompt(pullRequest: pullRequest, plan: plan)

        #expect(prompt.contains("리뷰반영을 하지 않고 spec문서만 갱신"))
        #expect(prompt.contains("최신 판단: spec 문서만 갱신"))
        #expect(prompt.contains("TODO도 갱신"))
        #expect(prompt.contains("원문 리뷰 (참고 자료)"))
        #expect(!prompt.contains("원래 제안: 리스너 구현"))
        #expect(!prompt.contains("이전 작업 계획"))
        #expect(prompt.contains("## 작업내용"))
        #expect(prompt.contains("코드 위치는 설명 문단 끝의 별도 `출처:`"))
    }

    @Test("답변 형식은 전역 지침의 설명 절만 읽고 없으면 기본 형식을 적용한다")
    func responseStyleLoadsOnlyPresentationSection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("AGENTS.md")
        try """
        ## 작업 방식
        작업 규칙은 가져오지 않는다
        ## 사용자에게 답변하는 방식
        역할과 목적을 쉬운 한국어로 설명한다
        ### 작업 완료 후
        별도 커밋 템플릿은 가져오지 않는다
        """.write(to: path, atomically: true, encoding: .utf8)

        let loaded = CursorAgent.responseStyleGuidance(cursorDirectory: directory)
        #expect(loaded.contains("역할과 목적을 쉬운 한국어로 설명한다"))
        #expect(!loaded.contains("작업 규칙은 가져오지 않는다"))
        #expect(!loaded.contains("별도 커밋 템플릿은 가져오지 않는다"))
        try FileManager.default.removeItem(at: path)
        let fallback = CursorAgent.responseStyleGuidance(cursorDirectory: directory)
        #expect(fallback.contains("결론을 먼저 말하고"))
        #expect(fallback.contains("코드 원문과 코드 블록은 기본적으로 표시하지 마라"))
    }

    @Test("재리뷰 추천 프롬프트는 코멘트별 커밋 종합과 근거 없는 완료 제외를 요구한다")
    func reReviewPromptUsesCommitEvidence() {
        let prompt = CursorAgent.reReviewMessagePrompt(pullRequest: PullRequest.samples[0], workSummary: "실제 커밋 메시지")
        #expect(prompt.contains("실제 커밋 메시지"))
        #expect(prompt.contains("같은 코멘트의 여러 커밋은 시간순으로 종합"))
        #expect(prompt.contains("미커밋 작업은 처리 완료의 근거로 사용하지 않는다"))
        #expect(!prompt.contains("AGENT WORK RESULTS"))
    }

    private func reviewCard() -> AgentReviewCard {
        AgentReviewCard(repository: "owner/repo", pullRequestNumber: 42, commentID: "comment",
                        commentAuthor: "reviewer", commentBody: "원문 리뷰: 전역 리스너를 구현하세요.",
                        title: "W2 - 리스너")
    }

}
