import Foundation
import Testing
@testable import PRReviewAssistant

@Suite("PR request review persistence")
struct BranchReviewPersistenceTests {
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
