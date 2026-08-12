import SwiftUI
import AppKit

struct ContentView: View {
    @Bindable var store: ReviewStore
    @State private var selection: SidebarItem? = .inbox
    @State private var cursorHistorySearch = ""
    @State private var showingPRBranchPicker = false
    @State private var showingAgentSpecSearch = false

    var body: some View {
        Group {
            if store.hasCompletedOnboarding {
                mainInterface
            } else {
                OnboardingView(store: store)
            }
        }
    }

    private var mainInterface: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("PR 리뷰 대응") {
                    if store.pullRequests.isEmpty {
                        Label("열린 PR이 없습니다", systemImage: "tray")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(store.pullRequests) { pullRequest in
                            Button {
                                selection = .inbox
                                store.selectedID = pullRequest.id
                            } label: {
                                PRBranchSidebarRow(
                                    branch: pullRequest.headBranch,
                                    subtitle: "\(pullRequest.repository) #\(pullRequest.number)",
                                    isUnread: store.isUnread(pullRequest)
                                )
                            }
                            .buttonStyle(.plain)
                            .help("PR #\(pullRequest.number) · \(pullRequest.headBranch) 코멘트 분류 보기")
                        }
                    }
                }
                Section {
                    ForEach(store.requestedBranches) { branch in
                        Button {
                            selection = .prRequest
                            store.selectedBranchID = branch.id
                        } label: {
                            PRBranchSidebarRow(branch: branch.name, subtitle: branch.repositoryName, isUnread: false)
                        }
                        .buttonStyle(.plain)
                        .help("PR 요청 브랜치 \(branch.name) 보기")
                    }
                } header: {
                    HStack(spacing: 6) {
                        Text("PR 요청")
                        Spacer()
                        Button {
                            selection = .prRequest
                            showingPRBranchPicker = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(.borderless)
                        .help("origin 브랜치를 PR 요청 목록에 추가")
                    }
                    .textCase(nil)
                }
                Section {
                    Button {
                        selection = .agentHistory
                        store.selectCursorSpec(nil)
                    } label: {
                        Label("최근 세션", systemImage: "clock.arrow.circlepath")
                    }
                    .buttonStyle(.plain)
                    Group {
                    ForEach(store.cursorSpecSidebarNames, id: \.self) { specName in
                        Button {
                            selection = .agentHistory
                            store.selectCursorSpec(specName)
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: "doc.text")
                                    .foregroundStyle(BrandColor.prPurple)
                                Text(specName).lineLimit(1)
                                if store.isCursorSpecPinned(specName) {
                                    Image(systemName: "pin.fill")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("\(store.cursorSessionCount(forSpec: specName))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("\(specName) spec의 세션 목록 보기")
                        .contextMenu {
                            Button {
                                store.toggleCursorSpecPinned(specName)
                            } label: {
                                Label(
                                    store.isCursorSpecPinned(specName) ? "고정 해제" : "고정",
                                    systemImage: store.isCursorSpecPinned(specName) ? "pin.slash" : "pin"
                                )
                            }
                            .disabled(!store.canPinCursorSpec(specName))

                            Divider()

                            Button {
                                store.closeCursorSpecFromSidebar(specName)
                            } label: {
                                Label("목록에서 닫기", systemImage: "xmark")
                            }
                        }
                    }
                    if store.unclassifiedCursorSessionCount > 0 {
                        Button(
                            store.isClassifyingCursorSessions
                                ? "미분류 분류 중…"
                                : "미분류 전체 분류 (\(store.unclassifiedCursorSessionCount)개)",
                            systemImage: "sparkles"
                        ) {
                            selection = .agentHistory
                            Task { await store.classifyUnclassifiedCursorSessions() }
                        }
                        .buttonStyle(.bordered)
                        .disabled(store.isClassifyingCursorSessions)
                        .help("미분류로 남은 모든 Cursor 세션을 spec 문서와 다시 연결합니다")
                    }
                    if !store.cursorSpecClassificationStatus.isEmpty {
                        Text(store.cursorSpecClassificationStatus)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    }
                    .disabled(!store.automaticCursorSessionClassification)
                    .opacity(store.automaticCursorSessionClassification ? 1 : 0.45)
                    if store.isLoadingCursorHistory {
                        Label("세션 기록 불러오는 중…", systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    HStack(spacing: 6) {
                        Text("에이전트")
                        if !store.automaticCursorSessionClassification {
                            Text("자동 분류 꺼짐")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            selection = .agentHistory
                            showingAgentSpecSearch = true
                        } label: {
                            Image(systemName: "magnifyingglass")
                        }
                        .buttonStyle(.borderless)
                        .disabled(!store.automaticCursorSessionClassification)
                        .help("Spec을 검색해 에이전트 목록에 열기")
                        .popover(isPresented: $showingAgentSpecSearch, arrowEdge: .leading) {
                            AgentSpecSearchPopover(query: $cursorHistorySearch, specNames: store.cursorSpecNames) { specName in
                                store.selectCursorSpec(specName)
                                showingAgentSpecSearch = false
                            }
                        }
                    }
                    .textCase(nil)
                }
            }
            .navigationTitle("PR Review")
            .listStyle(.sidebar)
        } detail: {
            if store.isInitialLoadInProgress {
                InitialLoadingView()
            } else if selection == .agentHistory {
                HSplitView {
                    CursorSessionListView(store: store)
                        .frame(minWidth: 360, idealWidth: 460, maxWidth: .infinity)
                    CursorSessionDetailView(store: store)
                        .frame(minWidth: 420, idealWidth: 620, maxWidth: .infinity)
                }
            } else if selection == .prRequest {
                if let branch = store.selectedBranch {
                    BranchRequestDetailView(branch: branch, store: store)
                } else {
                    ContentUnavailableView("PR 요청 브랜치를 추가하세요", systemImage: "plus", description: Text("사이드바 ‘PR 요청’ 제목 오른쪽의 + 버튼을 누르면 origin 브랜치를 검색해 추가할 수 있습니다."))
                }
            } else if let pullRequest = store.selectedPullRequest {
                // The PR's comment categories are now the main (centre)
                // content. Selecting a card opens its in-app side panel.
                PullRequestDetailView(pullRequest: pullRequest, store: store)
            } else {
                ContentUnavailableView("PR 브랜치를 선택하세요", systemImage: "arrow.left")
            }
        }
        .onChange(of: store.selectedID) { _, id in
            guard let id, let pullRequest = store.pullRequests.first(where: { $0.id == id }) else { return }
            store.markPullRequestRead(pullRequest)
        }
        .alert("새 PR과 코멘트 알림을 켤까요?", isPresented: $store.showsNotificationPermissionGuide) {
            Button("나중에", role: .cancel) {}
            Button("알림 허용") {
                Task { await store.requestNotificationPermission() }
            }
        } message: {
            Text("다음 macOS 권한 창에서 ‘허용’을 선택하면 새 PR과 리뷰 코멘트를 배너와 알림 센터로 받아볼 수 있습니다. 이후에도 설정 › 감시에서 변경할 수 있습니다.")
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    if selection == .agentHistory {
                        Task {
                            await store.loadCursorHistory()
                        }
                    }
                    else if selection == .prRequest { Task { await store.loadRepositoryBranches() } }
                    else { store.refresh() }
                } label: {
                    Label("새로 고침", systemImage: "arrow.clockwise")
                }
                .disabled(selection == .agentHistory ? store.isLoadingCursorHistory : (selection == .prRequest ? store.isLoadingBranches : store.isRefreshing))
                .help(selection == .agentHistory ? "Cursor 세션 기록 새로 고침" : (selection == .prRequest ? "브랜치 목록 새로 고침" : "새로 고침"))
            }
        }
        .sheet(isPresented: $showingPRBranchPicker) {
            BranchPickerSheet(store: store)
        }
        .task { await store.loadCursorHistory() }
    }
}

private struct PRBranchSidebarRow: View {
    let branch: String
    let subtitle: String
    let isUnread: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "arrow.triangle.branch")
                .foregroundStyle(BrandColor.prPurple)
            VStack(alignment: .leading, spacing: 2) {
                Text(branch)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 2)
            if isUnread { UnreadDot() }
        }
        .contentShape(Rectangle())
    }
}

private struct AgentSpecSearchPopover: View {
    @Binding var query: String
    let specNames: [String]
    let select: (String) -> Void

    private var matches: [String] {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return specNames }
        return specNames.filter { $0.localizedCaseInsensitiveContains(value) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Spec 찾기").font(.headline)
            Text("찾은 spec을 선택하면 해당 세션 목록을 중앙에 표시합니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Spec 이름", text: $query)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
                .onSubmit { if let first = matches.first { select(first) } }
            if matches.isEmpty {
                Text("일치하는 spec이 없습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(matches, id: \.self) { name in
                            Button(name) { select(name) }
                                .buttonStyle(.plain)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 4)
                        }
                    }
                }
                .frame(maxHeight: 130)
            }
            HStack {
                Button("지우기") { query = "" }
                    .disabled(query.isEmpty)
                Spacer()
                Button("완료") { if let first = matches.first { select(first) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(matches.isEmpty)
            }
        }
        .padding(16)
    }
}

private struct OnboardingView: View {
    @Bindable var store: ReviewStore
    @State private var currentStep = 0
    private let steps = ["Git 설치", "GitHub 로그인", "프로젝트 사본", "Cursor CLI", "LLM Agent", "Git 계정"]

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("PR Review Assistant 시작하기")
                    .font(.largeTitle.bold())
                Text("필요한 연결을 하나씩 확인합니다. 지금 하지 않는 항목은 언제든 설정에서 다시 진행할 수 있습니다.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(.top, 52)

            HStack(spacing: 0) {
                ForEach(steps.indices, id: \.self) { index in
                    VStack(spacing: 6) {
                        Image(systemName: index < currentStep ? "checkmark.circle.fill" : "\(index + 1).circle.fill")
                            .foregroundStyle(index <= currentStep ? BrandColor.prPurple : .secondary)
                        Text(steps[index]).font(.caption).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    if index < steps.count - 1 { Rectangle().fill(.quaternary).frame(height: 1).offset(y: -12) }
                }
            }
            .frame(maxWidth: 720)
            .padding(.vertical, 38)

            GroupBox {
                VStack(alignment: .leading, spacing: 18) {
                    Text(steps[currentStep]).font(.title2.bold())
                    stepContent
                    Divider()
                    HStack {
                        if currentStep > 0 { Button("이전") { currentStep -= 1 } }
                        Spacer()
                        Button("나중에") { skipAndAdvance() }
                        Button(currentStep == steps.count - 1 ? "시작하기" : "완료하고 다음", action: completeAndAdvance)
                            .buttonStyle(.borderedProminent)
                    }
                }
                .padding(10)
            }
            .frame(maxWidth: 680)
            Spacer()
        }
        .padding(.horizontal, 32)
        .task { await store.checkOnboardingPrerequisites() }
    }

    @ViewBuilder private var stepContent: some View {
        switch currentStep {
        case 0:
            StatusRow(status: store.gitCLIStatus, success: store.gitCLIStatus.hasPrefix("설치됨"))
            Text("Git은 프로젝트 사본을 확인하고 PR 작업 폴더를 안전하게 준비하는 데 사용됩니다. 설치되지 않았다면 Xcode Command Line Tools 또는 Git을 설치한 뒤 상태를 다시 확인하세요.")
                .foregroundStyle(.secondary)
            Button("Git 설치 상태 다시 확인", systemImage: "arrow.clockwise") { Task { await store.checkOnboardingPrerequisites() } }
        case 1:
            StatusRow(status: store.githubIdentity.map { "로그인됨 · @\($0.login)" } ?? store.statusMessage, success: store.githubIdentity != nil)
            Text("GitHub CLI 로그인은 본인이 작성한 PR과 사람 리뷰 코멘트를 가져오는 데 필요합니다. 브라우저 인증은 Terminal에서 안전하게 진행됩니다.")
                .foregroundStyle(.secondary)
            HStack {
                Button("GitHub 로그인 진행", systemImage: "person.badge.key") { store.startGitHubLogin() }
                    .buttonStyle(.borderedProminent)
                Button("로그인 상태 다시 확인") { Task { await store.checkAuthentication() } }
            }
        case 2:
            if store.projectCopyFolder.isEmpty {
                Text("아직 지정한 폴더가 없습니다.").foregroundStyle(.secondary)
            } else {
                StatusRow(status: store.projectCopyFolder, success: true)
            }
            Text("원본 프로젝트와 별도로 복사본을 둘 상위 폴더를 선택하세요. 이후 저장소를 추가할 때 이 위치의 Git 프로젝트를 지정하면 원본을 건드리지 않고 작업할 수 있습니다. 선택 창에서 새 폴더를 만들 수도 있습니다.")
                .foregroundStyle(.secondary)
            Button("프로젝트 사본 폴더 지정", systemImage: "folder.badge.plus") { chooseProjectCopyFolder() }
        case 3:
            let installed = store.cursorConnection.state != .unavailable
            StatusRow(status: installed ? "Cursor CLI를 찾았습니다. \(store.cursorConnection.detail)" : store.cursorConnection.detail, success: installed)
            Text("Cursor 앱을 설치하면 Cursor CLI도 함께 사용할 수 있습니다. 설치가 끝난 뒤에는 이 앱을 다시 열거나 상태 확인을 눌러 CLI를 찾아보세요.")
                .foregroundStyle(.secondary)
            HStack {
                if !installed {
                    Button("Cursor 다운로드 열기", systemImage: "arrow.down.app") { store.openCursorDownload() }
                        .buttonStyle(.borderedProminent)
                }
                Button("Cursor CLI 설치 상태 확인", systemImage: "arrow.clockwise") { Task { await store.checkCursorConnection() } }
            }
        case 4:
            StatusRow(status: store.cursorConnection.detail, success: store.cursorConnection.state == .connected)
            Text("Cursor Agent를 연결하면 PR 코멘트를 읽기 전용으로 분석하고, 설정한 모델로 대화할 수 있습니다. 모델은 설정에서 언제든 바꿀 수 있습니다.")
                .foregroundStyle(.secondary)
            HStack {
                Button("LLM 연결 상태 확인", systemImage: "arrow.clockwise") { Task { await store.checkCursorConnection() } }
                if store.cursorConnection.state == .needsLogin {
                    Button("Cursor 로그인 진행", systemImage: "sparkles") { store.startCursorLogin() }
                }
            }
        default:
            StatusRow(status: store.gitAccountStatus, success: !store.gitAccountStatus.hasPrefix("이름과 이메일"))
            Text("Git 작성자 이름과 이메일은 변경을 커밋할 때 사용됩니다. GitHub 로그인 계정과 달라도 되지만, 팀에서 사용하는 계정인지 확인하세요.")
                .foregroundStyle(.secondary)
            Button("Git 계정 다시 확인", systemImage: "arrow.clockwise") { Task { await store.checkOnboardingPrerequisites() } }
        }
    }

    private func completeAndAdvance() {
        if currentStep == steps.count - 1 { store.finishOnboarding() }
        else { currentStep += 1 }
    }

    private func skipAndAdvance() {
        store.skipOnboardingStep(steps[currentStep])
        completeAndAdvance()
    }

    private func chooseProjectCopyFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "사본 폴더 선택"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.setProjectCopyFolder(url.path)
    }
}

private struct StatusRow: View {
    let status: String
    let success: Bool
    var body: some View {
        Label(status, systemImage: success ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
            .foregroundStyle(success ? .green : .orange)
            .textSelection(.enabled)
    }
}

private enum SidebarItem: Hashable { case inbox, prRequest, agentHistory }

private struct InitialLoadingView: View {
    var body: some View {
        ContentUnavailableView {
            Label("PR 불러오는 중", systemImage: "arrow.triangle.2.circlepath")
        } description: {
            Text("등록된 저장소의 열린 PR과 리뷰를 확인하고 있습니다.")
        } actions: {
            ProgressView()
                .controlSize(.small)
        }
    }
}

private struct InboxView: View {
    @Bindable var store: ReviewStore

    var body: some View {
        List(selection: $store.selectedID) {
            Section {
                ForEach(store.pullRequests) { pullRequest in
                    PullRequestRow(pullRequest: pullRequest, isUnread: store.isUnread(pullRequest))
                        .tag(pullRequest.id)
                }
            } header: {
                HStack {
                    Text("리뷰 Inbox")
                    Spacer()
                    Text("\(store.unreadCount)개 확인 필요")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Inbox")
        .overlay {
            if store.repositories.isEmpty {
                ContentUnavailableView("등록된 저장소가 없습니다", systemImage: "folder.badge.plus", description: Text("툴바의 저장소 추가 버튼으로 로컬 GitHub 저장소를 등록하세요."))
            }
        }
        .overlay(alignment: .bottom) {
            Text("마지막 확인: \(store.lastRefreshed, format: .dateTime.hour().minute())")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(8)
        }
    }
}

private struct PullRequestRow: View {
    let pullRequest: PullRequest
    let isUnread: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(pullRequest.repository) #\(pullRequest.number)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if isUnread { UnreadDot() }
                Spacer()
                Text(pullRequest.reviewState.rawValue)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(pullRequest.reviewState.tint)
            }
            Text(pullRequest.title).font(.headline)
            HStack(spacing: 8) {
                Label(pullRequest.reviewer, systemImage: "person")
                Label("\(pullRequest.commentCount)", systemImage: "bubble.left")
                Text(pullRequest.analysisStatus.rawValue)
                    .foregroundStyle(pullRequest.analysisStatus.tint)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 5)
    }
}

private struct UnreadDot: View {
    var body: some View {
        Circle()
            .fill(.red)
            .frame(width: 8, height: 8)
            .accessibilityLabel("읽지 않은 항목")
    }
}
