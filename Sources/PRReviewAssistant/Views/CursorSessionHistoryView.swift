import SwiftUI
import AppKit

struct CursorSessionListView: View {
    @Bindable var store: ReviewStore
    @Binding var searchText: String
    @State private var selectedSpecName = "전체"

    private var specNames: [String] {
        ["전체"] + Set(store.cursorSessionSpecs.values.map(\.specName)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var sessions: [CursorSession] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            // A text search is intentionally global, regardless of the active spec filter.
            return store.cursorSessions.filter { $0.searchableText.localizedCaseInsensitiveContains(query) }
        }
        guard selectedSpecName != "전체" else { return store.cursorSessions }
        return store.cursorSessions.filter { store.cursorSessionSpecs[$0.id]?.specName == selectedSpecName }
    }

    var body: some View {
        List(selection: $store.selectedCursorSessionID) {
            Section {
                ForEach(sessions) { session in
                    CursorSessionRow(session: session, spec: store.cursorSessionSpecs[session.id])
                        .tag(session.id)
                }
            } header: {
                HStack {
                    Text("Cursor 세션")
                    Spacer()
                    Text("\(sessions.count)개")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("에이전트 기록")
        .searchable(text: $searchText, prompt: "모든 세션 대화 검색")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("Spec 필터", selection: $selectedSpecName) {
                        ForEach(specNames, id: \.self) { Text($0).tag($0) }
                    }
                } label: {
                    Label(selectedSpecName, systemImage: "line.3.horizontal.decrease.circle")
                }
                .help("Spec으로 세션 필터")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await store.classifyUpdatedCursorSessions() }
                } label: {
                    Label(store.isClassifyingCursorSessions ? "분류 중" : "갱신 세션 분류", systemImage: "sparkles")
                }
                .disabled(store.isClassifyingCursorSessions || store.pendingCursorSpecClassificationCount == 0)
                .help("연결된 LLM으로 갱신된 세션을 spec 문서에 연결")
            }
        }
        .onChange(of: specNames) { _, names in
            if !names.contains(selectedSpecName) { selectedSpecName = "전체" }
        }
        .overlay {
            if store.isLoadingCursorHistory {
                ProgressView("Cursor 세션 기록을 읽는 중")
            } else if sessions.isEmpty {
                ContentUnavailableView(
                    searchText.isEmpty ? "표시할 Cursor 세션이 없습니다" : "일치하는 세션이 없습니다",
                    systemImage: searchText.isEmpty ? "clock.arrow.circlepath" : "magnifyingglass",
                    description: Text(store.cursorHistoryStatus)
                )
            }
        }
        .task { await store.loadCursorHistory() }
    }
}

private struct CursorSessionRow: View {
    let session: CursorSession
    let spec: CursorSessionSpec?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(session.title).font(.headline).lineLimit(2)
            Label(spec?.specName ?? "Spec 분류 대기", systemImage: spec == nil ? "clock" : "doc.text")
                .font(.caption)
                .foregroundStyle(spec == nil ? .secondary : Color.accentColor)
            HStack(spacing: 5) {
                Text(session.id)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                Button(copied ? "복사됨" : "ID 복사", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(session.id, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .help("세션 ID 복사")
            }
            if let workspacePath = session.workspacePath {
                Text(workspacePath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack {
                Text(session.updatedAt, format: .dateTime.month().day().hour().minute())
                Spacer()
                Text("대화 \(session.messages.count)개")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

struct CursorSessionDetailView: View {
    @Bindable var store: ReviewStore
    @State private var exportError: String?

    var body: some View {
        Group {
            if let session = store.selectedCursorSession {
                VStack(alignment: .leading, spacing: 0) {
                    header(session)
                    Divider()
                    if let summary = store.cursorSessionSummaries[session.id] {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 8) {
                                Label("대화 요약", systemImage: "text.append")
                                    .font(.headline)
                                MarkdownContentView(summary).textSelection(.enabled)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                        }
                        .frame(maxHeight: 230)
                        Divider()
                    }
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            if session.messages.isEmpty {
                                ContentUnavailableView("대화 내용을 읽을 수 없습니다", systemImage: "exclamationmark.bubble")
                            } else {
                                ForEach(session.messages) { message in
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(message.role.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                        Text(message.body).textSelection(.enabled)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(12)
                                    .background(message.role == .user ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                                }
                            }
                        }
                        .padding()
                    }
                }
            } else {
                ContentUnavailableView("세션을 선택하세요", systemImage: "arrow.left")
            }
        }
        .alert("TXT 저장 실패", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("확인", role: .cancel) {}
        } message: { Text(exportError ?? "") }
    }

    @ViewBuilder private func header(_ session: CursorSession) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(session.title).font(.title2.bold())
            Text(session.id).font(.caption.monospaced()).textSelection(.enabled).foregroundStyle(.secondary)
            if let spec = store.cursorSessionSpecs[session.id] {
                Label(spec.specName, systemImage: "doc.text")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(spec.specPath ?? "연결된 spec 문서 없음")
            }
            HStack {
                Button("전체 복사", systemImage: "doc.on.doc") { copy(session.plainText) }
                    .help("대화 내용을 모두 복사")
                Button("TXT로 저장", systemImage: "square.and.arrow.down") { saveText(session) }
                    .help("대화 내용을 텍스트 파일로 저장")
                Button(store.isSummarizingCursorSessionID == session.id ? "요약 중" : "요약", systemImage: "text.append") {
                    Task { await store.summarizeCursorSession(session) }
                }
                .disabled(session.messages.isEmpty || store.isSummarizingCursorSessionID != nil)
                .help("연결된 LLM으로 대화 요약")
                if store.isSummarizingCursorSessionID == session.id { ProgressView().controlSize(.small) }
                Spacer()
            }
        }
        .padding()
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func saveText(_ session: CursorSession) {
        let panel = NSSavePanel()
        let safeTitle = session.title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "\(safeTitle.prefix(60))-\(session.id.prefix(8)).txt"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try session.plainText.write(to: url, atomically: true, encoding: .utf8) }
        catch { exportError = error.localizedDescription }
    }
}
