import Foundation

struct ExternalAgentError: LocalizedError {
    let detail: String
    var errorDescription: String? { detail }
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

    var loginArguments: [String] {
        self == .claude ? ["auth", "login"] : ["login"]
    }

    func connection() -> CursorConnection {
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

    func run(
        prompt: String, model: String, directory: String?, writable: Bool, timeout: TimeInterval
    ) throws -> CommandResult {
        let runner = ProcessRunner()
        var arguments: [String]
        var outputFile: URL?
        defer {
            if let outputFile { try? FileManager.default.removeItem(at: outputFile.deletingLastPathComponent()) }
        }

        switch self {
        case .cursor:
            preconditionFailure("Cursor uses its existing CLI workflow")
        case .codex:
            let temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let file = temporaryDirectory.appendingPathComponent("response.txt")
            outputFile = file
            arguments = ["-a", "never", "exec", "--ephemeral", "--skip-git-repo-check",
                         "--sandbox", writable ? "workspace-write" : "read-only",
                         "--output-last-message", file.path]
        case .claude:
            arguments = ["--print", "--output-format", "text", "--no-session-persistence",
                         "--strict-mcp-config",
                         "--setting-sources", "user",
                         "--permission-mode", writable ? "acceptEdits" : "plan",
                         "--tools", writable ? "Read,Glob,Grep,Edit,Write,Bash" : "Read,Glob,Grep,Bash",
                         "--disable-slash-commands"]
        }
        if !model.isEmpty { arguments += ["--model", model] }
        if self == .codex { arguments.append("-") }
        do {
            let result = try runner.run(rawValue, arguments: arguments, workingDirectory: directory, input: prompt, timeout: timeout)
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
