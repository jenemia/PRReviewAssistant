import SwiftUI

/// Spec tab: lists each registered repository's spec documents and generates UnitTests from the chosen one.
struct SpecUnitTestView: View {
    @Bindable var store: ReviewStore
    @State private var groups: [SpecGroup] = []
    @State private var selection: SpecEntry.ID?
    @State private var isLoading = false

    private var selected: SpecEntry? { groups.lazy.flatMap(\.entries).first { $0.id == selection } }

    var body: some View {
        HSplitView {
            List(selection: $selection) {
                ForEach(groups) { group in
                    Section(group.repository.fullName) {
                        if group.entries.isEmpty {
                            Text("spec 문서가 없습니다").font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(group.entries) { entry in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.title).lineLimit(1)
                                Text([entry.status, entry.path].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            .tag(entry.id)
                        }
                    }
                }
            }
            .overlay {
                if isLoading && groups.isEmpty {
                    ProgressView()
                } else if groups.allSatisfy(\.entries.isEmpty) && !isLoading {
                    ContentUnavailableView("spec 문서가 없습니다", systemImage: "doc.text", description: Text("등록한 저장소의 specs/ 또는 .specs/ 아래 spec.md를 찾습니다."))
                }
            }
            .frame(minWidth: 300, idealWidth: 360, maxWidth: .infinity)

            Group {
                if let selected, let repository = store.repositories.first(where: { $0.id == selected.repository.id }) {
                    SpecUnitTestDetailView(store: store, entry: selected, repository: repository)
                } else {
                    ContentUnavailableView("spec 문서를 선택하세요", systemImage: "arrow.left", description: Text("선택한 spec의 규칙과 테스트 시나리오를 기대값 기준으로 UnitTest를 생성합니다."))
                }
            }
            .frame(minWidth: 460, idealWidth: 640, maxWidth: .infinity)
        }
        .navigationTitle("Spec")
        .toolbar {
            ToolbarItem {
                Button { Task { await load() } } label: { Label("spec 목록 새로 고침", systemImage: "doc.badge.arrow.up") }
                    .disabled(isLoading)
                    .help("spec 문서 목록 새로 고침")
            }
        }
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        let found = await store.specDocuments()
        groups = await Task.detached(priority: .userInitiated) {
            found.map { item in
                SpecGroup(repository: item.repository, entries: item.documents.map { document in
                    let header = SpecEntry.header(of: (item.repository.localPath as NSString).appendingPathComponent(document.relativePath))
                    return SpecEntry(repository: item.repository, path: document.relativePath, title: header.title ?? document.name, status: header.status)
                })
            }
        }.value
        if selection != nil, selected == nil { selection = nil }
    }
}

private struct SpecGroup: Identifiable {
    let repository: RegisteredRepository
    let entries: [SpecEntry]
    var id: UUID { repository.id }
}

struct SpecEntry: Identifiable, Hashable, Sendable {
    let repository: RegisteredRepository
    let path: String
    let title: String
    let status: String?
    var id: String { ReviewStore.specUnitTestID(repositoryID: repository.id, specPath: path) }

    /// First `# ` heading and `> 상태 …` line of the document, when present.
    nonisolated static func header(of file: String) -> (title: String?, status: String?) {
        guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { return (nil, nil) }
        let lines = text.split(whereSeparator: \.isNewline).prefix(20).map { $0.trimmingCharacters(in: .whitespaces) }
        let title = lines.first { $0.hasPrefix("# ") }.map { String($0.dropFirst(2)) }
        let status = lines.first { $0.hasPrefix("> 상태") }
            .map { String($0.dropFirst(1)).trimmingCharacters(in: .whitespaces) }
            .map { $0.split(separator: "·").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? $0 }
        return (title, status)
    }
}

private struct SpecUnitTestDetailView: View {
    @Bindable var store: ReviewStore
    let entry: SpecEntry
    let repository: RegisteredRepository
    @State private var text = ""
    @State private var showingConfirmation = false

    private var isRunning: Bool { store.verifyingSpecUnitTestIDs.contains(entry.id) }
    private var currentBranch: String? { store.checkedOutBranches[repository.id] }
    private var outputBranch: String? { currentBranch.map(UnitTestVerifier.unitTestBranchName(for:)) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.title).font(.title2.bold())
                    Text("\(repository.fullName) · \(entry.path)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }

                GroupBox("spec 기반 UnitTest 생성") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("이 spec의 규칙과 테스트 시나리오를 기대값으로 삼아 구현 소스의 NUnit 테스트를 Agent가 생성하고 `dotnet test`로 검증합니다. 브랜치 diff는 쓰지 않습니다. 통과한 테스트는 로컬 UnitTest 브랜치의 작업 트리에 커밋하지 않고 둡니다.")
                            .font(.caption).foregroundStyle(.secondary)
                        if let currentBranch, let outputBranch {
                            Text(currentBranch == outputBranch
                                 ? "현재 UnitTest 브랜치 \(outputBranch)에서 이어서 작업합니다."
                                 : "기준: 현재 브랜치 \(currentBranch) HEAD → 작업 브랜치 \(outputBranch)")
                                .font(.caption).textSelection(.enabled)
                        } else {
                            Text("등록 폴더의 현재 브랜치를 확인하지 못했습니다. 브랜치를 체크아웃한 상태에서 실행하세요.")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        HStack {
                            Button(isRunning ? "생성 중…" : "UnitTest 생성·검증", systemImage: "checkmark.shield") {
                                showingConfirmation = true
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(isRunning || store.isUnitTestBlocked(in: repository.id))
                            .help(store.isUnitTestBlocked(in: repository.id) && !isRunning ? "이 저장소에서 다른 UnitTest 또는 구현 작업이 진행 중입니다." : "spec 기준으로 UnitTest를 생성하고 검증합니다.")
                            if isRunning { ProgressView().controlSize(.small) }
                            Spacer()
                            if let result = store.specUnitTestResults[entry.id] { outcomeLabel(result) }
                        }
                        if let message = store.specUnitTestMessages[entry.id] {
                            Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        if let error = store.specUnitTestErrors[entry.id] {
                            Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                        }
                        if let result = store.specUnitTestResults[entry.id] {
                            if store.specUnitTestMessages[entry.id] == nil {
                                Text(result.summary).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            if !result.files.isEmpty { UnitTestFileResultsView(files: result.files) }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(4)
                }

                GroupBox("spec 본문") {
                    MarkdownContentView(text, nativeSelection: true).frame(maxWidth: .infinity, alignment: .leading).padding(4)
                }
            }
            .padding(20)
        }
        .task(id: entry.id) {
            let file = (repository.localPath as NSString).appendingPathComponent(entry.path)
            text = (try? String(contentsOfFile: file, encoding: .utf8)) ?? "spec 문서를 읽을 수 없습니다."
        }
        .confirmationDialog("spec 기준으로 UnitTest를 생성할까요?", isPresented: $showingConfirmation) {
            Button("생성·검증") { Task { await store.verifySpecUnitTests(repository: repository, specPath: entry.path) } }
            Button("취소", role: .cancel) {}
        } message: {
            Text("등록 폴더가 \(outputBranch ?? "UnitTest") 로컬 브랜치로 전환됩니다. 커밋하지 않은 추적 파일 변경은 stash로 보관했다가 다시 적용합니다. 커밋·푸시는 하지 않습니다.")
        }
        .alert(store.branchAgentPermissionRequest?.title ?? "에이전트 권한 요청", isPresented: Binding(
            get: { if case let .specUnitTest(path) = store.branchAgentPermissionRequest?.action { return path == entry.path && store.branchAgentPermissionRequest?.branch.repositoryID == repository.id } else { return false } },
            set: { presented in if !presented { store.cancelBranchAgentPermission() } }
        )) {
            Button("취소", role: .cancel) { store.cancelBranchAgentPermission() }
            Button(store.branchAgentPermissionRequest?.approvalTitle ?? "확인") { store.approveBranchAgentPermission() }
        } message: {
            Text(store.branchAgentPermissionRequest?.detail ?? "에이전트 권한 확인이 필요합니다.")
        }
    }

    private func outcomeLabel(_ result: UnitTestVerification) -> some View {
        let label: (String, String, Color) = switch result.outcome {
        case .failed: ("확인 필요", "xmark.octagon.fill", .red)
        case .passed: ("검증 통과", "checkmark.seal.fill", .green)
        case .notApplicable: ("대상 없음", "minus.circle.fill", .secondary)
        }
        return Label(label.0, systemImage: label.1).font(.caption.weight(.semibold)).foregroundStyle(label.2)
    }
}
