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
}
