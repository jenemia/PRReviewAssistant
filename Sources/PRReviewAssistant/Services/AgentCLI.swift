import Foundation

struct ExternalAgentError: LocalizedError {
    let detail: String
    var errorDescription: String? { detail }
}

/// One agent CLI call, described by what it needs rather than by any one CLI's flags.
struct AgentRequest: Sendable {
    enum Access: Sendable { case readOnly, writable }
    /// Cursor's output format. Other CLIs always return plain text.
    enum CursorOutput: String, Sendable { case text, json, streamJSON = "stream-json" }

    var prompt: String
    var model: String
    var access: Access = .readOnly
    /// The repository the agent works in. It is also the process's working directory.
    var directory: String?
    /// Read-only Cursor runs pass `--trust` only after the user approved it.
    var trustWorkspace = false
    var timeout: TimeInterval = 300
    var allowSubagents = false
    var cursorOutput: CursorOutput = .text
    /// The conversation this run belongs to. Without it the CLI keeps no session.
    /// Claude Code starts a new session under this ID; Cursor picks its own ID
    /// for a new session and reports it in its stream output.
    var sessionID: String?
    /// Continue the existing conversation `sessionID` instead of starting it.
    var resumesSession = false
}

enum AgentProvider: String, CaseIterable, Codable, Sendable {
    case cursor, codex, claude

    var title: String {
        switch self {
        case .cursor: "Cursor"
        case .codex: "Codex"
        case .claude: "Claude Code"
        }
    }

    var skillDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".\(rawValue)/skills", isDirectory: true)
    }

    /// Whether follow-up questions continue the card's earlier conversation.
    /// Codex stays off: its `exec resume` has no `--sandbox` option, and keeping
    /// a resumed run read-only has not been verified yet.
    var supportsResume: Bool { self != .codex }

    var loginArguments: [String] {
        self == .claude ? ["auth", "login"] : ["login"]
    }

    func connection() -> AgentConnection {
        let runner = ProcessRunner()
        do {
            _ = try runner.run(rawValue, arguments: ["--version"], timeout: 15)
            let statusArguments = self == .codex ? ["login", "status"] : ["auth", "status"]
            let status = try runner.run(rawValue, arguments: statusArguments, timeout: 15)
            if self == .claude {
                struct AuthStatus: Decodable { let loggedIn: Bool }
                let auth = try JSONDecoder().decode(AuthStatus.self, from: Data(status.output.utf8))
                if !auth.loggedIn {
                    return .init(state: .needsLogin, detail: "\(title) CLI 로그인 필요")
                }
            }
            return .init(state: .connected, detail: "\(title) CLI 로그인 확인됨")
        } catch CommandError.notFound {
            return .init(state: .unavailable, detail: "\(title) CLI를 설치한 뒤 다시 확인하세요.")
        } catch CommandError.failed(let result) where result.status == 1 && (
            (result.output + result.error).localizedCaseInsensitiveContains("not logged in")
            || (result.output + result.error).contains("\"loggedIn\": false")
        ) {
            return .init(state: .needsLogin, detail: "\(title) CLI 로그인 필요")
        } catch {
            return .init(state: .failed, detail: "\(title) CLI 연결 확인 실패. \(error.localizedDescription)")
        }
    }

    /// Cursor CLI arguments for a request. Cursor takes the prompt as the last argument.
    static func cursorArguments(for request: AgentRequest) -> [String] {
        var arguments = ["agent", "--print", "--output-format", request.cursorOutput.rawValue]
        switch request.access {
        case .readOnly: arguments += ["--mode", "ask"]
        case .writable: arguments.append("--trust")
        }
        if let directory = request.directory { arguments += ["--workspace", directory] }
        if request.access == .readOnly && request.trustWorkspace { arguments.append("--trust") }
        if !request.model.isEmpty { arguments += ["--model", request.model] }
        if request.resumesSession, let sessionID = request.sessionID { arguments.append("--resume=\(sessionID)") }
        arguments += ["--", request.prompt]
        return arguments
    }

    /// Claude Code arguments before `--model`. The prompt goes in on stdin.
    static func claudeArguments(for request: AgentRequest) -> [String] {
        let writable = request.access == .writable
        var arguments = ["--print", "--output-format", "text", "--strict-mcp-config",
                         "--setting-sources", "user",
                         "--permission-mode", writable ? "acceptEdits" : "plan",
                         "--tools", writable ? "Read,Glob,Grep,Edit,Write,Bash" : (request.allowSubagents ? "Read,Glob,Grep,Bash,Agent" : "Read,Glob,Grep,Bash"),
                         "--disable-slash-commands"]
        if let sessionID = request.sessionID {
            arguments += [request.resumesSession ? "--resume" : "--session-id", sessionID]
        } else {
            arguments.append("--no-session-persistence")
        }
        return arguments
    }

    /// Runs one request with this provider's CLI. Cursor's raw output is returned
    /// as is, since its callers read it in the format they asked for.
    func run(_ request: AgentRequest, onOutputLine: (@Sendable (Data) -> Void)? = nil) throws -> CommandResult {
        let runner = ProcessRunner()
        if self == .cursor {
            return try runner.run(
                "cursor", arguments: Self.cursorArguments(for: request), workingDirectory: request.directory,
                timeout: request.timeout, onOutputLine: onOutputLine
            )
        }
        let writable = request.access == .writable
        let model = request.model
        var arguments: [String]
        var outputFile: URL?
        defer {
            if let outputFile { try? FileManager.default.removeItem(at: outputFile.deletingLastPathComponent()) }
        }

        switch self {
        case .cursor:
            preconditionFailure("Handled above")
        case .codex:
            let temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let file = temporaryDirectory.appendingPathComponent("response.txt")
            outputFile = file
            arguments = ["-a", "never", "exec", "--ephemeral", "--skip-git-repo-check",
                         "--sandbox", writable ? "workspace-write" : "read-only",
                         "--output-last-message", file.path]
        case .claude:
            arguments = Self.claudeArguments(for: request)
        }
        if !model.isEmpty { arguments += ["--model", model] }
        if self == .codex { arguments.append("-") }
        do {
            let result = try runner.run(rawValue, arguments: arguments, workingDirectory: request.directory, input: request.prompt, timeout: request.timeout)
            let output = try outputFile.map { try String(contentsOf: $0, encoding: .utf8) } ?? result.output
            guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ExternalAgentError(detail: "최종 응답이 비어 있습니다.")
            }
            return .init(output: output, error: result.error, status: result.status)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ExternalAgentError(detail: "\(title) CLI 실행 실패. \(error.localizedDescription)")
        }
    }
}
