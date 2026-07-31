import SwiftUI
import AppKit

/// The repository screen is reached from the main sidebar, not buried in app settings.
struct RepositoryManagementView: View {
    @Bindable var store: ReviewStore
    @State private var repositoryPendingRemoval: RegisteredRepository?

    var body: some View {
        List {
            Section {
                Button(action: chooseRepository) {
                    Label("저장소 추가", systemImage: "plus")
                }
                Button {
                    Task { await store.refresh() }
                } label: {
                    Label("모든 저장소 새로 고침", systemImage: "arrow.clockwise")
                }
                .disabled(store.isRefreshing || store.repositories.isEmpty)
            } header: {
                Text("저장소")
            } footer: {
                Text("GitHub 원격이 연결된 로컬 Git 작업 폴더만 등록됩니다.")
            }

            Section("로컬 연습 PR") {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "testtube.2")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("GitHub 없이 전체 흐름 연습")
                        Text("임시 Git 저장소와 리뷰 코멘트를 만들며, 마지막 푸시도 로컬에서만 처리됩니다.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if store.hasLocalPracticePullRequest {
                    Button("연습 PR과 임시 저장소 삭제", systemImage: "trash", role: .destructive) {
                        store.removeLocalPracticePullRequest()
                    }
                } else {
                    Button("연습 PR 만들기", systemImage: "plus") {
                        Task { await store.addLocalPracticePullRequest() }
                    }
                }
            }

            Section("등록된 저장소") {
                if store.repositories.isEmpty {
                    ContentUnavailableView("등록된 저장소가 없습니다", systemImage: "folder.badge.plus", description: Text("‘저장소 추가’에서 로컬 GitHub 저장소를 선택하세요."))
                } else {
                    ForEach($store.repositories) { $repository in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(repository.fullName)
                                    .font(.headline)
                                if repository.isLocalPractice == true {
                                    Text("LOCAL ONLY")
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(.orange)
                                }
                                Spacer()
                                Button("삭제", systemImage: "trash", role: .destructive) {
                                    if repository.isLocalPractice == true {
                                        store.removeLocalPracticePullRequest()
                                    } else {
                                        repositoryPendingRemoval = repository
                                    }
                                }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                            }
                            Text(repository.localPath)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                            if repository.isLocalPractice == true {
                                Label("GitHub API와 네트워크 푸시를 사용하지 않습니다.", systemImage: "checkmark.shield")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Toggle("PR 감시", isOn: $repository.monitoringEnabled)
                                    .onChange(of: repository.monitoringEnabled) { _, _ in
                                        store.repositoryMonitoringChanged()
                                    }
                            }
                        }
                        .padding(.vertical, 5)
                    }
                }
            }
        }
        .navigationTitle("저장소 관리")
        .confirmationDialog(
            "등록된 저장소를 삭제할까요?",
            isPresented: Binding(
                get: { repositoryPendingRemoval != nil },
                set: { if !$0 { repositoryPendingRemoval = nil } }
            ),
            presenting: repositoryPendingRemoval
        ) { repository in
            Button("등록 해제", role: .destructive) {
                store.removeRepository(repository)
                repositoryPendingRemoval = nil
            }
        } message: { repository in
            Text("\(repository.fullName)을 앱의 감시 목록에서 제거합니다. 원본 폴더와 Git 저장소, 작업 파일은 그대로 유지됩니다.")
        }
    }

    private func chooseRepository() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "저장소 등록"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await store.registerRepository(at: url.path) }
    }
}
