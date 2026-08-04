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

                Section("리뷰 Inbox") {
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
                    TextField("업데이트 배포 저장소 (owner/repository)", text: $store.updateRepository)
                    Text("GitHub Release를 올릴 저장소를 입력하세요. 비공개 저장소는 이 Mac의 GitHub CLI 로그인 계정에 읽기 권한이 있어야 합니다.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("새 버전 자동 확인", isOn: $store.updatesEnabled)
                    Text("앱이 실행 중이면 한국 시간 기준 매일 10:00, 13:00, 16:00, 19:00에 확인합니다.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("업데이트 확인", systemImage: "arrow.triangle.2.circlepath") {
                            Task { await store.checkForAppUpdate() }
                        }
                        .disabled(store.isCheckingForAppUpdate || !store.updateRepositoryIsValid)
                        if let release = store.latestAppRelease {
                            Button("GitHub Release 열기", systemImage: "arrow.up.forward.app") {
                                store.openLatestAppRelease()
                            }
                            .help("\(release.tagName) Release 페이지 열기")
                        }
                    }
                    if store.isCheckingForAppUpdate {
                        HStack(spacing: 6) { ProgressView(); Text("GitHub Release를 확인하는 중입니다.") }
                            .font(.caption).foregroundStyle(.secondary)
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

            AgentSettingsView(store: store)
                .tabItem { Label("LLM Agent", systemImage: "sparkles") }
        }
        .frame(width: 540, height: 420)
    }

}

private struct AgentSettingsView: View {
    @Bindable var store: ReviewStore

    var body: some View {
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
                    Text("Auto (Cursor 기본 선택)").tag("auto")
                    Text("GPT-5.3 Codex").tag("gpt-5.3-codex")
                    Text("GPT-5.3 Codex High").tag("gpt-5.3-codex-high")
                    Text("GPT-5.6 Sol High").tag("gpt-5.6-sol-high")
                    Text("Claude Sonnet 5 High").tag("claude-sonnet-5-high")
                    Text("Claude Opus 5 Thinking High").tag("claude-opus-5-thinking-high")
                }
                TextField("사용자 지정 모델 ID (선택)", text: $store.customAgentModel)
                    .font(.system(.body, design: .monospaced))
                Text(store.customAgentModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "선택한 모델이 plan 분석과 ask 대화 모두에 적용됩니다." : "사용자 지정 모델 ID가 선택값보다 우선 적용됩니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }

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
