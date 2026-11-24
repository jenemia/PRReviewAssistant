import SwiftUI
import AppKit

/// Per-repository project rules. Opens right after a repository is registered and from the repository list.
/// Nothing is saved until the user presses Save.
struct RepositoryRulesView: View {
    @Bindable var store: ReviewStore
    let repositoryID: UUID
    @Environment(\.dismiss) private var dismiss

    @State private var rules = ""
    @State private var skillPath: String?
    @State private var specFolders = ""
    @State private var unitTestFolder = ""
    @State private var remote = ""
    @State private var remotes: [String] = []
    @State private var branches: [String] = []
    @State private var proposal: ParentBranchRuleProposal?
    @State private var isProposing = false
    @State private var errorMessage: String?

    private static let previewLimit = 40
    private var repository: RegisteredRepository? { store.repositories.first { $0.id == repositoryID } }

    /// Branches a rule matches come first so the effect of the rules is visible.
    private var previewBranches: [String] {
        let matched = branches.filter { ParentBranchRules.parent(of: $0, rules: rules) != nil }
        return Array((matched + branches.filter { !matched.contains($0) }).prefix(Self.previewLimit))
    }

    var body: some View {
        VStack(spacing: 0) {
            if let repository {
                Form {
                    Section {
                        Text(repository.fullName).font(.headline)
                        Text(repository.localPath).font(.caption.monospaced()).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    }
                    if repository.isLocalPractice != true {
                        remoteSection
                    }
                    rulesSection(repository)
                    previewSection(repository)
                    Section("spec 폴더") {
                        TextField("폴더 이름(쉼표로 구분)", text: $specFolders)
                        Text("Spec 탭이 이 이름의 폴더 아래 spec.md를 찾습니다. 브랜치 UnitTest도 이 폴더에서 브랜치가 바꾼 spec을 찾습니다. 비우면 기본값 specs, .specs를 씁니다.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Section("UnitTest 폴더") {
                        TextField("저장소 기준 경로", text: $unitTestFolder, prompt: Text("예: unity_project/devil_hunter_idle/Assets/Supercent/TestCase/Editor"))
                        Text("생성한 UnitTest를 이 폴더에 둡니다. 비우면 비슷한 소스 옆의 Tests 폴더를 씁니다. Unity는 Editor 폴더나 테스트 asmdef 안이어야 Test Runner가 읽습니다.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)
                Divider()
                HStack {
                    Spacer()
                    Button("취소") { dismiss() }
                    Button("저장") { save(repository) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(isProposing)
                }
                .padding(12)
            } else {
                ContentUnavailableView("저장소를 찾을 수 없습니다", systemImage: "folder.badge.questionmark")
            }
        }
        // Fits inside the 640×460 Settings window; the form scrolls.
        .frame(width: 600, height: 440)
        .task { await load() }
    }

    private var remoteSection: some View {
        Section("원격") {
            Picker("사용할 원격", selection: $remote) {
                ForEach(remotes, id: \.self) { Text($0).tag($0) }
            }
            Text("PR 브랜치를 가져오고 푸시하는 원격입니다. 감시할 GitHub 저장소도 이 원격의 URL에서 읽습니다. PR 브랜치가 이 원격에 있어야 하므로, fork의 브랜치로 원본 저장소에 PR을 여는 흐름은 아직 지원하지 않습니다.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func rulesSection(_ repository: RegisteredRepository) -> some View {
        Section("부모 브랜치 규칙") {
            HStack {
                Button("스킬로 규칙 정의…", systemImage: "doc.text.magnifyingglass") { chooseSkill(repository) }
                    .disabled(isProposing)
                if isProposing {
                    ProgressView().controlSize(.small)
                    Text("에이전트가 스킬을 읽는 중").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let skillPath {
                Text("근거 스킬: \(skillPath)").font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            }
            if store.hasChangedRuleSkill(repository) {
                Label("규칙을 저장한 뒤 스킬 파일이 바뀌었습니다. 다시 정의해 확인하세요.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            if let proposal {
                if !proposal.evidence.isEmpty {
                    DisclosureGroup("스킬 근거 \(proposal.evidence.count)개") {
                        ForEach(proposal.evidence, id: \.self) { Text($0).font(.caption).textSelection(.enabled) }
                    }
                }
                if !proposal.unsupported.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("규칙으로 옮기지 못한 내용입니다. 이런 브랜치는 저장소 기본 브랜치와 비교합니다.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        ForEach(proposal.unsupported, id: \.self) { Text("· \($0)").textSelection(.enabled) }
                    }
                    .font(.caption)
                }
            }
            TextEditor(text: $rules)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 70)
            Text("한 줄에 `head 패턴 -> 부모 브랜치`. 위에서부터 처음 맞는 줄을 씁니다. `*`는 경로 한 칸(`$1`, `$2`로 사용), 끝의 `**`는 나머지 경로입니다. 맞는 줄이 없으면 저장소 기본 브랜치를 씁니다. 예: `sprint/*/** -> sprint/$1/main`")
                .font(.caption).foregroundStyle(.secondary)
            let invalid = ParentBranchRules.invalidLines(rules)
            if !invalid.isEmpty {
                Label("형식이 맞지 않아 무시하는 줄: \(invalid.joined(separator: ", "))", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func previewSection(_ repository: RegisteredRepository) -> some View {
        Section("미리보기 (원격 브랜치 → 비교·머지 기준)") {
            if branches.isEmpty {
                Text("가져온 원격 브랜치가 없습니다.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(previewBranches, id: \.self) { name in
                LabeledContent(name) {
                    if let parent = ParentBranchRules.parent(of: name, rules: rules) {
                        Text(parent)
                    } else {
                        Text("\(repository.defaultBranch) (기본)").foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
            }
            if branches.count > Self.previewLimit {
                Text("외 \(branches.count - Self.previewLimit)개").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func load() async {
        guard let repository else { return }
        rules = repository.effectiveParentBranchRules
        skillPath = repository.parentBranchRuleSkillPath
        specFolders = repository.effectiveSpecFolders.joined(separator: ", ")
        unitTestFolder = repository.unitTestFolder ?? ""
        remote = repository.remoteName
        remotes = await store.remoteNames(of: repository)
        if !remotes.contains(remote) { remotes.insert(remote, at: 0) }
        branches = await store.branchNames(of: repository)
    }

    private func chooseSkill(_ repository: RegisteredRepository) {
        let panel = NSOpenPanel()
        panel.title = "브랜치 규칙 스킬 선택"
        panel.message = "브랜치·PR base 규칙이 적힌 Markdown 파일 또는 SKILL.md가 들어 있는 폴더를 선택하세요."
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: repository.localPath)
        guard panel.runModal() == .OK, let selected = panel.url else { return }
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: selected.path, isDirectory: &isDirectory)
        let file = isDirectory.boolValue ? selected.appendingPathComponent("SKILL.md") : selected
        guard FileManager.default.isReadableFile(atPath: file.path) else {
            errorMessage = "읽을 수 있는 파일을 선택하거나 SKILL.md가 들어 있는 폴더를 선택하세요."
            return
        }
        errorMessage = nil
        isProposing = true
        Task {
            defer { isProposing = false }
            do {
                let result = try await store.proposeParentBranchRules(for: repository, skillPath: file.path)
                proposal = result
                rules = result.rules
                skillPath = file.path
            } catch {
                errorMessage = "규칙을 만들지 못했습니다: \(error.localizedDescription)"
            }
        }
    }

    private func save(_ repository: RegisteredRepository) {
        var updated = repository
        let folders = specFolders.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        updated.specFolders = folders.isEmpty || folders == WorkspaceSpecCatalog.defaultFolders ? nil : folders
        let testFolder = unitTestFolder.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "/")))
        guard !testFolder.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) else {
            errorMessage = "UnitTest 폴더는 저장소 안의 경로여야 합니다."
            return
        }
        updated.unitTestFolder = testFolder.isEmpty ? nil : testFolder
        store.updateRepository(updated)
        store.saveParentBranchRules(rules, for: repositoryID, skillPath: skillPath)
        if remote != repository.remoteName {
            let id = repositoryID, remote = remote
            Task { await store.changeRemote(of: id, to: remote) }
        }
        dismiss()
    }
}
