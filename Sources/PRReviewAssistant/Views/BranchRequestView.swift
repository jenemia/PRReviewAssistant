import SwiftUI

struct BranchRequestListView: View {
    @Bindable var store: ReviewStore
    @State private var showingBranchPicker = false

    var body: some View {
        List(selection: $store.selectedBranchID) {
            ForEach(Dictionary(grouping: store.requestedBranches, by: \.repositoryName).sorted(by: { $0.key < $1.key }), id: \.key) { repository, branches in
                Section(repository) {
                    ForEach(branches) { branch in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(branch.name).font(.body.weight(.medium))
                                if branch.isCurrent { Text("현재").font(.caption2.weight(.semibold)).padding(.horizontal, 5).padding(.vertical, 2).background(.green.opacity(0.15), in: Capsule()).foregroundStyle(.green) }
                            }
                            Text("\(branch.sha) · \(branch.subject.isEmpty ? "커밋 메시지 없음" : branch.subject)")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .tag(branch.id)
                        .contextMenu {
                            Button("PR 요청 삭제", systemImage: "trash", role: .destructive) {
                                store.removeRequestedBranch(branch)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("PR 요청")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("브랜치 추가", systemImage: "plus") {
                    showingBranchPicker = true
                }
                .help("origin 브랜치를 PR 요청 목록에 추가")
            }
        }
        .sheet(isPresented: $showingBranchPicker) {
            BranchPickerSheet(store: store)
        }
        .overlay {
            if store.isLoadingBranches { ProgressView("origin 브랜치 불러오는 중") }
            else if store.requestedBranches.isEmpty { ContentUnavailableView("PR 요청 브랜치가 없습니다", systemImage: "point.3.connected.trianglepath.dotted", description: Text("오른쪽 위 + 버튼으로 origin 브랜치를 추가하세요.")) }
        }
        .task { await store.loadRepositoryBranches() }
    }
}

struct BranchPickerSheet: View {
    @Bindable var store: ReviewStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var candidates: [RepositoryBranch] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let branches = store.repositoryBranches
        guard !text.isEmpty else { return Array(branches.prefix(30)) }
        return branches.filter {
            $0.name.localizedCaseInsensitiveContains(text) ||
            $0.repositoryName.localizedCaseInsensitiveContains(text)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("PR 요청 브랜치 추가").font(.title2.bold())
                    Text("origin의 브랜치를 입력해 찾고 목록에 추가하세요.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("닫기", systemImage: "xmark") { dismiss() }
                    .buttonStyle(.borderless)
            }

            TextField("브랜치 이름 입력", text: $query)
                .textFieldStyle(.roundedBorder)
                .onChange(of: query) { _, _ in
                    // Filtering is immediate, so every keystroke updates the
                    // autocomplete candidates without another network call.
                }

            List(candidates) { branch in
                Button {
                    store.addRequestedBranch(branch)
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(branch.name).font(.body.weight(.medium))
                            if branch.isCurrent {
                                Text("현재")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.green)
                            }
                        }
                        Text("\(branch.repositoryName) · \(branch.sha)")
                            .font(.caption).foregroundStyle(.secondary)
                        if !branch.subject.isEmpty {
                            Text(branch.subject).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .overlay {
                if store.isLoadingBranches && candidates.isEmpty {
                    ProgressView("origin 브랜치 불러오는 중")
                } else if candidates.isEmpty {
                    ContentUnavailableView(
                        query.isEmpty ? "origin 브랜치가 없습니다" : "일치하는 origin 브랜치가 없습니다",
                        systemImage: query.isEmpty ? "point.3.connected.trianglepath.dotted" : "magnifyingglass"
                    )
                }
            }

            if store.repositoryBranches.isEmpty, !store.isLoadingBranches, store.statusMessage.contains("불러오지 못했습니다") {
                Text(store.statusMessage).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }

            HStack {
                Text("입력할 때마다 origin 브랜치 후보가 자동완성됩니다.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("origin 새로 고침", systemImage: "arrow.clockwise") {
                    Task { await store.loadRepositoryBranches() }
                }
                .disabled(store.isLoadingBranches)
                Button("취소", role: .cancel) { dismiss() }
            }
        }
        .padding(24)
        .frame(width: 560, height: 520)
        .task { await store.loadRepositoryBranches() }
    }
}

struct BranchRequestDetailView: View {
    let branch: RepositoryBranch
    @Bindable var store: ReviewStore
    @State private var selectedCardID: BranchReviewCard.ID?
    @State private var showingRequestSheet = false
    @State private var showingQuizSheet = false
    @State private var showingUnitTestConfirmation = false
    @State private var showingUnitTestWarning = false
    @State private var showingUnitTestBranchPicker = false

    private var cards: [BranchReviewCard] { store.branchCards(for: branch) }
    private var unitTestResult: UnitTestVerification? { store.branchUnitTestResults[branch.id] }
    private var isVerifyingUnitTests: Bool { store.isVerifyingUnitTests(for: branch) }

    private var unitTestWarningMessage: String {
        guard let result = unitTestResult else { return "UnitTest 검증을 아직 실행하지 않았습니다." }
        if result.outcome == .failed { return "UnitTest 검증이 실패했습니다. \(result.summary)" }
        return "UnitTest 검증 이후 브랜치에 새 커밋이 있어 결과가 현재 코드와 맞지 않습니다."
    }
    private var isClear: Bool { !cards.isEmpty && cards.allSatisfy { $0.isReference || $0.category == .passed } }

    var body: some View {
        Group {
            if let card = cards.first(where: { $0.id == selectedCardID }) {
                HSplitView {
                    detailContent
                    BranchAgentSidePanel(card: card, branch: branch, store: store) { selectedCardID = nil }
                        .id(card.id)
                        .frame(minWidth: 330, idealWidth: 430, maxWidth: .infinity)
                }
            } else {
                detailContent
            }
        }
        .navigationTitle("PR 요청")
        .sheet(isPresented: $showingRequestSheet) {
            PullRequestRequestSheet(branch: branch, store: store, isPresented: $showingRequestSheet)
        }
        .sheet(isPresented: $showingQuizSheet) {
            BranchQuizSheet(branch: branch, store: store)
        }
        .sheet(isPresented: $showingUnitTestBranchPicker) {
            UnitTestBranchPickerSheet(store: store)
        }
        .alert("UnitTest 생성·검증을 시작할까요?", isPresented: $showingUnitTestConfirmation) {
            Button("취소", role: .cancel) {}
            Button("시작") { Task { await store.verifyUnitTests(for: branch) } }
        } message: {
            Text("등록 폴더를 \(UnitTestVerifier.unitTestBranchName(for: branch.name)) 로컬 브랜치로 전환합니다. 통과한 테스트 파일은 커밋하지 않고 작업 트리에 둡니다. 커밋하지 않은 변경이 있으면 전환하지 않습니다.")
        }
        .alert("UnitTest 검증이 통과되지 않았습니다", isPresented: $showingUnitTestWarning) {
            Button("취소", role: .cancel) {}
            Button("그래도 PR 요청", role: .destructive) { showingRequestSheet = true }
        } message: {
            Text("\(unitTestWarningMessage)\n그래도 PR을 요청할까요?")
        }
        .alert(store.branchAgentPermissionRequest?.title ?? "에이전트 권한 요청", isPresented: Binding(
            get: { store.branchAgentPermissionRequest?.branch.id == branch.id },
            set: { presented in if !presented { store.cancelBranchAgentPermission() } }
        )) {
            Button("취소", role: .cancel) { store.cancelBranchAgentPermission() }
            Button(store.branchAgentPermissionRequest?.approvalTitle ?? "확인") { store.approveBranchAgentPermission() }
        } message: {
            Text(branchPermissionMessage)
        }
        .onChange(of: branch.id) { _, _ in selectedCardID = nil }
    }

    private var detailContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("브랜치 정보") {
                    VStack(alignment: .leading, spacing: 9) {
                        HStack(alignment: .top) {
                            Text(branch.name).font(.title3.bold()).textSelection(.enabled)
                            Spacer()
                            Button("PR 요청 삭제", systemImage: "trash", role: .destructive) {
                                store.removeRequestedBranch(branch)
                            }
                            .help("앱의 요청 목록에서 삭제합니다. 원격 브랜치와 GitHub PR은 유지됩니다.")
                        }
                        LabeledContent("저장소", value: branch.repositoryName)
                        LabeledContent("PR 기준 브랜치", value: requestProposal?.base ?? "Agent가 프로젝트 스킬로 확인")
                        LabeledContent("HEAD", value: branch.sha)
                        if !branch.subject.isEmpty { LabeledContent("최근 커밋", value: branch.subject) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(4)
                }

                GroupBox("리뷰하기") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("`.cursor`와 저장소 하위의 `SKILL.md`/`AGENTS.md`에서 code review 지침을 찾아, 이 브랜치를 읽기 전용으로 검토합니다.")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button(store.isReviewingBranch ? "리뷰 중…" : "리뷰 시작", systemImage: "sparkles") {
                                Task { await store.reviewSelectedBranch() }
                            }
                            .buttonStyle(.borderedProminent).disabled(store.isReviewingBranch || store.implementingBranchRepositoryIDs.contains(branch.repositoryID) || cards.contains(where: { store.branchCardBusy.contains($0.id) }))
                            if store.reviewingBranchID == branch.id {
                                Button("취소", action: store.cancelBranchReview)
                            }
                            Spacer()
                            if !cards.isEmpty { Text("리뷰 항목 \(cards.filter { !$0.isReference }.count)개").font(.caption).foregroundStyle(.secondary) }
                        }
                        if let message = store.branchReviewMessages[branch.id] {
                            Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        if !cards.isEmpty {
                            ForEach(BranchReviewCategory.allCases, id: \.self) { category in
                                let items = cards.filter { $0.category == category }
                                if !items.isEmpty {
                                    BranchReviewCategoryView(category: category, items: items, selectedCardID: $selectedCardID)
                                }
                            }
                        } else {
                            Text("리뷰를 시작하면 위험도별 항목이 표시됩니다. 항목을 선택해 개별 검토를 시작할 수 있습니다.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(4)
                }

                GroupBox("작업영역") {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("PR 리뷰 대응과 같은 작업영역입니다.", systemImage: "archivebox")
                        Text("리뷰 카드에서 확인한 사항을 반영할 때는 해당 브랜치의 작업 위치와 변경 범위를 확인한 뒤 진행합니다. 이 화면의 리뷰는 코드를 수정하지 않습니다.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
                }

                GroupBox("UnitTest 검증") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("변경된 C# 파일 중 테스트가 없는 순수 로직의 NUnit 테스트를 Agent가 생성하고 `dotnet test`로 검증합니다. 통과한 테스트는 로컬 UnitTest 브랜치의 작업 트리에 커밋하지 않고 둡니다.")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button(isVerifyingUnitTests ? "검증 중…" : "UnitTest 생성·검증", systemImage: "checkmark.shield") {
                                showingUnitTestConfirmation = true
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(isVerifyingUnitTests || store.implementingBranchRepositoryIDs.contains(branch.repositoryID))
                            .help("UnitTest를 생성하고 검증합니다.")
                            Button("다른 브랜치 선택") { showingUnitTestBranchPicker = true }
                            if isVerifyingUnitTests { ProgressView().controlSize(.small) }
                            Spacer()
                            if let result = unitTestResult { UnitTestBadge(result: result, isCurrent: store.isUnitTestPassed(for: branch)) }
                        }
                        if let message = store.branchUnitTestMessages[branch.id] {
                            Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        if let error = store.branchUnitTestErrors[branch.id] {
                            Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                        }
                        if let result = unitTestResult, !result.files.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(result.files) { file in
                                    DisclosureGroup {
                                        if let rules = file.rules, !rules.isEmpty {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text("추출한 비즈니스 규칙").font(.caption.bold())
                                                ForEach(rules, id: \.self) { Text($0).font(.caption) }
                                            }
                                            .textSelection(.enabled)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                        Text(file.detail).font(.caption.monospaced()).textSelection(.enabled)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    } label: {
                                        HStack(spacing: 6) {
                                            Image(systemName: file.status == .passed ? "checkmark.circle.fill" : (file.status == .failed ? "xmark.octagon.fill" : "minus.circle"))
                                                .foregroundStyle(file.status == .passed ? .green : (file.status == .failed ? .red : .secondary))
                                            Text(file.sourcePath).font(.caption).lineLimit(1).truncationMode(.middle)
                                            if let test = file.testPath { Text("→ \(test)").font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                                        }
                                    }
                                }
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
                }

                GroupBox("PR 요청하기") {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(
                            cards.isEmpty
                                ? "내부 리뷰 없이 PR을 요청할 수 있습니다."
                                : (isClear ? "내부 리뷰에서 특이사항이 확인되지 않았습니다." : "내부 리뷰 결과와 관계없이 PR을 요청할 수 있습니다."),
                            systemImage: cards.isEmpty ? "arrow.up.right.square" : (isClear ? "checkmark.seal.fill" : "arrow.up.right.square")
                        )
                            .foregroundStyle(isClear ? .green : .secondary)
                        Text("Agent가 저장소의 PR 생성 스킬을 읽기 전용으로 적용해 base·리뷰어·제목·본문을 준비합니다. 앱이 Git 이력과 원격 SHA를 검증한 뒤에만 PR을 생성합니다.")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("(선택적) 퀴즈", systemImage: "questionmark.circle") { showingQuizSheet = true }
                                .buttonStyle(.bordered)
                                .disabled(cards.isEmpty)
                                .help("PR의 핵심 기능과 흐름을 확인하는 5문제 퀴즈")
                            Spacer()
                            Button("PR 요청하기", systemImage: "arrow.up.right.square") {
                                if store.isUnitTestPassed(for: branch) { showingRequestSheet = true } else { showingUnitTestWarning = true }
                            }.buttonStyle(.borderedProminent)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
                }
            }
            .padding(20).frame(maxWidth: 900, alignment: .leading)
        }
    }

    private var repository: RegisteredRepository? { store.repositories.first { $0.id == branch.repositoryID } }
    private var requestProposal: PullRequestProposal? { store.pullRequestProposal(for: branch) }

    private var branchPermissionMessage: String {
        guard let request = store.branchAgentPermissionRequest else { return "에이전트 권한 확인이 필요합니다." }
        switch request.kind {
        case .workspaceTrust:
            return "Cursor Agent가 이 저장소의 코드를 읽으려면 작업 공간 신뢰가 필요합니다. 승인하면 이 브랜치의 현재 요청만 읽기 전용으로 다시 시도합니다. 수정·테스트·푸시는 실행되지 않습니다."
        case .cursorLogin:
            return "Cursor Agent 로그인이 필요합니다. 승인하면 Terminal과 브라우저에서 Cursor 인증을 시작합니다. 인증 후 브랜치 요청을 다시 시도하세요."
        case .other:
            return "Cursor Agent가 추가 권한을 요청했습니다. 앱은 범위를 알 수 없는 권한을 자동 허용하지 않습니다. Cursor에서 요청 내용을 확인하고 승인하세요.\n\n\(request.detail)"
        }
    }
}

struct UnitTestBranchPickerSheet: View {
    @Bindable var store: ReviewStore
    @Environment(\.dismiss) private var dismiss
    @State private var localBranches: [RepositoryBranch] = []
    @State private var selected: RepositoryBranch?
    @State private var query = ""

    private var branches: [RepositoryBranch] {
        (localBranches + store.repositoryBranches).filter {
            query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.repositoryName.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("UnitTest 대상 브랜치").font(.title2.bold())
            Text("로컬 또는 원격 브랜치를 선택하세요. 통과한 테스트는 선택한 커밋에서 만든 로컬 UnitTest 브랜치에 커밋하지 않고 둡니다.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("브랜치 또는 저장소 검색", text: $query).textFieldStyle(.roundedBorder)
            List(Array(branches.enumerated()), id: \.offset) { _, branch in
                Button {
                    if !store.isVerifyingUnitTests(for: branch) {
                        store.branchUnitTestMessages[branch.id] = nil
                        store.branchUnitTestErrors[branch.id] = nil
                    }
                    selected = branch
                } label: {
                    VStack(alignment: .leading) {
                        Text("\(branch.name) · \(branch.isRemote ? "원격" : "로컬")")
                        Text("\(branch.repositoryName) · \(branch.sha)").font(.caption).foregroundStyle(.secondary)
                    }
                }.buttonStyle(.plain)
            }
            if let selected {
                Text("선택: \(selected.name) (\(selected.isRemote ? "원격" : "로컬"))").font(.caption)
                if let message = store.branchUnitTestMessages[selected.id] {
                    HStack(spacing: 6) {
                        if store.isVerifyingUnitTests(for: selected) { ProgressView().controlSize(.small) }
                        Text(message).font(.caption).textSelection(.enabled)
                    }
                }
                if let error = store.branchUnitTestErrors[selected.id] { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                if let result = store.branchUnitTestResults[selected.id], result.verifiedSHA.hasPrefix(selected.sha) {
                    Text(result.summary).font(.caption).textSelection(.enabled)
                }
            }
            HStack {
                Spacer()
                Button("닫기") { dismiss() }
                Button(selected.map { store.isVerifyingUnitTests(for: $0) } == true ? "검증 중…" : "생성·검증") {
                    if let selected { Task { await store.verifyUnitTests(for: selected) } }
                }
                .disabled(selected == nil || selected.map { store.isVerifyingUnitTests(for: $0) || store.implementingBranchRepositoryIDs.contains($0.repositoryID) } == true)
            }
        }
        .padding(24).frame(width: 600, height: 560)
        .task {
            async let locals = store.localUnitTestBranches()
            await store.loadRepositoryBranches()
            localBranches = await locals
        }
    }
}

private struct UnitTestBadge: View {
    let result: UnitTestVerification
    let isCurrent: Bool

    private var label: (text: String, symbol: String, tint: Color) {
        switch result.outcome {
        case .failed: ("검증 실패", "xmark.octagon.fill", .red)
        case .passed where isCurrent: ("검증 통과", "checkmark.seal.fill", .green)
        case .notApplicable where isCurrent: ("대상 없음", "minus.circle.fill", .secondary)
        default: ("결과가 오래됨", "exclamationmark.triangle.fill", .orange)
        }
    }

    var body: some View {
        Label(label.text, systemImage: label.symbol).font(.caption.weight(.semibold)).foregroundStyle(label.tint)
    }
}

private struct BranchReviewCategoryView: View {
    let category: BranchReviewCategory
    let items: [BranchReviewCard]
    @Binding var selectedCardID: BranchReviewCard.ID?
    @State private var isExpanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(items) { card in
                    if card.details == BranchReviewCard.noFindings {
                        Text(card.details).font(.caption).foregroundStyle(.secondary)
                    } else {
                        Button { selectedCardID = card.id } label: {
                            HStack {
                                Text(card.title).frame(maxWidth: .infinity, alignment: .leading)
                                Image(systemName: "chevron.right").foregroundStyle(.secondary)
                            }
                            .padding(8)
                            .background(selectedCardID == card.id ? BrandColor.prPurple.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.top, 4)
        } label: {
            Label("\(category.rawValue) · \(items.filter { !$0.isReference }.count)개", systemImage: category.symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(category.tint)
        }
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct BranchAgentSidePanel: View {
    let card: BranchReviewCard
    let branch: RepositoryBranch
    @Bindable var store: ReviewStore
    let close: () -> Void
    @State private var draft = ""
    @State private var showingImplementation = false
    @State private var implementationRequest = ""
    var body: some View {
        VStack(spacing: 0) {
            HStack { VStack(alignment: .leading) { Text("에이전트 검토").font(.headline); Text(card.title).font(.caption).foregroundStyle(.secondary) }; Spacer(); Button("닫기", systemImage: "xmark", action: close).buttonStyle(.borderless) }.padding(16)
            Divider()
            ScrollView { LazyVStack(alignment: .leading, spacing: 12) {
                GroupBox("\(card.category.rawValue) · 검토 내용") { MarkdownContentView(card.details, nativeSelection: true).frame(maxWidth: .infinity, alignment: .leading) }
                ForEach(card.messages) { message in BranchChatBubble(message: message) }
                if let error = store.branchCardErrors[card.id] { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                if let result = store.branchImplementationResults[card.id] {
                    GroupBox("구현 결과") { MarkdownContentView(result, nativeSelection: true).frame(maxWidth: .infinity, alignment: .leading) }
                }
            }.padding(16) }
            Divider()
            if !card.isReference {
                HStack {
                    if store.branchCardBusy.contains(card.id) {
                        ProgressView().controlSize(.small)
                        Text(store.cardReviewProgress[card.id] ?? "에이전트 작업 중…").font(.caption)
                        if store.canCancelBranchMessage(card.id) {
                            Button("취소") { store.cancelBranchMessage(card.id) }
                        }
                    }
                    if !store.branchCardReviewed.contains(card.id) {
                        Button("에이전트 검토 시작") { Task { await store.sendBranchMessage(cardID: card.id, branch: branch, message: "이 카드의 지적과 수정 방향을 검토하고 대응 계획을 알려주세요.") } }
                            .disabled(store.branchCardBusy.contains(card.id))
                    }
                    Spacer()
                    Button("구현 요청") {
                        implementationRequest = ReviewStore.branchImplementationRequest(card: card)
                        showingImplementation = true
                    }
                    .disabled(!store.branchCardReviewed.contains(card.id) || store.branchCardBusy.contains(card.id) || store.implementingBranchRepositoryIDs.contains(branch.repositoryID))
                }.padding(.horizontal, 12).padding(.top, 10)
                HStack(alignment: .bottom) {
                    TextField("추가 질문을 입력하세요", text: $draft, axis: .vertical).lineLimit(1...4).onSubmit(send)
                    Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title2) }.buttonStyle(.plain).disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.branchCardBusy.contains(card.id))
                }.padding(12)
            }
        }.background(.bar)
        .sheet(isPresented: $showingImplementation) {
            VStack(alignment: .leading, spacing: 12) {
                Text("구현 요청 확인").font(.title2.bold())
                Text("등록된 작업 폴더에서 \(branch.name) 브랜치와 검토한 커밋을 확인한 뒤 구현합니다. 커밋과 푸시는 하지 않습니다.").foregroundStyle(.secondary)
                TextEditor(text: $implementationRequest).font(.body.monospaced()).border(.quaternary)
                HStack { Spacer(); Button("취소") { showingImplementation = false }; Button("구현 시작") {
                    let request = implementationRequest
                    showingImplementation = false
                    Task { await store.implementBranchCard(card, branch: branch, request: request) }
                }.buttonStyle(.borderedProminent).disabled(implementationRequest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }.padding(20).frame(width: 680, height: 600)
        }
    }
    private func send() { let message = draft.trimmingCharacters(in: .whitespacesAndNewlines); guard !message.isEmpty, !store.branchCardBusy.contains(card.id) else { return }; draft = ""; Task { await store.sendBranchMessage(cardID: card.id, branch: branch, message: message) } }
}

private struct BranchChatBubble: View {
    let message: AgentChatMessage
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(message.role == .user ? "나" : "에이전트").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            MarkdownContentView(message.body, nativeSelection: true, plainText: message.role == .user)
        }.padding(10).textSelection(.enabled).background(message.role == .user ? AnyShapeStyle(BrandColor.prPurple.opacity(0.16)) : AnyShapeStyle(.quaternary), in: RoundedRectangle(cornerRadius: 10)).frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PullRequestRequestSheet: View {
    let branch: RepositoryBranch
    @Bindable var store: ReviewStore
    @Binding var isPresented: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var bodyText = ""
    @State private var isSubmitting = false
    @State private var submissionError = ""

    private var proposal: PullRequestProposal? { store.pullRequestProposal(for: branch) }
    private var isPreparing: Bool { store.isPreparingPullRequestProposal(for: branch) }
    private var preparationError: String { store.branchPullRequestProposalErrors[branch.id] ?? "" }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("PR 요청 준비").font(.title2.bold())
                    Text("프로젝트 PR 스킬의 제안을 확인한 뒤 생성합니다.").foregroundStyle(.secondary)
                }
                Spacer()
                if proposal != nil {
                    Button("다시 분석", systemImage: "arrow.clockwise") {
                        Task { await prepare(force: true) }
                    }
                    .disabled(isPreparing || isSubmitting)
                    .help("프로젝트 PR 스킬을 다시 적용해 base·리뷰어·본문을 새로 준비합니다.")
                }
            }
            .padding(24)

            Divider()

            Group {
                if isPreparing && proposal == nil {
                    VStack(spacing: 14) {
                        ProgressView()
                        Text("Agent가 프로젝트 PR 스킬을 적용하는 중…").font(.headline)
                        Text("이 단계에서는 파일 수정, push, PR 생성을 실행하지 않습니다.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let proposal {
                    proposalForm(proposal)
                } else {
                    ContentUnavailableView {
                        Label("PR 요청을 준비하지 못했습니다", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(preparationError.isEmpty ? "Agent 요청이 중단되었습니다." : preparationError)
                    } actions: {
                        Button("다시 시도") { Task { await prepare(force: true) } }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack {
                if isPreparing { ProgressView().controlSize(.small) }
                if !submissionError.isEmpty {
                    Text(submissionError).font(.caption).foregroundStyle(.red).lineLimit(2)
                }
                Spacer()
                Button("취소", role: .cancel) { dismiss() }
                Button(isSubmitting ? "요청 중…" : submissionButtonTitle) {
                    Task { await submit() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(proposal == nil || isPreparing || isSubmitting || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(16)
        }
        .frame(width: 680, height: 720)
        .task { await prepare(force: true) }
        .onChange(of: proposal, initial: true) { _, newProposal in
            guard let newProposal else { return }
            title = newProposal.title
            bodyText = newProposal.body
            submissionError = ""
        }
        .alert(store.branchAgentPermissionRequest?.title ?? "에이전트 권한 요청", isPresented: Binding(
            get: { store.branchAgentPermissionRequest?.branch.id == branch.id },
            set: { presented in if !presented { store.cancelBranchAgentPermission() } }
        )) {
            Button("취소", role: .cancel) { store.cancelBranchAgentPermission() }
            Button(store.branchAgentPermissionRequest?.approvalTitle ?? "확인") { store.approveBranchAgentPermission() }
        } message: {
            Text(branchPermissionMessage)
        }
    }

    @ViewBuilder
    private func proposalForm(_ proposal: PullRequestProposal) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("Agent 제안") {
                    VStack(alignment: .leading, spacing: 9) {
                        LabeledContent("적용 스킬", value: proposal.skillName)
                        LabeledContent("Base", value: proposal.base)
                        LabeledContent("Head", value: proposal.head)
                        LabeledContent("선택 근거", value: proposal.baseSource)
                        LabeledContent("포함 범위", value: "커밋 \(proposal.commitCount)개 · 변경 파일 \(proposal.changedFiles)개")
                        LabeledContent("리뷰어", value: proposal.reviewers.isEmpty ? "없음" : proposal.reviewers.joined(separator: ", "))
                        if let existing = proposal.existingPullRequest {
                            HStack {
                                Text("기존 PR")
                                Spacer()
                                if let url = URL(string: existing.url) {
                                    Link("#\(existing.number) · \(existing.state)", destination: url)
                                } else {
                                    Text("#\(existing.number) · \(existing.state)")
                                }
                            }
                        }
                    }
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }

                if !proposal.warnings.isEmpty {
                    GroupBox("확인 필요") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(proposal.warnings, id: \.self) { warning in
                                Label(warning, systemImage: "exclamationmark.triangle.fill")
                            }
                        }
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(4)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("PR 제목").font(.headline)
                    TextField("PR 제목", text: $title)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("PR 본문").font(.headline)
                    TextEditor(text: $bodyText)
                        .font(.body.monospaced())
                        .frame(minHeight: 190)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                }
                Text("생성 버튼을 누르면 앱이 base/head SHA와 커밋 범위를 다시 검증한 뒤 GitHub PR을 생성합니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(24)
        }
    }

    private func prepare(force: Bool) async {
        _ = await store.preparePullRequestProposal(for: branch, force: force)
    }

    private var submissionButtonTitle: String {
        proposal?.existingPullRequest?.state.uppercased() == "OPEN" ? "기존 PR 사용" : "PR 요청 생성"
    }

    private func submit() async {
        guard let proposal else { return }
        isSubmitting = true
        submissionError = ""
        let created = await store.requestPullRequest(
            for: branch,
            proposal: proposal,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            body: bodyText
        ) != nil
        isSubmitting = false
        guard created else {
            submissionError = store.statusMessage
            return
        }
        isPresented = false
    }

    private var branchPermissionMessage: String {
        guard let request = store.branchAgentPermissionRequest else { return "에이전트 권한 확인이 필요합니다." }
        switch request.kind {
        case .workspaceTrust:
            return "Cursor Agent가 PR 생성 스킬과 저장소를 읽으려면 작업 공간 신뢰가 필요합니다. 승인해도 준비 단계에서는 수정·push·PR 생성을 실행하지 않습니다."
        case .cursorLogin:
            return "Cursor Agent 로그인이 필요합니다. 승인하면 Terminal과 브라우저에서 Cursor 인증을 시작합니다. 인증 후 다시 시도하세요."
        case .other:
            return "Cursor Agent가 추가 권한을 요청했습니다. Cursor에서 요청 범위를 확인한 뒤 다시 시도하세요.\n\n\(request.detail)"
        }
    }
}

private struct BranchQuizSheet: View {
    let branch: RepositoryBranch
    @Bindable var store: ReviewStore
    @Environment(\.dismiss) private var dismiss
    @State private var questions: [BranchQuizQuestion] = []
    @State private var answers: [UUID: Int] = [:]
    @State private var currentIndex = 0
    @State private var isLoading = true
    @State private var isFinished = false
    @State private var notice = ""
    @State private var errorMessage = ""

    private var question: BranchQuizQuestion? { questions.indices.contains(currentIndex) ? questions[currentIndex] : nil }
    private var score: Int { questions.reduce(0) { $0 + (answers[$1.id] == $1.correctIndex ? 1 : 0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("PR 이해도 퀴즈").font(.title2.bold())
                    Text("핵심 기능과 흐름을 확인하는 3지선다 5문제입니다.").foregroundStyle(.secondary)
                }
                Spacer()
                Button("닫기", systemImage: "xmark") { dismiss() }.buttonStyle(.borderless)
            }

            if isLoading {
                Spacer(); ProgressView("퀴즈 만드는 중…").frame(maxWidth: .infinity); Spacer()
            } else if isFinished {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: score == questions.count ? "checkmark.seal.fill" : "chart.bar.fill").font(.system(size: 42)).foregroundStyle(score == questions.count ? .green : BrandColor.prPurple)
                    Text("\(questions.count)문제 중 \(score)문제 정답").font(.title2.bold())
                    Text(score == questions.count ? "PR의 핵심 흐름을 모두 확인했습니다." : "각 문제의 해설을 확인해 PR 내용을 다시 점검하세요.").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity)
                Spacer()
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(questions.indices, id: \.self) { index in
                        let item = questions[index]
                        Label("\(index + 1). \(answers[item.id] == item.correctIndex ? "정답" : "오답") · \(item.explanation)", systemImage: answers[item.id] == item.correctIndex ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.caption).foregroundStyle(answers[item.id] == item.correctIndex ? .green : .secondary)
                    }
                }.padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            } else if let question {
                ProgressView(value: Double(currentIndex + 1), total: Double(questions.count))
                Text("문제 \(currentIndex + 1) / \(questions.count)").font(.caption).foregroundStyle(.secondary)
                Text(question.question).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(question.choices.indices, id: \.self) { index in
                        BranchQuizChoice(
                            title: question.choices[index],
                            selected: answers[question.id] == index,
                            choose: { answers[question.id] = index }
                        )
                    }
                }
                Spacer()
                HStack {
                    Button("이전") { currentIndex -= 1 }.disabled(currentIndex == 0)
                    Spacer()
                    Button(currentIndex == questions.count - 1 ? "채점하기" : "다음") {
                        if currentIndex == questions.count - 1 { isFinished = true } else { currentIndex += 1 }
                    }.buttonStyle(.borderedProminent).disabled(answers[question.id] == nil)
                }
            } else if !notice.isEmpty {
                ContentUnavailableView("퀴즈가 필요하지 않습니다", systemImage: "checkmark.circle", description: Text(notice))
            } else {
                ContentUnavailableView {
                    Label("퀴즈를 만들지 못했습니다", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage.isEmpty ? "생성 요청이 아직 끝나지 않았거나 응답을 받지 못했습니다." : errorMessage)
                } actions: {
                    Button("다시 만들기", systemImage: "arrow.clockwise") {
                        Task { await loadQuiz(retry: true) }
                    }
                    .disabled(store.isMakingBranchQuiz)
                }
            }
        }
        .padding(24).frame(width: 590, height: 520)
        .task {
            await loadQuiz()
        }
    }

    private func loadQuiz(retry: Bool = false) async {
        isLoading = true
        notice = ""
        errorMessage = ""
        if !retry, let cached = store.branchQuizzes[branch.id] {
            questions = cached
        } else if !retry, let storedNotice = store.branchQuizNotices[branch.id] {
            notice = storedNotice
        } else {
            let created = retry ? await store.retryBranchQuiz(for: branch) : await store.makeBranchQuiz(for: branch)
            if let created { questions = created }
            else if let storedNotice = store.branchQuizNotices[branch.id] { notice = storedNotice }
            else { errorMessage = store.branchQuizErrors[branch.id] ?? "퀴즈 생성이 진행 중이면 잠시 후 ‘다시 만들기’를 선택하세요." }
        }
        isLoading = false
    }
}

private struct BranchQuizChoice: View {
    let title: String
    let selected: Bool
    let choose: () -> Void
    var body: some View {
        Button(action: choose) {
            HStack(spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                Text(title).multilineTextAlignment(.leading)
                Spacer()
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .background(selected ? AnyShapeStyle(BrandColor.prPurple.opacity(0.13)) : AnyShapeStyle(.quaternary), in: RoundedRectangle(cornerRadius: 9))
    }
}
