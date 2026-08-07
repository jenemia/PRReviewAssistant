import Foundation

enum CursorConversationRole: String, Hashable, Sendable {
    case user
    case agent

    var title: String { self == .user ? "사용자" : "에이전트" }
}

struct CursorConversationMessage: Identifiable, Hashable, Sendable {
    let id: UUID
    let role: CursorConversationRole
    let body: String
}

struct CursorSession: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let workspacePath: String?
    let updatedAt: Date
    let isArchived: Bool
    let messages: [CursorConversationMessage]

    var searchableText: String {
        ([title] + messages.map(\.body)).joined(separator: "\n")
    }

    var plainText: String {
        let metadata = [
            "세션 제목: \(title)",
            "세션 ID: \(id)",
            workspacePath.map { "작업 폴더: \($0)" },
            "마지막 수정: \(updatedAt.formatted(.dateTime.year().month().day().hour().minute()))"
        ].compactMap { $0 }.joined(separator: "\n")
        let conversation = messages.map { "[\($0.role.title)]\n\($0.body)" }.joined(separator: "\n\n")
        return "\(metadata)\n\n대화 내용\n\(conversation)"
    }
}

/// A local, user-owned mapping. It is keyed by Cursor's immutable session ID
/// and is intentionally kept outside Cursor's own databases.
struct CursorSessionSpec: Hashable, Sendable {
    let sessionID: String
    let specName: String
    let specPath: String?
    let sessionUpdatedAt: Date
    let classifiedAt: Date

    static let unclassifiedName = "미분류"
}

struct WorkspaceSpecDocument: Hashable, Sendable {
    let name: String
    let relativePath: String
}

struct CursorSessionSpecClassification: Sendable {
    let specName: String
    let specPath: String?
}
