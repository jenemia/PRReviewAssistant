import Foundation

struct PersistedState: Codable {
    var repositories: [RegisteredRepository] = []
    var processedCommentIDs: Set<String> = []
    var knownPullRequestIDs: Set<String> = []
    var unreadPullRequestIDs: Set<String> = []
    var unreadCommentIDs: Set<String> = []
    var hasEstablishedNotificationBaseline = false
    /// PRs that were already approved at the most recent successful refresh.
    /// This lets polling notify only on an actual transition to approval.
    var approvedPullRequestIDs: Set<String> = []
    /// Kept separate from the general notification baseline so existing users
    /// do not receive one alert per already-approved PR after this upgrade.
    var hasEstablishedApprovalBaseline = false
    var monitoringEnabled = true
    var monitoringInterval = 60
    var analyses: [String: AgentAnalysis] = [:]
    var agentReviewCards: [AgentReviewCard] = []
    var implementationPlans: [String: ImplementationPlan] = [:]
    var committedHeads: [String: String] = [:]
    var postedReReviewCommentTokens: Set<String> = []
    var agentModel = "auto"
    var customAgentModel = ""
    /// The GitHub login (or the local Git author name as a fallback) whose PRs
    /// are shown in the review inbox.
    var reviewAuthorFilter = ""
    var petVisible = true
    var petSize = 190.0
    var petReduceMotion = false
    var latestPetNotification: PetBubbleContent?
    var hasCompletedOnboarding = false
    var skippedOnboardingSteps: Set<String> = []
    var projectCopyFolder = ""
    var updateRepository = ""
    var updatesEnabled = true
    var lastNotifiedUpdateTag = ""
    /// Branches the user explicitly added to the PR-request queue.  Available
    /// origin branches are refreshed separately and are not persisted as UI
    /// choices by themselves.
    var requestedBranches: [RepositoryBranch] = []
    /// The five spec groups shown under the Agent sidebar, including pin and
    /// non-destructive dismissal state.
    var cursorSpecSidebarCache = CursorSpecSidebarCache()
    /// Whether newly read Agent sessions are automatically linked to a spec.
    /// This remains opt-in because classification sends session context to the
    /// configured LLM.
    var automaticCursorSessionClassification = false

    private enum CodingKeys: String, CodingKey {
        case repositories, processedCommentIDs, knownPullRequestIDs, unreadPullRequestIDs, unreadCommentIDs
        case hasEstablishedNotificationBaseline, approvedPullRequestIDs, hasEstablishedApprovalBaseline
        case monitoringEnabled, monitoringInterval, analyses, agentReviewCards, implementationPlans, committedHeads, postedReReviewCommentTokens, agentModel, customAgentModel, reviewAuthorFilter, petVisible, petSize, petReduceMotion, latestPetNotification, hasCompletedOnboarding, skippedOnboardingSteps, projectCopyFolder, updateRepository, updatesEnabled, lastNotifiedUpdateTag, requestedBranches, cursorSpecSidebarCache, automaticCursorSessionClassification
    }
    init(repositories: [RegisteredRepository] = [], processedCommentIDs: Set<String> = [], knownPullRequestIDs: Set<String> = [], unreadPullRequestIDs: Set<String> = [], unreadCommentIDs: Set<String> = [], hasEstablishedNotificationBaseline: Bool = false, approvedPullRequestIDs: Set<String> = [], hasEstablishedApprovalBaseline: Bool = false, monitoringEnabled: Bool = true, monitoringInterval: Int = 60, analyses: [String: AgentAnalysis] = [:], agentReviewCards: [AgentReviewCard] = [], implementationPlans: [String: ImplementationPlan] = [:], committedHeads: [String: String] = [:], postedReReviewCommentTokens: Set<String> = [], agentModel: String = "auto", customAgentModel: String = "", reviewAuthorFilter: String = "", petVisible: Bool = true, petSize: Double = 190.0, petReduceMotion: Bool = false, latestPetNotification: PetBubbleContent? = nil, hasCompletedOnboarding: Bool = false, skippedOnboardingSteps: Set<String> = [], projectCopyFolder: String = "", updateRepository: String = "", updatesEnabled: Bool = true, lastNotifiedUpdateTag: String = "", requestedBranches: [RepositoryBranch] = [], cursorSpecSidebarCache: CursorSpecSidebarCache = CursorSpecSidebarCache(), automaticCursorSessionClassification: Bool = false) {
        self.repositories = repositories
        self.processedCommentIDs = processedCommentIDs
        self.knownPullRequestIDs = knownPullRequestIDs
        self.unreadPullRequestIDs = unreadPullRequestIDs
        self.unreadCommentIDs = unreadCommentIDs
        self.hasEstablishedNotificationBaseline = hasEstablishedNotificationBaseline
        self.approvedPullRequestIDs = approvedPullRequestIDs
        self.hasEstablishedApprovalBaseline = hasEstablishedApprovalBaseline
        self.monitoringEnabled = monitoringEnabled
        self.monitoringInterval = monitoringInterval
        self.analyses = analyses
        self.agentReviewCards = agentReviewCards
        self.implementationPlans = implementationPlans
        self.committedHeads = committedHeads
        self.postedReReviewCommentTokens = postedReReviewCommentTokens
        self.agentModel = agentModel
        self.customAgentModel = customAgentModel
        self.reviewAuthorFilter = reviewAuthorFilter
        self.petVisible = petVisible
        self.petSize = petSize
        self.petReduceMotion = petReduceMotion
        self.latestPetNotification = latestPetNotification
        self.hasCompletedOnboarding = hasCompletedOnboarding
        self.skippedOnboardingSteps = skippedOnboardingSteps
        self.projectCopyFolder = projectCopyFolder
        self.updateRepository = updateRepository
        self.updatesEnabled = updatesEnabled
        self.lastNotifiedUpdateTag = lastNotifiedUpdateTag
        self.requestedBranches = requestedBranches
        self.cursorSpecSidebarCache = cursorSpecSidebarCache
        self.automaticCursorSessionClassification = automaticCursorSessionClassification
    }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        repositories = try container.decodeIfPresent([RegisteredRepository].self, forKey: .repositories) ?? []
        processedCommentIDs = try container.decodeIfPresent(Set<String>.self, forKey: .processedCommentIDs) ?? []
        knownPullRequestIDs = try container.decodeIfPresent(Set<String>.self, forKey: .knownPullRequestIDs) ?? []
        unreadPullRequestIDs = try container.decodeIfPresent(Set<String>.self, forKey: .unreadPullRequestIDs) ?? []
        unreadCommentIDs = try container.decodeIfPresent(Set<String>.self, forKey: .unreadCommentIDs) ?? []
        hasEstablishedNotificationBaseline = try container.decodeIfPresent(Bool.self, forKey: .hasEstablishedNotificationBaseline) ?? false
        approvedPullRequestIDs = try container.decodeIfPresent(Set<String>.self, forKey: .approvedPullRequestIDs) ?? []
        hasEstablishedApprovalBaseline = try container.decodeIfPresent(Bool.self, forKey: .hasEstablishedApprovalBaseline) ?? false
        monitoringEnabled = try container.decodeIfPresent(Bool.self, forKey: .monitoringEnabled) ?? true
        monitoringInterval = try container.decodeIfPresent(Int.self, forKey: .monitoringInterval) ?? 60
        analyses = try container.decodeIfPresent([String: AgentAnalysis].self, forKey: .analyses) ?? [:]
        agentReviewCards = try container.decodeIfPresent([AgentReviewCard].self, forKey: .agentReviewCards) ?? []
        implementationPlans = try container.decodeIfPresent([String: ImplementationPlan].self, forKey: .implementationPlans) ?? [:]
        committedHeads = try container.decodeIfPresent([String: String].self, forKey: .committedHeads) ?? [:]
        postedReReviewCommentTokens = try container.decodeIfPresent(Set<String>.self, forKey: .postedReReviewCommentTokens) ?? []
        agentModel = try container.decodeIfPresent(String.self, forKey: .agentModel) ?? "auto"
        customAgentModel = try container.decodeIfPresent(String.self, forKey: .customAgentModel) ?? ""
        reviewAuthorFilter = try container.decodeIfPresent(String.self, forKey: .reviewAuthorFilter) ?? ""
        petVisible = try container.decodeIfPresent(Bool.self, forKey: .petVisible) ?? true
        petSize = try container.decodeIfPresent(Double.self, forKey: .petSize) ?? 190.0
        petReduceMotion = try container.decodeIfPresent(Bool.self, forKey: .petReduceMotion) ?? false
        latestPetNotification = try container.decodeIfPresent(PetBubbleContent.self, forKey: .latestPetNotification)
        hasCompletedOnboarding = try container.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding) ?? false
        skippedOnboardingSteps = try container.decodeIfPresent(Set<String>.self, forKey: .skippedOnboardingSteps) ?? []
        projectCopyFolder = try container.decodeIfPresent(String.self, forKey: .projectCopyFolder) ?? ""
        updateRepository = try container.decodeIfPresent(String.self, forKey: .updateRepository) ?? ""
        updatesEnabled = try container.decodeIfPresent(Bool.self, forKey: .updatesEnabled) ?? true
        lastNotifiedUpdateTag = try container.decodeIfPresent(String.self, forKey: .lastNotifiedUpdateTag) ?? ""
        requestedBranches = try container.decodeIfPresent([RepositoryBranch].self, forKey: .requestedBranches) ?? []
        cursorSpecSidebarCache = try container.decodeIfPresent(CursorSpecSidebarCache.self, forKey: .cursorSpecSidebarCache) ?? CursorSpecSidebarCache()
        automaticCursorSessionClassification = try container.decodeIfPresent(Bool.self, forKey: .automaticCursorSessionClassification) ?? false
    }
}

@MainActor
final class AppPersistence {
    private let url: URL
    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PRReviewAssistant", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        url = support.appendingPathComponent("state.json")
    }
    func load() -> PersistedState {
        guard let data = try? Data(contentsOf: url), let state = try? JSONDecoder().decode(PersistedState.self, from: data) else { return PersistedState() }
        return state
    }
    func save(_ state: PersistedState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
