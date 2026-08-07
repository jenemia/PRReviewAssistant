import Foundation
import SQLite3

enum CursorSessionHistoryError: LocalizedError {
    case unavailable
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: "Cursor의 로컬 세션 기록을 찾을 수 없습니다."
        case .unreadable(let detail): "Cursor 세션 기록을 읽을 수 없습니다. \(detail)"
        }
    }
}

/// Reads Cursor's local search index only. This service never writes to, locks,
/// or attempts to repair Cursor-managed databases.
struct CursorSessionHistoryService: Sendable {
    private let userDataURL: URL

    init(userDataURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Cursor/User", isDirectory: true)) {
        self.userDataURL = userDataURL
    }

    func loadSessions() throws -> [CursorSession] {
        let searchDatabase = userDataURL.appendingPathComponent("globalStorage/conversation-search.db")
        let workspacePaths = workspacePaths()
        let headers = composerHeaders()
        let indexedRows = FileManager.default.fileExists(atPath: searchDatabase.path)
            ? try readSearchRows(from: searchDatabase)
            : []
        guard !headers.isEmpty || !indexedRows.isEmpty else { throw CursorSessionHistoryError.unavailable }
        let indexedByID = Dictionary(uniqueKeysWithValues: indexedRows.map { ($0.id, $0) })

        // The search index can lag behind Cursor's composer metadata. Start
        // from headers so newly updated sessions are visible immediately, then
        // attach indexed conversation text when it has arrived.
        var sessions = headers.map { header -> CursorSession in
            let indexed = indexedByID[header.id]
            return CursorSession(
                id: header.id,
                title: indexed?.title.isEmpty == false ? indexed!.title : header.title,
                workspacePath: workspacePaths[header.workspaceID],
                updatedAt: Date(timeIntervalSince1970: TimeInterval(header.updatedAt) / 1_000),
                isArchived: header.isArchived,
                messages: indexed.map { Self.parseMessages($0.body) } ?? []
            )
        }
        let headerIDs = Set(headers.map(\.id))
        sessions += indexedRows.filter { !headerIDs.contains($0.id) }.map { row in
            CursorSession(
                id: row.id,
                title: row.title.isEmpty ? "제목 없는 Cursor 세션" : row.title,
                workspacePath: nil,
                updatedAt: Date(timeIntervalSince1970: TimeInterval(row.updatedAt) / 1_000),
                isArchived: row.isArchived,
                messages: Self.parseMessages(row.body)
            )
        }
        return sessions.sorted { $0.updatedAt > $1.updatedAt }
    }

    static func parseMessages(_ body: String) -> [CursorConversationMessage] {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let markers: [(String, CursorConversationRole)] = [
            ("사용자:", .user), ("User:", .user), ("You:", .user),
            ("에이전트:", .agent), ("Agent:", .agent), ("Assistant:", .agent), ("Cursor:", .agent), ("AI:", .agent)
        ]
        var messages: [CursorConversationMessage] = []
        var role: CursorConversationRole = .agent
        var lines: [String] = []

        func appendMessage() {
            let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            messages.append(.init(id: UUID(), role: role, body: text))
        }

        for line in trimmed.components(separatedBy: .newlines) {
            if let marker = markers.first(where: { line.hasPrefix($0.0) }) {
                appendMessage()
                role = marker.1
                lines = [String(line.dropFirst(marker.0.count)).trimmingCharacters(in: .whitespaces)]
            } else {
                lines.append(line)
            }
        }
        appendMessage()
        return messages
    }

    private func workspacePaths() -> [String: String] {
        let storage = userDataURL.appendingPathComponent("workspaceStorage", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(at: storage, includingPropertiesForKeys: nil) else { return [:] }
        return entries.reduce(into: [:]) { result, directory in
            let workspace = directory.appendingPathComponent("workspace.json")
            guard let data = try? Data(contentsOf: workspace),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let folder = object["folder"] as? String,
                  let url = URL(string: folder) else { return }
            result[directory.lastPathComponent] = url.path.removingPercentEncoding ?? url.path
        }
    }

    private func composerHeaders() -> [SessionHeader] {
        let database = userDataURL.appendingPathComponent("globalStorage/state.vscdb")
        guard FileManager.default.fileExists(atPath: database.path),
              let rows = try? SQLiteReader(path: database.path).rows("SELECT composerId, workspaceId, lastUpdatedAt, isArchived, value FROM composerHeaders") else { return [] }
        return rows.compactMap { row in
            guard let id = row["composerId"], let workspaceID = row["workspaceId"],
                  let updatedAt = Int64(row["lastUpdatedAt"] ?? "") else { return nil }
            let title = Self.headerTitle(row["value"]) ?? "제목 없는 Cursor 세션"
            return SessionHeader(id: id, workspaceID: workspaceID, title: title, updatedAt: updatedAt, isArchived: row["isArchived"] == "1")
        }
    }

    private static func headerTitle(_ value: String?) -> String? {
        guard let value, let data = value.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = object["name"] as? String else { return nil }
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    private func readSearchRows(from database: URL) throws -> [SearchRow] {
        let query = """
        SELECT c.id, c.title, c.updated_at, c.is_archived, f.body
        FROM conversations c
        JOIN conversation_fts f ON f.rowid = c.fts_rowid
        ORDER BY c.updated_at DESC
        """
        return try SQLiteReader(path: database.path).rows(query).compactMap { row in
            guard let id = row["id"], let title = row["title"], let body = row["body"],
                  let updatedAt = Int64(row["updated_at"] ?? "") else { return nil }
            return SearchRow(id: id, title: title, body: body, updatedAt: updatedAt, isArchived: row["is_archived"] == "1")
        }
    }

    private struct SearchRow: Sendable {
        let id: String
        let title: String
        let body: String
        let updatedAt: Int64
        let isArchived: Bool
    }

    private struct SessionHeader: Sendable {
        let id: String
        let workspaceID: String
        let title: String
        let updatedAt: Int64
        let isArchived: Bool
    }
}

private final class SQLiteReader {
    private var database: OpaquePointer?

    init(path: String) throws {
        let result = sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK else {
            defer { sqlite3_close(database) }
            throw CursorSessionHistoryError.unreadable(String(cString: sqlite3_errmsg(database)))
        }
        sqlite3_busy_timeout(database, 1_000)
    }

    deinit { sqlite3_close(database) }

    func rows(_ query: String) throws -> [[String: String]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else {
            throw CursorSessionHistoryError.unreadable(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        var results: [[String: String]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            var row: [String: String] = [:]
            for index in 0..<sqlite3_column_count(statement) {
                guard let name = sqlite3_column_name(statement, index), let value = sqlite3_column_text(statement, index) else { continue }
                row[String(cString: name)] = String(cString: value)
            }
            results.append(row)
        }
        return results
    }
}
