import Foundation

/// Creates a tiny, self-contained Git repository for exercising the Inbox flow.
/// Its `origin` is a bare repository under `/tmp`, never a GitHub remote.
struct LocalPracticeRepository: Sendable {
    static let fullName = "local/pr-review-practice"
    private let root = URL(fileURLWithPath: "/tmp/PRReviewAssistant-LocalPractice", isDirectory: true)
    private let runner = ProcessRunner()

    struct Fixture: Sendable {
        let repository: RegisteredRepository
        let pullRequest: PullRequest
        let comments: [ReviewComment]
    }

    func create() throws -> Fixture {
        try removeFilesIfPresent()
        let remote = root.appending(path: "remote.git", directoryHint: .isDirectory)
        let source = root.appending(path: "source", directoryHint: .isDirectory)
        let checkout = root.appending(path: "checkout", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        _ = try runner.run("git", arguments: ["init", "--bare", remote.path])
        _ = try runner.run("git", arguments: ["init", "-b", "main", source.path])
        _ = try runner.run("git", arguments: ["config", "user.name", "Local Practice"] , workingDirectory: source.path)
        _ = try runner.run("git", arguments: ["config", "user.email", "local-practice@example.invalid"], workingDirectory: source.path)
        try writeBasePackage(at: source)
        _ = try runner.run("git", arguments: ["add", "."], workingDirectory: source.path)
        _ = try runner.run("git", arguments: ["commit", "-m", "chore: create practice package"], workingDirectory: source.path)
        _ = try runner.run("git", arguments: ["remote", "add", "origin", remote.path], workingDirectory: source.path)
        _ = try runner.run("git", arguments: ["push", "-u", "origin", "main"], workingDirectory: source.path)
        // `git init --bare` defaults HEAD to master. Point it at the branch we
        // actually pushed before cloning, otherwise the clone has an unborn HEAD.
        _ = try runner.run("git", arguments: ["--git-dir", remote.path, "symbolic-ref", "HEAD", "refs/heads/main"])

        let branch = "review-practice/empty-name"
        _ = try runner.run("git", arguments: ["switch", "-c", branch], workingDirectory: source.path)
        try writePullRequestChange(at: source)
        _ = try runner.run("git", arguments: ["add", "."], workingDirectory: source.path)
        _ = try runner.run("git", arguments: ["commit", "-m", "feat: customize greeting"], workingDirectory: source.path)
        _ = try runner.run("git", arguments: ["push", "-u", "origin", branch], workingDirectory: source.path)
        let sha = try runner.run("git", arguments: ["rev-parse", "HEAD"], workingDirectory: source.path).output.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try runner.run("git", arguments: ["clone", remote.path, checkout.path])

        return fixture(checkoutPath: checkout.path, sha: sha)
    }

    func load(from repository: RegisteredRepository) throws -> Fixture {
        let branch = "review-practice/empty-name"
        // Repair fixtures created before the bare remote's HEAD was corrected.
        // This is intentionally local-only and never changes a GitHub repository.
        if (try? runner.run("git", arguments: ["rev-parse", "--verify", "HEAD"], workingDirectory: repository.localPath)) == nil {
            _ = try runner.run("git", arguments: ["switch", "--force-create", "main", "origin/main"], workingDirectory: repository.localPath)
        }
        let sha = try runner.run("git", arguments: ["rev-parse", "origin/\(branch)"], workingDirectory: repository.localPath)
            .output.trimmingCharacters(in: .whitespacesAndNewlines)
        return fixture(checkoutPath: repository.localPath, sha: sha)
    }

    func remove(at path: String) throws {
        // Do not permit an app-state value to turn cleanup into a broad deletion.
        guard path == root.appending(path: "checkout", directoryHint: .isDirectory).path else {
            throw CommandError.failed(.init(output: "", error: "로컬 연습 저장소 경로가 예상과 다릅니다.", status: 1))
        }
        try removeFilesIfPresent()
    }

    private func fixture(checkoutPath: String, sha: String) -> Fixture {
        let repository = RegisteredRepository(
            localPath: checkoutPath,
            fullName: Self.fullName,
            defaultBranch: "main",
            monitoringEnabled: false,
            isLocalPractice: true
        )
        let pullRequest = PullRequest(
            id: stableID,
            repository: Self.fullName,
            number: 1,
            title: "연습: 빈 이름 인사 처리",
            author: "local-practice",
            headBranch: "review-practice/empty-name",
            baseBranch: "main",
            headSHA: String(sha.prefix(12)),
            reviewer: "practice-reviewer",
            commentCount: 1,
            updatedAt: .now,
            reviewState: .changesRequested,
            analysisStatus: .needsAnalysis,
            summary: "빈 이름과 공백 이름도 안전하게 처리하도록 수정해 주세요.",
            files: [.init(path: "Sources/Practice/Greeting.swift", additions: 3, deletions: 1)]
        )
        let comment = ReviewComment(
            id: "local-practice-review-1",
            author: "practice-reviewer",
            body: "`greeting(for:)`에 빈 문자열이나 공백만 들어오면 `Hello, stranger!`를 반환하도록 처리하고, 해당 테스트도 추가해 주세요.",
            path: "Sources/Practice/Greeting.swift",
            line: 4,
            createdAt: .now,
            kind: .line,
            reviewState: .changesRequested,
            parentID: nil
        )
        return Fixture(repository: repository, pullRequest: pullRequest, comments: [comment])
    }

    private var stableID: UUID {
        UUID(uuidString: "4D011B3A-9B91-45F1-81A3-093D15338451")!
    }

    private func removeFilesIfPresent() throws {
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        try FileManager.default.removeItem(at: root)
    }

    private func writeBasePackage(at source: URL) throws {
        try write("""
        // swift-tools-version: 6.0
        import PackageDescription

        let package = Package(
            name: "Practice",
            products: [.library(name: "Practice", targets: ["Practice"])],
            targets: [.target(name: "Practice"), .testTarget(name: "PracticeTests", dependencies: ["Practice"])]
        )
        """, to: source.appending(path: "Package.swift"))
        try write("""
        public func greeting(for name: String) -> String {
            "Hello, \\(name)!"
        }
        """, to: source.appending(path: "Sources/Practice/Greeting.swift"))
        try write("""
        import Testing
        @testable import Practice

        @Test func greetingIncludesName() {
            #expect(greeting(for: "Ada") == "Hello, Ada!")
        }
        """, to: source.appending(path: "Tests/PracticeTests/GreetingTests.swift"))
    }

    private func writePullRequestChange(at source: URL) throws {
        try write("""
        public func greeting(for name: String) -> String {
            "Hello, \\(name)! Welcome to the practice flow."
        }
        """, to: source.appending(path: "Sources/Practice/Greeting.swift"))
    }

    private func write(_ content: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }
}
