import Foundation
import Testing
@testable import PRReviewAssistant

@Suite("기능별 에이전트 모델")
struct AgentFeatureModelTests {
    @MainActor
    private func store() -> ReviewStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
        return ReviewStore(persistence: AppPersistence(url: url), startsBackgroundTasks: false)
    }

    @Test("덮어쓰기가 없으면 모든 기능이 기본 모델을 쓴다")
    @MainActor func defaultsToProviderModel() {
        let store = store()
        store.agentProvider = .claude
        store.claudeModel = "claude-opus-5-5"
        for feature in AgentFeature.allCases {
            #expect(store.model(for: feature) == store.effectiveAgentModel)
        }
    }

    @Test("덮어쓴 기능만 지정 모델을 쓴다")
    @MainActor func overridesOnlyThatFeature() {
        let store = store()
        store.agentProvider = .claude
        store.claudeModel = "claude-opus-5-5"
        store.agentFeatureModels[.claude] = [.branchQuestion: "claude-sonnet-5-5"]
        #expect(store.model(for: .branchQuestion) == "claude-sonnet-5-5")
        #expect(store.model(for: .branchReview) == "claude-opus-5-5")
    }

    @Test("에이전트를 바꾸면 그 에이전트의 덮어쓰기만 적용되고 돌아오면 복원된다")
    @MainActor func overridesArePerProvider() {
        let store = store()
        store.agentModel = "composer-2.5"
        store.agentFeatureModels[.claude] = [.branchReview: "claude-sonnet-5-5"]
        store.agentProvider = .cursor
        #expect(store.model(for: .branchReview) == "composer-2.5")
        store.agentProvider = .claude
        #expect(store.model(for: .branchReview) == "claude-sonnet-5-5")
    }

    @Test("공백만 있는 덮어쓰기는 기본 모델을 따른다")
    @MainActor func blankOverrideFallsBack() {
        let store = store()
        store.agentProvider = .codex
        store.codexModel = "gpt-6.1-sol"
        store.agentFeatureModels[.codex] = [.branchQuiz: "  "]
        #expect(store.model(for: .branchQuiz) == "gpt-6.1-sol")
    }

    @Test("덮어쓰기는 저장 후 다시 읽어도 유지되고 예전 저장 파일은 빈 값으로 읽힌다")
    func persistence() throws {
        var state = PersistedState()
        state.agentFeatureModels = [.cursor: [.reviewAnalysis: "auto"]]
        let restored = try JSONDecoder().decode(PersistedState.self, from: JSONEncoder().encode(state))
        #expect(restored.agentFeatureModels[.cursor]?[.reviewAnalysis] == "auto")
        let existing = try JSONDecoder().decode(PersistedState.self, from: Data("{}".utf8))
        #expect(existing.agentFeatureModels.isEmpty)
    }
}
