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
    var testResults: [String: String] = [:]
    var testSucceeded: Set<String> = []
    var diffStats: [String: String] = [:]
    var committedHeads: [String: String] = [:]
    var cursorConnection = CursorConnection(state: .unknown, detail: "연결 상태를 확인하세요.")
    var isCheckingCursorConnection = false
    var agentReviewCards: [AgentReviewCard] = []
    var implementationPlans: [String: ImplementationPlan] = [:]
    var agentPermissionRequest: AgentPermissionRequest?
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

    private let persistence = AppPersistence()
    private let github = GitHubClient()
    private let workspaces = WorkspaceManager()
    private let localPractice = LocalPracticeRepository()
    private let cursor = CursorAgent()
    private let notifications = NotificationService()
    private var processedCommentIDs: Set<String> = []
    private var trustedAgentReviewIDs: Set<AgentReviewCard.ID> = []
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
        recoverInterruptedWork()
        Task { await startup() }
    }

    var selectedPullRequest: PullRequest? { pullRequests.first { $0.id == selectedID } }
    var unreadCount: Int { pullRequests.filter(isUnread(_:)).count }
    var canCommit: Bool { selectedPullRequest != nil && worktreePaths[worktreeKey(selectedPullRequest!)] != nil }
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
            startAutomaticReviews(for: fixture.pullRequest, comments: fixture.comments)
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
                    startAutomaticReviews(for: fixture.pullRequest, comments: fixture.comments)
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
                    // as soon as it is received, then begin read-only analysis.
                    // Existing cards are never recreated on a later poll.
                    startAutomaticReviews(for: pr, comments: newComments)
                    let shouldNotify = hasEstablishedNotificationBaseline && matchesAuthorFilter(pr)
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

    func runTests(for pullRequest: PullRequest, command: String) async {
        guard let path = worktreePaths[worktreeKey(pullRequest)], !command.isEmpty else { statusMessage = "먼저 분석을 실행하고 테스트 명령을 입력하세요."; return }
        let key = worktreeKey(pullRequest)
        do {
            let workspace = workspaces
            let result = try await background { try workspace.test(at: path, command: command) }
            testResults[key] = result.output
            diffStats[key] = (try? await background { try workspace.changes(at: path) }) ?? ""
            testSucceeded.insert(key)
            committedHeads[key] = nil
            persist()
            statusMessage = "테스트가 성공했습니다. 변경 내용을 검토하세요."
        } catch {
            testResults[key] = error.localizedDescription
            testSucceeded.remove(key)
            statusMessage = "테스트가 실패했습니다."
        }
    }

    func commitApprovedChanges(for pullRequest: PullRequest, message: String) async {
        let key = worktreeKey(pullRequest)
        guard let path = worktreePaths[key] else { statusMessage = "검증된 PR 작업 폴더가 없습니다."; return }
        guard testSucceeded.contains(key) else { statusMessage = "커밋 전 최신 변경에 대해 성공한 테스트가 필요합니다."; return }
        do {
            let workspace = workspaces
            let committedSHA = try await background {
                try workspace.commit(at: path, message: message, branch: pullRequest.headBranch, expectedSHA: pullRequest.headSHA)
            }
            committedHeads[key] = committedSHA
            persist()
            statusMessage = "로컬 커밋이 완료되었습니다. 추천 메시지를 만든 뒤 재리뷰를 요청하세요."
            updateImplementationResult(for: pullRequest, status: .completed, result: "로컬 커밋이 완료되었습니다. 푸시는 재리뷰 요청 시 진행합니다.")
        } catch {
            let result = "커밋에 실패했습니다: \(error.localizedDescription)"
            statusMessage = "커밋 실패: \(error.localizedDescription)"
            updateImplementationResult(for: pullRequest, status: .failed, result: result)
        }
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

        let cards = agentCards(for: pullRequest)
        let completedCardResults = cards.compactMap { card -> String? in
            guard let answer = card.messages.last(where: { $0.role == .agent })?.body else { return nil }
            return """
            [코멘트별 에이전트 검토: \(card.sectionTitle ?? card.title)]
            \(answer)
            """
        }
        var sections: [String] = []
        if let analysis = analyses[key] {
            sections.append("[전체 에이전트 분석]\n\(analysis.rawOutput)")
        }
        sections.append(contentsOf: completedCardResults)
        if let diff = diffStats[key] {
            sections.append("[변경 요약]\n\(diff.isEmpty ? "기록된 변경 파일 없음" : diff)")
        }
        if let test = testResults[key] {
            let testStatus = testSucceeded.contains(key) ? "성공" : "실패"
            sections.append("[테스트 \(testStatus)]\n\(test.isEmpty ? "추가 출력 없음" : test)")
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
        guard pullRequest.reviewer != "리뷰 대기" else { statusMessage = "재리뷰를 요청할 리뷰어가 없습니다."; return }
        let key = worktreeKey(pullRequest)
        guard let path = worktreePaths[key], let committedSHA = committedHeads[key] else {
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

            try await background {
                try self.github.requestReview(repository: pullRequest.repository, number: pullRequest.number, reviewers: [pullRequest.reviewer])
            }
            committedHeads[key] = nil
            postedReReviewCommentTokens.remove(commentToken)
            persist()
            statusMessage = "푸시와 PR 코멘트 등록을 완료하고 \(pullRequest.reviewer)에게 재리뷰를 요청했습니다."
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
        if let existing = agentReviewCards.first(where: {
            $0.repository == pullRequest.repository &&
            $0.pullRequestNumber == pullRequest.number &&
            $0.commentID == comment.id &&
            $0.sectionID == section.id
        }) {
            return existing.id
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
            .sorted { $0.updatedAt > $1.updatedAt }
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
                }
            }
        }
        return created
    }

    /// Both GitHub PRs and the local practice fixture enter the same
    /// section-card flow. Local practice completes with its safe simulated
    /// review response; GitHub PRs use the normal read-only Cursor analysis.
    private func startAutomaticReviews(for pullRequest: PullRequest, comments: [ReviewComment]) {
        let cardIDs = createAnalysisCards(for: pullRequest, comments: comments)
        guard !cardIDs.isEmpty else { return }
        let key = worktreeKey(pullRequest)
        if let activeKey = activePullRequestKeys[pullRequest.repository], activeKey != key {
            setCards(cardIDs, status: .queued)
            statusMessage = "(pullRequest.repository)의 활성 PR 분석이 끝날 때까지 새 리뷰를 분석 대기열에 넣었습니다."
            return
        }
        if activePullRequestKeys[pullRequest.repository] == nil {
            // A persisted historical path is not proof that this branch is
            // still checked out after an app relaunch. Prepare it once again.
            worktreePaths[key] = nil
        }
        activePullRequestKeys[pullRequest.repository] = key
        for cardID in cardIDs {
            Task { await self.beginAgentReview(id: cardID, pullRequest: pullRequest) }
        }
    }

    private func setCards(_ ids: [AgentReviewCard.ID], status: AgentReviewStatus) {
        for index in agentReviewCards.indices where ids.contains(agentReviewCards[index].id) {
            agentReviewCards[index].status = status
            agentReviewCards[index].updatedAt = .now
        }
        persist()
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

    /// Carries only the review conclusion and its actionable source context,
    /// never the complete conversational transcript, into the work area.
    func createImplementationPlan(for pullRequest: PullRequest) -> ImplementationPlan? {
        let cards = agentCards(for: pullRequest)
        let items = cards.compactMap { card -> String? in
            guard let conclusion = card.messages.last(where: { $0.role == .agent })?.body else { return nil }
            let request = (card.sectionBody ?? card.commentBody).trimmingCharacters(in: .whitespacesAndNewlines)
            return """
            ## \(card.sectionTitle ?? card.title)
            **리뷰 요청:** \(request)

            **에이전트 판단 및 수행 항목:**
            \(conclusion)
            """
        }
        guard !items.isEmpty else { return nil }
        let content = "# PR #\(pullRequest.number) 구현 계획\n\n검토 대화 전체가 아닌, 구현에 필요한 리뷰 요청과 에이전트의 최종 판단만 전달합니다.\n\n\(items.joined(separator: "\n\n---\n\n"))"
        let plan = ImplementationPlan(
            repository: pullRequest.repository,
            pullRequestNumber: pullRequest.number,
            content: content,
            sourceCardIDs: cards.map(\.id),
            sourceReviewIDs: cards.compactMap(\.reviewID)
        )
        implementationPlans[worktreeKey(pullRequest)] = plan
        persist()
        return plan
    }

    func implementationPlan(for pullRequest: PullRequest) -> ImplementationPlan? {
        implementationPlans[worktreeKey(pullRequest)]
    }

    /// Starts a real, user-approved implementation run on the PR source branch.
    /// This never commits or pushes; those remain separate approval steps.
    func startImplementation(for pullRequest: PullRequest) async {
        guard reserveActiveWorkspace(for: pullRequest) else { return }
        let key = worktreeKey(pullRequest)
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
            let agent = cursor
            let model = effectiveAgentModel
            let implementationPlan = plan
            let result = try await background { try agent.implement(worktreePath: path, pullRequest: pullRequest, plan: implementationPlan, model: model) }
            diffStats[key] = (try? await background { try self.workspaces.changes(at: path) }) ?? ""
            let summary = result.isEmpty ? "에이전트 구현이 종료되었습니다. 변경 사항과 테스트 결과를 확인하세요." : result
            updateImplementationResult(for: pullRequest, status: .completed, result: summary)
            statusMessage = "에이전트 구현이 완료되었습니다. 변경 사항을 검토하고 테스트하세요."
        } catch {
            let message = "에이전트 구현 실패: \(error.localizedDescription)"
            updateImplementationResult(for: pullRequest, status: .failed, result: message)
            statusMessage = message
        }
    }

    private func updateImplementationResult(for pullRequest: PullRequest, status: ImplementationWorkStatus, result: String) {
        guard var plan = implementationPlans[worktreeKey(pullRequest)] else { return }
        plan.status = status
        plan.result = result
        plan.completedAt = .now
        implementationPlans[worktreeKey(pullRequest)] = plan
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

    func beginAgentReview(id: AgentReviewCard.ID, pullRequest: PullRequest) async {
        guard let index = agentReviewCards.firstIndex(where: { $0.id == id }) else { return }
        let isLocalPractice = repositories.first(where: { $0.fullName == pullRequest.repository })?.isLocalPractice == true
        guard agentReviewCards[index].status != .reviewing,
              agentReviewCards[index].messages.isEmpty || isLocalPractice else { return }
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
        let starter = "선택한 리뷰 섹션이 현재 PR 코드에 적용되는지 검토하고, 핵심 판단과 확인할 파일을 알려줘."
        await sendAgentMessage(id: id, pullRequest: pullRequest, message: starter, hidesUserMessage: true)
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
    func testResult(for pr: PullRequest) -> String? { testResults[worktreeKey(pr)] }
    func diffStat(for pr: PullRequest) -> String? { diffStats[worktreeKey(pr)] }
    func refresh() { Task { await refresh() } }

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
    private func persist() { persistence.save(.init(repositories: repositories, processedCommentIDs: processedCommentIDs, knownPullRequestIDs: knownPullRequestIDs, unreadPullRequestIDs: unreadPullRequestIDs, unreadCommentIDs: unreadCommentIDs, hasEstablishedNotificationBaseline: hasEstablishedNotificationBaseline, approvedPullRequestIDs: approvedPullRequestIDs, hasEstablishedApprovalBaseline: hasEstablishedApprovalBaseline, monitoringEnabled: monitoringEnabled, monitoringInterval: monitoringInterval, analyses: analyses, agentReviewCards: agentReviewCards, implementationPlans: implementationPlans, committedHeads: committedHeads, postedReReviewCommentTokens: postedReReviewCommentTokens, agentModel: agentModel, customAgentModel: customAgentModel, reviewAuthorFilter: reviewAuthorFilter, petVisible: petVisible, petSize: petSize, petReduceMotion: petReduceMotion, latestPetNotification: latestPetNotification, hasCompletedOnboarding: hasCompletedOnboarding, skippedOnboardingSteps: skippedOnboardingSteps, projectCopyFolder: projectCopyFolder, updateRepository: updateRepository, updatesEnabled: updatesEnabled, lastNotifiedUpdateTag: lastNotifiedUpdateTag)) }
    private func background<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T { try await Task.detached(priority: .userInitiated, operation: work).value }
}
