import Foundation
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

    @Test("Warning과 Suggestion의 W/S 항목 헤더는 각각 독립 카드로 분리한다")
    func separatesCodedFindingsWithinSeverity() {
        let body = """
        ## 🟠 Warning (2)

        ### W1 - 결제 전 리스트 재적재
        결제가 실패해도 리스트가 이미 바뀝니다.

        ### W2 - 점수 0 처리
        0점 응답도 유효합니다.

        ## 🔵 Suggestion (1)

        ### S1 - partial 분리
        partial을 정리합니다.
        """

        let sections = ReviewCommentSection.parse(commentID: "comment-coded", body: body)

        #expect(sections.count == 3)
        #expect(sections.map(\.title) == ["### W1 - 결제 전 리스트 재적재", "### W2 - 점수 0 처리", "### S1 - partial 분리"])
        #expect(ReviewCommentSection.displayLabel(for: sections[0].title) == "W1 - 결제 전 리스트 재적재")
        #expect(ReviewCommentSection.displayLabel(for: sections[1].title) == "W2 - 점수 0 처리")
        #expect(ReviewCommentSection.displayLabel(for: sections[2].title) == "S1 - partial 분리")
        #expect(ReviewCommentSection.categoryLabel(for: sections[0].title) == "Warning")
        #expect(ReviewCommentSection.categoryLabel(for: sections[2].title) == "Suggestion")
    }

    @Test("분류된 카드 제목에는 W2 이후 제목 전체를 보존하고 본문은 포함하지 않는다")
    func preservesCodedFindingTitle() {
        let title = "W2 - 신규 SaveData 2종이 계정 전환 리스너(OnSwitch)를 등록하지 않음"

        #expect(AgentReviewCard.title(for: "### \(title)") == title)
        #expect(AgentReviewCard.title(for: "### \(title)\n본문 설명") == title)
        #expect(ReviewCommentSection.displayLabel(for: "w2: 점수 0 처리") == "W2: 점수 0 처리")
        #expect(ReviewCommentSection.displayLabel(for: "W2") == "W2")
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

    @Test("새 설명 형식의 현재 동작과 이유도 GitHub 응답 초안에 유지한다")
    @MainActor
    func replyDraftIncludesNarrativeEvidence() {
        let card = AgentReviewCard(
            repository: "owner/repository", pullRequestNumber: 1, commentID: "comment-new",
            commentAuthor: "reviewer", commentBody: "캐시 갱신", title: "캐시 갱신",
            messages: [.init(role: .agent, body: """
            ## 판단
            수정 불필요
            ## 현재 동작과 이유
            계정을 전환하면 기존 캐시를 비우므로 이전 계정 데이터가 남지 않습니다.
            ## 대응 계획
            현재 처리를 유지합니다.
            """)]
        )
        let draft = ReviewStore.defaultReviewResponseDraft(for: card)
        #expect(draft.contains("기존 캐시를 비우므로 이전 계정 데이터가 남지 않습니다."))
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

    @Test("커밋 메시지에는 문제와 이유 및 작업내용만 요약한다")
    @MainActor
    func synthesizesCommitMessageFromReviewAndWork() {
        let message = ReviewStore.synthesizedCommitMessage(
            pullRequestNumber: 42,
            developerName: "션킴",
            reviewTitle: "Suggestion (1)",
            reviewComment: """
            **연관도:** 직접
            **파일·위치:** Secret.swift:12
            **문제:** 캐시를 갱신해 주세요.
            **이유:** 만료된 캐시가 남습니다.
            **판단:** 수정 필요
            """,
            implementationSummary: """
            ## 판단
            수정 완료
            ## 작업 내용
            캐시 무효화와 갱신 경로를 추가했습니다.
            ## 변경 파일
            Secret.swift
            ## 작업 카드 파일
            Internal.swift
            """
        )

        #expect(message.contains("[개발 - 션킴] PR #42 Suggestion (1) 검토 반영"))
        #expect(message.contains("캐시를 갱신해 주세요."))
        #expect(message.contains("캐시 무효화와 갱신 경로를 추가했습니다."))
        #expect(message.contains("이유:\n만료된 캐시가 남습니다."))
        #expect(!message.contains("연관도"))
        #expect(!message.contains("파일"))
        #expect(!message.contains("판단"))
        #expect(!message.contains("Secret.swift"))
        #expect(!message.contains("Internal.swift"))
    }

    @Test("커밋 요약은 일반 문장을 유지하고 누락된 이유를 임의로 만들지 않는다")
    @MainActor
    func commitSummaryHandlesPlainTextAndMissingReason() {
        let message = ReviewStore.synthesizedCommitMessage(
            pullRequestNumber: 42,
            developerName: "션킴",
            reviewTitle: "캐시 갱신",
            reviewComment: "캐시를 갱신해 주세요.",
            implementationSummary: "캐시 무효화를 추가했습니다."
        )

        #expect(message.contains("문제:\n캐시를 갱신해 주세요."))
        #expect(message.contains("이유:\n이유 요약 없음"))
        #expect(message.contains("작업내용:\n캐시 무효화를 추가했습니다."))
    }

    @Test("재리뷰 요약은 실제 커밋과 카드 연결만 사용하고 미반영 제안을 섞지 않는다")
    @MainActor
    func reReviewSummaryUsesCommits() {
        var card = AgentReviewCard(
            repository: "owner/repository", pullRequestNumber: 1, commentID: "comment-active",
            commentAuthor: "reviewer", commentBody: "캐시를 갱신해 주세요.",
            sectionTitle: "W2 - 캐시 갱신", title: "W2",
            messages: [.init(role: .agent, body: "미반영 제안: 전체 캐시 재구현")]
        )
        card.reviewResponsePostedAt = .now
        let plan = ImplementationPlan(repository: card.repository, pullRequestNumber: 1,
                                      content: "미반영 계획", sourceCardIDs: [card.id], committedSHA: "fix-sha")
        let summary = ReviewStore.reReviewCommitSummary(
            commits: [(sha: "fix-sha", message: "문제: 캐시 잔류\n작업내용: spec 문서만 갱신")],
            cards: [card], plans: [plan]
        )
        #expect(summary.contains("W2 - 캐시 갱신"))
        #expect(summary.contains("spec 문서만 갱신"))
        #expect(summary.contains("### 연결된 실제 커밋\nfix-sha"))
        #expect(!summary.contains("미반영 제안"))
        #expect(!summary.contains("미반영 계획"))

        let unlinked = ReviewStore.reReviewCommitSummary(
            commits: [(sha: "manual-sha", message: "수동 문서 갱신")], cards: [card], plans: [plan]
        )
        #expect(unlinked.contains("명시적 연결 없음"))
        #expect(!unlinked.contains("fix-sha"))

        var recreatedCard = card
        recreatedCard.id = UUID()
        recreatedCard.reviewID = "stable-review-id"
        var linkedPlan = plan
        linkedPlan.sourceReviewIDs = ["stable-review-id"]
        let recreated = ReviewStore.reReviewCommitSummary(
            commits: [(sha: "fix-sha", message: "문서 갱신")], cards: [recreatedCard], plans: [linkedPlan]
        )
        #expect(recreated.contains("### 연결된 실제 커밋\nfix-sha"))
    }
}
