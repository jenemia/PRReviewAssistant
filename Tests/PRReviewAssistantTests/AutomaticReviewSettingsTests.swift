import Foundation
import Testing
@testable import PRReviewAssistant

@Suite struct AutomaticReviewSettingsTests {
    @Test func defaultsToEnabledForNewAndExistingState() throws {
        #expect(PersistedState().automaticReviewAnalysis)
        let existing = try JSONDecoder().decode(PersistedState.self, from: Data("{}".utf8))
        #expect(existing.automaticReviewAnalysis)
    }

    @Test func disabledSettingPersists() throws {
        let state = PersistedState(automaticReviewAnalysis: false)
        let restored = try JSONDecoder().decode(PersistedState.self, from: JSONEncoder().encode(state))
        #expect(!restored.automaticReviewAnalysis)
    }
}
