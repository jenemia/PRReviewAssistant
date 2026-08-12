import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Stores only PR Review Assistant's classification metadata. Cursor's files
/// remain read-only and are never modified by this database.
struct CursorSessionSpecStore: Sendable {
    private let databaseURL: URL

    init(databaseURL: URL? = nil) {
        if let databaseURL {
            self.databaseURL = databaseURL
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("PRReviewAssistant", isDirectory: true)
            try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            self.databaseURL = support.appendingPathComponent("cursor-session-specs.sqlite")
        }
    }

    func load() throws -> [String: CursorSessionSpec] {
        let database = try SessionSpecDatabase(path: databaseURL.path)
        try database.prepare()
        return try database.read()
    }

    func save(_ spec: CursorSessionSpec) throws {
        let database = try SessionSpecDatabase(path: databaseURL.path)
        try database.prepare()
        try database.upsert(spec)
    }

    static func isCanonicalSpecPath(_ path: String?) -> Bool {
        guard let path else { return false }
        return URL(fileURLWithPath: path).lastPathComponent.lowercased() == "spec.md"
    }
}

struct WorkspaceSpecCatalog: Sendable {
    func documents(in workspacePath: String?) -> [WorkspaceSpecDocument] {
        guard let workspacePath else { return [] }
        let root = URL(fileURLWithPath: workspacePath, isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let excluded = Set([".git", ".build", "Library", "node_modules", "DerivedData"])
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            // `.specs` is intentionally hidden on disk, but it is the
            // primary source of candidate documents for session grouping.
            // Only the explicit excluded directories below are skipped.
            options: []
        ) else { return [] }

        var documents: [WorkspaceSpecDocument] = []
        for case let fileURL as URL in enumerator {
            if excluded.contains(fileURL.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            guard fileURL.lastPathComponent.lowercased() == "spec.md" else { continue }
            let relative = fileURL.path.replacingOccurrences(of: root.path + "/", with: "")
            let components = relative.lowercased().split(separator: "/")
            guard components.contains(where: { $0 == "specs" || $0 == ".specs" }) else { continue }
            let name = fileURL.deletingLastPathComponent().lastPathComponent
            documents.append(.init(name: name, relativePath: relative))
            if documents.count == 200 { break }
        }
        return documents.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }
}

private final class SessionSpecDatabase {
    private var handle: OpaquePointer?

    init(path: String) throws {
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw CursorSessionHistoryError.unreadable("세션 spec DB를 열 수 없습니다.")
        }
    }

    deinit { sqlite3_close(handle) }

    func prepare() throws {
        try execute("""
        CREATE TABLE IF NOT EXISTS cursor_session_specs (
            session_id TEXT PRIMARY KEY NOT NULL,
            spec_name TEXT NOT NULL,
            spec_path TEXT,
            session_updated_at REAL NOT NULL,
            classified_at REAL NOT NULL
        )
        """)
    }

    func read() throws -> [String: CursorSessionSpec] {
        var statement: OpaquePointer?
        let sql = "SELECT session_id, spec_name, spec_path, session_updated_at, classified_at FROM cursor_session_specs"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        var records: [String: CursorSessionSpec] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let sessionID = sqlite3_column_text(statement, 0), let specName = sqlite3_column_text(statement, 1) else { continue }
            let specPath = sqlite3_column_text(statement, 2).map { String(cString: $0) }
            let record = CursorSessionSpec(
                sessionID: String(cString: sessionID), specName: String(cString: specName), specPath: specPath,
                sessionUpdatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                classifiedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
            )
            records[record.sessionID] = record
        }
        return records
    }

    func upsert(_ spec: CursorSessionSpec) throws {
        let sql = """
        INSERT INTO cursor_session_specs (session_id, spec_name, spec_path, session_updated_at, classified_at)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(session_id) DO UPDATE SET spec_name=excluded.spec_name, spec_path=excluded.spec_path,
        session_updated_at=excluded.session_updated_at, classified_at=excluded.classified_at
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, spec.sessionID, -1, sqliteTransient)
        sqlite3_bind_text(statement, 2, spec.specName, -1, sqliteTransient)
        if let specPath = spec.specPath { sqlite3_bind_text(statement, 3, specPath, -1, sqliteTransient) }
        else { sqlite3_bind_null(statement, 3) }
        sqlite3_bind_double(statement, 4, spec.sessionUpdatedAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 5, spec.classifiedAt.timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }

    private func failure() -> CursorSessionHistoryError {
        guard let handle, let message = sqlite3_errmsg(handle) else { return .unreadable("세션 spec DB 오류") }
        return .unreadable(String(cString: message))
    }
}
