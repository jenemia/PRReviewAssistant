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
        .frame(width: 640, height: 520)
    }

}

private struct AgentSettingsView: View {
    @Bindable var store: ReviewStore

    var body: some View {
        ScrollView {
            Form {
                Section("기본 에이전트") {
                    ForEach(AgentProvider.allCases, id: \.self) { provider in
                        DefaultProviderRow(store: store, provider: provider)
                    }
                    Text("기능별 설정에서 '기본 따름'을 고르면 여기서 지정한 에이전트가 사용됩니다.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    ForEach(AgentProvider.allCases, id: \.self) { provider in
                        ProviderAgentFold(store: store, provider: provider)
                    }
                } header: {
                    Text("에이전트 연결 및 모델")
                }

                FeatureProviderSection(store: store)

                Section("에이전트 권한") {
                    Label("기본 분석은 읽기 전용 plan 모드로 실행됩니다.", systemImage: "eye")
                    Label("수정·테스트는 선택한 PR 작업 폴더에서만 수행됩니다.", systemImage: "folder.badge.gearshape")
                    Label("리뷰 코멘트는 실행 지시가 아닌 분석 데이터로만 전달됩니다.", systemImage: "checkmark.shield")
                }
            }
            .formStyle(.grouped)
        }
        .padding()
        .task { await store.checkCursorConnection() }
        .alert("Cursor 작업 공간 신뢰", isPresented: Binding(
            get: { store.modelCheckWorkspaceTrustRequest != nil },
            set: { if !$0 { store.modelCheckWorkspaceTrustRequest = nil } }
        )) {
            Button("취소", role: .cancel) { store.modelCheckWorkspaceTrustRequest = nil }
            Button("Terminal에서 연결", systemImage: "terminal") { store.startModelCheckWorkspaceTrust() }
            Button("신뢰 후 다시 확인") { store.retryModelCheckAfterWorkspaceTrust() }
        } message: {
            Text(store.modelCheckWorkspaceTrustRequest?.detail ?? "Cursor가 모델 확인용 폴더에 접근하려면 작업 공간을 신뢰해야 합니다. Terminal에서 신뢰를 승인한 뒤 다시 확인하세요.")
        }
    }
}

private struct DefaultProviderRow: View {
    @Bindable var store: ReviewStore
    let provider: AgentProvider

    var body: some View {
        Button {
            store.agentProvider = provider
        } label: {
            HStack {
                Image(systemName: store.agentProvider == provider ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(store.agentProvider == provider ? Color.accentColor : .secondary)
                Text(provider.featurePickerTitle)
                Spacer()
                Text(provider.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .disabled(!store.isAgentProviderEnabled(provider))
    }
}

/// One agent provider: connection, default model, and preset rows in a fold.
private struct ProviderAgentFold: View {
    @Bindable var store: ReviewStore
    let provider: AgentProvider
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ProviderConnectionSection(store: store, provider: provider)
            ProviderDefaultModelSection(store: store, provider: provider)
            ProviderModelListSection(store: store, provider: provider)
            ProviderFeatureModelSection(store: store, provider: provider)
        } label: {
            HStack {
                Toggle("", isOn: Binding(
                    get: { store.isAgentProviderEnabled(provider) },
                    set: { store.setAgentProvider(provider, enabled: $0) }
                ))
                .labelsHidden()
                .disabled(provider == store.agentProvider)
                .help(provider == store.agentProvider ? "기본 에이전트는 끌 수 없습니다. 다른 에이전트를 기본으로 지정한 뒤 끄세요." : "끄면 이 에이전트를 쓰던 기능은 기본 에이전트로 실행됩니다.")
                Text(provider.featurePickerTitle)
                    .fontWeight(.medium)
                if provider == store.agentProvider {
                    Text("*활성화중").font(.caption).foregroundStyle(.green)
                }
                Spacer()
                Text(store.effectiveAgentModel(for: provider).isEmpty ? "CLI 기본값" : store.effectiveAgentModel(for: provider))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .onAppear { if provider == store.agentProvider { isExpanded = true } }
    }
}

private struct ProviderConnectionSection: View {
    @Bindable var store: ReviewStore
    let provider: AgentProvider
    @State private var connection = AgentConnection(state: .unknown, detail: "CLI 연결 확인 중")
    @State private var checking = false

    var body: some View {
        Group {
            if provider == .cursor {
                HStack(spacing: 10) {
                    Image(systemName: cursorStatusSymbol)
                        .foregroundStyle(cursorStatusColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(cursorStatusTitle).fontWeight(.medium)
                        Text(store.cursorConnection.detail)
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Button("Cursor 로그인 진행", systemImage: "person.badge.key") {
                    store.startCursorLogin()
                }
                .disabled(store.cursorConnection.state != .needsLogin)
                Button("연결 상태 다시 확인", systemImage: "arrow.clockwise") {
                    Task { await store.checkCursorConnection() }
                }
                .disabled(store.isCheckingCursorConnection)
            } else {
                Text(connection.detail)
                    .font(.caption)
                Button("연결 상태 다시 확인", systemImage: "arrow.clockwise") {
                    Task { await refreshConnection() }
                }
                .disabled(checking)
                Button("Terminal에서 로그인", systemImage: "person.badge.key") {
                    loginInTerminal()
                }
                .disabled(checking || connection.state == .unavailable)
            }
        }
        .task(id: provider) {
            if provider != .cursor { await refreshConnection() }
        }
    }

    private var cursorStatusTitle: String {
        switch store.cursorConnection.state {
        case .connected: "연결됨"
        case .needsLogin, .needsWorkspaceTrust: "로그인 필요"
        case .unavailable: "Cursor CLI를 찾을 수 없음"
        case .failed: "LLM 연결 실패"
        case .unknown: "연결 확인 전"
        }
    }

    private var cursorStatusSymbol: String {
        switch store.cursorConnection.state {
        case .connected: "checkmark.circle.fill"
        case .needsLogin, .needsWorkspaceTrust: "person.crop.circle.badge.exclamationmark"
        case .unavailable: "exclamationmark.triangle.fill"
        case .failed: "wifi.exclamationmark"
        case .unknown: "questionmark.circle"
        }
    }

    private var cursorStatusColor: Color {
        switch store.cursorConnection.state {
        case .connected: .green
        case .needsLogin, .needsWorkspaceTrust: .orange
        case .unavailable, .failed: .red
        case .unknown: .secondary
        }
    }

    private func refreshConnection() async {
        guard !checking else { return }
        checking = true
        let provider = provider
        connection = await Task.detached(priority: .userInitiated) { provider.connection() }.value
        checking = false
    }

    private func loginInTerminal() {
        do {
            let command = ProcessRunner.terminalPathExport + "; " + ([provider.rawValue] + provider.loginArguments).joined(separator: " ")
            try ProcessRunner().launchInTerminal(command: command)
            connection = .init(state: .needsLogin, detail: "로그인을 마친 뒤 연결 상태를 다시 확인하세요.")
        } catch {
            connection = .init(state: .failed, detail: error.localizedDescription)
        }
    }
}

private struct ProviderDefaultModelSection: View {
    @Bindable var store: ReviewStore
    let provider: AgentProvider

    var body: some View {
        Text("기본 모델").font(.caption).foregroundStyle(.secondary)
        if provider != .cursor {
            DefaultModelRow(title: "CLI 기본값", modelID: "", isSelected: selectedModelID.isEmpty) {
                setModel("")
            }
        }
        ForEach(store.enabledModelPresets(for: provider), id: \.id) { preset in
            DefaultModelRow(title: preset.title, modelID: preset.id, isSelected: selectedModelID == preset.id) {
                setModel(preset.id)
            }
        }
        switch provider {
        case .cursor:
            TextField("사용자 지정 모델 ID (선택)", text: $store.customAgentModel)
                .font(.system(.body, design: .monospaced))
            Text(store.customAgentModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                 ? "목록에서 고른 모델이 이 에이전트의 기본으로 쓰입니다."
                 : "사용자 지정 모델 ID가 목록 선택보다 우선 적용됩니다.")
                .font(.caption).foregroundStyle(.secondary)
        case .codex:
            TextField("모델 ID 직접 입력", text: $store.codexModel)
                .font(.system(.body, design: .monospaced))
        case .claude:
            TextField("모델 ID 직접 입력", text: $store.claudeModel)
                .font(.system(.body, design: .monospaced))
            if store.claudeModel == "claude-opus-5-5" {
                Text("Opus 5.5를 사용하려면 Claude Code 2.1.280 이상이 필요합니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var selectedModelID: String {
        switch provider {
        case .cursor:
            let custom = store.customAgentModel.trimmingCharacters(in: .whitespacesAndNewlines)
            return custom.isEmpty ? store.agentModel : custom
        case .codex: return store.codexModel
        case .claude: return store.claudeModel
        }
    }

    private func setModel(_ id: String) {
        switch provider {
        case .cursor:
            store.customAgentModel = ""
            store.agentModel = id
        case .codex: store.codexModel = id
        case .claude: store.claudeModel = id
        }
    }
}

private struct DefaultModelRow: View {
    let title: String
    let modelID: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    if !modelID.isEmpty {
                        Text(modelID).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
        }
        .buttonStyle(.plain)
    }
}

/// Preset models for one provider: connection check and on/off toggle per row.
private struct ProviderModelListSection: View {
    @Bindable var store: ReviewStore
    let provider: AgentProvider

    var body: some View {
        HStack {
            Text("모델 연결 확인").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("켜진 모델 모두 확인") {
                Task { await store.checkEnabledAgentModels(provider: provider) }
            }
            .font(.caption)
        }
        ForEach(provider.modelPresets, id: \.id) { preset in
            ModelListRow(store: store, provider: provider, model: preset.id, title: preset.title)
        }
        Text("확인은 모델마다 짧은 질문을 한 번 보냅니다. Cursor에서 작업 공간 신뢰가 필요하면 안내 창과 Terminal 연결이 열립니다.")
            .font(.caption).foregroundStyle(.secondary)
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
                Label(checkLabel(check), systemImage: checkIcon(check))
                    .font(.caption)
                    .foregroundStyle(checkColor(check))
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: 180, alignment: .trailing)
                    .help(check.detail)
            }
            if store.agentModelChecks[key]?.state == .needsWorkspaceTrust {
                Button("신뢰 안내", systemImage: "terminal") {
                    store.modelCheckWorkspaceTrustRequest = .init(provider: provider, model: model, detail: store.agentModelChecks[key]?.detail ?? "")
                }
                .font(.caption)
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
            .help(inUse ? "이 에이전트의 기본 모델은 끌 수 없습니다." : "끄면 이 에이전트의 기본 모델 목록에서 숨깁니다.")
        }
    }

    private func checkIcon(_ check: AgentConnection) -> String {
        switch check.state {
        case .connected: "checkmark.circle.fill"
        case .needsWorkspaceTrust, .needsLogin: "person.crop.circle.badge.exclamationmark"
        default: "exclamationmark.triangle.fill"
        }
    }

    private func checkColor(_ check: AgentConnection) -> Color {
        switch check.state {
        case .connected: .green
        case .needsWorkspaceTrust, .needsLogin: .orange
        default: .red
        }
    }

    private func checkLabel(_ check: AgentConnection) -> String {
        switch check.state {
        case .needsWorkspaceTrust: "작업 공간 신뢰 필요"
        default: check.detail
        }
    }
}

/// Per-feature agent provider. Each provider's detailed model is set in its fold above.
private struct FeatureProviderSection: View {
    @Bindable var store: ReviewStore

    var body: some View {
        Section {
            ForEach(AgentFeature.Group.allCases, id: \.self) { group in
                FeatureProviderGroup(store: store, group: group)
            }
            Text("기능마다 Cursor·Claude 등 에이전트만 고릅니다. 카테고리 전체에 한 번에 적용하거나, 끄고 기능별로 지정할 수 있습니다. 상세 모델은 위 에이전트 접힘 안의 '기능별 모델'에서 지정합니다. 변경은 다음 실행부터 적용됩니다.")
                .font(.caption).foregroundStyle(.secondary)
        } header: {
            HStack {
                Text("기능별 에이전트")
                Spacer()
                Button("모두 기본으로") { store.agentFeatureProviders = [:] }
                    .disabled(store.agentFeatureProviders.isEmpty)
            }
        }
    }
}

/// One category: a single agent for every feature in it, or per-feature agents when that is turned off.
private struct FeatureProviderGroup: View {
    @Bindable var store: ReviewStore
    let group: AgentFeature.Group
    @State private var perFeature = false

    private var features: [AgentFeature] { AgentFeature.allCases.filter { $0.group == group } }
    private var overrides: Set<String> { Set(features.map { store.agentFeatureProviders[$0]?.rawValue ?? "" }) }

    private var groupSelection: Binding<String> {
        Binding(
            get: { overrides.count == 1 ? overrides.first! : "mixed" },
            set: { raw in
                for feature in features {
                    if let provider = AgentProvider(rawValue: raw) {
                        store.agentFeatureProviders[feature] = provider
                    } else {
                        store.agentFeatureProviders.removeValue(forKey: feature)
                    }
                }
            }
        )
    }

    var body: some View {
        Toggle(isOn: Binding(get: { !perFeature }, set: { perFeature = !$0 })) {
            Text("\(group.rawValue) 전체 적용").fontWeight(.medium)
        }
        if perFeature {
            ForEach(features, id: \.self) { feature in
                FeatureProviderRow(store: store, feature: feature)
            }
        } else {
            Picker("에이전트", selection: groupSelection) {
                if overrides.count > 1 { Text("기능별로 다름").tag("mixed") }
                Text("기본 따름 (\(store.agentProvider.featurePickerTitle))").tag("")
                ForEach(AgentProvider.allCases.filter { store.isAgentProviderEnabled($0) }, id: \.self) { provider in
                    Text(provider.featurePickerTitle).tag(provider.rawValue)
                }
            }
        }
    }
}

private struct FeatureProviderRow: View {
    @Bindable var store: ReviewStore
    let feature: AgentFeature

    private var selection: Binding<String> {
        Binding(
            get: {
                store.agentFeatureProviders[feature].flatMap { store.isAgentProviderEnabled($0) ? $0.rawValue : nil } ?? ""
            },
            set: { raw in
                if raw.isEmpty {
                    store.agentFeatureProviders.removeValue(forKey: feature)
                } else if let provider = AgentProvider(rawValue: raw) {
                    store.agentFeatureProviders[feature] = provider
                }
            }
        )
    }

    var body: some View {
        Picker(feature.title, selection: selection) {
            Text("기본 따름 (\(store.agentProvider.featurePickerTitle))").tag("")
            ForEach(AgentProvider.allCases.filter { store.isAgentProviderEnabled($0) }, id: \.self) { provider in
                Text(provider.featurePickerTitle).tag(provider.rawValue)
            }
        }
    }
}

/// Model overrides for the features that run on this agent. An empty override
/// follows the agent's default model.
private struct ProviderFeatureModelSection: View {
    @Bindable var store: ReviewStore
    let provider: AgentProvider

    var body: some View {
        let features = AgentFeature.allCases.filter { store.provider(for: $0) == provider }
        HStack {
            Text("기능별 모델").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("모두 기본으로") { store.agentFeatureModels[provider] = nil }
                .disabled(store.agentFeatureModels[provider]?.isEmpty ?? true)
        }
        if features.isEmpty {
            Text("이 에이전트를 쓰는 기능이 없습니다. 위 '기능별 에이전트'에서 지정하세요.")
                .font(.caption).foregroundStyle(.secondary)
        }
        ForEach(AgentFeature.Group.allCases, id: \.self) { group in
            ForEach(features.filter { $0.group == group }, id: \.self) { feature in
                FeatureModelRow(store: store, provider: provider, feature: feature)
            }
        }
        Text("바꾼 모델은 다음 실행부터 적용됩니다. 대화 중에 모델을 바꾸면 새 대화로 시작합니다.")
            .font(.caption).foregroundStyle(.secondary)
    }
}

private struct FeatureModelRow: View {
    @Bindable var store: ReviewStore
    let provider: AgentProvider
    let feature: AgentFeature
    @State private var isCustom = false

    private static let customTag = "\u{0}custom"

    private var override: String { store.agentFeatureModels[provider]?[feature] ?? "" }
    private var isPreset: Bool { store.enabledModelPresets(for: provider).contains { $0.id == override } }

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
        let defaultModel = store.effectiveAgentModel(for: provider)
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
