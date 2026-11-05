import SwiftUI

/// Settings tab: pick a review role or UnitTest skill, read it, edit it and save it.
struct SkillSettingsView: View {
    private let files = SkillFileStore()
    @State private var skills: [EditableSkill] = []
    @State private var selectedID: EditableSkill.ID?
    @State private var text = ""
    @State private var savedText = ""
    @State private var message = ""
    @State private var messageIsError = false

    private var selected: EditableSkill? { skills.first { $0.id == selectedID } }
    private var isDirty: Bool { text != savedText }

    var body: some View {
        HSplitView {
            List(selection: $selectedID) {
                ForEach([EditableSkill.Group.review, .unitTest], id: \.self) { group in
                    Section(group.rawValue) {
                        let items = skills.filter { $0.group == group }
                        if items.isEmpty {
                            Text(group == .unitTest ? "없음 — 아래 '기본 스킬 설치'로 추가하세요." : "없음").font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(items) { skill in Text(skill.name).tag(skill.id) }
                    }
                }
            }
            .frame(minWidth: 190, idealWidth: 200, maxWidth: 240)
            .safeAreaInset(edge: .bottom) {
                Button("기본 UnitTest 스킬 설치", systemImage: "square.and.arrow.down") { installDefaults() }
                    .buttonStyle(.borderless).padding(8)
                    .help("없는 기본 스킬만 ~/.cursor/skills에 추가합니다. 기존 파일은 덮어쓰지 않습니다.")
            }

            VStack(alignment: .leading, spacing: 8) {
                if let skill = selected {
                    Text(skill.url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                    TextEditor(text: $text)
                        .font(.system(.body, design: .monospaced))
                        .border(.quaternary)
                    HStack {
                        if !message.isEmpty { Text(message).font(.caption).foregroundStyle(messageIsError ? .red : .secondary).lineLimit(2) }
                        Spacer()
                        Button("되돌리기") { text = savedText }.disabled(!isDirty)
                        Button("저장", systemImage: "square.and.arrow.down") { save(skill) }
                            .buttonStyle(.borderedProminent).disabled(!isDirty)
                            .keyboardShortcut("s", modifiers: .command)
                    }
                } else {
                    ContentUnavailableView("스킬을 선택하세요", systemImage: "doc.text", description: Text("리뷰와 UnitTest 생성에 쓰이는 지침 파일을 보고 수정할 수 있습니다."))
                }
            }
            .padding(12)
            .frame(minWidth: 320)
        }
        .onAppear { reload() }
        .onChange(of: selectedID) { _, _ in loadSelected() }
    }

    private func reload() {
        skills = files.list()
        if selected == nil { selectedID = skills.first?.id }
        loadSelected()
    }

    private func loadSelected() {
        message = ""
        guard let skill = selected else { text = ""; savedText = ""; return }
        do {
            savedText = try files.read(skill)
            text = savedText
        } catch {
            text = ""; savedText = ""
            show(error.localizedDescription, isError: true)
        }
    }

    private func save(_ skill: EditableSkill) {
        do {
            try files.write(text, to: skill)
            savedText = text
            show("저장했습니다. 다음 실행부터 적용됩니다.", isError: false)
        } catch {
            show(error.localizedDescription, isError: true)
        }
    }

    private func installDefaults() {
        do {
            let count = try files.installDefaultUnitTestSkills()
            reload()
            show(count == 0 ? "추가할 기본 스킬이 없습니다. 모두 설치되어 있습니다." : "기본 UnitTest 스킬 \(count)개를 설치했습니다.", isError: false)
        } catch {
            show("설치 실패: \(error.localizedDescription)", isError: true)
        }
    }

    private func show(_ text: String, isError: Bool) {
        message = text
        messageIsError = isError
    }
}
