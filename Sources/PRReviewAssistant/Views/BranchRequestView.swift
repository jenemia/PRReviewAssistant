import SwiftUI

struct BranchRequestListView: View {
    @Bindable var store: ReviewStore

    var body: some View {
        List(selection: $store.selectedBranchID) {
            ForEach(Dictionary(grouping: store.repositoryBranches, by: \.repositoryName).sorted(by: { $0.key < $1.key }), id: \.key) { repository, branches in
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
                    }
                }
            }
        }
        .navigationTitle("브랜치")
        .overlay {
            if store.isLoadingBranches { ProgressView("브랜치 불러오는 중") }
            else if store.repositoryBranches.isEmpty { ContentUnavailableView("표시할 브랜치가 없습니다", systemImage: "point.3.connected.trianglepath.dotted", description: Text("연결된 저장소를 확인한 뒤 새로 고침하세요.")) }
        }
        .task { store.loadRepositoryBranches() }
    }
}

struct BranchRequestDetailView: View {
    let branch: RepositoryBranch
    @Bindable var store: ReviewStore
    @State private var selectedCardID: BranchReviewCard.ID?
    @State private var showingRequestSheet = false
    @State private var showingQuizSheet = false

    private var cards: [BranchReviewCard] { store.branchCards(for: branch) }
    private var isClear: Bool { !cards.isEmpty && cards.allSatisfy { $0.details.localizedCaseInsensitiveContains("특이사항 없음") } }

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
            PullRequestRequestSheet(branch: branch, store: store)
        }
        .sheet(isPresented: $showingQuizSheet) {
            BranchQuizSheet(branch: branch, store: store)
        }
        .onChange(of: branch.id) { _, _ in selectedCardID = nil }
    }

    private var detailContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("브랜치 정보") {
                    VStack(alignment: .leading, spacing: 9) {
                        Text(branch.name).font(.title3.bold()).textSelection(.enabled)
                        LabeledContent("저장소", value: branch.repositoryName)
                        LabeledContent("기준 브랜치", value: repository?.defaultBranch ?? "main")
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
                            .buttonStyle(.borderedProminent).disabled(store.isReviewingBranch)
                            Spacer()
                            if !cards.isEmpty { Text("분류 카드 \(cards.count)개").font(.caption).foregroundStyle(.secondary) }
                        }
                        if !cards.isEmpty {
                            ScrollView(.horizontal) {
                                HStack(alignment: .top, spacing: 10) {
                                    ForEach(cards) { card in
                                        Button { selectedCardID = card.id } label: { BranchReviewCardView(card: card) }
                                            .buttonStyle(.plain)
                                    }
                                }.padding(.vertical, 2)
                            }
                        } else {
                            Text("리뷰를 시작하면 분류별 카드를 여기에서 확인하고, 카드를 눌러 에이전트와 대화할 수 있습니다.")
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

                GroupBox("PR 요청하기") {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(isClear ? "리뷰에서 특이사항이 확인되지 않았습니다." : "리뷰를 통과해야 PR을 요청할 수 있습니다.", systemImage: isClear ? "checkmark.seal.fill" : "lock.fill")
                            .foregroundStyle(isClear ? .green : .secondary)
                        Text(isClear ? "기준 브랜치 `\(repository?.defaultBranch ?? "main")`로 PR을 생성합니다." : "리뷰를 실행한 뒤 모든 분류에서 ‘특이사항 없음’으로 확인되면 활성화됩니다.")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("(선택적) 퀴즈", systemImage: "questionmark.circle") { showingQuizSheet = true }
                                .buttonStyle(.bordered)
                                .disabled(cards.isEmpty)
                                .help("PR의 핵심 기능과 흐름을 확인하는 5문제 퀴즈")
                            Spacer()
                            Button("PR 요청하기", systemImage: "arrow.up.right.square") { showingRequestSheet = true }.buttonStyle(.borderedProminent).disabled(!isClear)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
                }
            }
            .padding(20).frame(maxWidth: 900, alignment: .leading)
        }
    }

    private var repository: RegisteredRepository? { store.repositories.first { $0.id == branch.repositoryID } }
}

private struct BranchReviewCardView: View {
    let card: BranchReviewCard
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(card.category.rawValue, systemImage: card.category.symbol).font(.caption.weight(.semibold)).foregroundStyle(card.category.tint)
            Text(card.title).font(.subheadline.weight(.semibold)).lineLimit(2)
            Text(card.summary.isEmpty ? "특이사항 없음" : card.summary).font(.caption).foregroundStyle(.secondary).lineLimit(4)
            Text("에이전트와 검토하기").font(.caption.weight(.medium)).foregroundStyle(BrandColor.prPurple)
        }
        .padding(12).frame(width: 200, height: 160, alignment: .topLeading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct BranchAgentSidePanel: View {
    let card: BranchReviewCard
    let branch: RepositoryBranch
    @Bindable var store: ReviewStore
    let close: () -> Void
    @State private var draft = ""
    var body: some View {
        VStack(spacing: 0) {
            HStack { VStack(alignment: .leading) { Text("에이전트 검토").font(.headline); Text(card.title).font(.caption).foregroundStyle(.secondary) }; Spacer(); Button("닫기", systemImage: "xmark", action: close).buttonStyle(.borderless) }.padding(16)
            Divider()
            ScrollView { LazyVStack(alignment: .leading, spacing: 12) {
                GroupBox("\(card.category.rawValue) · 검토 내용") { MarkdownContentView(card.details).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                ForEach(card.messages) { message in BranchChatBubble(message: message) }
            }.padding(16) }
            Divider()
            HStack(alignment: .bottom) {
                TextField("추가 질문을 입력하세요", text: $draft, axis: .vertical).lineLimit(1...4).onSubmit(send)
                Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title2) }.buttonStyle(.plain).disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.padding(12)
        }.background(.bar)
    }
    private func send() { let message = draft.trimmingCharacters(in: .whitespacesAndNewlines); guard !message.isEmpty else { return }; draft = ""; Task { await store.sendBranchMessage(cardID: card.id, branch: branch, message: message) } }
}

private struct BranchChatBubble: View {
    let message: AgentChatMessage
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(message.role == .user ? "나" : "에이전트").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            if message.role == .agent { MarkdownContentView(message.body) } else { Text(message.body) }
        }.padding(10).textSelection(.enabled).background(message.role == .user ? AnyShapeStyle(BrandColor.prPurple.opacity(0.16)) : AnyShapeStyle(.quaternary), in: RoundedRectangle(cornerRadius: 10)).frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PullRequestRequestSheet: View {
    let branch: RepositoryBranch
    @Bindable var store: ReviewStore
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var description = ""
    @State private var isSubmitting = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("PR 요청하기").font(.title2.bold())
            Text("`\(branch.name)`에서 PR을 생성합니다. 요청 후 GitHub에서 리뷰어와 내용을 계속 확인할 수 있습니다.").foregroundStyle(.secondary)
            TextField("PR 제목", text: $title)
            TextEditor(text: $description).frame(minHeight: 140).overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            HStack { Spacer(); Button("취소", role: .cancel) { dismiss() }; Button(isSubmitting ? "요청 중…" : "PR 요청 생성") { Task { isSubmitting = true; defer { isSubmitting = false }; if await store.requestPullRequest(for: branch, title: title.isEmpty ? branch.subject : title, body: description) != nil { dismiss() } } }.buttonStyle(.borderedProminent).disabled(isSubmitting || (title.isEmpty && branch.subject.isEmpty)) }
        }.padding(24).frame(width: 520)
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
            } else {
                ContentUnavailableView("퀴즈를 만들지 못했습니다", systemImage: "exclamationmark.triangle")
            }
        }
        .padding(24).frame(width: 590, height: 520)
        .task {
            if let cached = store.branchQuizzes[branch.id] { questions = cached }
            else if let created = await store.makeBranchQuiz(for: branch) { questions = created }
            isLoading = false
        }
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
