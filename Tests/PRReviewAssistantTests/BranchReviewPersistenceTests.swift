import Foundation
import Testing
@testable import PRReviewAssistant

@Suite("PR request review persistence")
struct BranchReviewPersistenceTests {
    @Test("위험도 아래의 리뷰를 코드 블록과 하위 제목을 유지하며 분리한다")
    @MainActor
    func splitsFindingsUnderSeverity() {
        let output = """
        ## 차단
        ### 요청 중복
        첫 번째 수정 범위
        ```markdown
        ## 개선
        ### 예제 제목
        ```
        #### 추가 근거
        ### 상태 누락
        두 번째 수정 범위
        ## 확인 필요
        ### 검토 범위와 한계
        테스트 미실행
        ## 통과
        특이사항 없음
        """
        let cards = ReviewStore.makeBranchReviewCards(from: output, reviewedSHA: "abc123")
        let findings = cards.filter { !$0.isReference }
        #expect(findings.map(\.title) == ["요청 중복", "상태 누락"])
        #expect(Set(findings.map(\.id)).count == 2)
        #expect(findings.allSatisfy { $0.category == .blocker && $0.reviewedSHA == "abc123" })
        #expect(findings.first?.details.contains("### 예제 제목") == true)
        #expect(findings.first?.details.contains("#### 추가 근거") == true)
        #expect(findings.first?.details.contains("두 번째 수정 범위") == false)
        #expect(cards.contains { $0.title == "검토 범위와 한계" && $0.isReference })
    }

    @Test("기존 위험도 전체 검토 기록은 새 항목의 승인으로 이어지지 않는다")
    @MainActor
    func preservesAggregateHistorySeparately() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = AppPersistence(url: directory.appendingPathComponent("state.json"))
        let branch = RepositoryBranch(repositoryID: UUID(), repositoryName: "test/repo", name: "feature", reference: "origin/feature", sha: "abc123", subject: "작업", updatedAt: nil, isCurrent: false, isRemote: true)
        var legacy = BranchReviewCard(category: .blocker, title: "첫 번째", summary: "", details: "### 첫 번째\n내용 A\n### 두 번째\n내용 B", reviewedSHA: branch.sha)
        legacy.messages = [.init(role: .agent, body: "위험도 전체 검토")]
        var state = PersistedState()
        state.requestedBranches = [branch]
        state.branchReviewCards = [branch.id: [legacy]]
        state.branchCardReviewed = [legacy.id]
        state.branchImplementationResults = [legacy.id: "이전 구현 결과"]
        persistence.save(state)

        let store = ReviewStore(persistence: persistence, startsBackgroundTasks: false)
        let cards = store.branchCards(for: branch)
        let findings = cards.filter { !$0.isReference }
        #expect(findings.map(\.title) == ["첫 번째", "두 번째"])
        #expect(findings.allSatisfy { $0.messages.isEmpty && !store.branchCardReviewed.contains($0.id) })
        let history = try #require(cards.first { $0.isArchivedAggregate == true })
        #expect(history.id == legacy.id)
        #expect(history.messages == legacy.messages)
        #expect(store.branchImplementationResults[history.id] == "이전 구현 결과")
        let reopened = ReviewStore(persistence: persistence, startsBackgroundTasks: false)
        #expect(reopened.branchCards(for: branch) == cards)
    }

    @Test("이전 상태에 브랜치 리뷰 필드가 없어도 빈 값으로 복원한다")
    func decodesLegacyState() throws {
        let state = try JSONDecoder().decode(PersistedState.self, from: Data("{}".utf8))
        #expect(state.branchReviewCards.isEmpty)
        #expect(state.branchCardReviewed.isEmpty)
        #expect(state.branchImplementationResults.isEmpty)
        #expect(state.branchImplementationInProgress.isEmpty)
    }

    @Test("브랜치 카드와 대화, 검토 및 구현 상태를 보존한다")
    func roundTripsReviewState() throws {
        var card = BranchReviewCard(category: .concern, title: "초기화 오류", summary: "요약", details: "원문", reviewedSHA: "abc123")
        card.messages = [
            .init(role: .user, body: "문서만 수정해주세요"),
            .init(role: .agent, body: "코드는 보류합니다")
        ]
        var state = PersistedState()
        state.branchReviewCards = ["repo:feature": [card]]
        state.branchCardReviewed = [card.id]
        state.branchImplementationResults = [card.id: "변경과 테스트 결과"]
        state.branchImplementationInProgress = [card.id]

        let restored = try JSONDecoder().decode(PersistedState.self, from: JSONEncoder().encode(state))
        let restoredCard = try #require(restored.branchReviewCards["repo:feature"]?.first)
        #expect(restoredCard == card)
        #expect(restored.branchCardReviewed == [card.id])
        #expect(restored.branchImplementationResults[card.id] == "변경과 테스트 결과")
        #expect(restored.branchImplementationInProgress == [card.id])
    }

    @Test("앱 재시작은 카드를 복원하고 진행 중 구현을 완료 미확인으로 표시한다")
    @MainActor
    func restoresStoreAndRecoversInterruptedImplementation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = AppPersistence(url: directory.appendingPathComponent("state.json"))
        let branch = RepositoryBranch(repositoryID: UUID(), repositoryName: "test/repo", name: "feature", reference: "origin/feature", sha: "abc123", subject: "작업", updatedAt: nil, isCurrent: false, isRemote: true)
        var card = BranchReviewCard(category: .concern, title: "검토", summary: "요약", details: "상세", reviewedSHA: "abc123")
        card.messages = [.init(role: .user, body: "수정 범위를 줄여주세요"), .init(role: .agent, body: "문서만 수정합니다")]
        var state = PersistedState()
        state.requestedBranches = [branch]
        state.branchReviewCards = [branch.id: [card]]
        state.branchCardReviewed = [card.id]
        state.branchImplementationInProgress = [card.id]
        state.branchImplementationResults = [card.id: "구현 중입니다"]
        persistence.save(state)

        let store = ReviewStore(persistence: persistence, startsBackgroundTasks: false)
        #expect(store.branchCards(for: branch) == [card])
        #expect(store.branchCardReviewed.contains(card.id))
        #expect(store.branchImplementationResults[card.id]?.contains("완료 여부를 확인할 수 없습니다") == true)
        #expect(!store.branchCardBusy.contains(card.id))
        let recovered = persistence.load()
        #expect(recovered.branchImplementationInProgress.isEmpty)
        #expect(recovered.branchImplementationResults[card.id]?.contains("완료 여부를 확인할 수 없습니다") == true)

        store.removeRequestedBranch(branch)
        let afterRemoval = persistence.load()
        #expect(afterRemoval.requestedBranches.isEmpty)
        #expect(afterRemoval.branchReviewCards[branch.id] == nil)
        #expect(!afterRemoval.branchCardReviewed.contains(card.id))
        #expect(afterRemoval.branchImplementationResults[card.id] == nil)
        let reopened = ReviewStore(persistence: persistence, startsBackgroundTasks: false)
        #expect(reopened.branchCards(for: branch).isEmpty)
    }
}
