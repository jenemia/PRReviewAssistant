import Testing
import Foundation
@testable import PRReviewAssistant

@Suite("Cursor session history")
struct CursorSessionHistoryTests {
    @Test("세션 자동 분류는 기본적으로 꺼져 있다")
    func automaticClassificationDefaultsToOff() {
        #expect(!PersistedState().automaticCursorSessionClassification)
    }

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

    @Test("숨김 .specs 폴더의 문서를 분류 후보로 읽는다")
    func catalogIncludesHiddenSpecsDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spec-catalog-\(UUID().uuidString)", isDirectory: true)
        let specDirectory = root.appendingPathComponent(".specs/login", isDirectory: true)
        try FileManager.default.createDirectory(at: specDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "# Login\n".write(to: specDirectory.appendingPathComponent("spec.md"), atomically: true, encoding: .utf8)

        let documents = WorkspaceSpecCatalog().documents(in: root.path)
        #expect(documents.contains { $0.name == "login" && $0.relativePath == ".specs/login/spec.md" })
    }

    @Test("보조 Markdown은 독립 spec 후보로 읽지 않는다")
    func catalogExcludesNestedSupportMarkdown() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spec-catalog-\(UUID().uuidString)", isDirectory: true)
        let specDirectory = root.appendingPathComponent(".specs/invasion", isDirectory: true)
        try FileManager.default.createDirectory(at: specDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "# Invasion\n".write(to: specDirectory.appendingPathComponent("spec.md"), atomically: true, encoding: .utf8)
        try "# Rival API notes\n".write(to: specDirectory.appendingPathComponent("rival-matching-api.md"), atomically: true, encoding: .utf8)

        let documents = WorkspaceSpecCatalog().documents(in: root.path)
        #expect(documents.map(\.name) == ["invasion"])
    }

    @Test("사이드바에는 최근 spec 다섯 개만 노출한다")
    func cachesFiveMostRecentSpecs() {
        var cache = CursorSpecSidebarCache()

        cache.reconcile(latestSessionAtByName: latestDates(1...6))

        #expect(cache.visibleNames == ["Spec 6", "Spec 5", "Spec 4", "Spec 3", "Spec 2"])
    }

    @Test("고정 spec은 유지하고 새 세션 spec을 비고정 목록의 첫 순서에 둔다")
    func keepsPinnedSpecAheadOfNewSessionSpec() {
        var cache = CursorSpecSidebarCache()
        var dates = latestDates(1...6)
        cache.reconcile(latestSessionAtByName: dates)
        let didPin = cache.togglePinned("Spec 4", latestSessionAtByName: dates)
        #expect(didPin)

        dates["Spec 7"] = date(7)
        cache.reconcile(latestSessionAtByName: dates)

        #expect(cache.visibleNames == ["Spec 4", "Spec 7", "Spec 6", "Spec 5", "Spec 3"])
        #expect(cache.visibleNames.count == CursorSpecSidebarCache.maximumVisibleCount)
    }

    @Test("닫은 spec은 삭제하지 않고 더 최신 세션이 생길 때 다시 노출한다")
    func dismissesUntilANewerSessionArrives() {
        var cache = CursorSpecSidebarCache()
        var dates = latestDates(1...6)
        cache.reconcile(latestSessionAtByName: dates)

        cache.close("Spec 6", latestSessionAt: dates["Spec 6"])
        cache.reconcile(latestSessionAtByName: dates)
        #expect(!cache.visibleNames.contains("Spec 6"))
        #expect(dates["Spec 6"] != nil)

        dates["Spec 6"] = date(8)
        cache.reconcile(latestSessionAtByName: dates)
        #expect(cache.visibleNames.first == "Spec 6")
    }

    @Test("검색에서 연 spec을 유지하면서 이후 새 세션 spec을 먼저 표시한다")
    func activatesSearchedSpecThenPrioritizesNewSession() {
        var cache = CursorSpecSidebarCache()
        var dates = latestDates(1...6)
        cache.reconcile(latestSessionAtByName: dates)

        let didActivate = cache.activate("Spec 1", latestSessionAtByName: dates)
        #expect(didActivate)
        #expect(cache.visibleNames.contains("Spec 1"))

        dates["Spec 7"] = date(7)
        cache.reconcile(latestSessionAtByName: dates)
        #expect(cache.visibleNames.first == "Spec 7")
        #expect(cache.visibleNames.contains("Spec 1"))
        #expect(cache.visibleNames.count == CursorSpecSidebarCache.maximumVisibleCount)
    }

    private func latestDates(_ range: ClosedRange<Int>) -> [String: Date] {
        Dictionary(uniqueKeysWithValues: range.map { ("Spec \($0)", date($0)) })
    }

    private func date(_ value: Int) -> Date {
        Date(timeIntervalSince1970: TimeInterval(value))
    }
}
