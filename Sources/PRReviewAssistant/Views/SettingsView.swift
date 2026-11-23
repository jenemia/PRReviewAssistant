import SwiftUI
import AppKit

struct SettingsView: View {
    @Bindable var store: ReviewStore
    @AppStorage("appearance") private var appearance = AppAppearance.defaultTheme.rawValue

    var body: some View {
        TabView {
            Form {
                Picker("모양", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { theme in
                        Text(theme.title).tag(theme.rawValue)
                    }
                }
                Text("기본은 macOS 시스템 외관을 따릅니다.")
                    .font(.caption).foregroundStyle(.secondary)

                Section("에이전트 세션 기록") {
                    Toggle("세션 기록 자동 분류", isOn: $store.automaticCursorSessionClassification)
                    Text("기본적으로 꺼져 있습니다. 켜면 새로 읽은 세션을 설정된 LLM으로 spec 문서에 자동 연결합니다.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("리뷰 Inbox") {
                    Toggle("새 리뷰 자동 검토", isOn: $store.automaticReviewAnalysis)
                    Text("기본적으로 켜져 있습니다. 새로 분류된 코멘트를 설정된 에이전트로 검토합니다. 다른 PR이 작업 중이면 전환 승인까지 대기합니다.")
                        .font(.caption).foregroundStyle(.secondary)
                    TextField("작업자 이름", text: $store.reviewAuthorFilter)
                    Text(store.authorFilterDescription)
                        .font(.caption).foregroundStyle(.secondary)
                    if let identity = store.githubIdentity {
                        Text("현재 GitHub 로그인: \(identity.login)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section("시작 안내") {
                    Button("첫 실행 안내 다시 열기", systemImage: "arrow.counterclockwise") {
                        store.restartOnboarding()
                    }
                    Text("Git, GitHub, 프로젝트 사본 폴더, LLM Agent, Git 계정을 다시 확인할 수 있습니다.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("앱 업데이트") {
                    Text("현재 버전 \(store.appVersionDescription)")
                        .foregroundStyle(.secondary)
                    Toggle("새 버전 자동 확인", isOn: $store.updatesEnabled)
                    Text("앱이 실행 중이면 한국 시간 기준 매일 10:00, 13:00, 16:00, 19:00에 확인합니다.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("업데이트 확인", systemImage: "arrow.triangle.2.circlepath") {
                            Task { await store.checkForAppUpdate() }
                        }
                        if store.hasAvailableAppUpdate, let release = store.latestAppRelease {
                            Button("업데이트 진행", systemImage: "arrow.down.circle") {
                                store.openLatestAppRelease()
                            }
                            .help("\(release.tagName) Release 페이지 열기")
                        }
                    }
                    if store.isCheckingForAppUpdate {
                        HStack(spacing: 6) { ProgressView(); Text("GitHub Release를 확인하는 중입니다.") }
                            .font(.caption).foregroundStyle(.secondary)
                    } else if !store.appUpdateStatus.isEmpty {
                        Text(store.appUpdateStatus)
                            .font(.caption)
                            .foregroundStyle(store.hasAvailableAppUpdate ? Color.accentColor : .secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .padding()
            .tabItem { Label("일반", systemImage: "gear") }

            Form {
                Toggle("리뷰 감시 활성화", isOn: $store.monitoringEnabled)
                Picker("확인 주기", selection: $store.monitoringInterval) {
                    Text("30초").tag(30)
                    Text("1분").tag(60)
                    Text("3분").tag(180)
                    Text("5분").tag(300)
                }
                Text("GitHub API 호출 제한을 고려해 변경되지 않은 항목은 다시 분석하지 않습니다.")
                    .font(.caption).foregroundStyle(.secondary)
                Label("GitHub 리뷰 감시와 알림은 LLM Agent 연결 없이도 동작합니다.", systemImage: "bell.and.waves.left.and.right")
                    .font(.caption).foregroundStyle(.secondary)

                Section("macOS 알림") {
                    LabeledContent("현재 상태") {
                        Text(store.notificationStatus)
                            .foregroundStyle(store.notificationStatus.hasPrefix("알림 허용") ? .green : .secondary)
                    }
                    Button("테스트 알림 보내기", systemImage: "bell.badge") {
                        Task { await store.sendTestNotification() }
                    }
                    Button("권한 상태 다시 확인", systemImage: "arrow.clockwise") {
                        Task { await store.refreshNotificationStatus() }
                    }
                    Button("시스템 알림 설정 열기", systemImage: "gear") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!)
                    }
                }
            }
            .formStyle(.grouped)
            .padding()
            .tabItem { Label("감시", systemImage: "bell") }

            Form {
                Toggle("데스크톱 펫 표시", isOn: $store.petVisible)
                Picker("펫 크기", selection: $store.petSize) {
                    Text("작게").tag(150.0)
                    Text("기본").tag(190.0)
                    Text("크게").tag(240.0)
                }
                Toggle("펫 모션 줄이기", isOn: $store.petReduceMotion)
                Text("펫은 다른 앱 위에 표시됩니다. 캐릭터를 드래그해 위치를 바꾸고, 말풍선을 누르면 최신 PR 제목을 확인할 수 있습니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .padding()
            .tabItem { Label("데스크톱 펫", systemImage: "figure.stand") }

            RepositoryManagementView(store: store)
                .tabItem { Label("저장소", systemImage: "folder") }

            AgentSettingsView(store: store)
                .tabItem { Label("LLM Agent", systemImage: "sparkles") }

            SkillSettingsView(store: store)
                .tabItem { Label("스킬", systemImage: "doc.text") }

            TeamRulesSettingsView(store: store)
                .tabItem { Label("팀 규칙", systemImage: "list.bullet.rectangle") }
        }
        .frame(width: 640, height: 460)
    }

}

private struct AgentSettingsView: View {
    @Bindable var store: ReviewStore

    var body: some View {
        VStack(spacing: 0) {
            Picker("에이전트", selection: $store.agentProvider) {
                ForEach(AgentProvider.allCases, id: \.self) { provider in
                    Text(provider.title).tag(provider)
                }
            }
            .padding()

            if store.agentProvider == .cursor {
                cursorSettings
            } else {
                ExternalAgentSettings(store: store, provider: store.agentProvider)
                    .id(store.agentProvider)
            }
        }
    }

    private var cursorSettings: some View {
        Form {
            Section("Cursor CLI") {
                HStack(spacing: 10) {
                    Image(systemName: statusSymbol)
                        .font(.title2)
                        .foregroundStyle(statusColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(statusTitle).fontWeight(.medium)
                        Text(store.cursorConnection.detail)
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .padding(.vertical, 4)

                LabeledContent("실행 명령") {
                    Text("cursor agent")
                        .font(.system(.body, design: .monospaced))
                }

                Button("Cursor 로그인 진행", systemImage: "person.badge.key") {
                    store.startCursorLogin()
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.cursorConnection.state != .needsLogin)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section("연결") {
                Button("연결 상태 다시 확인", systemImage: "arrow.clockwise") {
                    Task { await store.checkCursorConnection() }
                }
                .disabled(store.isCheckingCursorConnection)
                if store.cursorConnection.state == .needsLogin {
                    Text("로그인 필요 상태입니다. 버튼을 누르면 Terminal과 브라우저에서 Cursor 인증을 진행합니다. 인증을 마치고 같은 버튼을 다시 누르면 연결을 확인합니다.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if store.cursorConnection.state == .connected {
                    Text("연결된 Agent는 선택한 PR 작업 폴더의 ask 모드와 분석 모드에서 사용할 수 있습니다.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if store.cursorConnection.state == .failed {
                    Text("CLI는 설치되어 있습니다. 표시된 오류를 확인한 뒤 네트워크 또는 Cursor 서비스 상태를 점검하고 다시 시도하세요.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("상태를 확인한 뒤 설치 또는 로그인에 필요한 다음 단계를 안내합니다.")
                    .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("모델") {
                Picker("Cursor 모델", selection: $store.agentModel) {
                    ForEach(store.enabledModelPresets(for: .cursor), id: \.id) { preset in
                        Text(preset.title).tag(preset.id)
                    }
                }
                TextField("사용자 지정 모델 ID (선택)", text: $store.customAgentModel)
                    .font(.system(.body, design: .monospaced))
                Text(store.customAgentModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "선택한 모델이 plan 분석과 ask 대화 모두에 적용됩니다." : "사용자 지정 모델 ID가 선택값보다 우선 적용됩니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            ModelListSection(store: store)
            FeatureModelSection(store: store)

            Section("에이전트 권한") {
                Label("기본 분석은 읽기 전용 plan 모드로 실행됩니다.", systemImage: "eye")
                Label("수정·테스트는 선택한 PR 작업 폴더에서만 수행됩니다.", systemImage: "folder.badge.gearshape")
                Label("리뷰 코멘트는 실행 지시가 아닌 분석 데이터로만 전달됩니다.", systemImage: "checkmark.shield")
            }
        }
        .formStyle(.grouped)
        .padding()
        .task { await store.checkCursorConnection() }
    }

    private var statusTitle: String {
        switch store.cursorConnection.state {
        case .connected: "연결됨"
        case .needsLogin: "로그인 필요"
        case .unavailable: "Cursor CLI를 찾을 수 없음"
        case .failed: "LLM 연결 실패"
        case .unknown: "연결 확인 전"
        }
    }

    private var statusSymbol: String {
        switch store.cursorConnection.state {
        case .connected: "checkmark.circle.fill"
        case .needsLogin: "person.crop.circle.badge.exclamationmark"
        case .unavailable: "exclamationmark.triangle.fill"
        case .failed: "wifi.exclamationmark"
        case .unknown: "questionmark.circle"
        }
    }

    private var statusColor: Color {
        switch store.cursorConnection.state {
        case .connected: .green
        case .needsLogin: .orange
        case .unavailable: .red
        case .failed: .red
        case .unknown: .secondary
        }
    }

}

private struct ExternalAgentSettings: View {
    @Bindable var store: ReviewStore
    let provider: AgentProvider
    @State private var connection = AgentConnection(state: .unknown, detail: "CLI 연결 확인 중")
    @State private var checking = false

    var body: some View {
        Form {
            Section("\(provider.title) CLI") {
                Text(connection.detail)
                Button("연결 상태 다시 확인", systemImage: "arrow.clockwise") {
                    Task { await refreshConnection() }
                }
                .disabled(checking)
                Button("Terminal에서 로그인", systemImage: "person.badge.key") {
                    do {
                        let command = ProcessRunner.terminalPathExport + "; " + ([provider.rawValue] + provider.loginArguments).joined(separator: " ")
                        try ProcessRunner().launchInTerminal(command: command)
                        connection = .init(state: .needsLogin, detail: "로그인을 마친 뒤 연결 상태를 다시 확인하세요.")
                    } catch {
                        connection = .init(state: .failed, detail: error.localizedDescription)
                    }
                }
                .disabled(checking || connection.state == .unavailable)
            }
            Section("모델") {
                if provider == .codex {
                    Picker("Codex 모델", selection: $store.codexModel) {
                        Text("CLI 기본값").tag("")
                        ForEach(store.enabledModelPresets(for: provider), id: \.id) { preset in
                            Text(preset.title).tag(preset.id)
                        }
                        if store.codexModel != "" && !provider.modelPresets.contains(where: { $0.id == store.codexModel }) {
                            Text(store.codexModel).tag(store.codexModel)
                        }
                    }
                    TextField("모델 ID", text: $store.codexModel)
                } else {
                    Picker("Claude Code 모델", selection: $store.claudeModel) {
                        Text("CLI 기본값").tag("")
                        ForEach(store.enabledModelPresets(for: provider), id: \.id) { preset in
                            Text(preset.title).tag(preset.id)
                        }
                        if store.claudeModel != "" && !provider.modelPresets.contains(where: { $0.id == store.claudeModel }) {
                            Text(store.claudeModel).tag(store.claudeModel)
                        }
                    }
                    TextField("모델 ID", text: $store.claudeModel)
                    if store.claudeModel == "claude-opus-5-5" {
                        Text("Opus 5.5를 사용하려면 Claude Code 2.1.280 이상이 필요합니다.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            ModelListSection(store: store)
            FeatureModelSection(store: store)
        }
        .formStyle(.grouped)
        .padding()
        .task { await refreshConnection() }
    }

    private func refreshConnection() async {
        guard !checking else { return }
        checking = true
        let provider = provider
        connection = await Task.detached(priority: .userInitiated) { provider.connection() }.value
        checking = false
    }
}

/// The provider's preset models as rows, each with a connection check and an
/// on/off toggle. Turned-off models are hidden from the model pickers.
private struct ModelListSection: View {
    @Bindable var store: ReviewStore

    var body: some View {
        let provider = store.agentProvider
        Section {
            ForEach(provider.modelPresets, id: \.id) { preset in
                ModelListRow(store: store, provider: provider, model: preset.id, title: preset.title)
            }
            Text("연결 확인은 모델마다 짧은 질문을 한 번 보냅니다. 사용 중인 모델(기본 모델이나 기능별 모델로 선택된 모델)은 끌 수 없습니다.")
                .font(.caption).foregroundStyle(.secondary)
        } header: {
            HStack {
                Text("모델 목록 (\(provider.title))")
                Spacer()
                Button("사용 중인 모델 모두 확인") {
                    Task { await store.checkEnabledAgentModels(provider: provider) }
                }
            }
        }
    }
}

private struct ModelListRow: View {
    @Bindable var store: ReviewStore
    let provider: AgentProvider
    let model: String
    let title: String

    var body: some View {
        let key = ReviewStore.modelCheckKey(model, provider: provider)
        let checking = store.checkingAgentModels.contains(key)
        let inUse = store.isAgentModelInUse(model, provider: provider)
        let enabled = !(store.disabledAgentModels[provider]?.contains(model) ?? false)
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(model).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Spacer()
            if checking {
                ProgressView().controlSize(.small)
            } else if let check = store.agentModelChecks[key] {
                Label(check.detail, systemImage: check.state == .connected ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(check.state == .connected ? .green : .red)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: 180, alignment: .trailing)
                    .help(check.detail)
            }
            Button("확인") { Task { await store.checkAgentModel(model, provider: provider) } }
                .disabled(checking || !enabled)
            Toggle("사용", isOn: Binding(
                get: { enabled },
                set: { store.setAgentModel(model, provider: provider, enabled: $0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .disabled(inUse)
            .help(inUse ? "사용 중인 모델은 끌 수 없습니다." : "끄면 모델 선택 목록에서 숨깁니다.")
        }
    }
}

/// Per-feature model overrides for the current provider. An empty override
/// follows the provider's default model.
private struct FeatureModelSection: View {
    @Bindable var store: ReviewStore

    var body: some View {
        let provider = store.agentProvider
        Section {
            ForEach(AgentFeature.Group.allCases, id: \.self) { group in
                Text(group.rawValue).font(.caption).foregroundStyle(.secondary)
                ForEach(AgentFeature.allCases.filter { $0.group == group }, id: \.self) { feature in
                    FeatureModelRow(store: store, provider: provider, feature: feature)
                }
            }
            Text("바꾼 모델은 다음 실행부터 적용됩니다. 대화 중에 모델을 바꾸면 기존 대화를 잇지 않고 새 대화로 시작합니다.")
                .font(.caption).foregroundStyle(.secondary)
        } header: {
            HStack {
                Text("기능별 모델 (\(provider.title))")
                Spacer()
                Button("모두 기본으로") { store.agentFeatureModels[provider] = nil }
                    .disabled(store.agentFeatureModels[provider]?.isEmpty ?? true)
            }
        }
        .id(provider)
    }
}

private struct FeatureModelRow: View {
    @Bindable var store: ReviewStore
    let provider: AgentProvider
    let feature: AgentFeature
    @State private var isCustom = false

    private static let customTag = "\u{0}custom"

    private var override: String { store.agentFeatureModels[provider]?[feature] ?? "" }
    private var isPreset: Bool { provider.modelPresets.contains { $0.id == override } }

    private var overrideBinding: Binding<String> {
        Binding(
            get: { override },
            set: { store.agentFeatureModels[provider, default: [:]][feature] = $0.isEmpty ? nil : $0 }
        )
    }

    private var selection: Binding<String> {
        Binding(
            get: { isCustom ? Self.customTag : override },
            set: { value in
                isCustom = value == Self.customTag
                if !isCustom { overrideBinding.wrappedValue = value }
            }
        )
    }

    var body: some View {
        let defaultModel = store.effectiveAgentModel
        Picker(feature.title, selection: selection) {
            Text("기본 모델 따름 (\(defaultModel.isEmpty ? "CLI 기본값" : defaultModel))").tag("")
            ForEach(store.enabledModelPresets(for: provider), id: \.id) { preset in
                Text(preset.title).tag(preset.id)
            }
            Text("직접 입력…").tag(Self.customTag)
        }
        .onAppear { isCustom = !override.isEmpty && !isPreset }
        if isCustom {
            TextField("\(feature.title) 모델 ID", text: overrideBinding)
                .font(.system(.body, design: .monospaced))
        }
    }
}

/// Team conventions shared by all repositories: the review role files.
private struct TeamRulesSettingsView: View {
    @Bindable var store: ReviewStore

    var body: some View {
        Form {
            Section("부모 브랜치 규칙") {
                Text("부모 브랜치 규칙과 spec 폴더, 원격은 저장소마다 다릅니다. 설정 → 저장소에서 각 저장소의 ‘프로젝트 규칙’을 여세요.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("리뷰 역할 지침") {
                LabeledContent("폴더") {
                    Text(store.reviewRolesDirectoryURL.path).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                }
                HStack {
                    Button("폴더 선택…") { selectRolesDirectory() }
                    Button("기본 폴더로") { store.reviewRolesDirectory = "" }
                        .disabled(store.reviewRolesDirectory.isEmpty)
                }
                ForEach(ReviewWorkflow.defaultRoleGuidance.keys.sorted(), id: \.self) { role in
                    let file = store.reviewRolesDirectoryURL.appendingPathComponent("\(role).md")
                    let hasFile = !((try? String(contentsOf: file, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    LabeledContent(role) {
                        if hasFile {
                            Button("파일 열기") { NSWorkspace.shared.open(file) }
                        } else {
                            Text("기본 지침 사용").foregroundStyle(.secondary)
                        }
                    }
                }
                Text("역할별 리뷰가 폴더의 `<역할>.md`를 읽습니다. 파일이 없거나 비어 있으면 앱의 기본 지침을 씁니다. 다음 리뷰부터 적용됩니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func selectRolesDirectory() {
        let panel = NSOpenPanel()
        panel.title = "리뷰 역할 지침 폴더 선택"
        panel.message = "`<역할>.md` 파일이 들어 있는 폴더를 선택하세요."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = store.reviewRolesDirectoryURL
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.reviewRolesDirectory = url.path
    }
}
