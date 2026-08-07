import SwiftUI
import AppKit

struct ContentView: View {
    @Bindable var store: ReviewStore
    @State private var selection: SidebarItem? = .inbox
    @State private var cursorHistorySearch = ""

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
                    HStack(spacing: 7) {
                        Label("Inbox", systemImage: "tray.full")
                        if store.unreadCount > 0 { UnreadDot() }
                    }
                        .tag(SidebarItem.inbox)
                }
                Section("PR 요청") {
                    Label("PR 요청", systemImage: "arrow.up.right.square")
                        .tag(SidebarItem.prRequest)
                }
                Section("에이전트") {
                    Label("에이전트 기록", systemImage: "clock.arrow.circlepath")
                        .tag(SidebarItem.agentHistory)
                }
            }
            .navigationTitle("PR Review")
            .listStyle(.sidebar)
        } content: {
            if store.isInitialLoadInProgress {
                InitialLoadingView()
            } else if selection == .agentHistory {
                CursorSessionListView(store: store, searchText: $cursorHistorySearch)
            } else if selection == .prRequest, let branch = store.selectedBranch {
                // In PR-request mode the centre is the branch detail; the
                // branch picker deliberately remains in the right side view.
                BranchRequestDetailView(branch: branch, store: store)
            } else if selection == .prRequest {
                ContentUnavailableView("브랜치를 선택하세요", systemImage: "arrow.right")
            } else {
                InboxView(store: store)
            }
        } detail: {
            if store.isInitialLoadInProgress {
                InitialLoadingView()
            } else if selection == .agentHistory {
                CursorSessionDetailView(store: store)
            } else if selection == .prRequest {
                BranchRequestListView(store: store)
                    .frame(minWidth: 280, idealWidth: 340, maxWidth: 420)
            } else if let pullRequest = store.selectedPullRequest {
                PullRequestDetailView(pullRequest: pullRequest, store: store)
            } else {
                ContentUnavailableView("PR을 선택하세요", systemImage: "arrow.left")
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
                            await store.classifyUpdatedCursorSessions()
                        }
                    }
                    else if selection == .prRequest { store.loadRepositoryBranches() }
                    else { store.refresh() }
                } label: {
                    Label("새로 고침", systemImage: "arrow.clockwise")
                }
                .disabled(selection == .agentHistory ? store.isLoadingCursorHistory : (selection == .prRequest ? store.isLoadingBranches : store.isRefreshing))
                .help(selection == .agentHistory ? "Cursor 세션 기록 새로 고침" : (selection == .prRequest ? "브랜치 목록 새로 고침" : "새로 고침"))
            }
        }
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
