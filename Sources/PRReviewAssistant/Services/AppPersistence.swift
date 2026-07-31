import Foundation

struct PersistedState: Codable {
    var repositories: [RegisteredRepository] = []
    var processedCommentIDs: Set<String> = []
    var knownPullRequestIDs: Set<String> = []
    var unreadPullRequestIDs: Set<String> = []
    var unreadCommentIDs: Set<String> = []
    var hasEstablishedNotificationBaseline = false
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

    private enum CodingKeys: String, CodingKey {
        case repositories, processedCommentIDs, knownPullRequestIDs, unreadPullRequestIDs, unreadCommentIDs
        case hasEstablishedNotificationBaseline
        case monitoringEnabled, monitoringInterval, analyses, agentReviewCards, implementationPlans, committedHeads, postedReReviewCommentTokens, agentModel, customAgentModel, reviewAuthorFilter, petVisible, petSize, petReduceMotion, latestPetNotification, hasCompletedOnboarding, skippedOnboardingSteps, projectCopyFolder
    }
    init(repositories: [RegisteredRepository] = [], processedCommentIDs: Set<String> = [], knownPullRequestIDs: Set<String> = [], unreadPullRequestIDs: Set<String> = [], unreadCommentIDs: Set<String> = [], hasEstablishedNotificationBaseline: Bool = false, monitoringEnabled: Bool = true, monitoringInterval: Int = 60, analyses: [String: AgentAnalysis] = [:], agentReviewCards: [AgentReviewCard] = [], implementationPlans: [String: ImplementationPlan] = [:], committedHeads: [String: String] = [:], postedReReviewCommentTokens: Set<String> = [], agentModel: String = "auto", customAgentModel: String = "", reviewAuthorFilter: String = "", petVisible: Bool = true, petSize: Double = 190.0, petReduceMotion: Bool = false, latestPetNotification: PetBubbleContent? = nil, hasCompletedOnboarding: Bool = false, skippedOnboardingSteps: Set<String> = [], projectCopyFolder: String = "") {
        self.repositories = repositories
        self.processedCommentIDs = processedCommentIDs
        self.knownPullRequestIDs = knownPullRequestIDs
        self.unreadPullRequestIDs = unreadPullRequestIDs
        self.unreadCommentIDs = unreadCommentIDs
        self.hasEstablishedNotificationBaseline = hasEstablishedNotificationBaseline
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
    }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        repositories = try container.decodeIfPresent([RegisteredRepository].self, forKey: .repositories) ?? []
        processedCommentIDs = try container.decodeIfPresent(Set<String>.self, forKey: .processedCommentIDs) ?? []
        knownPullRequestIDs = try container.decodeIfPresent(Set<String>.self, forKey: .knownPullRequestIDs) ?? []
        unreadPullRequestIDs = try container.decodeIfPresent(Set<String>.self, forKey: .unreadPullRequestIDs) ?? []
        unreadCommentIDs = try container.decodeIfPresent(Set<String>.self, forKey: .unreadCommentIDs) ?? []
        hasEstablishedNotificationBaseline = try container.decodeIfPresent(Bool.self, forKey: .hasEstablishedNotificationBaseline) ?? false
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
