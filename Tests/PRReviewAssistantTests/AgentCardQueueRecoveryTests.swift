import Foundation
import Testing
@testable import PRReviewAssistant

@Suite("분석 대기 카드 복구")
struct AgentCardQueueRecoveryTests {
    @Test("앱을 다시 열면 분석 대기 카드는 검토 준비로 돌아가 다시 시작할 수 있다")
    @MainActor
    func restoresQueuedCardsAsReady() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = AppPersistence(url: directory.appendingPathComponent("state.json"))
        var queued = AgentReviewCard(repository: "owner/repo", pullRequestNumber: 462, commentID: "comment", commentAuthor: "reviewer", commentBody: "본문", title: "카드")
        queued.status = .queued
        var state = PersistedState()
        state.agentReviewCards = [queued]
        persistence.save(state)

        let store = ReviewStore(persistence: persistence, startsBackgroundTasks: false)

        #expect(store.agentCard(id: queued.id)?.status == .ready)
    }
}
