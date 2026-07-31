@preconcurrency import Foundation

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
    func run(_ executable: String, arguments: [String], workingDirectory: String? = nil, input: String? = nil, timeout: TimeInterval? = nil) throws -> CommandResult {
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
        let readers = DispatchGroup()
        let commandOutput = CommandOutput()
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            commandOutput.setStandardOutput(data)
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            commandOutput.setStandardError(data)
            readers.leave()
        }

        let termination = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in termination.signal() }
        if let input {
            let inputPipe = Pipe()
            process.standardInput = inputPipe
            try process.run()
            inputPipe.fileHandleForWriting.write(Data(input.utf8))
            try? inputPipe.fileHandleForWriting.close()
        } else {
            try process.run()
        }
        if let timeout, termination.wait(timeout: .now() + timeout) == .timedOut {
            if process.isRunning { process.terminate() }
            _ = termination.wait(timeout: .now() + 5)
            readers.wait()
            throw CommandError.timedOut(executable)
        }
        if timeout == nil { termination.wait() }
        readers.wait()
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
        let paths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        return paths.map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
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
