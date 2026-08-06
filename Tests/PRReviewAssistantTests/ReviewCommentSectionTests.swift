import Testing
@testable import PRReviewAssistant

struct ReviewCommentSectionTests {
    @Test("Warning 본문의 Markdown 소제목은 별도 검토카드로 분리하지 않는다")
    func warningKeepsNestedHeadingsInOneSection() {
        let body = """
        ## Warning (1)
        캐시 무효화가 누락되었습니다.
        ### 영향 범위
        로그인 화면과 토큰 갱신 경로입니다.
        ### 수정 제안
        만료 시 캐시를 비우세요.
        """

        let sections = ReviewCommentSection.parse(commentID: "comment-1", body: body)

        #expect(sections.count == 1)
        #expect(sections[0].title.contains("Warning"))
        #expect(sections[0].body.contains("### 영향 범위"))
    }

    @Test("Warning과 Suggestion은 발견 순서대로 분리한다")
    func separatesSeverityFindingsInSourceOrder() {
        let body = """
        Warning (1)
        오류 처리가 필요합니다.
        ## 근거
        재시도 시 상태가 남습니다.
        Suggestion (2)
        로그에 요청 ID를 포함하세요.
        """

        let sections = ReviewCommentSection.parse(commentID: "comment-2", body: body)

        #expect(sections.count == 2)
        #expect(sections.map(\.title) == ["Warning (1)", "Suggestion (2)"])
        #expect(sections[0].body.contains("## 근거"))
    }

    @Test("심각도 제목은 레벨과 순번을 카드 목록용 라벨로 표시한다")
    func formatsSeverityLabelWithSequenceNumber() {
        #expect(ReviewCommentSection.displayLabel(for: "Suggestion (2)") == "Suggestion-2")
        #expect(ReviewCommentSection.displayLabel(for: "## Warning (1)") == "Warning-1")
    }

    @Test("Suggestion 안의 번호가 붙은 항목은 각각 카드 섹션으로 분리한다")
    func separatesNumberedFindingsWithinSeverity() {
        let body = """
        ## Suggestion (3)

        ### 1. 첫 번째 개선점
        첫 번째 내용입니다.

        ### 2. 두 번째 개선점
        두 번째 내용입니다.

        ### 3. 세 번째 개선점
        세 번째 내용입니다.
        """

        let sections = ReviewCommentSection.parse(commentID: "comment-3", body: body)

        #expect(sections.map(\.title) == ["Suggestion (1)", "Suggestion (2)", "Suggestion (3)"])
        #expect(sections[0].body.contains("첫 번째 개선점"))
        #expect(sections[1].body.contains("두 번째 개선점"))
        #expect(sections[2].body.contains("세 번째 개선점"))
    }

    @Test("원문 코드 위치 URL은 스크립트와 라인 링크로 읽기 쉽게 표시한다")
    func formatsRawCodeLocationURL() {
        let raw = "(prreview://open?path=unity_project/devil_hunter_idle/Assets/Supercent/Devil_Hunter_Idle/0.%20Battle/Scripts/BattleManager.cs&line=662)"

        let formatted = CodeLocationLinkFormatter.format(raw)

        #expect(formatted == "[BattleManager.cs · 662행](prreview://open?path=unity_project/devil_hunter_idle/Assets/Supercent/Devil_Hunter_Idle/0.%20Battle/Scripts/BattleManager.cs&line=662)")
    }

    @Test("응답 작성 팝업은 에이전트 호출 전에도 편집 가능한 기본 초안을 가진다")
    @MainActor
    func createsNonEmptyInitialReviewResponseDraft() {
        let card = AgentReviewCard(
            repository: "owner/repository",
            pullRequestNumber: 1,
            commentID: "comment-1",
            commentAuthor: "reviewer",
            commentBody: "Suggestion (1)",
            sectionTitle: "Suggestion (1)",
            sectionBody: "리뷰 내용",
            title: "Suggestion-1",
            messages: [.init(role: .agent, body: """
            ## 판단
            - 수정 불필요
            ## 코드 확인
            - BattleManager.SetPaused는 false일 때 무적 상태를 해제합니다.
            """)]
        )

        let draft = ReviewStore.defaultReviewResponseDraft(for: card)

        #expect(!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(draft.contains("Suggestion-1"))
        #expect(draft.contains("판단 근거"))
        #expect(draft.contains("BattleManager.SetPaused"))
    }

    @Test("기존 에이전트의 핵심 근거 형식도 응답 초안의 판단 근거로 포함한다")
    @MainActor
    func includesLegacyAgentEvidenceInReviewResponseDraft() {
        let card = AgentReviewCard(
            repository: "owner/repository",
            pullRequestNumber: 1,
            commentID: "comment-2",
            commentAuthor: "reviewer",
            commentBody: "Warning (1)",
            sectionTitle: "Warning (1)",
            sectionBody: "리뷰 내용",
            title: "Warning-1",
            messages: [.init(role: .agent, body: """
            ## 판단: **Boss Raid에서는 영향 없음**

            ### 핵심 근거
            1. BossRaidPlayer는 Arcade Player와 별개 타입입니다.
            2. SetPaused(false)는 else 분기에서 Invincible을 false로 되돌립니다.
            """)]
        )

        let draft = ReviewStore.defaultReviewResponseDraft(for: card)

        #expect(draft.contains("검토 판단: Boss Raid에서는 영향 없음"))
        #expect(draft.contains("BossRaidPlayer"))
        #expect(draft.contains("Invincible을 false"))
    }

    @Test("응답 초안의 코드 위치는 로컬 경로 없이 클래스 함수와 라인만 표시한다")
    func formatsCodeReferenceForGitHubReply() {
        let text = "[BattleManager.cs — SetPaused(false)](prreview://open?path=unity_project/Assets/Battle/Scripts/BattleManager.cs&line=661)"

        let formatted = ReviewResponseReferenceFormatter.format(text)

        #expect(formatted == "BattleManager.SetPaused(false) · 661행")
        #expect(!formatted.contains("unity_project"))
        #expect(!formatted.contains("prreview://"))
    }

    @Test("사이드뷰 에이전트 메시지도 내부 코드 위치 링크를 평문 참조로 바꾼다")
    func formatsCodeReferenceForSideViewMessage() {
        let text = "[CheatPlayerGroup.cs 26행](prreview://open?path=unity_project/Assets/Cheat/Scripts/CheatPlayerGroup.cs&line=26) public getter만 존재합니다."

        let formatted = ReviewResponseReferenceFormatter.format(text)

        #expect(formatted == "CheatPlayerGroup · 26행 public getter만 존재합니다.")
        #expect(!formatted.contains("prreview://"))
    }
}
