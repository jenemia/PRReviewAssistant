import SwiftUI

enum AppAppearance: String, CaseIterable, Identifiable {
    case defaultTheme
    case dark

    var id: String { rawValue }
    var title: String { self == .defaultTheme ? "기본" : "다크" }
    var colorScheme: ColorScheme? { self == .dark ? .dark : nil }
}

enum ReviewState: String, CaseIterable, Codable {
    case changesRequested = "변경 요청"
    case commented = "코멘트"
    case approved = "승인"

    var tint: Color {
        switch self {
        case .changesRequested: .red
        case .commented: .orange
        case .approved: .green
        }
    }
}

enum AnalysisStatus: String, Codable {
    case needsAnalysis = "미분석"
    case analyzing = "분석 중"
    case needsChanges = "수정 필요"
    case resolved = "이미 해결됨"

    var tint: Color {
        switch self {
        case .needsAnalysis: .secondary
        case .analyzing: .blue
        case .needsChanges: .orange
        case .resolved: .green
        }
    }
}

enum PetState: Equatable {
    case idle
    case attention
    case working
    case completed

    static func resolve(pullRequests: [PullRequest], unreadCount: Int) -> PetState {
        if pullRequests.contains(where: { $0.analysisStatus == .analyzing }) { return .working }
        if unreadCount > 0 { return .attention }
        if pullRequests.max(by: { $0.updatedAt < $1.updatedAt })?.reviewState == .approved { return .completed }
        return .idle
    }
}

struct PetBubbleContent: Codable, Equatable {
    let title: String
    let subtitle: String
    let body: String
    /// The PR author whose Inbox filter controls whether this event is shown.
    let sourceAuthor: String?

    init(title: String, subtitle: String, body: String, sourceAuthor: String? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.sourceAuthor = sourceAuthor
    }

    static func latest(in pullRequests: [PullRequest]) -> PetBubbleContent {
        guard let pullRequest = pullRequests.max(by: { $0.updatedAt < $1.updatedAt }) else {
            return PetBubbleContent(title: "새로운 PR 또는 리뷰가 없습니다", subtitle: "최근 알림 없음", body: "감시 중인 저장소의 PR을 확인하면 여기에 표시됩니다.")
        }
        return PetBubbleContent(
            title: "최근 PR",
            subtitle: "\(pullRequest.repository) #\(pullRequest.number)",
            body: "\(pullRequest.title) · \(pullRequest.reviewState.rawValue)"
        )
    }

    static func newReview(for pullRequest: PullRequest, count: Int) -> PetBubbleContent {
        PetBubbleContent(title: "새 리뷰가 도착했습니다", subtitle: "\(pullRequest.repository) #\(pullRequest.number)", body: "\(pullRequest.title) · 새 코멘트 \(count)개", sourceAuthor: pullRequest.author)
    }

    static func newPullRequest(_ pullRequest: PullRequest) -> PetBubbleContent {
        PetBubbleContent(title: "새 PR이 열렸습니다", subtitle: "\(pullRequest.repository) #\(pullRequest.number)", body: "\(pullRequest.author) · \(pullRequest.title)", sourceAuthor: pullRequest.author)
    }

    static func approved(_ pullRequest: PullRequest) -> PetBubbleContent {
        PetBubbleContent(title: "PR이 승인되었습니다", subtitle: "\(pullRequest.repository) #\(pullRequest.number)", body: "\(pullRequest.title) · 머지할 수 있습니다", sourceAuthor: pullRequest.author)
    }

    static func appUpdate(version: String) -> PetBubbleContent {
        PetBubbleContent(title: "새 앱 버전이 있습니다", subtitle: "PR Review Assistant \(version)", body: "설정에서 변경 사항을 확인하고 GitHub Release를 열 수 있습니다.")
    }

    static let notificationTest = PetBubbleContent(title: "PR Review Assistant 알림 테스트", subtitle: "알림 테스트", body: "이 배너가 보이면 macOS 로컬 알림이 정상 동작합니다.")
}

struct AppVersion: Comparable, Hashable, Sendable {
    let components: [Int]
    let displayString: String

    init(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        displayString = trimmed
        components = trimmed
            .trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            .split(separator: ".")
            .compactMap { Int($0.prefix { $0.isNumber }) }
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(components)
    }

    var isValid: Bool { !components.isEmpty }
}

enum UpdateCheckSchedule {
    static let timeZone = TimeZone(secondsFromGMT: 9 * 60 * 60)!
    static let hours = [10, 13, 16, 19]

    static func nextDate(after date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let today = calendar.startOfDay(for: date)
        for hour in hours {
            guard let candidate = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: today) else { continue }
            if candidate >= date { return candidate }
        }
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        return calendar.date(bySettingHour: hours[0], minute: 0, second: 0, of: tomorrow)!
    }
}

struct PullRequest: Identifiable, Hashable, Codable {
    var id: UUID
    var repository: String
    var number: Int
    var title: String
    var author: String
    var headBranch: String
    var baseBranch: String
    var headSHA: String
    var reviewer: String
    var commentCount: Int
    var updatedAt: Date
    var reviewState: ReviewState
    var analysisStatus: AnalysisStatus
    var summary: String
    var files: [ChangedFile]

    static let samples: [PullRequest] = [
        PullRequest(id: UUID(), repository: "supercent/mobile-app", number: 142, title: "로그인 오류 처리 개선", author: "minji", headBranch: "feature/login-error-handling", baseBranch: "main", headSHA: "8f3c12a", reviewer: "alex-kim", commentCount: 3, updatedAt: .now.addingTimeInterval(-600), reviewState: .changesRequested, analysisStatus: .needsChanges, summary: "로그인 실패 시 이전 세션이 남을 수 있다는 리뷰가 도착했습니다.", files: [.init(path: "Sources/Auth/LoginService.swift", additions: 12, deletions: 4), .init(path: "Tests/Auth/LoginServiceTests.swift", additions: 26, deletions: 0)]),
        PullRequest(id: UUID(), repository: "supercent/ios-design-system", number: 88, title: "Button 접근성 레이블 추가", author: "david", headBranch: "fix/button-accessibility", baseBranch: "develop", headSHA: "2b6d97e", reviewer: "soyeon", commentCount: 1, updatedAt: .now.addingTimeInterval(-3600), reviewState: .commented, analysisStatus: .needsAnalysis, summary: "VoiceOver 레이블 명명 규칙에 대한 코멘트를 확인하세요.", files: [.init(path: "Sources/Components/PrimaryButton.swift", additions: 8, deletions: 2)]),
        PullRequest(id: UUID(), repository: "supercent/api-gateway", number: 317, title: "결제 webhook 재시도 정책", author: "james", headBranch: "feat/webhook-retry", baseBranch: "main", headSHA: "6e14c0d", reviewer: "hana", commentCount: 2, updatedAt: .now.addingTimeInterval(-86_400), reviewState: .approved, analysisStatus: .resolved, summary: "최신 커밋에서 리뷰 코멘트가 해결되었습니다.", files: [.init(path: "Sources/Webhooks/RetryPolicy.swift", additions: 4, deletions: 1)])
    ]
}

struct ChangedFile: Hashable, Codable {
    var path: String
    var additions: Int
    var deletions: Int
}

struct RegisteredRepository: Identifiable, Hashable, Codable {
    var id = UUID()
    var localPath: String
    var fullName: String
    var remoteName: String = "origin"
    var defaultBranch: String
    var monitoringEnabled = true
    var lastCheckedAt: Date?
    /// A disposable repository generated by the app for an end-to-end local flow.
    /// It has no GitHub remote and must never make GitHub API requests.
    var isLocalPractice: Bool? = false
}

/// A local branch shown in the PR-request flow.  This deliberately contains
/// only local Git metadata: selecting a branch must not check it out.
struct RepositoryBranch: Identifiable, Hashable, Codable {
    var repositoryID: UUID
    var repositoryName: String
    var name: String
    /// Git reference used for read-only inspection.  A PR request still sends
    /// `name` to GitHub, while an origin-only branch is inspected as
    /// `origin/name` locally.
    var reference: String
    var sha: String
    var subject: String
    var updatedAt: Date?
    var isCurrent: Bool
    var isRemote: Bool

    var id: String { "\(repositoryID.uuidString):\(name)" }
}

enum BranchReviewCategory: String, CaseIterable, Codable, Hashable {
    case blocker = "차단"
    case concern = "확인 필요"
    case improvement = "개선"
    case passed = "통과"

    var symbol: String {
        switch self {
        case .blocker: "xmark.octagon.fill"
        case .concern: "exclamationmark.triangle.fill"
        case .improvement: "lightbulb.fill"
        case .passed: "checkmark.seal.fill"
        }
    }

    var tint: Color {
        switch self {
        case .blocker: .red
        case .concern: .orange
        case .improvement: .blue
        case .passed: .green
        }
    }
}

struct BranchReviewCard: Identifiable, Hashable, Codable {
    var id = UUID()
    var category: BranchReviewCategory
    var title: String
    var summary: String
    var details: String
    var messages: [AgentChatMessage] = []
    var updatedAt = Date()
}

struct BranchQuizQuestion: Identifiable, Hashable, Codable {
    var id = UUID()
    var question: String
    var choices: [String]
    var correctIndex: Int
    var explanation: String

    private enum CodingKeys: String, CodingKey { case question, choices, correctIndex, explanation }
    init(question: String, choices: [String], correctIndex: Int, explanation: String) {
        self.question = question
        self.choices = choices
        self.correctIndex = correctIndex
        self.explanation = explanation
    }
}

struct ReviewComment: Identifiable, Hashable, Codable {
    var id: String
    var author: String
    var body: String
    var path: String?
    var line: Int?
    var createdAt: Date
    var kind: ReviewCommentKind
    var reviewState: ReviewState?
    var parentID: String?
    var isResolved = false
    var analysisStatus: AnalysisStatus = .needsAnalysis

    /// A reviewer can place several independent findings in one GitHub comment.
    /// Keep those findings as separate work units so each gets its own agent session.
    var sections: [ReviewCommentSection] {
        ReviewCommentSection.parse(commentID: id, body: body)
    }
}

struct ReviewCommentSection: Identifiable, Hashable {
    let id: String
    let title: String
    let body: String

    static func parse(commentID: String, body: String) -> [ReviewCommentSection] {
        let lines = body.components(separatedBy: .newlines)
        var groups: [(title: String, lines: [String])] = []
        var currentTitle: String?
        var currentLines: [String] = []

        func appendCurrent() {
            let content = currentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard let currentTitle, !content.isEmpty else { return }
            groups.append((currentTitle, content.components(separatedBy: .newlines)))
        }

        for line in lines {
            if let title = severityTitle(in: line) {
                appendCurrent()
                currentTitle = title
                currentLines = []
            } else if let activeTitle = currentTitle,
                      let severityName = severityName(in: activeTitle),
                      let itemNumber = numberedItemNumber(in: line) {
                // A numbered finding beneath one severity heading is its own
                // work unit: `Suggestion (3)` with `1.`, `2.`, `3.` becomes
                // Suggestion-1, Suggestion-2, Suggestion-3. Ordinary Markdown
                // subheadings remain part of their surrounding finding.
                let hasFindingContent = currentLines.contains {
                    !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                if hasFindingContent { appendCurrent() }
                currentTitle = "\(severityName) (\(itemNumber))"
                currentLines = [line]
            } else if currentTitle != nil {
                // Markdown headings inside a severity finding are context, not
                // separate findings. Splitting on every `#` made one Warning
                // review turn into several duplicate analysis cards.
                currentLines.append(line)
            }
        }
        appendCurrent()

        guard !groups.isEmpty else {
            return [ReviewCommentSection(id: "\(commentID)#section-0", title: "전체 코멘트", body: body)]
        }
        return groups.enumerated().map { index, group in
            ReviewCommentSection(id: "\(commentID)#section-\(index)", title: group.title, body: group.lines.joined(separator: "\n"))
        }
    }

    /// Only severity headers create a review work unit. Their source order is
    /// retained (for example Warning, then Suggestion).
    private static func severityTitle(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = "^(?:#{1,6}\\s*)?(?:[🔴🟠🟡🔵⚪]\\s*)?(?:Blocker|Critical|Error|Warning|Suggestion|Info|주의|오류|제안)\\s*\\(\\d+\\)"
        guard trimmed.range(of: pattern, options: .regularExpression) != nil else { return nil }
        return trimmed
    }

    private static func severityName(in title: String) -> String? {
        let pattern = "^(?:#{1,6}\\s*)?(?:[🔴🟠🟡🔵⚪]\\s*)?(Blocker|Critical|Error|Warning|Suggestion|Info|주의|오류|제안)\\s*\\(\\d+\\)"
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(title.startIndex..., in: title)
        guard let match = expression.firstMatch(in: title, range: range),
              let levelRange = Range(match.range(at: 1), in: title) else { return nil }
        return String(title[levelRange])
    }

    private static func numberedItemNumber(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = "^(?:#{1,6}\\s*)?(\\d+)\\s*[.)]\\s+"
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        guard let match = expression.firstMatch(in: trimmed, range: range),
              let numberRange = Range(match.range(at: 1), in: trimmed) else { return nil }
        return String(trimmed[numberRange])
    }

    static func severitySortRank(for title: String?) -> Int {
        let normalized = (title ?? "").lowercased()
        if normalized.contains("blocker") { return 0 }
        if normalized.contains("critical") { return 1 }
        if normalized.contains("error") || normalized.contains("오류") { return 2 }
        if normalized.contains("warning") || normalized.contains("주의") { return 3 }
        if normalized.contains("suggestion") || normalized.contains("제안") { return 4 }
        if normalized.contains("info") { return 5 }
        return 6
    }

    /// Turns a severity heading such as `Suggestion (2)` into the compact
    /// center-list label `Suggestion-2` while retaining the original title
    /// and body for the detail view.
    static func displayLabel(for title: String?) -> String? {
        guard let title else { return nil }
        let pattern = "^(?:#{1,6}\\s*)?(?:[🔴🟠🟡🔵⚪]\\s*)?(Blocker|Critical|Error|Warning|Suggestion|Info|주의|오류|제안)\\s*\\(\\s*(\\d+)\\s*\\)"
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(title.startIndex..., in: title)
        guard let match = expression.firstMatch(in: title, range: range),
              let levelRange = Range(match.range(at: 1), in: title),
              let numberRange = Range(match.range(at: 2), in: title) else { return nil }
        return "\(title[levelRange])-\(title[numberRange])"
    }
}

enum ReviewCommentKind: String, Codable, CaseIterable {
    case review = "리뷰"
    case general = "일반 코멘트"
    case line = "라인 코멘트"
    case reply = "답글"

    var symbol: String {
        switch self {
        case .review: "text.bubble"
        case .general: "bubble.left"
        case .line: "curlybraces"
        case .reply: "arrowshape.turn.up.left"
        }
    }
}

struct AgentAnalysis: Codable, Hashable {
    var judgment: String
    var confidence: String
    var affectedFiles: [String]
    var impact: String
    var recommendation: String
    var suggestedTests: [String]
    var rawOutput: String
}

enum AgentReviewStatus: String, Codable {
    case ready = "검토 준비"
    case queued = "분석 대기"
    case reviewing = "검토 중"
    case complete = "검토 완료"
    case failed = "연결 필요"
    case workspaceTrustRequired = "작업 공간 신뢰 필요"
    case permissionRequired = "권한 승인 필요"
}

enum AgentChatRole: String, Codable {
    case user
    case agent
}

struct AgentChatMessage: Identifiable, Codable, Hashable {
    var id = UUID()
    var role: AgentChatRole
    var body: String
    var createdAt = Date()
}

enum WorkspaceDestination: String, CaseIterable, Codable, Identifiable {
    case currentLocal
    case separateWorktree
    case separateBranch

    var id: String { rawValue }

    var title: String {
        switch self {
        case .currentLocal: "현재 로컬"
        case .separateWorktree: "별도의 워크트리"
        case .separateBranch: "별도 브랜치"
        }
    }

    var detail: String {
        switch self {
        case .currentLocal: "등록한 로컬 저장소에서 현재 PR 브랜치로 작업합니다."
        case .separateWorktree: "현재 작업을 건드리지 않고, PR 전용 폴더에서 작업합니다."
        case .separateBranch: "등록한 저장소에 별도 작업 브랜치를 만들어 작업합니다."
        }
    }
}

struct ImplementationPlan: Codable, Hashable {
    var repository: String
    var pullRequestNumber: Int
    var content: String
    var sourceCardIDs: [UUID]
    /// New plans depend on review-section IDs; UUIDs remain for old saved plans.
    var sourceReviewIDs: [String]?
    var createdAt = Date()
    var destination: WorkspaceDestination?
    var status: ImplementationWorkStatus = .ready
    var result: String?
    var startedAt: Date?
    var completedAt: Date?
    /// Local commit created for this individual review work card.
    var committedSHA: String?
    /// Files already changed before this card's implementation began.
    var baselineChangedFiles: [String]?
    /// Files newly changed by this card's implementation, used for scoped commits.
    var changedFiles: [String]?
}

enum ImplementationWorkStatus: String, Codable {
    case ready = "계획 전달됨"
    case inProgress = "구현 중"
    case completed = "작업 완료"
    case failed = "작업 확인 필요"

    var symbol: String {
        switch self {
        case .ready: "tray.and.arrow.down"
        case .inProgress: "hammer"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }
}

struct AgentReviewCard: Identifiable, Codable, Hashable {
    var id = UUID()
    /// Stable work-unit identifier issued for a PR comment section.
    /// Format: `prid_review_{n}` where `prid` is the stable PR UUID.
    var reviewID: String?
    var repository: String
    var pullRequestNumber: Int
    var commentID: String
    var commentAuthor: String
    var commentBody: String
    /// Nil means this is a session created before section-level reviews existed.
    var sectionID: String?
    var sectionTitle: String?
    var sectionBody: String?
    var title: String
    var status: AgentReviewStatus = .ready
    var messages: [AgentChatMessage] = []
    /// Opening an analysis card, rather than merely opening the PR, acknowledges it.
    var isUnread = false
    var updatedAt = Date()
    /// Set only after this card's response has been successfully posted to GitHub.
    var reviewResponsePostedAt: Date?

    static func title(for body: String) -> String {
        if let severityLabel = ReviewCommentSection.displayLabel(for: body) {
            return severityLabel
        }
        let plain = body
            .replacingOccurrences(of: "#", with: "")
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(plain.prefix(58)) + (plain.count > 58 ? "…" : "")
    }
}
