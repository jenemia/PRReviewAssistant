@preconcurrency import Foundation

func runCancellable<Value: Sendable>(_ operation: @escaping @Sendable () throws -> Value) async throws -> Value {
    try Task.checkCancellation()
    let worker = Task.detached(operation: operation)
    return try await withTaskCancellationHandler {
        let result = try await worker.value
        try Task.checkCancellation()
        return result
    } onCancel: {
        worker.cancel()
    }
}

struct CommandResult: Sendable {
    let output: String
    let error: String
    let status: Int32
}

private final class CommandOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var standardOutput = Data()
    private var standardError = Data()

    func setStandardOutput(_ data: Data) {
        lock.lock()
        standardOutput = data
        lock.unlock()
    }

    func setStandardError(_ data: Data) {
        lock.lock()
        standardError = data
        lock.unlock()
    }

    func snapshot() -> (output: Data, error: Data) {
        lock.lock()
        defer { lock.unlock() }
        return (standardOutput, standardError)
    }
}

enum CommandError: LocalizedError {
    case failed(CommandResult)
    case notFound(String)
    case timedOut(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let command): "\(command)을 찾을 수 없습니다. 설치 후 다시 시도하세요."
        case .timedOut(let command): "\(command) 응답 시간이 초과되었습니다. 카드 상태를 확인한 뒤 다시 시도하세요."
        case .failed(let result): result.error.isEmpty ? result.output : result.error
        }
    }
}

final class ProcessRunner: @unchecked Sendable {
    /// A child can exit before reading its stdin. Without this, writing the rest
    /// of the input delivers SIGPIPE and terminates the whole app.
    private static let ignoreBrokenPipeSignal: Void = { _ = signal(SIGPIPE, SIG_IGN) }()

    private let defaultTimeout: TimeInterval?

    init(defaultTimeout: TimeInterval? = nil) {
        self.defaultTimeout = defaultTimeout
    }

    func run(_ executable: String, arguments: [String], workingDirectory: String? = nil, input: String? = nil, timeout: TimeInterval? = nil, onOutputLine: (@Sendable (Data) -> Void)? = nil) throws -> CommandResult {
        try Task.checkCancellation()
        let timeout = timeout ?? defaultTimeout
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let resolvedURL: URL
        if executable.contains("/") {
            resolvedURL = URL(fileURLWithPath: executable)
        } else if let path = findExecutable(executable) {
            resolvedURL = URL(fileURLWithPath: path)
        } else {
            throw CommandError.notFound(executable)
        }
        process.executableURL = resolvedURL
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory.map(URL.init(fileURLWithPath:))
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        // Drain both pipes while the child is running. Waiting for a verbose
        // agent before reading its output can fill the pipe buffer forever.
        // These block rather than compute, and a low priority could leave them
        // queued long enough to look like a stalled command under load.
        let readers = DispatchGroup()
        let commandOutput = CommandOutput()
        let termination = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in termination.signal() }
        if let input {
            _ = Self.ignoreBrokenPipeSignal
            let inputPipe = Pipe()
            process.standardInput = inputPipe
            try process.run()
            // Write off this thread so a child that never reads stdin cannot
            // delay the timeout below. A write error only means the child has
            // already exited; its exit status reports the actual outcome.
            let writer = inputPipe.fileHandleForWriting
            DispatchQueue.global(qos: .userInitiated).async {
                try? writer.write(contentsOf: Data(input.utf8))
                try? writer.close()
            }
        } else {
            try process.run()
        }
        readers.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let handle = outputPipe.fileHandleForReading
            var data = Data()
            if let onOutputLine {
                var pending = Data()
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    data.append(chunk)
                    pending.append(chunk)
                    while let end = pending.firstIndex(of: 10) {
                        onOutputLine(Data(pending[..<end]))
                        pending.removeSubrange(...end)
                    }
                }
                if !pending.isEmpty { onOutputLine(pending) }
            } else {
                data = handle.readDataToEndOfFile()
            }
            commandOutput.setStandardOutput(data)
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            commandOutput.setStandardError(data)
            readers.leave()
        }

        let pid = process.processIdentifier
        // Foundation normally starts a separate process group. Never signal
        // a group unless this command is its leader.
        let target = getpgid(pid) == pid ? -pid : pid
        let deadline = timeout.map { DispatchTime.now() + $0 }
        while termination.wait(timeout: min(deadline ?? .distantFuture, .now() + 0.1)) == .timedOut {
            let cancelled = Task.isCancelled
            guard cancelled || deadline.map({ DispatchTime.now() >= $0 }) == true else { continue }
            kill(target, SIGTERM)
            let needsForce = termination.wait(timeout: .now() + 0.5) == .timedOut
            if needsForce || target < 0 { kill(target, SIGKILL) }
            if needsForce { _ = termination.wait(timeout: .now() + 1) }
            if cancelled { throw CancellationError() }
            throw CommandError.timedOut(executable)
        }
        // Descendants can keep inherited pipes open after the CLI exits.
        let drainDeadline = DispatchTime.now() + 5
        while readers.wait(timeout: min(drainDeadline, .now() + 0.1)) == .timedOut {
            if Task.isCancelled {
                if target < 0 { kill(target, SIGKILL) }
                throw CancellationError()
            }
            if DispatchTime.now() >= drainDeadline { throw CommandError.timedOut(executable) }
        }
        try Task.checkCancellation()
        let capturedOutput = commandOutput.snapshot()
        let result = CommandResult(
            output: String(decoding: capturedOutput.output, as: UTF8.self),
            error: String(decoding: capturedOutput.error, as: UTF8.self),
            status: process.terminationStatus
        )
        guard result.status == 0 else { throw CommandError.failed(result) }
        return result
    }

    private func findExecutable(_ name: String) -> String? {
        let environmentPaths = ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":")
            .map(String.init) ?? []
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let paths = environmentPaths + [
            "\(home)/.local/bin",
            "\(home)/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/Applications/Cursor.app/Contents/Resources/app/bin"
        ]
        var visited = Set<String>()
        return paths
            .filter { visited.insert($0).inserted }
            .map { "\($0)/\(name)" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Starts an interactive CLI command without holding the UI until it exits.
    func launch(_ executable: String, arguments: [String], workingDirectory: String? = nil) throws {
        let process = Process()
        let resolvedURL: URL
        if executable.contains("/") { resolvedURL = URL(fileURLWithPath: executable) }
        else if let path = findExecutable(executable) { resolvedURL = URL(fileURLWithPath: path) }
        else { throw CommandError.notFound(executable) }
        process.executableURL = resolvedURL
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory.map(URL.init(fileURLWithPath:))
        try process.run()
    }

    /// Cursor login can require a browser and interactive terminal feedback.
    /// Running it in Terminal keeps that feedback visible to the user.
    func launchInTerminal(command: String) throws {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"Terminal\"\nactivate\ndo script \"\(escaped)\"\nend tell"
        _ = try run("/usr/bin/osascript", arguments: ["-e", script])
    }
}
