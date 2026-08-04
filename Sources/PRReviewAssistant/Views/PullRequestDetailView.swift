import SwiftUI
import AppKit

/// Keeps the two detail side panels mutually exclusive.
///
/// In particular, opening the human-review panel must replace an open agent
/// review, otherwise the agent panel's higher display priority hides it.
struct ReviewDetailNavigation: Equatable {
    enum Panel: Equatable {
        case comments
        case agent(UUID)
        case work(UUID)
    }

    private(set) var panel: Panel?

    var isShowingComments: Bool {
        panel == .comments
    }

    var selectedAgentCardID: UUID? {
        guard case let .agent(id) = panel else { return nil }
        return id
    }

    var selectedWorkCardID: UUID? {
        guard case let .work(id) = panel else { return nil }
        return id
    }

    mutating func showComments() {
        panel = .comments
    }

    mutating func showAgent(_ id: UUID) {
        panel = .agent(id)
    }

    mutating func showWork(_ id: UUID) {
        panel = .work(id)
    }

    mutating func closePanel() {
        panel = nil
    }
}

struct PullRequestDetailView: View {
    let pullRequest: PullRequest
    @Bindable var store: ReviewStore
    @State private var showingPushApproval = false
    @State private var showingReviewApproval = false
    @State private var testCommand = "swift test"
    @State private var detailNavigation = ReviewDetailNavigation()
    @State private var expandedCommentIDs: Set<String> = []
    @State private var selectedCommentIDs: Set<String> = []
    @State private var selectedSectionIDs: Set<String> = []
    @State private var showingImplementationPlan = false
    @State private var showingWorkArea = false
    @State private var showingMergeApproval = false
    

    var body: some View {
        Group {
            if let cardID = detailNavigation.selectedWorkCardID,
               let card = store.agentCard(id: cardID),
               let plan = store.implementationPlan(for: pullRequest) {
                HSplitView {
                    detailContent
                    WorkReviewSidePanel(card: card, workResult: plan.result, close: { detailNavigation.closePanel() })
                        // Recreate the panel when another work card is selected,
                        // so its scroll position and review context never leak.
                        .id(cardID)
                        .frame(minWidth: 360, idealWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
                }
            } else if let cardID = detailNavigation.selectedAgentCardID, let card = store.agentCard(id: cardID) {
                HSplitView {
                    detailContent
                    
                AgentChatSidePanel(
                    card: card,
                    sourceComment: store.comments(for: pullRequest).first { $0.id == card.commentID },
                    pullRequest: pullRequest,
                    send: { message in Task { await store.sendAgentMessage(id: cardID, pullRequest: pullRequest, message: message) } },
                    openCodeLocation: { path, line, column in
                        store.openInCursor(path: path, line: line, column: column, for: pullRequest)
                    },
                    beginImplementation: {
                        guard store.createImplementationPlan(for: pullRequest) != nil else { return }
                        showingWorkArea = true
                    },
                    close: { detailNavigation.closePanel() }
                )
                    // The panel owns draft and toast state. Give each review
                    // card a distinct identity so selecting another card while
                    // this side view is already open recreates it with that
                    // card's PR-comment context and conversation.
                    .id(cardID)
                    .frame(minWidth: 320, idealWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
                }
            } else if detailNavigation.isShowingComments {
                HSplitView {
                    detailContent
                CommentSidePanel(
                    pullRequest: pullRequest,
                    comments: store.comments(for: pullRequest),
                    expandedCommentIDs: $expandedCommentIDs,
                    selectedSectionIDs: $selectedSectionIDs,
                    isUnread: { store.isUnread($0) },
                    reviewSection: { comment, section in reviewSection(comment, section: section) },
                    close: { detailNavigation.closePanel() }
                )
                    .frame(minWidth: 300, idealWidth: 410, maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                detailContent
            }
        }
        .animation(.default, value: detailNavigation)
        .onAppear { store.markPullRequestRead(pullRequest) }
        .onChange(of: pullRequest.id) { _, _ in
            // Agent work continues in the background, but a result from the
            // previous PR must never pin the detail screen open.
            detailNavigation.closePanel()
            selectedCommentIDs = []
            selectedSectionIDs = []
        }
        .onChange(of: detailNavigation.isShowingComments) { _, isShowing in
            if isShowing { store.markCommentsRead(for: pullRequest) }
        }
        .alert(store.agentPermissionRequest?.title ?? "에이전트 권한 요청", isPresented: Binding(
            get: { store.agentPermissionRequest?.pullRequest.id == pullRequest.id },
            set: { presented in if !presented { store.cancelAgentPermission() } }
        )) {
            Button("취소", role: .cancel) { store.cancelAgentPermission() }
            Button(store.agentPermissionRequest?.approvalTitle ?? "확인") { store.approveAgentPermission() }
        } message: {
            Text(permissionMessage)
        }
        .alert("활성 PR 전환", isPresented: Binding(
            get: { store.workspaceSwitchRequest?.target.id == pullRequest.id },
            set: { presented in if !presented { store.cancelWorkspaceSwitch() } }
        )) {
            Button("취소", role: .cancel) { store.cancelWorkspaceSwitch() }
            Button("stash 후 분석 시작") { store.approveWorkspaceSwitch() }
        } message: {
            Text(workspaceSwitchMessage)
        }
        .alert("PR 머지", isPresented: $showingMergeApproval) {
            Button("취소", role: .cancel) {}
            Button("Create a merge commit으로 머지", role: .destructive) {
                Task { await store.mergeApprovedPullRequest(pullRequest) }
            }
        } message: {
            Text("GitHub에서 이 PR을 Create a merge commit 방식으로 머지합니다. 머지와 푸시가 성공한 경우 소스 브랜치를 삭제합니다.")
        }
        .navigationTitle("PR #\(pullRequest.number)")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("GitHub에서 열기", systemImage: "arrow.up.right.square") {}
                    .help("GitHub에서 열기")
                Button(detailNavigation.isShowingComments ? "댓글 닫기" : "모든 코멘트", systemImage: "text.bubble") {
                    if detailNavigation.isShowingComments {
                        detailNavigation.closePanel()
                    } else {
                        detailNavigation.showComments()
                    }
                }
                .help(detailNavigation.isShowingComments ? "댓글 닫기" : "모든 코멘트")
                if pullRequest.reviewState != .approved {
                    Button("분석 실행", systemImage: "sparkles") { Task { await store.startAnalysis(for: pullRequest) } }
                        .disabled(pullRequest.analysisStatus == .analyzing)
                        .help("분석 실행")
                    Button("반영 계획", systemImage: "checklist") {
                        showingImplementationPlan = true
                    }
                    .disabled(store.comments(for: pullRequest).isEmpty)
                    .help("반영 계획")
                }
                if detailNavigation.selectedAgentCardID != nil {
                    Button("검토 닫기", systemImage: "xmark.rectangle") {
                        detailNavigation.closePanel()
                    }
                    .help("검토 닫기")
                }
            }
        }
    }

    private var detailContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                Divider()
                reviewSummary
                if pullRequest.reviewState == .approved {
                    mergeArea
                } else {
                    analysis
                    workArea
                    executionLog
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(pullRequest.title).font(.largeTitle.bold())
                Spacer()
                Label(pullRequest.reviewState.rawValue, systemImage: "bubble.left.and.bubble.right")
                    .foregroundStyle(pullRequest.reviewState.tint)
            }
            Text("\(pullRequest.repository) · 작성자 \(pullRequest.author)")
                .foregroundStyle(.secondary)
            checkoutLocation
            HStack(spacing: 10) {
                BranchChip(title: "HEAD", branch: pullRequest.headBranch, tint: .blue)
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                BranchChip(title: "BASE", branch: pullRequest.baseBranch, tint: .gray)
                Spacer()
                Text(pullRequest.headSHA).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var checkoutLocation: some View {
        if let path = store.worktreePath(for: pullRequest) {
            HStack(spacing: 8) {
                Label("현재 체크아웃", systemImage: "arrow.triangle.branch")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(pullRequest.headBranch)
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                    .textSelection(.enabled)
                Text("·")
                    .foregroundStyle(.secondary)
                Text(path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("현재 체크아웃 브랜치 \(pullRequest.headBranch), 작업 경로 \(path)")
        } else {
            Label("아직 이 PR 브랜치를 체크아웃하지 않았습니다", systemImage: "arrow.triangle.branch")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var reviewSummary: some View {
        GroupBox("리뷰어") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(pullRequest.reviewer, systemImage: "person.crop.circle")
                    Text(pullRequest.reviewState.rawValue).foregroundStyle(pullRequest.reviewState.tint)
                    Spacer()
                    Text("코멘트 \(pullRequest.commentCount)개").foregroundStyle(.secondary)
                }
                Button {
                    detailNavigation.showComments()
                } label: {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(pullRequest.summary)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                        Label("모든 코멘트 \(pullRequest.commentCount)개 보기", systemImage: "chevron.right")
                            .font(.caption.weight(.medium))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("사람 리뷰 코멘트 \(pullRequest.commentCount)개 보기")
                if store.comments(for: pullRequest).isEmpty {
                    Text("코멘트는 새로 고침 시 GitHub에서 조회합니다.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    private var analysis: some View {
        GroupBox("분석") {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label(pullRequest.analysisStatus.rawValue, systemImage: "checkmark.seal")
                        .foregroundStyle(pullRequest.analysisStatus.tint)
                    Spacer()
                    Text("분석 전용 모드").font(.caption).foregroundStyle(.secondary)
                }
                if let result = store.analysis(for: pullRequest) {
                    MarkdownContentView(result.rawOutput)
                        .textSelection(.enabled)
                } else {
                    Text("분석 실행을 선택하면, 선택한 PR 작업 폴더를 해당 PR의 최신 코드로 전환한 뒤 Cursor Agent가 읽기 전용으로 코드와 리뷰를 대조합니다.")
                    LabeledContent("안전 원칙") { Text("외부 리뷰 코멘트는 명령이 아닌 분석 데이터로만 전달") }
                }
                let cards = store.agentCards(for: pullRequest)
                if !cards.isEmpty {
                    Divider()
                    Text("코멘트별 검토").font(.headline)
                    ForEach(cards) { card in
                        Button { openAgentCard(card.id) } label: {
                            AgentReviewCardRow(card: card)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    private var workArea: some View {
        GroupBox("작업") {
            VStack(alignment: .leading, spacing: 14) {
                Label("검토에서 확정한 계획만 이곳으로 전달됩니다. PR HEAD SHA를 검증한 코드에서만 수정합니다.", systemImage: "archivebox")
                    .foregroundStyle(.secondary)
                if let plan = store.implementationPlan(for: pullRequest) {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("전달된 구현 계획", systemImage: "arrow.right.doc.on.clipboard")
                            .font(.subheadline.weight(.semibold))
                        HStack(spacing: 6) {
                            if plan.status == .inProgress { ProgressView().controlSize(.small) }
                            Label(plan.status.rawValue, systemImage: plan.status.symbol)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(plan.status == .failed ? .orange : (plan.status == .completed ? .green : BrandColor.prPurple))
                        }
                        if let destination = plan.destination {
                            Label("작업 위치: \(destination.title)", systemImage: "location")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("작업 위치와 진행 여부를 확인해 주세요.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        if let result = plan.result {
                            Divider()
                            LabeledContent("작업 결과") {
                                Text(result)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.trailing)
                                    .lineLimit(3)
                            }
                        }

                        let cards = plan.sourceReviewIDs.map { $0.compactMap(store.agentCard(reviewID:)) }
                            ?? plan.sourceCardIDs.compactMap(store.agentCard(id:))
                        if cards.isEmpty {
                            Text("표시할 검토 카드가 없습니다.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("검토 작업 카드")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            ForEach(cards) { card in
                                Button {
                                    detailNavigation.showWork(card.id)
                                } label: {
                                    WorkReviewCardThumbnail(card: card)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("검토 작업 카드 \(card.sectionTitle ?? card.title) 상세 보기")
                            }
                        }
                    }
                    .padding(10)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                }
                HStack {
                    Spacer()
                    Button("커밋", systemImage: "checkmark.circle") { showingPushApproval = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(!store.canCommit)
                }
                HStack {
                    Text("작업 영역에서는 커밋까지만 진행합니다. 푸시는 재리뷰 요청을 승인할 때 실행됩니다.")
                    Spacer()
                    Text("HEAD \(pullRequest.headSHA)").font(.system(.caption, design: .monospaced))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    private var mergeArea: some View {
        GroupBox("Merge pull request") {
            VStack(alignment: .leading, spacing: 14) {
                Label("이 PR은 승인되었습니다.", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .font(.headline)
                Text("Create a merge commit 방식으로 GitHub에 머지합니다. 머지와 푸시가 성공하면 소스 브랜치를 삭제합니다.")
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Create a merge commit으로 머지", systemImage: "arrow.triangle.merge") {
                        showingMergeApproval = true
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    private var executionLog: some View {
        GroupBox("실행 결과") {
            VStack(alignment: .leading, spacing: 12) {
                if let worktree = store.worktreePath(for: pullRequest) {
                    LabeledContent("PR 작업 폴더") { Text(worktree).font(.caption.monospaced()).lineLimit(1) }
                }
                HStack {
                    TextField("테스트 명령", text: $testCommand)
                    Button("재리뷰 요청") { showingReviewApproval = true }
                }
                if let result = store.testResult(for: pullRequest) {
                    Text(result.isEmpty ? "테스트가 성공했습니다." : result)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                }
                if let diff = store.diffStat(for: pullRequest) {
                    Text(diff.isEmpty ? "아직 변경된 파일이 없습니다." : diff)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
        .sheet(isPresented: $showingImplementationPlan) {
            ImplementationPlanSheet(
                pullRequest: pullRequest,
                comments: store.comments(for: pullRequest),
                selectedCommentIDs: $selectedCommentIDs,
                prepareAndOpenWorkspace: { Task { await prepareAndOpenWorkspace() } }
            )
        }
        .sheet(isPresented: $showingWorkArea) {
            if let plan = store.implementationPlan(for: pullRequest) {
                WorkAreaSheet(
                    pullRequest: pullRequest,
                    plan: plan,
                    confirm: {
                        Task { await store.startImplementation(for: pullRequest) }
                        showingWorkArea = false
                    }
                )
            }
        }
        .sheet(isPresented: $showingReviewApproval) {
            ReReviewRequestSheet(
                pullRequest: pullRequest,
                generateMessage: { await store.generateReReviewMessage(for: pullRequest) },
                submit: { comment in
                    Task { await store.requestReReview(for: pullRequest, comment: comment) }
                }
            )
        }
        .alert("커밋 승인", isPresented: $showingPushApproval) {
            Button("취소", role: .cancel) {}
            Button("승인하고 커밋") { Task { await store.commitApprovedChanges(for: pullRequest, message: "fix: address PR review feedback") } }
        } message: { Text("PR HEAD SHA와 작업 폴더를 다시 검증하고 로컬 \(pullRequest.headBranch) 브랜치에만 커밋합니다. 아직 원격에는 푸시하지 않습니다.") }
    }

    private func openWorkspace() {
        guard let path = store.worktreePath(for: pullRequest) else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    private func prepareAndOpenWorkspace() async {
        guard let path = await store.prepareWorkspace(for: pullRequest) else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
        showingImplementationPlan = false
    }

    private func reviewSection(_ comment: ReviewComment, section: ReviewCommentSection) {
        let id = store.createAgentReview(for: comment, section: section, pullRequest: pullRequest)
        detailNavigation.showAgent(id)
        Task { await store.beginAgentReview(id: id, pullRequest: pullRequest) }
    }

    private func openAgentCard(_ id: AgentReviewCard.ID) {
        store.markAgentCardRead(id)
        detailNavigation.showAgent(id)
        Task { await store.beginAgentReview(id: id, pullRequest: pullRequest) }
    }

    private var permissionMessage: String {
        guard let request = store.agentPermissionRequest else { return "에이전트 권한 확인이 필요합니다." }
        switch request.kind {
        case .workspaceTrust:
            return "Cursor Agent가 이 저장소의 코드를 읽으려면 작업 공간 신뢰가 필요합니다. 승인하면 이 검토 카드의 ask 대화를 읽기 전용으로 다시 시도합니다. 수정·테스트·푸시는 실행되지 않습니다."
        case .cursorLogin:
            return "Cursor Agent 로그인이 필요합니다. 승인하면 Terminal과 브라우저에서 Cursor 인증을 시작합니다. 인증 후 검토 카드를 다시 선택해 재시도하세요."
        case .other:
            return "Cursor Agent가 추가 권한을 요청했습니다. 앱은 범위를 알 수 없는 권한을 자동 허용하지 않습니다. Cursor에서 요청 내용을 확인하고 승인하세요.\n\n\(request.detail)"
        }
    }

    private var workspaceSwitchMessage: String {
        guard let request = store.workspaceSwitchRequest else { return "활성 PR을 전환합니다." }
        let active = request.active.map { "현재 활성 PR #\($0.number) (\($0.headBranch))의 미커밋 변경은 stash합니다.\n\n" } ?? ""
        return "\(active)PR #\(pullRequest.number) (\(pullRequest.headBranch))로 체크아웃을 전환하고 분석을 시작합니다."
    }
}

private struct ReReviewRequestSheet: View {
    let pullRequest: PullRequest
    let generateMessage: () async -> String?
    let submit: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var comment = ""
    @State private var isGenerating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("재리뷰 요청").font(.title2.bold())
                Text("메시지를 확인한 뒤 푸시, PR 코멘트 등록, \(pullRequest.reviewer) 재요청을 순서대로 진행합니다.")
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("재리뷰 코멘트").font(.headline)
                    Spacer()
                    Button {
                        Task {
                            isGenerating = true
                            defer { isGenerating = false }
                            if let recommendation = await generateMessage() {
                                comment = recommendation
                            }
                        }
                    } label: {
                        Label(
                            isGenerating ? "추천 메시지 생성 중…" : "추천 메시지 만들기",
                            systemImage: "wand.and.stars"
                        )
                    }
                    .disabled(isGenerating)
                }

                TextEditor(text: $comment)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 180)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        if comment.isEmpty {
                            Text("변경 내용과 테스트 결과를 입력하거나 추천 메시지를 만들어 보세요.")
                                .foregroundStyle(.tertiary)
                                .padding(14)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                .allowsHitTesting(false)
                        }
                    }

                Text("추천 메시지는 에이전트 분석·코멘트별 검토·변경 및 테스트 결과를 압축해 만듭니다. 전송 전에 사실과 표현을 확인하세요.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack {
                Label("승인된 로컬 커밋만 원격에 반영합니다.", systemImage: "arrow.triangle.branch")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("취소", role: .cancel) { dismiss() }
                Button("푸시 후 코멘트 및 재리뷰 요청") {
                    submit(comment)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isGenerating || comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 620)
    }
}

private struct ImplementationPlanSheet: View {
    let pullRequest: PullRequest
    let comments: [ReviewComment]
    @Binding var selectedCommentIDs: Set<String>
    let prepareAndOpenWorkspace: () -> Void
    @Environment(\.dismiss) private var dismiss

    private var selectedComments: [ReviewComment] {
        comments.filter { selectedCommentIDs.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("반영 계획 검토").font(.title2.bold())
                Text("PR #\(pullRequest.number) · 코드 변경 전 선택 항목과 영향 위치를 확인하세요.")
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            Divider()

            if comments.isEmpty {
                ContentUnavailableView("분석할 코멘트가 없습니다", systemImage: "bubble.left")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Button(selectedCommentIDs.count == comments.count ? "전체 선택 해제" : "전체 선택") {
                                selectedCommentIDs = selectedCommentIDs.count == comments.count ? [] : Set(comments.map(\.id))
                            }
                            Spacer()
                            Text("\(selectedComments.count)개 반영 예정")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(selectedComments.isEmpty ? Color.secondary : Color.orange)
                        }

                        ForEach(comments) { comment in
                            Toggle(isOn: selectionBinding(for: comment.id)) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(comment.body).lineLimit(3)
                                    Label(comment.path.map { "\($0)\(comment.line.map { ": \($0)번째 줄" } ?? "")" } ?? "일반 코멘트", systemImage: comment.path == nil ? "bubble.left" : "curlybraces")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .toggleStyle(.checkbox)
                            .padding(12)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
                        }

                        if !selectedComments.isEmpty {
                            Label("수정 후 diff와 테스트 결과를 확인한 뒤 로컬 커밋을 만들 수 있습니다. 푸시는 재리뷰 요청 시 진행합니다.", systemImage: "shield.lefthalf.filled")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.top, 4)
                        }
                    }
                    .padding(24)
                }
            }

            Divider()
            HStack {
                Button("나중에") { dismiss() }
                Spacer()
                Button("수정 작업 폴더 열기", systemImage: "folder") { prepareAndOpenWorkspace() }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedComments.isEmpty)
            }
            .padding(20)
        }
        .frame(minWidth: 560, minHeight: 460)
    }

    private func selectionBinding(for id: String) -> Binding<Bool> {
        Binding(get: { selectedCommentIDs.contains(id) }, set: { selected in
            if selected { selectedCommentIDs.insert(id) } else { selectedCommentIDs.remove(id) }
        })
    }
}

private struct WorkAreaSheet: View {
    let pullRequest: PullRequest
    let plan: ImplementationPlan
    let confirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    init(pullRequest: PullRequest, plan: ImplementationPlan, confirm: @escaping () -> Void) {
        self.pullRequest = pullRequest
        self.plan = plan
        self.confirm = confirm
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("작업 영역").font(.title2.bold())
                Text("검토 세션에서 전달된 계획입니다. PR 소스 브랜치에서 에이전트 구현을 시작합니다.")
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                MarkdownContentView(plan.content)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 260)
            .padding(12)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

            Label("체크아웃 브랜치: \(pullRequest.headBranch)", systemImage: "arrow.triangle.branch")
                .font(.subheadline.weight(.medium))
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(BrandColor.prPurple.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

            HStack {
                Button("나중에") { dismiss() }
                Spacer()
                Button("에이전트 구현 시작", systemImage: "hammer.fill") {
                    confirm()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 680, height: 640)
    }
}

private struct WorkReviewCardThumbnail: View {
    let card: AgentReviewCard

    private var summary: String {
        let text = card.messages.last(where: { $0.role == .agent })?.body
            ?? card.sectionBody
            ?? card.commentBody
        return text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "text.bubble")
                .foregroundStyle(BrandColor.prPurple)
            VStack(alignment: .leading, spacing: 3) {
                Text(card.sectionTitle ?? card.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.opacity(0.65), in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
    }
}

private struct WorkReviewSidePanel: View {
    let card: AgentReviewCard
    let workResult: String?
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("검토 작업 카드").font(.headline)
                    Text(card.sectionTitle ?? card.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Button("작업 영역으로 돌아가기", systemImage: "xmark") { close() }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("검토 작업 카드 사이드 뷰 닫기")
            }
            .padding(16)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    GroupBox("검토한 리뷰") {
                        MarkdownContentView(card.sectionBody ?? card.commentBody)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    GroupBox("검토 결과") {
                        if let answer = card.messages.last(where: { $0.role == .agent })?.body {
                            MarkdownContentView(answer)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Text("아직 이 검토 카드의 결과가 없습니다.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    if !card.messages.isEmpty {
                        GroupBox("검토 대화 전체") {
                            VStack(alignment: .leading, spacing: 12) {
                                ForEach(card.messages) { message in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(message.role == .user ? "요청" : "에이전트")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.secondary)
                                        MarkdownContentView(message.body)
                                            .textSelection(.enabled)
                                    }
                                    if message.id != card.messages.last?.id { Divider() }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    if let workResult, !workResult.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        GroupBox("작업 결과 전체") {
                            MarkdownContentView(workResult)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(16)
            }
        }
        .background(.bar)
    }
}

private struct CommentSidePanel: View {
    let pullRequest: PullRequest
    let comments: [ReviewComment]
    @Binding var expandedCommentIDs: Set<String>
    @Binding var selectedSectionIDs: Set<String>
    let isUnread: (ReviewComment) -> Bool
    let reviewSection: (ReviewComment, ReviewCommentSection) -> Void
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("모든 코멘트").font(.headline)
                    Text("\(pullRequest.repository) #\(pullRequest.number) · \(comments.count)개")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: close) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("댓글 패널 닫기")
            }
            .padding(16)
            Divider()
            if comments.isEmpty {
                ContentUnavailableView("표시할 코멘트가 없습니다", systemImage: "bubble.left")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(comments) { comment in
                            FoldableComment(
                                comment: comment,
                                isUnread: isUnread(comment),
                                isExpanded: binding(for: comment.id),
                                selectedSectionIDs: $selectedSectionIDs,
                                reviewSection: reviewSection
                            )
                            Divider().padding(.leading, comment.parentID == nil ? 16 : 36)
                        }
                    }
                }
            }
        }
        .background(.bar)
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { expandedCommentIDs.contains(id) },
            set: { expanded in
                if expanded { expandedCommentIDs.insert(id) }
                else { expandedCommentIDs.remove(id) }
            }
        )
    }

}

private struct FoldableComment: View {
    let comment: ReviewComment
    let isUnread: Bool
    @Binding var isExpanded: Bool
    @Binding var selectedSectionIDs: Set<String>
    let reviewSection: (ReviewComment, ReviewCommentSection) -> Void

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(comment.sections) { section in
                    ReviewSectionRow(
                        section: section,
                        isSelected: sectionBinding(for: section.id),
                        review: { reviewSection(comment, section) }
                    )
                }
                if let path = comment.path {
                    Label("\(path)\(comment.line.map { ": \($0)번째 줄" } ?? "")", systemImage: "curlybraces")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 8)
            .padding(.leading, 4)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: comment.kind.symbol)
                    .foregroundStyle(comment.reviewState?.tint ?? .secondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(comment.author).font(.subheadline.weight(.semibold))
                        if isUnread {
                            Circle().fill(.red).frame(width: 8, height: 8)
                                .accessibilityLabel("읽지 않은 코멘트")
                        }
                        Text(comment.kind.rawValue)
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                        if let state = comment.reviewState {
                            Text(state.rawValue).font(.caption2).foregroundStyle(state.tint)
                        }
                        if comment.sections.count > 1 {
                            Text("섹션 \(comment.sections.count)개")
                                .font(.caption2)
                                .foregroundStyle(BrandColor.prPurple)
                        }
                        Spacer(minLength: 4)
                        Button(comment.sections.count > 1 ? "섹션 검토" : "에이전트 검토", systemImage: "sparkles") {
                            if comment.sections.count > 1 {
                                isExpanded = true
                            } else if let section = comment.sections.first {
                                reviewSection(comment, section)
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    Text(comment.body)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Text(comment.createdAt, format: .dateTime.month().day().hour().minute())
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.leading, comment.parentID == nil ? 0 : 20)
            .padding(.vertical, 12)
        }
        .padding(.horizontal, 16)
    }

    private func sectionBinding(for id: String) -> Binding<Bool> {
        Binding(get: { selectedSectionIDs.contains(id) }, set: { selected in
            if selected { selectedSectionIDs.insert(id) } else { selectedSectionIDs.remove(id) }
        })
    }
}

private struct ReviewSectionRow: View {
    let section: ReviewCommentSection
    @Binding var isSelected: Bool
    let review: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Toggle("검토 대상", isOn: $isSelected)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .onChange(of: isSelected) { _, selected in
                        if selected { review() }
                    }
                Text(section.title).font(.subheadline.weight(.semibold))
                Spacer()
                Button("검토", systemImage: "sparkles", action: review)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            MarkdownContentView(section.body)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct AgentReviewCardRow: View {
    let card: AgentReviewCard

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sparkles")
                .foregroundStyle(BrandColor.prPurple)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 4) {
                Text(card.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                if let reviewID = card.reviewID {
                    Text(reviewID)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Text(card.status.rawValue)
                    Text("·")
                    Text(card.commentAuthor)
                    Text("·")
                    Text(card.updatedAt, format: .dateTime.hour().minute())
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if card.isUnread {
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
                    .accessibilityLabel("확인하지 않은 분석 카드")
            }
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct AgentChatSidePanel: View {
    let card: AgentReviewCard
    /// Read from the store on every detail refresh instead of relying only on
    /// the snapshot saved when this agent review was created. GitHub comments
    /// can be edited while an agent conversation remains open.
    let sourceComment: ReviewComment?
    let pullRequest: PullRequest
    let send: (String) -> Void
    let openCodeLocation: (String, Int?, Int?) -> String
    let beginImplementation: () -> Void
    let close: () -> Void
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("에이전트 검토").font(.headline)
                    Text(card.title).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button("백그라운드로 보내기", systemImage: "xmark") { close() }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("에이전트 검토를 백그라운드로 보내기")
            }
            .padding(16)
            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 6) {
                        Image(systemName: "eye")
                        Text("PR 작업 폴더 · ask 모드 · 읽기 전용")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(.quaternary, in: Capsule())

                    GroupBox("PR 코멘트") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 6) {
                                Label(sourceComment?.author ?? card.commentAuthor, systemImage: "person")
                                if let path = sourceComment?.path {
                                    Text("\(path):\(sourceComment?.line.map(String.init) ?? "-")")
                                }
                                Spacer()
                                Text(sourceComment == nil ? "저장된 원문" : "GitHub 최신 원문")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)

                            MarkdownContentView(sourceComment?.body ?? card.commentBody)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .padding(.vertical, 2)
                    }

                    if card.messages.isEmpty {
                        ContentUnavailableView("검토를 시작하는 중입니다", systemImage: "sparkles", description: Text("코드 수정 없이 현재 저장소를 읽고 리뷰 내용을 검토합니다."))
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    }

                    ForEach(card.messages) { message in
                        ChatBubble(message: message, quote: { quote(message) })
                    }

                    if card.status == .reviewing {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("에이전트가 검토 중입니다…").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if card.status == .workspaceTrustRequired {
                        Label("작업 공간 신뢰 승인을 기다리고 있습니다.", systemImage: "lock.trianglebadge.exclamationmark")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    if card.status == .permissionRequired {
                        Label("에이전트 권한 승인을 기다리고 있습니다.", systemImage: "lock.trianglebadge.exclamationmark")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .padding(16)
            }
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("검토를 마쳤나요?").font(.caption.weight(.medium))
                    Text("대화를 종합한 계획을 작업 영역으로 보냅니다.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Button("구현 시작", systemImage: "hammer") { beginImplementation() }
                    .buttonStyle(.bordered)
                    .disabled(card.messages.isEmpty || card.status == .reviewing)
            }
            .padding(12)
            Divider()
            HStack(alignment: .bottom, spacing: 8) {
                TextField("추가 질문을 입력하세요", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .onSubmit(sendDraft)
                Button(action: sendDraft) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || card.status == .reviewing ? .secondary : BrandColor.prPurple)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || card.status == .reviewing)
            }
            .padding(12)
        }
        .background(.bar)
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "prreview", url.host == "open" else { return .systemAction }
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let path = components?.queryItems?.first(where: { $0.name == "path" })?.value ?? ""
            let line = components?.queryItems?.first(where: { $0.name == "line" })?.value.flatMap(Int.init)
            let column = components?.queryItems?.first(where: { $0.name == "column" })?.value.flatMap(Int.init)
            withAnimation { quoteToast = openCodeLocation(path, line, column) }
            Task {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                withAnimation { quoteToast = nil }
            }
            return .handled
        })
        .overlay(alignment: .bottom) {
            if let toast = quoteToast {
                Text(toast)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(radius: 4)
                    .padding(.bottom, 72)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    @State private var quoteToast: String?

    private func quote(_ message: AgentChatMessage) {
        let speaker = message.role == .user ? "나" : "에이전트"
        let timestamp = message.createdAt.formatted(.dateTime.month().day().hour().minute())
        let quoted = message.body
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "> \($0)" }
            .joined(separator: "\n")
        let reference = "> \(speaker) 검토 메시지 · \(timestamp)\n\(quoted)\n\n"
        draft = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? reference : "\(draft)\n\n\(reference)"
        withAnimation { quoteToast = "메시지를 입력창에 인용했습니다" }
        Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            withAnimation { quoteToast = nil }
        }
    }

    private func sendDraft() {
        let message = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, card.status != .reviewing else { return }
        draft = ""
        send(message)
    }

}

private struct ChatBubble: View {
    let message: AgentChatMessage
    let quote: () -> Void
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top) {
            if message.role == .user { Spacer(minLength: 36) }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(message.role == .user ? "나" : "에이전트")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(action: copyMessage) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("메시지 복사")
                    .accessibilityLabel("메시지 복사")
                }
                if message.role == .agent {
                    MarkdownContentView(message.body)
                } else {
                    Text(message.body)
                }
            }
            .padding(10)
            // Keep today's compact bubble size as the minimum, then grow with
            // the draggable side panel instead of leaving unused whitespace.
            .frame(minWidth: 330, maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            .textSelection(.enabled)
            .background(message.role == .user ? AnyShapeStyle(BrandColor.prPurple.opacity(0.16)) : AnyShapeStyle(.quaternary), in: RoundedRectangle(cornerRadius: 10))
            .contextMenu {
                Button("입력창에 인용", systemImage: "text.quote") { quote() }
                Button("메시지 전체 복사", systemImage: "doc.on.doc") { copyMessage() }
            }
            if message.role == .agent { Spacer(minLength: 20) }
        }
    }

    private func copyMessage() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.body, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }
}

private struct BranchChip: View {
    let title: String
    let branch: String
    let tint: Color

    var body: some View {
        HStack(spacing: 5) {
            Text(title).fontWeight(.semibold)
            Text(branch)
        }
        .font(.caption)
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(tint.opacity(0.13), in: Capsule())
        .foregroundStyle(tint)
    }
}
