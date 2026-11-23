import Foundation
import Testing
@testable import PRReviewAssistant

@Suite("기능별 에이전트")
struct AgentFeatureModelTests {
    @MainActor
    private func store() -> ReviewStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
        return ReviewStore(persistence: AppPersistence(url: url), startsBackgroundTasks: false)
    }

    @Test("덮어쓰기가 없으면 모든 기능이 기본 에이전트와 그 모델을 쓴다")
    @MainActor func defaultsToProviderModel() {
        let store = store()
        store.agentProvider = .claude
        store.claudeModel = "claude-opus-5-5"
        for feature in AgentFeature.allCases {
            #expect(store.provider(for: feature) == .claude)
            #expect(store.model(for: feature) == "claude-opus-5-5")
        }
    }

    @Test("덮어쓴 기능만 지정 에이전트를 쓴다")
    @MainActor func overridesOnlyThatFeature() {
        let store = store()
        store.agentProvider = .cursor
        store.agentModel = "composer-2.5"
        store.claudeModel = "claude-opus-5-5"
        store.agentFeatureProviders[.reviewAnalysis] = .claude
        #expect(store.provider(for: .reviewAnalysis) == .claude)
        #expect(store.model(for: .reviewAnalysis) == "claude-opus-5-5")
        #expect(store.provider(for: .reviewImplementation) == .cursor)
        #expect(store.model(for: .reviewImplementation) == "composer-2.5")
    }

    @Test("기본 에이전트를 바꿔도 기능별 덮어쓰기는 유지된다")
    @MainActor func featureOverridesSurviveDefaultChange() {
        let store = store()
        store.agentFeatureProviders[.branchReview] = .claude
        store.claudeModel = "claude-sonnet-5-5"
        store.agentProvider = .cursor
        #expect(store.provider(for: .branchReview) == .claude)
        store.agentProvider = .codex
        #expect(store.provider(for: .branchReview) == .claude)
    }

    @Test("기능별 에이전트는 저장 후 다시 읽어도 유지되고 예전 저장 파일은 빈 값으로 읽힌다")
    func featureProvidersPersist() throws {
        var state = PersistedState()
        state.agentFeatureProviders = [.reviewAnalysis: .claude]
        let restored = try JSONDecoder().decode(PersistedState.self, from: JSONEncoder().encode(state))
        #expect(restored.agentFeatureProviders[.reviewAnalysis] == .claude)
        let existing = try JSONDecoder().decode(PersistedState.self, from: Data("{}".utf8))
        #expect(existing.agentFeatureProviders.isEmpty)
    }

    @Test("끈 모델은 선택 목록에서 빠지고 다시 켜면 돌아온다")
    @MainActor func disabledModelIsHidden() {
        let store = store()
        store.claudeModel = ""
        store.setAgentModel("claude-sonnet-5-5", provider: .claude, enabled: false)
        #expect(!store.enabledModelPresets(for: .claude).contains { $0.id == "claude-sonnet-5-5" })
        store.setAgentModel("claude-sonnet-5-5", provider: .claude, enabled: true)
        #expect(store.enabledModelPresets(for: .claude).contains { $0.id == "claude-sonnet-5-5" })
    }

    @Test("에이전트 기본 모델로 쓰는 프리셋은 끌 수 없다")
    @MainActor func inUseModelCannotBeDisabled() {
        let store = store()
        store.agentModel = "composer-2.5"
        store.setAgentModel("composer-2.5", provider: .cursor, enabled: false)
        store.setAgentModel("auto", provider: .cursor, enabled: false)
        #expect(store.disabledAgentModels[.cursor]?.isEmpty ?? true)
    }

    @Test("끈 모델 목록은 저장 후 유지되고 예전 저장 파일은 빈 값으로 읽힌다")
    func disabledModelsPersist() throws {
        var state = PersistedState()
        state.disabledAgentModels = [.codex: ["gpt-6-sol"]]
        let restored = try JSONDecoder().decode(PersistedState.self, from: JSONEncoder().encode(state))
        #expect(restored.disabledAgentModels[.codex] == ["gpt-6-sol"])
        let existing = try JSONDecoder().decode(PersistedState.self, from: Data("{}".utf8))
        #expect(existing.disabledAgentModels.isEmpty)
    }

    @Test("에이전트를 끄면 그 에이전트를 쓰던 기능은 기본 에이전트로 바뀌고 다시 켜면 돌아온다")
    @MainActor func disabledProviderFallsBackToDefault() {
        let store = store()
        store.agentProvider = .cursor
        store.agentFeatureProviders[.reviewAnalysis] = .codex
        store.codexModel = "gpt-6-sol"
        #expect(store.provider(for: .reviewAnalysis) == .codex)
        store.setAgentProvider(.codex, enabled: false)
        #expect(store.provider(for: .reviewAnalysis) == .cursor)
        #expect(store.model(for: .reviewAnalysis) == store.effectiveAgentModel(for: .cursor))
        store.setAgentProvider(.codex, enabled: true)
        #expect(store.provider(for: .reviewAnalysis) == .codex)
    }

    @Test("기본 에이전트는 끌 수 없다")
    @MainActor func defaultProviderCannotBeDisabled() {
        let store = store()
        store.agentProvider = .claude
        store.setAgentProvider(.claude, enabled: false)
        #expect(store.isAgentProviderEnabled(.claude))
    }

    @Test("끈 에이전트 목록은 저장 후 유지되고 예전 저장 파일은 빈 값으로 읽힌다")
    func disabledProvidersPersist() throws {
        var state = PersistedState()
        state.disabledAgentProviders = [.codex]
        let restored = try JSONDecoder().decode(PersistedState.self, from: JSONEncoder().encode(state))
        #expect(restored.disabledAgentProviders == [.codex])
        let existing = try JSONDecoder().decode(PersistedState.self, from: Data("{}".utf8))
        #expect(existing.disabledAgentProviders.isEmpty)
    }

    @Test("기능별 모델은 그 기능의 에이전트 아래에서만 적용되고 공백이면 기본 모델을 쓴다")
    @MainActor func featureModelOverride() {
        let store = store()
        store.agentProvider = .cursor
        store.agentModel = "composer-2.5"
        store.claudeModel = "claude-opus-5-5"
        store.agentFeatureProviders[.reviewAnalysis] = .claude
        store.agentFeatureModels[.claude] = [.reviewAnalysis: "claude-sonnet-5-5"]
        #expect(store.model(for: .reviewAnalysis) == "claude-sonnet-5-5")
        #expect(store.model(for: .reviewImplementation) == "composer-2.5")
        store.agentFeatureModels[.claude] = [.reviewAnalysis: "  "]
        #expect(store.model(for: .reviewAnalysis) == "claude-opus-5-5")
    }

    @Test("기능별 모델로 쓰는 모델은 끌 수 없다")
    @MainActor func featureModelCannotBeDisabled() {
        let store = store()
        store.agentFeatureModels[.claude] = [.branchReview: "claude-sonnet-5-5"]
        store.setAgentModel("claude-sonnet-5-5", provider: .claude, enabled: false)
        #expect(store.disabledAgentModels[.claude]?.isEmpty ?? true)
    }
}
