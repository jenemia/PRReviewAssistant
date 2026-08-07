import Testing
import Foundation
@testable import PRReviewAssistant

@Suite("Cursor session history")
struct CursorSessionHistoryTests {
    @Test("대화 역할 표지를 사용자와 에이전트 메시지로 나눈다")
    func parsesMessageRoles() {
        let messages = CursorSessionHistoryService.parseMessages("""
        User: 로그인 오류를 확인해줘
        Assistant: 원인을 확인했습니다.
        에이전트: 재현 절차를 정리하겠습니다.
        """)

        #expect(messages.map(\.role) == [.user, .agent, .agent])
        #expect(messages.map(\.body) == ["로그인 오류를 확인해줘", "원인을 확인했습니다.", "재현 절차를 정리하겠습니다."])
    }

    @Test("긴 대화는 요약 입력 한도에 맞춰 분할한다")
    func chunksLongSummaryInput() {
        let chunks = CursorAgent.summaryChunks(from: "abcdefghij\n\nklmnopqrst\n\nuvwxyz", maximumCharacters: 12)

        #expect(chunks.count == 3)
        #expect(chunks.allSatisfy { $0.count <= 12 })
        #expect(chunks.joined(separator: "").replacingOccurrences(of: "\n", with: "") == "abcdefghijklmnopqrstuvwxyz")
    }

    @Test("세션 ID별 spec 분류는 최신 분류로 대체한다")
    func persistsSessionSpecByID() throws {
        let databaseURL = FileManager.default.temporaryDirectory.appendingPathComponent("cursor-spec-test-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = CursorSessionSpecStore(databaseURL: databaseURL)
        let sessionID = "session-123"
        let original = CursorSessionSpec(sessionID: sessionID, specName: "첫 Spec", specPath: ".specs/first/spec.md", sessionUpdatedAt: .distantPast, classifiedAt: .distantPast)
        let refreshed = CursorSessionSpec(sessionID: sessionID, specName: "새 Spec", specPath: ".specs/new/spec.md", sessionUpdatedAt: .now, classifiedAt: .now)

        try store.save(original)
        try store.save(refreshed)

        let loaded = try store.load()[sessionID]
        #expect(loaded?.specName == "새 Spec")
        #expect(loaded?.specPath == ".specs/new/spec.md")
    }

    @Test("모델 출력은 후보 spec 경로로만 연결한다")
    func acceptsOnlyCatalogSpecPath() {
        let documents = [WorkspaceSpecDocument(name: "로그인", relativePath: ".specs/login/spec.md")]

        #expect(CursorAgent.parseSpecClassification("{\"specPath\":\".specs/login/spec.md\"}", documents: documents).specName == "로그인")
        #expect(CursorAgent.parseSpecClassification("{\"specPath\":\"invented/spec.md\"}", documents: documents).specName == CursorSessionSpec.unclassifiedName)
    }
}
