import Foundation
import Observation
import AppKit

@MainActor @Observable
final class ReviewStore {
    private static let appUpdateRepository = "jenemia/PRReviewAssistant"
    struct AgentPermissionRequest: Identifiable {
        enum Kind { case workspaceTrust, cursorLogin, other }
        let id = UUID()
        let kind: Kind
        let cardID: AgentReviewCard.ID
        let pullRequest: PullRequest
        let question: String
        let hidesUserMessage: Bool
        let detail: String

        var title: String {
            switch kind {
            case .workspaceTrust: "Cursor 작업 공간 신뢰"
            case .cursorLogin: "Cursor 로그인 필요"
            case .other: "에이전트 권한 요청"
            }
        }
        var approvalTitle: String {
            switch kind {
            case .workspaceTrust: "신뢰하고 계속"
            case .cursorLogin: "Cursor 로그인 진행"
            case .other: "Cursor에서 권한 처리"
            }
        }
    }
    struct WorkspaceSwitchRequest: Identifiable {
        let id = UUID()
        let cardID: AgentReviewCard.ID
        let target: PullRequest
        let active: PullRequest?
    }
    struct BranchAgentPermissionRequest: Identifiable {
        enum Action {
            case review
            case message(cardID: BranchReviewCard.ID, message: String)
            case quiz
            case pullRequestProposal
        }

        let id = UUID()
        let kind: AgentPermissionRequest.Kind
        let branch: RepositoryBranch
        let action: Action
        let detail: String

        var title: String {
            switch kind {
            case .workspaceTrust: "Cursor 작업 공간 신뢰"
            case .cursorLogin: "Cursor 로그인 필요"
            case .other: "에이전트 권한 요청"
            }
        }
        var approvalTitle: String {
            switch kind {
            case .workspaceTrust: "신뢰하고 계속"
            case .cursorLogin: "Cursor 로그인 진행"
            case .other: "Cursor에서 권한 처리"
            }
        }
    }
    var pullRequests: [PullRequest] = []
    /// Unfiltered refresh result. `pullRequests` is the author-filtered Inbox.
    private var allPullRequests: [PullRequest] = []
    var repositories: [RegisteredRepository] = []
    var selectedID: PullRequest.ID?
    var lastRefreshed = Date.now
    var isRefreshing = false
    var isInitialLoadInProgress = true
    var statusMessage = "GitHub CLI를 확인하고 저장소를 등록하세요."
    var notificationStatus = "알림 권한을 확인 중입니다"
    var showsNotificationPermissionGuide = false
    var githubIdentity: GitHubIdentity?
    var comments: [String: [ReviewComment]] = [:]
    var analyses: [String: AgentAnalysis] = [:]
    var worktreePaths: [String: String] = [:]
    var diffStats: [String: String] = [:]
    var committedHeads: [String: String] = [:]
    var cursorConnection = CursorConnection(state: .unknown, detail: "연결 상태를 확인하세요.")
    var isCheckingCursorConnection = false
    var agentReviewCards: [AgentReviewCard] = []
    var implementationPlans: [String: ImplementationPlan] = [:]
    var agentPermissionRequest: AgentPermissionRequest?
    var branchAgentPermissionRequest: BranchAgentPermissionRequest?
    var workspaceSwitchRequest: WorkspaceSwitchRequest?
    var agentModel = "auto" { didSet { persist() } }
    var customAgentModel = "" { didSet { persist() } }
    var reviewAuthorFilter = "" { didSet { persist(); applyAuthorFilter() } }
    var monitoringEnabled = true { didSet { persist(); restartMonitoring() } }
    var monitoringInterval = 60 { didSet { persist(); restartMonitoring() } }
    var petVisible = true { didSet { persist() } }
    var petSize = 190.0 { didSet { persist() } }
    var petReduceMotion = false { didSet { persist() } }
    var latestPetNotification: PetBubbleContent?
    /// Changes for every notification, even when the displayed text repeats.
    var petNotificationEventID = UUID()
    var hasCompletedOnboarding = false
    var skippedOnboardingSteps: Set<String> = []
    var projectCopyFolder = ""
    var gitCLIStatus = "Git 설치 상태를 확인 중입니다."
    var gitAccountStatus = "Git 계정을 확인 중입니다."
    var updateRepository: String { Self.appUpdateRepository }
    var updatesEnabled = true { didSet { persist(); restartUpdateChecks() } }
    var latestAppRelease: GitHubRelease?
    var isCheckingForAppUpdate = false
    var appUpdateStatus = ""
    var cursorSessions: [CursorSession] = []
    /// The spec selected from the Agent sidebar. Nil means all sessions.
    var selectedCursorSpecName: String?
    var selectedCursorSessionID: String?
    var cursorHistoryStatus = "Cursor 세션 기록을 아직 불러오지 않았습니다."
    var isLoadingCursorHistory = false
    var cursorSessionSummaries: [String: String] = [:]
    var isSummarizingCursorSessionID: String?
    var cursorSessionSpecs: [String: CursorSessionSpec] = [:]
    var cursorSpecSidebarCache = CursorSpecSidebarCache()
    var automaticCursorSessionClassification = false { didSet { persist() } }
    var isClassifyingCursorSessions = false
    var cursorSpecClassificationStatus = ""
    var repositoryBranches: [RepositoryBranch] = []
    var requestedBranches: [RepositoryBranch] = []
    var selectedBranchID: String?
    var branchReviewCards: [String: [BranchReviewCard]] = [:]
    var isLoadingBranches = false
    var isReviewingBranch = false
    var branchQuizzes: [String: [BranchQuizQuestion]] = [:]
    var branchQuizNotices: [String: String] = [:]
    var branchQuizErrors: [String: String] = [:]
    var isMakingBranchQuiz = false
    var branchPullRequestProposals: [String: PullRequestProposal] = [:]
    var branchPullRequestProposalErrors: [String: String] = [:]
    var preparingPullRequestProposalBranchIDs: Set<String> = []

    private let persistence = AppPersistence()
    private let github = GitHubClient()
    private let workspaces = WorkspaceManager()
    private let localPractice = LocalPracticeRepository()
    private let cursor = CursorAgent()
    private let pullRequestProposalVerifier = PullRequestProposalVerifier()
    private let cursorHistory = CursorSessionHistoryService()
    private let cursorSessionSpecStore = CursorSessionSpecStore()
    private let workspaceSpecCatalog = WorkspaceSpecCatalog()
    private let notifications = NotificationService()
    private var processedCommentIDs: Set<String> = []
    private var trustedAgentReviewIDs: Set<AgentReviewCard.ID> = []
    private var trustedBranchReviewIDs: Set<RepositoryBranch.ID> = []
    private var knownPullRequestIDs: Set<String> = []
    private var unreadPullRequestIDs: Set<String> = []
    private var unreadCommentIDs: Set<String> = []
    private var hasEstablishedNotificationBaseline = false
    private var approvedPullRequestIDs: Set<String> = []
    private var hasEstablishedApprovalBaseline = false
    private var postedReReviewCommentTokens: Set<String> = []
    /// One registered local folder can only be checked out to one PR at a time.
    private var activePullRequestKeys: [String: String] = [:]
    private var preparingWorkspaceKeys: Set<String> = []
    private var monitoringTask: Task<Void, Never>?
    private var updateCheckTask: Task<Void, Never>?
    private var lastNotifiedUpdateTag = ""

    init() {
        let state = persistence.load()
        repositories = state.repositories
        processedCommentIDs = state.processedCommentIDs
        knownPullRequestIDs = state.knownPullRequestIDs
        unreadPullRequestIDs = state.unreadPullRequestIDs
        unreadCommentIDs = state.unreadCommentIDs
        hasEstablishedNotificationBaseline = state.hasEstablishedNotificationBaseline
        approvedPullRequestIDs = state.approvedPullRequestIDs
        hasEstablishedApprovalBaseline = state.hasEstablishedApprovalBaseline
        monitoringEnabled = state.monitoringEnabled
        monitoringInterval = state.monitoringInterval
        analyses = state.analyses
        agentReviewCards = state.agentReviewCards
        implementationPlans = state.implementationPlans
        migrateImplementationPlansToWorkCards()
        committedHeads = state.committedHeads
        postedReReviewCommentTokens = state.postedReReviewCommentTokens
        for repository in repositories where committedHeads.keys.contains(where: { $0.hasPrefix("\(repository.fullName)#") }) {
            for key in committedHeads.keys where key.hasPrefix("\(repository.fullName)#") {
                worktreePaths[key] = repository.localPath
            }
        }
        agentModel = state.agentModel
        customAgentModel = state.customAgentModel
        reviewAuthorFilter = state.reviewAuthorFilter
        petVisible = state.petVisible
        petSize = state.petSize
        petReduceMotion = state.petReduceMotion
        latestPetNotification = state.latestPetNotification
        hasCompletedOnboarding = state.hasCompletedOnboarding
        skippedOnboardingSteps = state.skippedOnboardingSteps
        projectCopyFolder = state.projectCopyFolder
        updatesEnabled = state.updatesEnabled
        lastNotifiedUpdateTag = state.lastNotifiedUpdateTag
        requestedBranches = state.requestedBranches
        cursorSpecSidebarCache = state.cursorSpecSidebarCache
        automaticCursorSessionClassification = state.automaticCursorSessionClassification
        recoverInterruptedWork()
        Task { await startup() }
    }

    var selectedPullRequest: PullRequest? { pullRequests.first { $0.id == selectedID } }
    var selectedBranch: RepositoryBranch? { requestedBranches.first { $0.id == selectedBranchID } }
    var selectedCursorSession: CursorSession? { cursorSessions.first { $0.id == selectedCursorSessionID } }
    var cursorSpecNames: [String] {
        let names = Set(cursorSessions.compactMap { session -> String? in
            let name = cursorSessionSpecName(for: session)
            return name == CursorSessionSpec.unclassifiedName ? nil : name
        })
        return names.sorted { lhs, rhs in
            let leftLatest = cursorSessions(forSpec: lhs).first?.updatedAt ?? .distantPast
            let rightLatest = cursorSessions(forSpec: rhs).first?.updatedAt ?? .distantPast
            if leftLatest != rightLatest { return leftLatest > rightLatest }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
    }
    var cursorSpecSidebarNames: [String] {
        cursorSpecSidebarCache.visibleNames.filter { cursorSpecLatestSessionDates[$0] != nil }
    }
    func cursorSessionCount(forSpec name: String) -> Int {
        cursorSessions.filter { cursorSessionSpecName(for: $0) == name }.count
    }
    func cursorSessions(forSpec name: String?) -> [CursorSession] {
        cursorSessions
            .filter { session in
                guard let name else { return true }
                return cursorSessionSpecName(for: session) == name
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }
    var unclassifiedCursorSessionCount: Int {
        cursorSessions(forSpec: CursorSessionSpec.unclassifiedName).count
    }
    func selectCursorSpec(_ name: String?) {
        if let name {
            let previousCache = cursorSpecSidebarCache
            cursorSpecSidebarCache.activate(name, latestSessionAtByName: cursorSpecLatestSessionDates)
            if cursorSpecSidebarCache != previousCache { persist() }
        }
        selectedCursorSpecName = name
        let sessions = cursorSessions(forSpec: name)
        if !sessions.contains(where: { $0.id == selectedCursorSessionID }) {
            selectedCursorSessionID = sessions.first?.id
        }
    }
    func closeCursorSpecFromSidebar(_ name: String) {
        cursorSpecSidebarCache.close(name, latestSessionAt: cursorSpecLatestSessionDates[name])
        if selectedCursorSpecName == name {
            selectedCursorSpecName = nil
            selectedCursorSessionID = cursorSessions(forSpec: nil).first?.id
        }
        persist()
    }
    func toggleCursorSpecPinned(_ name: String) {
        guard cursorSpecSidebarCache.togglePinned(name, latestSessionAtByName: cursorSpecLatestSessionDates) else {
            cursorHistoryStatus = "Spec 고정은 최대 \(CursorSpecSidebarCache.maximumPinnedCount)개까지 가능합니다."
            return
        }
        persist()
    }
    func isCursorSpecPinned(_ name: String) -> Bool {
        cursorSpecSidebarCache.isPinned(name)
    }
    func canPinCursorSpec(_ name: String) -> Bool {
        cursorSpecSidebarCache.canPin(name)
    }
    var pendingCursorSpecClassificationCount: Int {
        cursorSessions.filter { session in
            guard let spec = cursorSessionSpecs[session.id], isCanonicalSpecRecord(spec) else { return true }
            return spec.sessionUpdatedAt < session.updatedAt
        }.count
    }

    private func isCanonicalSpecRecord(_ record: CursorSessionSpec) -> Bool {
        record.specName != CursorSessionSpec.unclassifiedName && CursorSessionSpecStore.isCanonicalSpecPath(record.specPath)
    }

    private func cursorSessionSpecName(for session: CursorSession) -> String {
        guard let record = cursorSessionSpecs[session.id], isCanonicalSpecRecord(record) else {
            return CursorSessionSpec.unclassifiedName
        }
        return record.specName
    }
    private var cursorSpecLatestSessionDates: [String: Date] {
        var latestDates: [String: Date] = [:]
        for session in cursorSessions {
            let name = cursorSessionSpecName(for: session)
            guard name != CursorSessionSpec.unclassifiedName else { continue }
            latestDates[name] = max(latestDates[name] ?? .distantPast, session.updatedAt)
        }
        return latestDates
    }
    private func reconcileCursorSpecSidebarCache() {
        let previousCache = cursorSpecSidebarCache
        cursorSpecSidebarCache.reconcile(latestSessionAtByName: cursorSpecLatestSessionDates)
        if cursorSpecSidebarCache != previousCache { persist() }
    }
    var unreadCount: Int { pullRequests.filter(isUnread(_:)).count }

    /// Fetching origin can take several seconds on a large repository. Keep it
    /// off the main actor so selecting the PR-request sidebar item remains
    /// immediate and the list can show its own loading state.
    func loadRepositoryBranches() async {
        guard !isLoadingBranches else { return }
        isLoadingBranches = true
        defer { isLoadingBranches = false }
        let registeredRepositories = repositories
        let manager = workspaces
        let result: ([RepositoryBranch], [String])
        do {
            result = try await background { () -> ([RepositoryBranch], [String]) in
                var loaded: [RepositoryBranch] = []
                var failures: [String] = []
                for repository in registeredRepositories {
                    do { loaded += try manager.branches(in: repository) }
                    catch { failures.append("\(repository.fullName) 브랜치를 불러오지 못했습니다: \(error.localizedDescription)") }
                }
                return (loaded, failures)
            }
        } catch {
            result = ([], ["브랜치 목록을 불러오지 못했습니다: \(error.localizedDescription)"])
        }
        repositoryBranches = result.0
        if let failure = result.1.first { statusMessage = failure }
        // Preserve user-added branches, but refresh their metadata whenever
        // origin reports the same branch again.
        requestedBranches = requestedBranches.compactMap { requested in
            result.0.first(where: { $0.id == requested.id }) ?? requested
        }
        if selectedBranch == nil { selectedBranchID = requestedBranches.first?.id }
    }

    func addRequestedBranch(_ branch: RepositoryBranch) {
        if let index = requestedBranches.firstIndex(where: { $0.id == branch.id }) {
            requestedBranches[index] = branch
        } else {
            requestedBranches.append(branch)
            requestedBranches.sort { lhs, rhs in
                if lhs.repositoryName != rhs.repositoryName { return lhs.repositoryName < rhs.repositoryName }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        }
        selectedBranchID = branch.id
        persist()
    }

    func removeRequestedBranch(_ branch: RepositoryBranch) {
        requestedBranches.removeAll { $0.id == branch.id }
        if selectedBranchID == branch.id { selectedBranchID = requestedBranches.first?.id }
        persist()
    }

    func branchCards(for branch: RepositoryBranch) -> [BranchReviewCard] { branchReviewCards[branch.id] ?? [] }

    func reviewSelectedBranch() async {
        guard let branch = selectedBranch,
              let repository = repositories.first(where: { $0.id == branch.repositoryID }),
              !isReviewingBranch else { return }
        isReviewingBranch = true
        defer { isReviewingBranch = false }
        do {
            let model = effectiveAgentModel
            let isTrusted = trustedBranchReviewIDs.contains(branch.id)
            let output = try await background { try self.cursor.reviewBranch(repositoryPath: repository.localPath, branch: branch, baseBranch: repository.defaultBranch, trustWorkspace: isTrusted, model: model) }
            branchReviewCards[branch.id] = Self.makeBranchReviewCards(from: output)
            statusMessage = "\(branch.name) 브랜치 리뷰를 분류했습니다."
        } catch {
            if let kind = permissionKind(for: error.localizedDescription) {
                branchAgentPermissionRequest = .init(kind: kind, branch: branch, action: .review, detail: error.localizedDescription)
                return
            }
            statusMessage = "브랜치 리뷰 실패: \(error.localizedDescription)"
        }
    }

    func sendBranchMessage(cardID: BranchReviewCard.ID, branch: RepositoryBranch, message: String, recordsUserMessage: Bool = true) async {
        guard let repository = repositories.first(where: { $0.id == branch.repositoryID }),
              let index = branchReviewCards[branch.id]?.firstIndex(where: { $0.id == cardID }) else { return }
        if recordsUserMessage { branchReviewCards[branch.id]?[index].messages.append(.init(role: .user, body: message)) }
        branchReviewCards[branch.id]?[index].updatedAt = .now
        let card = branchReviewCards[branch.id]![index]
        do {
            let model = effectiveAgentModel
            let isTrusted = trustedBranchReviewIDs.contains(branch.id)
            let response = try await background { try self.cursor.askAboutBranch(repositoryPath: repository.localPath, branch: branch, card: card, question: message, trustWorkspace: isTrusted, model: model) }
            guard let updated = branchReviewCards[branch.id]?.firstIndex(where: { $0.id == cardID }) else { return }
            branchReviewCards[branch.id]?[updated].messages.append(.init(role: .agent, body: response))
            branchReviewCards[branch.id]?[updated].updatedAt = .now
        } catch {
            if let kind = permissionKind(for: error.localizedDescription) {
                branchAgentPermissionRequest = .init(kind: kind, branch: branch, action: .message(cardID: cardID, message: message), detail: error.localizedDescription)
                return
            }
            guard let updated = branchReviewCards[branch.id]?.firstIndex(where: { $0.id == cardID }) else { return }
            branchReviewCards[branch.id]?[updated].messages.append(.init(role: .agent, body: "대화 요청에 실패했습니다. \(error.localizedDescription)"))
        }
    }

    func pullRequestProposal(for branch: RepositoryBranch) -> PullRequestProposal? {
        branchPullRequestProposals[branch.id]
    }

    func isPreparingPullRequestProposal(for branch: RepositoryBranch) -> Bool {
        preparingPullRequestProposalBranchIDs.contains(branch.id)
    }

    @discardableResult
    func preparePullRequestProposal(for branch: RepositoryBranch, force: Bool = false) async -> PullRequestProposal? {
        guard let repository = repositories.first(where: { $0.id == branch.repositoryID }) else { return nil }
        if !force, let proposal = branchPullRequestProposals[branch.id] { return proposal }
        guard !preparingPullRequestProposalBranchIDs.contains(branch.id) else {
            return branchPullRequestProposals[branch.id]
        }
        if force { branchPullRequestProposals[branch.id] = nil }
        branchPullRequestProposalErrors[branch.id] = nil
        preparingPullRequestProposalBranchIDs.insert(branch.id)
        defer { preparingPullRequestProposalBranchIDs.remove(branch.id) }
        do {
            let model = effectiveAgentModel
            let isTrusted = trustedBranchReviewIDs.contains(branch.id)
            let proposal = try await background {
                let draft = try self.cursor.preparePullRequest(
                    repositoryPath: repository.localPath,
                    branch: branch,
                    defaultBranch: repository.defaultBranch,
                    trustWorkspace: isTrusted,
                    model: model
                )
                var verified = try self.pullRequestProposalVerifier.verify(draft, repository: repository, branch: branch)
                verified.existingPullRequest = try self.github.pullRequest(repository: repository, headBranch: branch.name)
                return verified
            }
            branchPullRequestProposals[branch.id] = proposal
            statusMessage = "\(proposal.skillName) 스킬로 PR 요청 내용을 준비했습니다."
            return proposal
        } catch {
            if let kind = permissionKind(for: error.localizedDescription) {
                branchAgentPermissionRequest = .init(kind: kind, branch: branch, action: .pullRequestProposal, detail: error.localizedDescription)
                return nil
            }
            let detail = error.localizedDescription
            branchPullRequestProposalErrors[branch.id] = detail
            statusMessage = "PR 요청 준비 실패: \(detail)"
            return nil
        }
    }

    func requestPullRequest(
        for branch: RepositoryBranch,
        proposal: PullRequestProposal,
        title: String,
        body: String
    ) async -> String? {
        guard let repository = repositories.first(where: { $0.id == branch.repositoryID }) else { return nil }
        do {
            let confirmedProposal: PullRequestProposal = {
                var value = proposal
                value.title = title
                value.body = body
                return value
            }()
            let verified = try await background {
                try self.pullRequestProposalVerifier.verify(confirmedProposal, repository: repository, branch: branch)
            }
            if let existing = try await background({
                try self.github.pullRequest(repository: repository, headBranch: branch.name)
            }), existing.state.uppercased() == "OPEN" {
                statusMessage = "이미 열린 PR이 있습니다: \(existing.url)"
                return existing.url
            }
            let url = try await background {
                try self.github.createPullRequest(
                    repository: repository,
                    branch: branch.name,
                    baseBranch: verified.base,
                    title: verified.title,
                    body: verified.body,
                    reviewers: verified.reviewers
                )
            }
            statusMessage = "PR 요청을 만들었습니다: \(url)"
            return url
        } catch {
            statusMessage = "PR 요청 실패: \(error.localizedDescription)"
            return nil
        }
    }

    func makeBranchQuiz(for branch: RepositoryBranch) async -> [BranchQuizQuestion]? {
        guard let repository = repositories.first(where: { $0.id == branch.repositoryID }),
              !isMakingBranchQuiz else { return branchQuizzes[branch.id] }
        let cards = branchCards(for: branch)
        guard !cards.isEmpty else {
            statusMessage = "퀴즈를 만들기 전에 브랜치 리뷰를 실행하세요."
            return nil
        }
        isMakingBranchQuiz = true
        defer { isMakingBranchQuiz = false }
        do {
            let model = effectiveAgentModel
            let isTrusted = trustedBranchReviewIDs.contains(branch.id)
            let generation = try await background { try self.cursor.makeBranchQuiz(repositoryPath: repository.localPath, branch: branch, reviewCards: cards, trustWorkspace: isTrusted, model: model) }
            branchQuizErrors[branch.id] = nil
            if generation.needsQuiz {
                branchQuizNotices[branch.id] = nil
                branchQuizzes[branch.id] = generation.questions
                return generation.questions
            }
            branchQuizzes[branch.id] = nil
            branchQuizNotices[branch.id] = generation.reason.isEmpty ? "이번 변경은 별도 퀴즈로 확인할 만큼 크거나 복잡하지 않습니다." : generation.reason
            statusMessage = "이 브랜치는 퀴즈가 필요하지 않습니다."
            return nil
        } catch {
            if let kind = permissionKind(for: error.localizedDescription) {
                branchAgentPermissionRequest = .init(kind: kind, branch: branch, action: .quiz, detail: error.localizedDescription)
                return nil
            }
            let detail = error.localizedDescription
            branchQuizErrors[branch.id] = detail
            statusMessage = "퀴즈 생성 실패: \(detail)"
            return nil
        }
    }

    func retryBranchQuiz(for branch: RepositoryBranch) async -> [BranchQuizQuestion]? {
        branchQuizzes[branch.id] = nil
        branchQuizNotices[branch.id] = nil
        branchQuizErrors[branch.id] = nil
        return await makeBranchQuiz(for: branch)
    }

    func approveBranchAgentPermission() {
        guard let request = branchAgentPermissionRequest else { return }
        branchAgentPermissionRequest = nil
        switch request.kind {
        case .workspaceTrust:
            trustedBranchReviewIDs.insert(request.branch.id)
            retryBranchAgentAction(request)
        case .cursorLogin:
            startCursorLogin()
        case .other:
            statusMessage = "Cursor에서 추가 권한을 승인한 뒤 다시 시도하세요. \(request.detail)"
        }
    }

    func cancelBranchAgentPermission() {
        guard let request = branchAgentPermissionRequest else { return }
        branchAgentPermissionRequest = nil
        statusMessage = "\(request.branch.name) 브랜치의 에이전트 요청을 시작하지 않았습니다."
    }

    private func retryBranchAgentAction(_ request: BranchAgentPermissionRequest) {
        Task {
            switch request.action {
            case .review:
                selectedBranchID = request.branch.id
                await reviewSelectedBranch()
            case let .message(cardID, message):
                await sendBranchMessage(cardID: cardID, branch: request.branch, message: message, recordsUserMessage: false)
            case .quiz:
                _ = await makeBranchQuiz(for: request.branch)
            case .pullRequestProposal:
                _ = await preparePullRequestProposal(for: request.branch, force: true)
            }
        }
    }

    private static func makeBranchReviewCards(from output: String) -> [BranchReviewCard] {
        let mapping: [(String, BranchReviewCategory)] = [("차단", .blocker), ("확인 필요", .concern), ("개선", .improvement), ("통과", .passed)]
        return mapping.map { title, category in
            let pattern = "(?s)##\\s*\(NSRegularExpression.escapedPattern(for: title))\\s*(.*?)(?=\\n##\\s|\\z)"
            let range = NSRange(output.startIndex..., in: output)
            let content: String
            if let expression = try? NSRegularExpression(pattern: pattern), let match = expression.firstMatch(in: output, range: range), let bodyRange = Range(match.range(at: 1), in: output) {
                content = String(output[bodyRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            } else { content = "특이사항 없음" }
            let firstHeading = content.split(separator: "\n").first(where: { $0.hasPrefix("###") })?.replacingOccurrences(of: "#", with: "").trimmingCharacters(in: .whitespaces) ?? title
            return BranchReviewCard(category: category, title: firstHeading, summary: String(content.replacingOccurrences(of: "\n", with: " ").prefix(130)), details: content)
        }
    }
    func canCommit(for card: AgentReviewCard, pullRequest: PullRequest) -> Bool {
        guard let plan = implementationPlan(for: card, pullRequest: pullRequest) else { return false }
        return plan.status == .completed
            && plan.committedSHA == nil
            && !(plan.changedFiles ?? []).isEmpty
    }
    var petState: PetState { PetState.resolve(pullRequests: pullRequests, unreadCount: unreadCount) }
    var petBubbleContent: PetBubbleContent {
        guard let latestPetNotification, matchesAuthorFilter(latestPetNotification.sourceAuthor) else {
            return PetBubbleContent.latest(in: pullRequests)
        }
        return latestPetNotification
    }

    func startup() async {
        defer { isInitialLoadInProgress = false }
        notificationStatus = await notifications.authorizationSummary()
        showsNotificationPermissionGuide = await notifications.isAuthorizationUndecided()
        if CommandLine.arguments.contains("--notification-test") {
            notificationStatus = await notifications.deliverTestNotification()
        }
        await checkAuthentication()
        await checkOnboardingPrerequisites()
        // GitHub polling and notifications do not depend on Cursor. Establish
        // the notification baseline first so a missing or slow LLM connection
        // can never delay review alerts.
        if !repositories.isEmpty { await refresh() }
        restartMonitoring()
        restartUpdateChecks()
        Task { [weak self] in await self?.checkCursorConnection() }
    }

    func loadCursorHistory() async {
        guard !isLoadingCursorHistory else { return }
        isLoadingCursorHistory = true
        defer { isLoadingCursorHistory = false }
        do {
            let result = try await background {
                (try self.cursorHistory.loadSessions(), try self.cursorSessionSpecStore.load())
            }
            let sessions = result.0
            cursorSessions = sessions
            cursorSessionSpecs = result.1
            reconcileCursorSpecSidebarCache()
            if let selectedCursorSpecName,
               !cursorSpecNames.contains(selectedCursorSpecName) {
                self.selectedCursorSpecName = nil
            }
            let selectedSessions = cursorSessions(forSpec: self.selectedCursorSpecName)
            if !selectedSessions.contains(where: { $0.id == selectedCursorSessionID }) {
                selectedCursorSessionID = selectedSessions.first?.id
            }
            cursorSessionSummaries = cursorSessionSummaries.filter { key, _ in sessions.contains(where: { $0.id == key }) }
            cursorHistoryStatus = sessions.isEmpty ? "표시할 Cursor 세션 기록이 없습니다." : "Cursor 세션 \(sessions.count)개를 읽었습니다."
            if automaticCursorSessionClassification {
                await classifyUpdatedCursorSessions()
            }
        } catch {
            cursorSessions = []
            selectedCursorSpecName = nil
            selectedCursorSessionID = nil
            cursorHistoryStatus = error.localizedDescription
        }
    }

    func summarizeCursorSession(_ session: CursorSession) async {
        guard isSummarizingCursorSessionID == nil else { return }
        isSummarizingCursorSessionID = session.id
        defer { isSummarizingCursorSessionID = nil }
        do {
            let model = effectiveAgentModel
            let summary = try await background { try self.cursor.summarize(session: session, model: model) }
            cursorSessionSummaries[session.id] = summary
        } catch {
            cursorHistoryStatus = "세션 요약 실패: \(error.localizedDescription)"
        }
    }

    func classifyUpdatedCursorSessions() async {
        let pending = cursorSessions.filter { session in
            guard let record = cursorSessionSpecs[session.id], isCanonicalSpecRecord(record) else { return true }
            return record.sessionUpdatedAt < session.updatedAt
        }
        await classifyCursorSessions(pending, emptyMessage: "새로 분류할 세션이 없습니다.", progressLabel: "갱신된 세션")
    }

    /// Retries every session that is still explicitly recorded as unclassified,
    /// including entries that were previously attempted at the same timestamp.
    func classifyUnclassifiedCursorSessions() async {
        let pending = cursorSessions(forSpec: CursorSessionSpec.unclassifiedName)
        await classifyCursorSessions(pending, emptyMessage: "미분류 세션이 없습니다.", progressLabel: "미분류 세션")
    }

    private func classifyCursorSessions(_ pending: [CursorSession], emptyMessage: String, progressLabel: String) async {
        guard !isClassifyingCursorSessions else { return }
        guard !pending.isEmpty else {
            cursorSpecClassificationStatus = emptyMessage
            return
        }
        isClassifyingCursorSessions = true
        cursorSpecClassificationStatus = "\(progressLabel) \(pending.count)개를 spec에 연결하는 중입니다."
        defer { isClassifyingCursorSessions = false }

        var completed = 0
        for session in pending {
            do {
                let documents = try await background { self.workspaceSpecCatalog.documents(in: session.workspacePath) }
                let model = effectiveAgentModel
                let classification = try await background {
                    try self.cursor.classifySpec(session: session, documents: documents, model: model)
                }
                let record = CursorSessionSpec(
                    sessionID: session.id,
                    specName: classification.specName,
                    specPath: classification.specPath,
                    sessionUpdatedAt: session.updatedAt,
                    classifiedAt: .now
                )
                try await background { try self.cursorSessionSpecStore.save(record) }
                cursorSessionSpecs[session.id] = record
                completed += 1
                cursorSpecClassificationStatus = "\(completed)/\(pending.count)개 세션을 분류했습니다."
            } catch {
                cursorSpecClassificationStatus = "세션 spec 분류 중 일부 항목을 건너뛰었습니다: \(error.localizedDescription)"
            }
        }
        reconcileCursorSpecSidebarCache()
        if let selectedCursorSpecName,
           !cursorSpecNames.contains(selectedCursorSpecName) {
            self.selectedCursorSpecName = cursorSpecSidebarNames.first
            selectedCursorSessionID = cursorSessions(forSpec: self.selectedCursorSpecName).first?.id
        }
        if completed == pending.count {
            cursorSpecClassificationStatus = "\(progressLabel) \(completed)개를 spec별로 분류했습니다."
        }
    }

    func checkOnboardingPrerequisites() async {
        do {
            let version = try await background { try ProcessRunner().run("git", arguments: ["--version"]).output.trimmingCharacters(in: .whitespacesAndNewlines) }
            gitCLIStatus = "설치됨 · \(version)"
        } catch {
            gitCLIStatus = "Git CLI를 찾을 수 없습니다. Xcode Command Line Tools 또는 Git을 설치하세요."
        }
        do {
            gitAccountStatus = try await background { try self.github.localGitAccount() }
        } catch {
            gitAccountStatus = "이름과 이메일을 아직 설정하지 않았습니다. Terminal에서 git config --global user.name / user.email을 설정하세요."
        }
    }

    func startGitHubLogin() {
        do {
            try github.startLogin()
            statusMessage = "Terminal과 브라우저에서 GitHub 인증을 완료한 뒤 다시 확인하세요."
        } catch { statusMessage = "GitHub 로그인 시작 실패: \(error.localizedDescription)" }
    }

    func setProjectCopyFolder(_ path: String) {
        projectCopyFolder = path
        persist()
    }

    func skipOnboardingStep(_ step: String) {
        skippedOnboardingSteps.insert(step)
        persist()
    }

    func finishOnboarding() {
        hasCompletedOnboarding = true
        persist()
    }

    func restartOnboarding() {
        hasCompletedOnboarding = false
        skippedOnboardingSteps = []
        persist()
    }

    func checkAuthentication() async {
        do {
            githubIdentity = try await background { try self.github.authentication() }
            if reviewAuthorFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                reviewAuthorFilter = githubIdentity!.login
            }
            statusMessage = "GitHub 로그인됨: \(githubIdentity!.login)"
        } catch {
            let localAuthor = try? await background { try self.github.localGitAuthorName() }
            if reviewAuthorFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let localAuthor,
               !localAuthor.isEmpty {
                reviewAuthorFilter = localAuthor
                statusMessage = "Git 작성자 이름을 불러왔습니다: \(localAuthor)"
            } else {
                statusMessage = "GitHub CLI 확인 필요: \(error.localizedDescription)"
            }
        }
    }

    func checkCursorConnection() async {
        guard !isCheckingCursorConnection else { return }
        isCheckingCursorConnection = true
        let agent = cursor
        cursorConnection = await Task.detached(priority: .userInitiated) { agent.connection() }.value
        isCheckingCursorConnection = false
    }

    /// Checks first, then launches the appropriate next step for the observed state.
    func reconnectCursorAgent() async {
        await checkCursorConnection()
        if cursorConnection.state == .needsLogin {
            startCursorLogin()
        }
    }

    func startCursorLogin() {
        do {
            try cursor.startLogin()
            cursorConnection = CursorConnection(state: .needsLogin, detail: "Terminal과 브라우저에서 Cursor 인증을 완료한 뒤 ‘다시 연결하기’를 선택하세요.")
        } catch {
            cursorConnection = CursorConnection(state: .unavailable, detail: error.localizedDescription)
        }
    }

    func openCursorDownload() {
        guard let url = URL(string: "https://cursor.com/downloads") else { return }
        NSWorkspace.shared.open(url)
        statusMessage = "브라우저에서 Cursor를 설치한 뒤 ‘Cursor CLI 설치 상태 확인’을 선택하세요."
    }

    func registerRepository(at path: String) async {
        do {
            let repository = try await background { try self.github.inspectRepository(at: path) }
            guard !repositories.contains(where: { $0.localPath == repository.localPath }) else { statusMessage = "이미 등록된 저장소입니다."; return }
            repositories.append(repository)
            persist()
            statusMessage = "\(repository.fullName)을 등록했습니다."
            await refresh()
        } catch { statusMessage = "저장소 등록 실패: \(error.localizedDescription)" }
    }

    var hasLocalPracticePullRequest: Bool {
        repositories.contains { $0.isLocalPractice == true }
    }

    /// Adds a disposable PR fixture backed only by a local bare Git remote.
    /// No GitHub repository, API call, or network push is involved.
    func addLocalPracticePullRequest() async {
        guard !hasLocalPracticePullRequest else {
            statusMessage = "로컬 연습 PR이 이미 Inbox에 있습니다. 삭제한 뒤 새로 만들 수 있습니다."
            return
        }
        do {
            let fixture = try await background { try self.localPractice.create() }
            repositories.append(fixture.repository)
            let key = worktreeKey(fixture.pullRequest)
            comments[key] = fixture.comments
            allPullRequests.removeAll { worktreeKey($0) == key }
            allPullRequests.append(fixture.pullRequest)
            allPullRequests.sort { $0.updatedAt > $1.updatedAt }
            knownPullRequestIDs.insert(key)
            unreadPullRequestIDs.insert(key)
            unreadCommentIDs.formUnion(fixture.comments.map(\.id))
            createAutomaticReviewCards(for: fixture.pullRequest, comments: fixture.comments)
            applyAuthorFilter()
            selectedID = fixture.pullRequest.id
            persist()
            statusMessage = "로컬 연습 PR을 Inbox에 추가했습니다. GitHub에는 아무것도 생성되지 않았습니다."
        } catch {
            statusMessage = "로컬 연습 PR 생성 실패: \(error.localizedDescription)"
        }
    }

    func removeLocalPracticePullRequest() {
        guard let repository = repositories.first(where: { $0.isLocalPractice == true }) else { return }
        do {
            try localPractice.remove(at: repository.localPath)
            removeRepository(repository)
            statusMessage = "로컬 연습 PR과 임시 Git 저장소를 삭제했습니다. GitHub에는 변경된 항목이 없습니다."
        } catch {
            statusMessage = "로컬 연습 PR 삭제 실패: \(error.localizedDescription)"
        }
    }

    func removeRepositories(at offsets: IndexSet) {
        let removed = offsets.map { repositories[$0] }
        removed.forEach(removeRepository)
    }

    /// Removes only this app's registration and cached review data. The local Git repository is never touched.
    func removeRepository(_ repository: RegisteredRepository) {
        repositories.removeAll { $0.id == repository.id }
        allPullRequests.removeAll { $0.repository == repository.fullName }
        let repositoryPrefix = "\(repository.fullName)#"
        pullRequests.removeAll { $0.repository == repository.fullName }
        comments = comments.filter { !$0.key.hasPrefix(repositoryPrefix) }
        analyses = analyses.filter { !$0.key.hasPrefix(repositoryPrefix) }
        worktreePaths = worktreePaths.filter { !$0.key.hasPrefix(repositoryPrefix) }
        committedHeads = committedHeads.filter { !$0.key.hasPrefix(repositoryPrefix) }
        postedReReviewCommentTokens = postedReReviewCommentTokens.filter { !$0.hasPrefix(repositoryPrefix) }
        agentReviewCards.removeAll { $0.repository == repository.fullName }
        selectedID = pullRequests.contains(where: { $0.id == selectedID }) ? selectedID : pullRequests.first?.id
        persist()
        statusMessage = "\(repository.fullName)을 등록 목록에서 제거했습니다. 원본 폴더는 그대로 유지됩니다."
    }

    func repositoryMonitoringChanged() { persist() }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false; lastRefreshed = .now }
        do {
            var fetched: [PullRequest] = []
            for repository in repositories where repository.monitoringEnabled || repository.isLocalPractice == true {
                if repository.isLocalPractice == true {
                    let fixture = try await background { try self.localPractice.load(from: repository) }
                    fetched.append(fixture.pullRequest)
                    comments[worktreeKey(fixture.pullRequest)] = fixture.comments
                    createAutomaticReviewCards(for: fixture.pullRequest, comments: fixture.comments)
                    continue
                }
                let prs = try await background { try self.github.pullRequests(for: repository) }
                for pr in prs {
                    let prKey = worktreeKey(pr)
                    let isNewPullRequest = !knownPullRequestIDs.contains(prKey)
                    let newComments = try await background { try self.github.comments(repository: repository.fullName, number: pr.number) }
                    comments[worktreeKey(pr)] = newComments
                    var enrichedPR = pr
                    enrichedPR.commentCount = newComments.count
                    if let latestReview = newComments.last(where: { $0.kind == .review }) {
                        enrichedPR.reviewer = latestReview.author
                        enrichedPR.summary = latestReview.body
                    } else if let firstComment = newComments.first {
                        enrichedPR.reviewer = firstComment.author
                        enrichedPR.summary = firstComment.body
                    }
                    fetched.append(enrichedPR)
                    let unseen = newComments.filter { !processedCommentIDs.contains($0.id) }
                    let becameApproved = hasEstablishedApprovalBaseline && pr.reviewState == .approved && !approvedPullRequestIDs.contains(prKey)
                    // A review body can contain multiple independently actionable
                    // sections. Create one durable analysis card for each section
                    // as soon as it is received. Analysis is always a user
                    // action; polling must never check out a branch.
                    let shouldNotify = hasEstablishedNotificationBaseline && matchesAuthorFilter(pr)
                    // The author filter scopes all automatic PR work, not just
                    // Inbox visibility and notifications. A filtered-out PR
                    // must never change the repository checkout in the
                    // background.
                    if matchesAuthorFilter(pr) {
                        createAutomaticReviewCards(for: pr, comments: newComments)
                    }
                    if shouldNotify && becameApproved {
                        publishPetNotification(.approved(pr))
                        notificationStatus = await notifications.deliverApproval(for: pr)
                    } else if shouldNotify && isNewPullRequest {
                        publishPetNotification(.newPullRequest(pr))
                        notificationStatus = await notifications.deliverNewPullRequest(pr)
                    } else if shouldNotify && !unseen.isEmpty {
                        publishPetNotification(.newReview(for: pr, count: unseen.count))
                        notificationStatus = await notifications.deliverNewReview(for: pr, count: unseen.count, eventID: unseen.map(\.id).joined(separator: "-"))
                    }
                    if shouldNotify && (isNewPullRequest || !unseen.isEmpty || becameApproved) {
                        unreadPullRequestIDs.insert(prKey)
                        unreadCommentIDs.formUnion(unseen.map(\.id))
                    }
                    knownPullRequestIDs.insert(prKey)
                    processedCommentIDs.formUnion(newComments.map(\.id))
                    if pr.reviewState == .approved {
                        approvedPullRequestIDs.insert(prKey)
                    } else {
                        approvedPullRequestIDs.remove(prKey)
                    }
                }
            }
            let previousSelectionKey = selectedPullRequest.map(worktreeKey)
            let uniquePullRequests = Dictionary(fetched.map { (worktreeKey($0), $0) }, uniquingKeysWith: { current, candidate in
                candidate.updatedAt > current.updatedAt ? candidate : current
            }).values
            allPullRequests = uniquePullRequests.sorted { $0.updatedAt > $1.updatedAt }
            applyAuthorFilter()
            hasEstablishedNotificationBaseline = true
            hasEstablishedApprovalBaseline = true
            selectedID = previousSelectionKey.flatMap { key in pullRequests.first(where: { worktreeKey($0) == key })?.id } ?? pullRequests.first?.id
            statusMessage = "PR \(pullRequests.count)개를 확인했습니다."
            persist()
        } catch { statusMessage = "새로 고침 실패: \(error.localizedDescription)" }
    }

    func startAnalysis(for pullRequest: PullRequest) async {
        guard reserveActiveWorkspace(for: pullRequest) else { return }
        if repositories.first(where: { $0.fullName == pullRequest.repository })?.isLocalPractice == true {
            analyses[worktreeKey(pullRequest)] = .init(
                judgment: "로컬 연습 PR",
                confidence: "해당 없음",
                affectedFiles: pullRequest.files.map(\.path),
                impact: "GitHub과 Cursor Agent를 호출하지 않는 안전한 UI 흐름 연습 항목입니다.",
                recommendation: "이 PR에서는 실제 에이전트 분석을 실행하지 않습니다. 필요하면 코드 수정, 테스트, 커밋과 로컬 푸시 흐름을 연습하세요.",
                suggestedTests: ["swift test"],
                rawOutput: "로컬 연습 PR: 실제 에이전트 검토는 생략했습니다."
            )
            updateStatus(.needsChanges, for: pullRequest.id)
            statusMessage = "로컬 연습 PR이므로 실제 에이전트 분석은 실행하지 않았습니다."
            persist()
            return
        }
        updateStatus(.analyzing, for: pullRequest.id)
        do {
            let repository = try registeredRepository(for: pullRequest)
            let path = try await background { try self.workspaces.prepareRepositoryWorkspace(repository: repository, pullRequest: pullRequest) }
            try await background { try self.workspaces.verifyHead(path, expectedSHA: pullRequest.headSHA, expectedBranch: pullRequest.headBranch) }
            setActiveWorkspace(path, for: pullRequest)
            let prComments = comments[worktreeKey(pullRequest)] ?? []
            let agent = cursor
            let model = effectiveAgentModel
            let result = try await background { try agent.analyze(worktreePath: path, pullRequest: pullRequest, comments: prComments, model: model) }
            analyses[worktreeKey(pullRequest)] = result
            updateStatus(.needsChanges, for: pullRequest.id)
            statusMessage = "분석이 완료되었습니다."
            persist()
        } catch { updateStatus(.needsAnalysis, for: pullRequest.id); statusMessage = "분석 실패: \(error.localizedDescription)" }
    }

    /// Prepares and verifies the PR branch without asking the agent to change code.
    /// The UI calls this immediately before handing the selected work to the user.
    func prepareWorkspace(for pullRequest: PullRequest) async -> String? {
        guard reserveActiveWorkspace(for: pullRequest) else { return nil }
        do {
            let repository = try registeredRepository(for: pullRequest)
            let path = try await background { try self.workspaces.prepareRepositoryWorkspace(repository: repository, pullRequest: pullRequest) }
            try await background { try self.workspaces.verifyHead(path, expectedSHA: pullRequest.headSHA, expectedBranch: pullRequest.headBranch) }
            setActiveWorkspace(path, for: pullRequest)
            statusMessage = "수정할 PR 작업 폴더를 준비했습니다."
            return path
        } catch {
            statusMessage = "작업 폴더 준비 실패: \(error.localizedDescription)"
            return nil
        }
    }

    func commitApprovedChanges(for card: AgentReviewCard, pullRequest: PullRequest) async {
        let pullRequestKey = worktreeKey(pullRequest)
        let planKey = implementationPlanKey(for: card, pullRequest: pullRequest)
        guard var plan = implementationPlans[planKey], plan.status == .completed, plan.committedSHA == nil else {
            statusMessage = "작업 완료된 미커밋 카드만 커밋할 수 있습니다."
            return
        }
        guard reserveActiveWorkspace(for: pullRequest) else { return }
        do {
            let workspace = workspaces
            let path: String
            if let activePath = worktreePaths[pullRequestKey] {
                try await background { try workspace.verifyHead(activePath, expectedSHA: pullRequest.headSHA, expectedBranch: pullRequest.headBranch) }
                path = activePath
            } else {
                let repository = try registeredRepository(for: pullRequest)
                let preparedPath = try await background { try workspace.prepareRepositoryWorkspace(repository: repository, pullRequest: pullRequest) }
                try await background { try workspace.verifyHead(preparedPath, expectedSHA: pullRequest.headSHA, expectedBranch: pullRequest.headBranch) }
                setActiveWorkspace(preparedPath, for: pullRequest)
                path = preparedPath
            }
            let changedFiles = plan.changedFiles ?? []
            guard !changedFiles.isEmpty else { statusMessage = "이 작업 카드에 기록된 변경 파일이 없습니다."; return }
            let scopedDiffStat = try await background { try workspace.changes(at: path, files: changedFiles) }
            let diffStat = ([scopedDiffStat.trimmingCharacters(in: .whitespacesAndNewlines), "작업 카드 파일:\n\(changedFiles.joined(separator: "\n"))"]
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n"))
            let developerName = try await background { try workspace.developerName(at: path) }
            let message = commitMessage(for: pullRequest, card: card, plan: plan, diffStat: diffStat, developerName: developerName)
            let committedSHA = try await background {
                try workspace.commit(at: path, message: message, files: changedFiles, branch: pullRequest.headBranch, expectedSHA: pullRequest.headSHA)
            }
            committedHeads[pullRequestKey] = committedSHA
            diffStats[pullRequestKey] = diffStat
            plan.committedSHA = committedSHA
            plan.result = "로컬 커밋 \(committedSHA.prefix(12))이 완료되었습니다. 푸시는 재리뷰 요청 시 진행합니다."
            plan.completedAt = .now
            implementationPlans[planKey] = plan
            persist()
            statusMessage = "로컬 커밋이 완료되었습니다. 추천 메시지를 만든 뒤 재리뷰를 요청하세요."
        } catch {
            let result = "커밋에 실패했습니다: \(error.localizedDescription)"
            statusMessage = "커밋 실패: \(error.localizedDescription)"
            updateImplementationResult(for: card, pullRequest: pullRequest, status: .failed, result: result)
        }
    }

    /// Records a user-authored change without requiring a review card. The
    /// user still confirms the exact commit message, and only files currently
    /// changed in the checked-out PR workspace are committed.
    func manualChangedFiles(for pullRequest: PullRequest) async -> [String] {
        guard reserveActiveWorkspace(for: pullRequest) else { return [] }
        do {
            let repository = try registeredRepository(for: pullRequest)
            let path = try await background { try self.workspaces.prepareRepositoryWorkspace(repository: repository, pullRequest: pullRequest) }
            try await background { try self.workspaces.verifyHead(path, expectedSHA: pullRequest.headSHA, expectedBranch: pullRequest.headBranch) }
            setActiveWorkspace(path, for: pullRequest)
            let files = try await background { try self.workspaces.changedFiles(at: path) }
            statusMessage = files.isEmpty ? "수동 커밋할 변경 파일이 없습니다." : "수동 커밋할 변경 파일 \(files.count)개를 확인했습니다."
            return files
        } catch {
            statusMessage = "수동 변경 파일 확인 실패: \(error.localizedDescription)"
            return []
        }
    }

    func commitManualChanges(for pullRequest: PullRequest, message: String) async -> Bool {
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMessage.isEmpty else {
            statusMessage = "커밋 메시지를 입력하세요."
            return false
        }
        guard reserveActiveWorkspace(for: pullRequest) else { return false }
        do {
            let repository = try registeredRepository(for: pullRequest)
            let path = try await background { try self.workspaces.prepareRepositoryWorkspace(repository: repository, pullRequest: pullRequest) }
            try await background { try self.workspaces.verifyHead(path, expectedSHA: pullRequest.headSHA, expectedBranch: pullRequest.headBranch) }
            setActiveWorkspace(path, for: pullRequest)
            let files = try await background { try self.workspaces.changedFiles(at: path) }
            guard !files.isEmpty else {
                statusMessage = "수동 커밋할 변경 파일이 없습니다."
                return false
            }
            let diff = try await background { try self.workspaces.changes(at: path, files: files) }
            let committedSHA = try await background {
                try self.workspaces.commit(at: path, message: trimmedMessage, files: files, branch: pullRequest.headBranch, expectedSHA: pullRequest.headSHA)
            }
            let key = worktreeKey(pullRequest)
            committedHeads[key] = committedSHA
            diffStats[key] = ([diff.trimmingCharacters(in: .whitespacesAndNewlines), "수동 커밋 파일:\n\(files.joined(separator: "\n"))"]
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n"))
            persist()
            statusMessage = "수동 로컬 커밋 \(committedSHA.prefix(12))이 완료되었습니다. 재리뷰 요청에서 코멘트를 작성하세요."
            return true
        } catch {
            statusMessage = "수동 커밋 실패: \(error.localizedDescription)"
            return false
        }
    }

    private func commitMessage(for pullRequest: PullRequest, card: AgentReviewCard, plan: ImplementationPlan, diffStat: String, developerName: String) -> String {
        return Self.synthesizedCommitMessage(
            pullRequestNumber: pullRequest.number,
            developerName: developerName,
            reviewTitle: card.sectionTitle ?? card.title,
            reviewComment: card.sectionBody ?? card.commentBody,
            implementationSummary: card.messages.last(where: { $0.role == .agent })?.body ?? plan.content,
            diffStat: diffStat
        )
    }

    static func synthesizedCommitMessage(pullRequestNumber: Int, developerName: String, reviewTitle: String, reviewComment: String, implementationSummary: String, diffStat: String) -> String {
        let subject = compactCommitText(reviewTitle, limit: 52).replacingOccurrences(of: "\n", with: " ")
        return """
        [개발 - \(compactCommitText(developerName, limit: 32).replacingOccurrences(of: "\n", with: " "))] PR #\(pullRequestNumber) \(subject) 검토 반영

        리뷰 코멘트:
        \(compactCommitText(reviewComment, limit: 700))

        작업 내용:
        \(compactCommitText(implementationSummary, limit: 700))

        변경 파일:
        \(compactCommitText(diffStat, limit: 1_200))
        """
    }

    private static func compactCommitText(_ text: String, limit: Int) -> String {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > limit else { return normalized }
        return "\(normalized.prefix(limit))\n…"
    }

    func generateReReviewMessage(for pullRequest: PullRequest) async -> String? {
        let key = worktreeKey(pullRequest)
        guard let path = worktreePaths[key] else {
            statusMessage = "추천 메시지를 만들려면 먼저 이 PR에서 에이전트 작업을 실행하세요."
            return nil
        }
        guard let committedSHA = committedHeads[key] else {
            statusMessage = "추천 메시지를 만들기 전에 작업 영역에서 변경 사항을 커밋하세요."
            return nil
        }

        let completedCardResults = Self.reReviewWorkSections(from: agentCards(for: pullRequest))
        var sections: [String] = []
        if let analysis = analyses[key] {
            sections.append("[전체 에이전트 분석]\n\(analysis.rawOutput)")
        }
        sections.append(contentsOf: completedCardResults)
        if let diff = diffStats[key] {
            sections.append("[변경 요약]\n\(diff.isEmpty ? "기록된 변경 파일 없음" : diff)")
        }
        guard !sections.isEmpty else {
            statusMessage = "압축할 에이전트 작업 결과가 없습니다."
            return nil
        }
        sections.insert("[로컬 커밋]\n\(String(committedSHA.prefix(12)))", at: 0)

        let agent = cursor
        let model = effectiveAgentModel
        let workSummary = sections.joined(separator: "\n\n")
        do {
            let message = try await background {
                try agent.suggestReReviewMessage(
                    repositoryPath: path,
                    pullRequest: pullRequest,
                    workSummary: workSummary,
                    model: model
                )
            }
            guard !message.isEmpty else {
                statusMessage = "에이전트가 추천 메시지를 만들지 못했습니다."
                return nil
            }
            statusMessage = "재리뷰 추천 메시지를 만들었습니다. 내용을 확인한 뒤 요청하세요."
            return message
        } catch {
            statusMessage = "추천 메시지 생성 실패: \(error.localizedDescription)"
            return nil
        }
    }

    func requestReReview(for pullRequest: PullRequest, comment: String = "") async {
        let key = worktreeKey(pullRequest)
        guard let committedSHA = committedHeads[key] else {
            statusMessage = "재리뷰 요청 전에 변경 사항을 로컬에 커밋하세요."
            return
        }
        let trimmedComment = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedComment.isEmpty else {
            statusMessage = "추천 메시지를 만들거나 재리뷰 코멘트를 입력하세요."
            return
        }
        let commentToken = "\(key)|\(committedSHA)|\(trimmedComment)"
        let workspace = workspaces
        var pushCompleted = false
        do {
            let repository = try registeredRepository(for: pullRequest)
            let path = try await background { try workspace.prepareRepositoryWorkspace(repository: repository, pullRequest: pullRequest) }
            try await background { try workspace.verifyHead(path, expectedSHA: pullRequest.headSHA, expectedBranch: pullRequest.headBranch) }
            setActiveWorkspace(path, for: pullRequest)
            try await background {
                try workspace.pushCommittedChanges(
                    at: path,
                    branch: pullRequest.headBranch,
                    expectedRemoteSHA: pullRequest.headSHA,
                    committedSHA: committedSHA
                )
            }
            pushCompleted = true
            if repository.isLocalPractice == true {
                committedHeads[key] = nil
                persist()
                statusMessage = "연습 PR의 변경을 로컬 임시 원격에만 푸시했습니다. GitHub 코멘트와 재리뷰 요청은 시뮬레이션으로 완료했습니다."
                return
            }
            statusMessage = "푸시가 완료되었습니다. PR 코멘트를 등록하는 중입니다."

            if !postedReReviewCommentTokens.contains(commentToken) {
                try await background {
                    try self.github.addComment(repository: pullRequest.repository, number: pullRequest.number, body: trimmedComment)
                }
                postedReReviewCommentTokens.insert(commentToken)
                persist()
            }
            statusMessage = "PR 코멘트를 등록했습니다. 재리뷰를 요청하는 중입니다."

            let reviewer = try await background {
                try self.github.latestReviewer(repository: pullRequest.repository, number: pullRequest.number)
            } ?? pullRequest.reviewer
            guard reviewer != "리뷰 대기", !reviewer.isEmpty else {
                throw CommandError.failed(.init(output: "", error: "PR 검토 기록에서 재요청할 리뷰어를 찾지 못했습니다.", status: 1))
            }
            try await background {
                try self.github.requestReview(repository: pullRequest.repository, number: pullRequest.number, reviewers: [reviewer])
            }
            committedHeads[key] = nil
            postedReReviewCommentTokens.remove(commentToken)
            persist()
            statusMessage = "푸시와 PR 코멘트 등록을 완료하고 \(reviewer)에게 재리뷰를 요청했습니다."
        } catch {
            if postedReReviewCommentTokens.contains(commentToken) {
                statusMessage = "푸시와 코멘트 등록은 완료했지만 재리뷰 요청에 실패했습니다: \(error.localizedDescription)"
            } else if pushCompleted {
                statusMessage = "푸시는 완료했지만 PR 코멘트 등록에 실패했습니다: \(error.localizedDescription)"
            } else {
                statusMessage = "푸시 실패: \(error.localizedDescription)"
            }
        }
    }

    /// Performs the user-confirmed GitHub merge. `gh --delete-branch` removes
    /// the source branch only when the server-side merge succeeds.
    func mergeApprovedPullRequest(_ pullRequest: PullRequest) async {
        guard pullRequest.reviewState == .approved else {
            statusMessage = "승인된 PR만 머지할 수 있습니다. 새로 고침 후 승인 상태를 확인하세요."
            return
        }
        guard repositories.first(where: { $0.fullName == pullRequest.repository })?.isLocalPractice != true else {
            statusMessage = "로컬 연습 PR은 GitHub 머지를 지원하지 않습니다."
            return
        }
        do {
            let repository = try registeredRepository(for: pullRequest)
            statusMessage = "GitHub에서 Create a merge commit으로 머지하는 중입니다."
            try await background {
                try self.github.mergePullRequest(
                    repository: pullRequest.repository,
                    number: pullRequest.number,
                    workingDirectory: repository.localPath
                )
            }
            let key = worktreeKey(pullRequest)
            committedHeads[key] = nil
            approvedPullRequestIDs.remove(key)
            persist()
            await refresh()
            statusMessage = "PR을 Create a merge commit으로 머지했고, 푸시 성공 후 소스 브랜치도 삭제했습니다."
        } catch {
            statusMessage = "PR 머지 실패: \(error.localizedDescription)"
        }
    }

    func createAgentReview(for comment: ReviewComment, pullRequest: PullRequest) -> AgentReviewCard.ID {
        createAgentReview(for: comment, section: comment.sections[0], pullRequest: pullRequest)
    }

    func createAgentReview(for comment: ReviewComment, section: ReviewCommentSection, pullRequest: PullRequest, reviewID: String? = nil, isUnread: Bool = false) -> AgentReviewCard.ID {
        let existingIndex = agentReviewCards.indices.first { index in
            let card = agentReviewCards[index]
            return card.repository == pullRequest.repository &&
                card.pullRequestNumber == pullRequest.number &&
                card.commentID == comment.id &&
                card.sectionID == section.id
        }
        if let index = existingIndex {
            // A reviewer can edit a comment after the first poll. Keep the
            // existing conversation but refresh the card's source section.
            agentReviewCards[index].reviewID = agentReviewCards[index].reviewID ?? reviewID
            agentReviewCards[index].commentAuthor = comment.author
            agentReviewCards[index].commentBody = comment.body
            agentReviewCards[index].sectionTitle = section.title
            agentReviewCards[index].sectionBody = section.body
            agentReviewCards[index].title = AgentReviewCard.title(for: section.title)
            agentReviewCards[index].updatedAt = .now
            persist()
            return agentReviewCards[index].id
        }
        let card = AgentReviewCard(
            reviewID: reviewID,
            repository: pullRequest.repository,
            pullRequestNumber: pullRequest.number,
            commentID: comment.id,
            commentAuthor: comment.author,
            commentBody: comment.body,
            sectionID: section.id,
            sectionTitle: section.title,
            sectionBody: section.body,
            title: AgentReviewCard.title(for: section.title),
            isUnread: isUnread
        )
        agentReviewCards.append(card)
        persist()
        return card.id
    }

    func agentCards(for pullRequest: PullRequest) -> [AgentReviewCard] {
        agentReviewCards.filter { $0.repository == pullRequest.repository && $0.pullRequestNumber == pullRequest.number }
            .sorted {
                let leftRank = ReviewCommentSection.severitySortRank(for: $0.sectionTitle)
                let rightRank = ReviewCommentSection.severitySortRank(for: $1.sectionTitle)
                if leftRank != rightRank { return leftRank < rightRank }
                if $0.commentID != $1.commentID { return $0.commentID < $1.commentID }
                return $0.sectionID ?? "" < $1.sectionID ?? ""
            }
    }

    func agentCard(id: AgentReviewCard.ID) -> AgentReviewCard? {
        agentReviewCards.first { $0.id == id }
    }

    func agentCard(reviewID: String) -> AgentReviewCard? {
        agentReviewCards.first { $0.reviewID == reviewID }
    }

    /// Builds the same section-level units exposed in the reviewer panel.
    /// The number is local to the stable PR identifier, so analysis and work
    /// cards remain linked even after app restarts.
    private func createAnalysisCards(for pullRequest: PullRequest, comments: [ReviewComment]) -> [AgentReviewCard.ID] {
        var sectionIndex = 0
        var created: [AgentReviewCard.ID] = []
        let commentIDs = Set(comments.map(\.id))
        let validSectionKeys = Set(comments.flatMap { comment in
            comment.sections.map { "\(comment.id)|\($0.id)" }
        })

        // Remove obsolete automatic cards created with the old parser. Manual
        // cards have no reviewID and are intentionally preserved.
        agentReviewCards.removeAll { card in
            let sectionID = card.sectionID ?? ""
            let sectionKey = "\(card.commentID)|\(sectionID)"
            return card.repository == pullRequest.repository &&
                card.pullRequestNumber == pullRequest.number &&
                card.reviewID != nil &&
                commentIDs.contains(card.commentID) &&
                !validSectionKeys.contains(sectionKey)
        }
        for comment in comments {
            for section in comment.sections {
                let reviewID = "\(pullRequest.id.uuidString.lowercased())_review_\(sectionIndex)"
                sectionIndex += 1
                let alreadyExists = agentReviewCards.contains {
                    $0.repository == pullRequest.repository &&
                    $0.pullRequestNumber == pullRequest.number &&
                    $0.commentID == comment.id &&
                    $0.sectionID == section.id
                }
                if !alreadyExists {
                    created.append(createAgentReview(for: comment, section: section, pullRequest: pullRequest, reviewID: reviewID, isUnread: true))
                } else {
                    _ = createAgentReview(for: comment, section: section, pullRequest: pullRequest, reviewID: reviewID)
                }
            }
        }
        persist()
        return created
    }

    /// Polling creates and refreshes cards only. It must not reserve a
    /// workspace, run Cursor, or check out a PR branch; those happen only
    /// after the user explicitly starts a card analysis.
    private func createAutomaticReviewCards(for pullRequest: PullRequest, comments: [ReviewComment]) {
        _ = createAnalysisCards(for: pullRequest, comments: comments)
    }

    /// Rebuilds persisted automatic cards from the currently loaded GitHub
    /// comments after a sectioning-rule improvement. User-created cards are
    /// preserved because they can include a manual conversation.
    func rebuildAutomaticReviewCards(for pullRequest: PullRequest) {
        let currentComments = comments(for: pullRequest)
        guard !currentComments.isEmpty else {
            statusMessage = "다시 분류할 PR 코멘트가 없습니다. 먼저 새로 고침을 실행하세요."
            return
        }
        let hasActiveAnalysis = agentReviewCards.contains {
            $0.repository == pullRequest.repository &&
            $0.pullRequestNumber == pullRequest.number &&
            $0.reviewID != nil &&
            ($0.status == .reviewing || $0.status == .queued)
        }
        guard !hasActiveAnalysis else {
            statusMessage = "진행 중이거나 대기 중인 자동 분석이 끝난 뒤 검토카드를 다시 분류하세요."
            return
        }

        agentReviewCards.removeAll {
            $0.repository == pullRequest.repository &&
            $0.pullRequestNumber == pullRequest.number &&
            $0.reviewID != nil
        }
        let rebuiltCount = createAnalysisCards(for: pullRequest, comments: currentComments).count
        persist()
        statusMessage = "개선된 규칙으로 자동 검토카드 \(rebuiltCount)개를 다시 만들었습니다. 분석은 '분석 시작'을 눌러야 진행됩니다."
    }

    func approveWorkspaceSwitch() {
        guard let request = workspaceSwitchRequest else { return }
        workspaceSwitchRequest = nil
        let key = worktreeKey(request.target)
        activePullRequestKeys[request.target.repository] = key
        worktreePaths[key] = nil
        Task { await self.beginAgentReview(id: request.cardID, pullRequest: request.target) }
    }

    func cancelWorkspaceSwitch() { workspaceSwitchRequest = nil }

    func markAgentCardRead(_ id: AgentReviewCard.ID) {
        guard let index = agentReviewCards.firstIndex(where: { $0.id == id }), agentReviewCards[index].isUnread else { return }
        agentReviewCards[index].isUnread = false
        persist()
    }

    /// Carries only the selected review card's conclusion and actionable
    /// source context into the work area. Other cards remain review history
    /// and must not be included in an implementation run by accident.
    func createImplementationPlan(for card: AgentReviewCard, pullRequest: PullRequest) -> ImplementationPlan? {
        guard card.repository == pullRequest.repository,
              card.pullRequestNumber == pullRequest.number,
              let conclusion = card.messages.last(where: { $0.role == .agent })?.body else {
            return nil
        }

        let request = (card.sectionBody ?? card.commentBody).trimmingCharacters(in: .whitespacesAndNewlines)
        let content = """
        # PR #\(pullRequest.number) 구현 계획

        검토 대화 전체가 아닌, 선택한 검토 카드의 리뷰 요청과 에이전트의 최종 판단만 전달합니다.

        ## \(card.sectionTitle ?? card.title)
        **리뷰 요청:** \(request)

        **에이전트 판단 및 수행 항목:**
        \(conclusion)
        """
        let planKey = implementationPlanKey(for: card, pullRequest: pullRequest)
        // A previously committed card is historical work. Reopening an
        // approved PR must create a fresh local-work cycle for the same
        // review card, while the old commit remains in Git history.
        if let existing = implementationPlans[planKey], existing.committedSHA == nil { return existing }
        let plan = ImplementationPlan(
            repository: pullRequest.repository,
            pullRequestNumber: pullRequest.number,
            content: content,
            sourceCardIDs: [card.id],
            sourceReviewIDs: card.reviewID.map { [$0] }
        )
        implementationPlans[planKey] = plan
        persist()
        return plan
    }

    func implementationPlan(for card: AgentReviewCard, pullRequest: PullRequest) -> ImplementationPlan? {
        implementationPlans[implementationPlanKey(for: card, pullRequest: pullRequest)]
    }

    func implementationPlans(for pullRequest: PullRequest) -> [ImplementationPlan] {
        implementationPlans.values
            .filter { $0.repository == pullRequest.repository && $0.pullRequestNumber == pullRequest.number }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// Starts a real, user-approved implementation run on the PR source branch.
    /// This never commits or pushes; those remain separate approval steps.
    func startImplementation(for card: AgentReviewCard, pullRequest: PullRequest) async {
        guard reserveActiveWorkspace(for: pullRequest) else { return }
        let key = implementationPlanKey(for: card, pullRequest: pullRequest)
        guard var plan = implementationPlans[key] else {
            statusMessage = "먼저 검토 카드에서 구현 계획을 만드세요."
            return
        }
        guard plan.status != .inProgress else { return }
        plan.destination = .currentLocal
        plan.status = .inProgress
        plan.result = "PR 소스 브랜치 \(pullRequest.headBranch)를 체크아웃하고 에이전트 구현을 시작하는 중입니다."
        plan.startedAt = .now
        plan.completedAt = nil
        implementationPlans[key] = plan
        statusMessage = "PR 소스 브랜치에서 에이전트 구현을 시작했습니다."
        persist()

        do {
            let repository = try registeredRepository(for: pullRequest)
            let path = try await background { try self.workspaces.prepareRepositoryWorkspace(repository: repository, pullRequest: pullRequest) }
            try await background { try self.workspaces.verifyHead(path, expectedSHA: pullRequest.headSHA, expectedBranch: pullRequest.headBranch) }
            setActiveWorkspace(path, for: pullRequest)
            let baselineFiles = try await background { try self.workspaces.changedFiles(at: path) }
            plan.baselineChangedFiles = baselineFiles
            implementationPlans[key] = plan
            persist()
            let agent = cursor
            let model = effectiveAgentModel
            let implementationPlan = plan
            let result = try await background { try agent.implement(worktreePath: path, pullRequest: pullRequest, plan: implementationPlan, model: model) }
            let changedFiles = try await background { try self.workspaces.changedFiles(at: path) }
            let cardChangedFiles = changedFiles.filter { !baselineFiles.contains($0) }
            diffStats[worktreeKey(pullRequest)] = (try? await background { try self.workspaces.changes(at: path) }) ?? ""
            let summary = result.isEmpty ? "에이전트 구현이 종료되었습니다. 변경 사항과 테스트 결과를 확인하세요." : result
            updateImplementationResult(for: card, pullRequest: pullRequest, status: .completed, result: summary, changedFiles: cardChangedFiles)
            statusMessage = "에이전트 구현이 완료되었습니다. 변경 사항을 검토하고 테스트하세요."
        } catch {
            let message = "에이전트 구현 실패: \(error.localizedDescription)"
            updateImplementationResult(for: card, pullRequest: pullRequest, status: .failed, result: message)
            statusMessage = message
        }
    }

    private func updateImplementationResult(for card: AgentReviewCard, pullRequest: PullRequest, status: ImplementationWorkStatus, result: String, changedFiles: [String]? = nil) {
        let key = implementationPlanKey(for: card, pullRequest: pullRequest)
        guard var plan = implementationPlans[key] else { return }
        plan.status = status
        plan.result = result
        plan.completedAt = .now
        if let changedFiles { plan.changedFiles = changedFiles }
        implementationPlans[key] = plan
        persist()
    }

    /// Non-card actions must never silently replace another PR's checkout.
    /// Card analysis is the only path that can ask for an explicit switch.
    private func reserveActiveWorkspace(for pullRequest: PullRequest) -> Bool {
        let key = worktreeKey(pullRequest)
        if let activeKey = activePullRequestKeys[pullRequest.repository], activeKey != key {
            statusMessage = "이 저장소에는 다른 활성 PR이 있습니다. 대기 중인 분석 카드를 선택해 전환을 승인하세요."
            return false
        }
        if activePullRequestKeys[pullRequest.repository] == nil {
            activePullRequestKeys[pullRequest.repository] = key
            worktreePaths[key] = nil
        }
        return true
    }

    /// Agent and implementation work run outside the app process. If the app
    /// is restarted, their old in-progress labels cannot be treated as live.
    private func recoverInterruptedWork() {
        var changed = false
        for index in agentReviewCards.indices where agentReviewCards[index].status == .reviewing {
            agentReviewCards[index].status = .failed
            agentReviewCards[index].updatedAt = .now
            changed = true
        }
        for key in implementationPlans.keys {
            guard var plan = implementationPlans[key], plan.status == .inProgress else { continue }
            plan.status = .failed
            plan.result = "앱이 다시 시작되어 이전 구현의 완료 여부를 확인할 수 없습니다. 변경 사항과 테스트 결과를 확인한 뒤 다시 진행하세요."
            plan.completedAt = .now
            implementationPlans[key] = plan
            changed = true
        }
        if changed { persist() }
    }

    /// Opens only a repository-relative location. This keeps agent-generated
    /// links from launching arbitrary local paths.
    func openInCursor(path relativePath: String, line: Int?, column: Int? = nil, for pullRequest: PullRequest) -> String {
        do {
            guard !relativePath.isEmpty, !relativePath.hasPrefix("/"), !relativePath.split(separator: "/").contains("..") else {
                throw CommandError.failed(.init(output: "", error: "저장소 밖의 경로는 열 수 없습니다.", status: 1))
            }
            let repository = try registeredRepository(for: pullRequest)
            let root = worktreePath(for: pullRequest) ?? repository.localPath
            let rootURL = URL(fileURLWithPath: root).standardizedFileURL
            let fileURL = rootURL.appendingPathComponent(relativePath).standardizedFileURL
            guard fileURL.path.hasPrefix(rootURL.path + "/"), FileManager.default.fileExists(atPath: fileURL.path) else {
                throw CommandError.failed(.init(output: "", error: "등록된 저장소에서 파일을 찾을 수 없습니다: \(relativePath)", status: 1))
            }
            var arguments = ["--reuse-window"]
            if let line, line > 0 {
                let suffix = column.map { ":\($0)" } ?? ""
                arguments += ["--goto", "\(fileURL.path):\(line)\(suffix)"]
            } else {
                arguments.append(fileURL.path)
            }
            try ProcessRunner().launch("cursor", arguments: arguments, workingDirectory: root)
            return "Cursor에서 \(relativePath)\(line.map { ": \($0)번째 줄" } ?? "")을 열었습니다"
        } catch {
            return "Cursor에서 열지 못했습니다: \(error.localizedDescription)"
        }
    }

    func beginAgentReview(id: AgentReviewCard.ID, pullRequest: PullRequest, allowsRetry: Bool = false) async {
        guard let index = agentReviewCards.firstIndex(where: { $0.id == id }) else { return }
        let isLocalPractice = repositories.first(where: { $0.fullName == pullRequest.repository })?.isLocalPractice == true
        guard agentReviewCards[index].status != .reviewing,
              agentReviewCards[index].messages.isEmpty || isLocalPractice || allowsRetry else { return }
        if !isLocalPractice {
            let targetKey = worktreeKey(pullRequest)
            if let activeKey = activePullRequestKeys[pullRequest.repository], activeKey != targetKey {
                if agentReviewCards.contains(where: { $0.repository == pullRequest.repository && $0.pullRequestNumber != pullRequest.number && $0.status == .reviewing }) {
                    agentReviewCards[index].status = .queued
                    agentReviewCards[index].updatedAt = .now
                    statusMessage = "현재 활성 PR의 분석이 끝난 뒤 이 리뷰를 전환할 수 있습니다."
                    persist()
                    return
                }
                agentReviewCards[index].status = .queued
                agentReviewCards[index].updatedAt = .now
                workspaceSwitchRequest = WorkspaceSwitchRequest(
                    cardID: id,
                    target: pullRequest,
                    active: allPullRequests.first { worktreeKey($0) == activeKey }
                )
                persist()
                return
            }
            if activePullRequestKeys[pullRequest.repository] == nil {
                worktreePaths[targetKey] = nil
            }
            activePullRequestKeys[pullRequest.repository] = targetKey
            if worktreePaths[targetKey] == nil {
                if preparingWorkspaceKeys.contains(targetKey) {
                    agentReviewCards[index].status = .queued
                    agentReviewCards[index].updatedAt = .now
                    persist()
                    return
                }
                preparingWorkspaceKeys.insert(targetKey)
                do {
                    let repository = try registeredRepository(for: pullRequest)
                    let path = try await background { try self.workspaces.prepareRepositoryWorkspace(repository: repository, pullRequest: pullRequest) }
                    try await background { try self.workspaces.verifyHead(path, expectedSHA: pullRequest.headSHA, expectedBranch: pullRequest.headBranch) }
                    setActiveWorkspace(path, for: pullRequest)
                } catch {
                    agentReviewCards[index].status = .failed
                    agentReviewCards[index].messages.append(.init(role: .agent, body: "작업 폴더 준비 실패: \(error.localizedDescription)"))
                    agentReviewCards[index].updatedAt = .now
                    preparingWorkspaceKeys.remove(targetKey)
                    persist()
                    return
                }
                preparingWorkspaceKeys.remove(targetKey)
                let waiting = agentCards(for: pullRequest).filter { $0.status == .queued }.map(\.id)
                for waitingID in waiting where waitingID != id {
                    Task { await self.beginAgentReview(id: waitingID, pullRequest: pullRequest) }
                }
            }
        }
        let starter = "선택한 리뷰 섹션을 코드와 대조해 수용 여부와 대응 계획을 알려줘. 원문 리뷰를 반복하지 말고, 수정할 파일·클래스·메서드와 검증 계획 중심으로 설명해줘."
        await sendAgentMessage(id: id, pullRequest: pullRequest, message: starter, hidesUserMessage: true)
    }

    /// Keeps the prior conversation visible, but starts a fresh read-only
    /// analysis attempt after an unavailable or failed agent response.
    func retryAgentReview(id: AgentReviewCard.ID, pullRequest: PullRequest) async {
        guard let card = agentCard(id: id), card.status != .reviewing, card.status != .queued else { return }
        statusMessage = "\(card.title) 검토를 다시 시작합니다."
        await beginAgentReview(id: id, pullRequest: pullRequest, allowsRetry: true)
    }

    /// Creates an editable GitHub reply draft from the selected review and the
    /// agent's existing judgment. It deliberately does not prepare or switch
    /// a workspace: writing a reply must not cause a checkout.
    static func defaultReviewResponseDraft(for card: AgentReviewCard) -> String {
        let section = ReviewCommentSection.displayLabel(for: card.sectionTitle) ?? card.title
        let agentResponse = card.messages.last(where: { $0.role == .agent })?.body
        let agentJudgment = agentResponse.map { conciseReviewJudgment(from: $0) }
        let evidence = agentResponse.flatMap { reviewEvidence(from: $0) }
        let judgmentLine = agentJudgment.map { "- 검토 판단: \($0)" }
            ?? "- 검토 판단: 현재 구현과 리뷰 지적의 관계를 확인했습니다."
        let evidenceLine = evidence.map { "- 판단 근거: \(ReviewResponseReferenceFormatter.format($0))" }
            ?? "- 판단 근거: 리뷰에서 언급한 동작과 현재 구현 경로를 대조해 추가 확인이 필요합니다."
        return """
        \(section) 관련 의견을 확인했습니다.

        \(judgmentLine)
        \(evidenceLine)
        - 대응 방향: 위 코드 확인 결과를 기준으로 변경 필요 여부를 판단하겠습니다.
        - 추가로 확인할 재현 조건이나 기대 동작이 있다면 공유 부탁드립니다.
        """
    }

    func generateReviewResponseDraft(id: AgentReviewCard.ID, pullRequest: PullRequest) async -> String? {
        guard let card = agentCard(id: id) else { return nil }
        let fallback = Self.defaultReviewResponseDraft(for: card)
        guard let analysis = card.messages.last(where: { $0.role == .agent })?.body,
              !analysis.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            statusMessage = "에이전트 검토 결과가 없어 기본 응답 초안을 만들었습니다. 내용을 편집해 게시할 수 있습니다."
            return fallback
        }
        let key = worktreeKey(pullRequest)
        guard let path = worktreePaths[key] else {
            statusMessage = "검토 작업 폴더가 없어 기본 응답 초안을 유지합니다. 새 체크아웃은 시작하지 않습니다."
            return fallback
        }
        do {
            let agent = cursor
            let model = effectiveAgentModel
            let draft = try await background {
                try agent.suggestReviewResponse(
                    repositoryPath: path,
                    pullRequest: pullRequest,
                    card: card,
                    analysis: analysis,
                    model: model
                )
            }
            guard !draft.isEmpty else {
                statusMessage = "에이전트가 응답 초안을 만들지 못해 기본 초안을 유지합니다."
                return fallback
            }
            statusMessage = "GitHub 응답 초안을 만들었습니다. 편집 후 게시하세요."
            return ReviewResponseReferenceFormatter.format(draft)
        } catch {
            statusMessage = "응답 초안 생성에 실패해 기본 초안을 유지합니다: \(error.localizedDescription)"
            return fallback
        }
    }

    private static func conciseReviewJudgment(from text: String) -> String {
        if let judgment = reviewResponseSection(named: "판단", in: text) {
            return judgment
                .replacingOccurrences(of: "**", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return "현재 구현과 리뷰 지적의 관계를 확인했습니다." }
        let firstLine = normalized.split(whereSeparator: { $0.isNewline }).first.map(String.init) ?? normalized
        let cleaned = firstLine
            .replacingOccurrences(of: "#", with: "")
            .replacingOccurrences(of: "-", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String((cleaned.isEmpty ? normalized : cleaned).prefix(180))
    }

    private static func reviewEvidence(from text: String) -> String? {
        ["코드 확인", "핵심 근거", "근거", "분석 내용", "확인할 파일"]
            .lazy
            .compactMap { reviewResponseSection(named: $0, in: text) }
            .first
    }

    private static func reviewResponseSection(named name: String, in text: String) -> String? {
        let lines = text.components(separatedBy: .newlines)
        var collecting = false
        var content: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("#") {
                if collecting { break }
                let heading = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
                collecting = heading == name || heading.hasPrefix("\(name):")
                if collecting, let colon = heading.firstIndex(of: ":") {
                    let inlineContent = heading[heading.index(after: colon)...]
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !inlineContent.isEmpty { content.append(inlineContent) }
                }
                continue
            }
            guard collecting, !trimmed.isEmpty else { continue }
            content.append(trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "-• ")))
        }
        guard !content.isEmpty else { return nil }
        return String(content.joined(separator: " ").prefix(520))
    }

    /// Posts only the user-edited text. It does not push, request re-review,
    /// or change the current branch.
    func postReviewResponse(for cardID: AgentReviewCard.ID, pullRequest: PullRequest, body: String) async -> Bool {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            statusMessage = "게시할 응답을 입력하세요."
            return false
        }
        guard let repository = repositories.first(where: { $0.fullName == pullRequest.repository }) else {
            statusMessage = "등록된 저장소를 찾을 수 없습니다."
            return false
        }
        if repository.isLocalPractice == true {
            statusMessage = "로컬 연습 PR에서는 GitHub 코멘트를 게시하지 않습니다."
            return false
        }
        do {
            try await background {
                try self.github.addComment(repository: pullRequest.repository, number: pullRequest.number, body: trimmed)
            }
            if let index = agentReviewCards.firstIndex(where: { $0.id == cardID }) {
                agentReviewCards[index].reviewResponsePostedAt = .now
                agentReviewCards[index].updatedAt = .now
                persist()
            }
            statusMessage = "GitHub PR 코멘트를 등록했습니다."
            await refresh()
            return true
        } catch {
            statusMessage = "GitHub PR 코멘트 등록 실패: \(error.localizedDescription)"
            return false
        }
    }

    func sendAgentMessage(id: AgentReviewCard.ID, pullRequest: PullRequest, message: String, hidesUserMessage: Bool = false, recordsUserMessage: Bool = true) async {
        let question = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, let index = agentReviewCards.firstIndex(where: { $0.id == id }) else { return }
        guard let repository = repositories.first(where: { $0.fullName == pullRequest.repository }) else { return }
        if !hidesUserMessage, recordsUserMessage { agentReviewCards[index].messages.append(.init(role: .user, body: question)) }
        if repository.isLocalPractice == true {
            agentReviewCards[index].messages.append(.init(role: .agent, body: "로컬 연습 PR이므로 실제 에이전트 검토는 실행하지 않았습니다. 이 항목에서는 GitHub와 Cursor에 요청하지 않으며, 체크아웃·수정·테스트·로컬 커밋 흐름만 확인할 수 있습니다."))
            agentReviewCards[index].status = .complete
            agentReviewCards[index].updatedAt = .now
            statusMessage = "로컬 연습 PR의 에이전트 검토를 안전하게 생략했습니다."
            persist()
            return
        }
        agentReviewCards[index].status = .reviewing
        agentReviewCards[index].updatedAt = .now
        let card = agentReviewCards[index]
        persist()
        let agent = cursor
        do {
            let key = worktreeKey(pullRequest)
            let path: String
            if activePullRequestKeys[pullRequest.repository] == key, let activePath = worktreePaths[key] {
                try await background { try self.workspaces.verifyHead(activePath, expectedSHA: pullRequest.headSHA, expectedBranch: pullRequest.headBranch) }
                path = activePath
            } else {
                path = try await background { try self.workspaces.prepareRepositoryWorkspace(repository: repository, pullRequest: pullRequest) }
                try await background { try self.workspaces.verifyHead(path, expectedSHA: pullRequest.headSHA, expectedBranch: pullRequest.headBranch) }
                setActiveWorkspace(path, for: pullRequest)
            }
            let isTrusted = trustedAgentReviewIDs.contains(id)
            let model = effectiveAgentModel
            let answer = try await background { try agent.ask(repositoryPath: path, pullRequest: pullRequest, card: card, question: question, trustWorkspace: isTrusted, model: model) }
            guard let updatedIndex = agentReviewCards.firstIndex(where: { $0.id == id }) else { return }
            agentReviewCards[updatedIndex].messages.append(.init(role: .agent, body: answer))
            agentReviewCards[updatedIndex].status = .complete
            agentReviewCards[updatedIndex].updatedAt = .now
            persist()
        } catch {
            guard let updatedIndex = agentReviewCards.firstIndex(where: { $0.id == id }) else { return }
            if let permissionKind = permissionKind(for: error.localizedDescription) {
                agentReviewCards[updatedIndex].status = permissionKind == .workspaceTrust ? .workspaceTrustRequired : .permissionRequired
                agentReviewCards[updatedIndex].updatedAt = .now
                agentPermissionRequest = AgentPermissionRequest(kind: permissionKind, cardID: id, pullRequest: pullRequest, question: question, hidesUserMessage: hidesUserMessage, detail: error.localizedDescription)
                persist()
                return
            }
            agentReviewCards[updatedIndex].messages.append(.init(role: .agent, body: "에이전트 응답을 가져오지 못했습니다. \(error.localizedDescription)"))
            agentReviewCards[updatedIndex].status = .failed
            agentReviewCards[updatedIndex].updatedAt = .now
            persist()
        }
    }

    func approveAgentPermission() {
        guard let request = agentPermissionRequest else { return }
        agentPermissionRequest = nil
        switch request.kind {
        case .workspaceTrust:
            trustedAgentReviewIDs.insert(request.cardID)
            Task {
                await sendAgentMessage(id: request.cardID, pullRequest: request.pullRequest, message: request.question, hidesUserMessage: request.hidesUserMessage, recordsUserMessage: false)
            }
        case .cursorLogin:
            startCursorLogin()
        case .other:
            if let index = agentReviewCards.firstIndex(where: { $0.id == request.cardID }) {
                agentReviewCards[index].messages.append(.init(role: .agent, body: "Cursor가 추가 권한을 요청했습니다. Cursor에서 권한을 승인한 뒤 검토 카드를 다시 선택해 재시도하세요.\n\n\(request.detail)"))
                agentReviewCards[index].status = .failed
                agentReviewCards[index].updatedAt = .now
                persist()
            }
        }
    }

    func cancelAgentPermission() {
        guard let request = agentPermissionRequest else { return }
        agentPermissionRequest = nil
        if let index = agentReviewCards.firstIndex(where: { $0.id == request.cardID }) {
            agentReviewCards[index].status = .failed
            agentReviewCards[index].messages.append(.init(role: .agent, body: "요청된 권한이 승인되지 않아 에이전트 검토를 시작하지 않았습니다."))
            agentReviewCards[index].updatedAt = .now
            persist()
        }
    }

    private func permissionKind(for message: String) -> AgentPermissionRequest.Kind? {
        let normalized = message.lowercased()
        if normalized.contains("workspace trust") { return .workspaceTrust }
        if normalized.contains("not logged in") || normalized.contains("login required") || normalized.contains("authentication required") { return .cursorLogin }
        if normalized.contains("permission") || normalized.contains("approval required") || normalized.contains("access denied") || normalized.contains("authorization required") { return .other }
        return nil
    }

    var effectiveAgentModel: String {
        let custom = customAgentModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return custom.isEmpty ? agentModel : custom
    }

    func worktreePath(for pr: PullRequest) -> String? { worktreePaths[worktreeKey(pr)] }
    func analysis(for pr: PullRequest) -> AgentAnalysis? { analyses[worktreeKey(pr)] }
    func comments(for pr: PullRequest) -> [ReviewComment] { comments[worktreeKey(pr)] ?? [] }
    func diffStat(for pr: PullRequest) -> String? { diffStats[worktreeKey(pr)] }
    func refresh() { Task { await refresh() } }

    static func reReviewWorkSections(from cards: [AgentReviewCard]) -> [String] {
        cards
            .filter { $0.reviewResponsePostedAt == nil }
            .compactMap { card -> String? in
                guard let answer = card.messages.last(where: { $0.role == .agent })?.body else { return nil }
                let level = card.sectionTitle ?? "일반 코멘트"
                let comment = card.sectionBody ?? card.commentBody
                return """
                ## \(level)

                ### 리뷰 코멘트
                \(comment)

                ### 작업 내용
                \(answer)
                """
            }
    }

    func refreshNotificationStatus() async {
        notificationStatus = await notifications.authorizationSummary()
    }

    func requestNotificationPermission() async {
        notificationStatus = await notifications.requestAuthorization()
    }

    func sendTestNotification() async {
        publishPetNotification(.notificationTest)
        notificationStatus = await notifications.deliverTestNotification()
        statusMessage = notificationStatus
        persist()
    }

    var appVersion: AppVersion {
        AppVersion(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.2.2")
    }

    var appVersionDescription: String { appVersion.displayString }

    var updateRepositoryIsValid: Bool { normalizedUpdateRepository != nil }
    var hasAvailableAppUpdate: Bool {
        guard let latestAppRelease else { return false }
        return appVersion < AppVersion(latestAppRelease.tagName)
    }

    func checkForAppUpdate(reportNoUpdate: Bool = true, presentsResultAlert: Bool = false) async {
        guard !isCheckingForAppUpdate else { return }
        guard let repository = normalizedUpdateRepository else {
            if reportNoUpdate { appUpdateStatus = "업데이트 배포 저장소를 찾을 수 없습니다." }
            if presentsResultAlert { presentAppUpdateResultAlert() }
            return
        }
        isCheckingForAppUpdate = true
        defer {
            isCheckingForAppUpdate = false
            if presentsResultAlert { presentAppUpdateResultAlert() }
        }
        do {
            let release = try await background { try self.github.latestRelease(repository: repository) }
            let releaseVersion = AppVersion(release.tagName)
            guard releaseVersion.isValid else {
                appUpdateStatus = "GitHub Release 버전 정보를 확인할 수 없습니다."
                return
            }
            latestAppRelease = release
            if releaseVersion > appVersion {
                appUpdateStatus = "새 버전 \(releaseVersion.displayString)이 있습니다."
                if lastNotifiedUpdateTag != release.tagName {
                    publishPetNotification(.appUpdate(version: releaseVersion.displayString))
                    notificationStatus = await notifications.deliverAppUpdate(version: releaseVersion.displayString)
                    lastNotifiedUpdateTag = release.tagName
                    persist()
                }
            } else {
                appUpdateStatus = "최신버전입니다."
            }
        } catch {
            if reportNoUpdate { appUpdateStatus = "업데이트 확인 실패: \(error.localizedDescription)" }
        }
    }

    func openLatestAppRelease() {
        guard let release = latestAppRelease, let url = URL(string: release.htmlURL) else {
            statusMessage = "먼저 업데이트를 확인하세요."
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func presentAppUpdateResultAlert() {
        let alert = NSAlert()
        if hasAvailableAppUpdate, let release = latestAppRelease {
            alert.messageText = "업데이트가 있습니다"
            alert.informativeText = "PR Review Assistant \(release.tagName) 버전을 설치할 수 있습니다. 업데이트 페이지로 이동할까요?"
            alert.addButton(withTitle: "업데이트 진행")
            alert.addButton(withTitle: "나중에")
            if alert.runModal() == .alertFirstButtonReturn {
                openLatestAppRelease()
            }
        } else if appUpdateStatus == "최신버전입니다." {
            alert.messageText = "최신버전입니다."
            alert.informativeText = "현재 설치된 PR Review Assistant가 최신 버전입니다."
            alert.addButton(withTitle: "확인")
            alert.runModal()
        } else {
            alert.messageText = "업데이트 확인 실패"
            alert.informativeText = appUpdateStatus.isEmpty ? "업데이트 정보를 확인할 수 없습니다." : appUpdateStatus
            alert.addButton(withTitle: "확인")
            alert.runModal()
        }
    }

    func isUnread(_ pullRequest: PullRequest) -> Bool {
        let key = worktreeKey(pullRequest)
        return unreadPullRequestIDs.contains(key) || comments[worktreeKey(pullRequest), default: []].contains { unreadCommentIDs.contains($0.id) }
    }

    var authorFilterDescription: String {
        let author = reviewAuthorFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        return author.isEmpty ? "모든 작성자의 PR을 표시합니다." : "\(author) 작성자의 PR만 Inbox에 표시합니다."
    }

    func isUnread(_ comment: ReviewComment) -> Bool { unreadCommentIDs.contains(comment.id) }

    func markPullRequestRead(_ pullRequest: PullRequest) {
        let key = worktreeKey(pullRequest)
        unreadPullRequestIDs.remove(key)
        // A PR detail includes its review summary, so opening it acknowledges
        // every pending notification associated with that PR as well.
        unreadCommentIDs.subtract(comments[key, default: []].map(\.id))
        persist()
    }

    func markCommentsRead(for pullRequest: PullRequest) {
        markPullRequestRead(pullRequest)
    }

    private func restartMonitoring() {
        monitoringTask?.cancel()
        guard monitoringEnabled else { return }
        let interval = UInt64(max(monitoringInterval, 30)) * 1_000_000_000
        monitoringTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                guard !Task.isCancelled, let self else { return }
                await self.refresh()
            }
        }
    }

    private func restartUpdateChecks() {
        updateCheckTask?.cancel()
        guard updatesEnabled, normalizedUpdateRepository != nil else { return }
        updateCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                let interval = max(UpdateCheckSchedule.nextDate(after: .now).timeIntervalSinceNow, 0)
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                await self.checkForAppUpdate(reportNoUpdate: false)
            }
        }
    }

    private func registeredRepository(for pr: PullRequest) throws -> RegisteredRepository {
        guard let repository = repositories.first(where: { $0.fullName == pr.repository }) else { throw CommandError.failed(.init(output: "", error: "등록된 로컬 저장소가 없습니다.", status: 1)) }
        return repository
    }
    private func setActiveWorkspace(_ path: String, for pr: PullRequest) {
        let repositoryPrefix = "\(pr.repository)#"
        worktreePaths = worktreePaths.filter { !$0.key.hasPrefix(repositoryPrefix) }
        worktreePaths[worktreeKey(pr)] = path
    }
    private func updateStatus(_ status: AnalysisStatus, for id: PullRequest.ID) { if let index = pullRequests.firstIndex(where: { $0.id == id }) { pullRequests[index].analysisStatus = status } }
    private func publishPetNotification(_ content: PetBubbleContent) {
        latestPetNotification = content
        petNotificationEventID = UUID()
    }
    private func worktreeKey(_ pr: PullRequest) -> String { "\(pr.repository)#\(pr.number)" }
    private func implementationPlanKey(for card: AgentReviewCard, pullRequest: PullRequest) -> String {
        implementationPlanKey(repository: pullRequest.repository, pullRequestNumber: pullRequest.number, card: card)
    }
    private func implementationPlanKey(repository: String, pullRequestNumber: Int, card: AgentReviewCard) -> String {
        "\(repository)#\(pullRequestNumber)#\(card.reviewID ?? card.id.uuidString)"
    }
    private func migrateImplementationPlansToWorkCards() {
        var migrated = implementationPlans
        for (key, plan) in implementationPlans where key == "\(plan.repository)#\(plan.pullRequestNumber)" {
            guard let card = plan.sourceReviewIDs?.compactMap(agentCard(reviewID:)).first
                ?? plan.sourceCardIDs.compactMap(agentCard(id:)).first else { continue }
            migrated[implementationPlanKey(repository: plan.repository, pullRequestNumber: plan.pullRequestNumber, card: card)] = plan
            migrated[key] = nil
        }
        implementationPlans = migrated
    }
    private func applyAuthorFilter() {
        pullRequests = allPullRequests.filter(matchesAuthorFilter)
        if selectedID == nil || !pullRequests.contains(where: { $0.id == selectedID }) {
            selectedID = pullRequests.first?.id
        }
    }
    private func matchesAuthorFilter(_ pullRequest: PullRequest) -> Bool {
        pullRequest.repository == LocalPracticeRepository.fullName || matchesAuthorFilter(pullRequest.author)
    }
    private func matchesAuthorFilter(_ author: String?) -> Bool {
        let filter = reviewAuthorFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !filter.isEmpty, let author else { return true }
        return author.compare(filter, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }
    private var normalizedUpdateRepository: String? {
        let value = updateRepository.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = value.split(separator: "/")
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && !$0.contains(" ") }) else { return nil }
        return value
    }
    private func persist() { persistence.save(.init(repositories: repositories, processedCommentIDs: processedCommentIDs, knownPullRequestIDs: knownPullRequestIDs, unreadPullRequestIDs: unreadPullRequestIDs, unreadCommentIDs: unreadCommentIDs, hasEstablishedNotificationBaseline: hasEstablishedNotificationBaseline, approvedPullRequestIDs: approvedPullRequestIDs, hasEstablishedApprovalBaseline: hasEstablishedApprovalBaseline, monitoringEnabled: monitoringEnabled, monitoringInterval: monitoringInterval, analyses: analyses, agentReviewCards: agentReviewCards, implementationPlans: implementationPlans, committedHeads: committedHeads, postedReReviewCommentTokens: postedReReviewCommentTokens, agentModel: agentModel, customAgentModel: customAgentModel, reviewAuthorFilter: reviewAuthorFilter, petVisible: petVisible, petSize: petSize, petReduceMotion: petReduceMotion, latestPetNotification: latestPetNotification, hasCompletedOnboarding: hasCompletedOnboarding, skippedOnboardingSteps: skippedOnboardingSteps, projectCopyFolder: projectCopyFolder, updateRepository: updateRepository, updatesEnabled: updatesEnabled, lastNotifiedUpdateTag: lastNotifiedUpdateTag, requestedBranches: requestedBranches, cursorSpecSidebarCache: cursorSpecSidebarCache, automaticCursorSessionClassification: automaticCursorSessionClassification)) }
    private func background<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T { try await Task.detached(priority: .userInitiated, operation: work).value }
}
