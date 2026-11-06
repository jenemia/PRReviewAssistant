import Foundation

/// Pre-PR UnitTest step, ported from SpecGuard's generate → patch guard → validate flow.
///
/// Agents read a temporary checkout of the selected commit. Validation and the
/// output commit use separate temporary files, leaving the registered checkout intact.
struct UnitTestVerifier: Sendable {
    static let maxTargets = 5
    static let maxAttempts = 3
    static let maxDependencies = 12
    private static let selectionBatchSize = 25
    static let maxSourceCharacters = 40_000
    static let forbiddenTokens = ["InternalsVisibleTo", "#define", "UnityEngine", "UnityEditor"]

    struct Target: Sendable {
        let sourcePath: String
        let source: String
        let diff: String
        let suggestedTestPath: String
        let stylePath: String?
        let styleSample: String?
        var behavior: String = ""
    }

    struct Change: Sendable {
        let sourcePath: String
        let diff: String
    }

    struct Candidate: Decodable, Sendable {
        let sourcePath: String
        let behavior: String
        let priority: Int
    }

    struct GenerationRequest: Sendable {
        let target: Target
        let previousError: String?
        var workspace: String = ""
    }

    struct ValidationOutcome: Sendable {
        let success: Bool
        let log: String
    }

    typealias Selector = @Sendable (String, String, [Change]) throws -> [Candidate]
    typealias Generator = @Sendable (GenerationRequest) throws -> UnitTestProposal
    /// (temp folder, source files, test files) → outcome. Replaceable so tests need no .NET SDK.
    typealias Validator = @Sendable (String, [String], [String]) throws -> ValidationOutcome

    private let runner = ProcessRunner(defaultTimeout: 600)
    private let validator: Validator

    init(validator: @escaping Validator = UnitTestVerifier.dotnetValidator) {
        self.validator = validator
    }

    // MARK: - Pure rules (unit tested)

    static func isTestPath(_ path: String) -> Bool {
        let parts = path.split(separator: "/").map(String.init)
        let file = parts.last ?? path
        return parts.dropLast().contains { ["Tests", "Test", "EditModeTests", "PlayModeTests"].contains($0) }
            || file.hasSuffix("Tests.cs") || file.hasSuffix("Test.cs")
    }

    /// Test-only patch guard (SpecGuard `PatchGuard.CheckProposal`).
    static func violations(of files: [UnitTestProposal.File], existingPaths: Set<String>) -> [String] {
        var result: [String] = files.isEmpty ? ["생성 파일 없음"] : []
        for file in files {
            let path = file.path
            let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            if path.hasPrefix("/") || parts.contains("..") || parts.contains(".") || path.contains("\\") {
                result.append("\(path): 저장소 밖 경로")
            } else if !path.hasSuffix("Tests.cs") || !parts.dropLast().contains("Tests") {
                result.append("\(path): 허용된 테스트 경로가 아님 (…/Tests/…Tests.cs)")
            } else if existingPaths.contains(path) {
                result.append("\(path): 기존 파일 덮어쓰기 금지")
            }
            for token in forbiddenTokens where file.content.contains(token) {
                result.append("\(path): 금지 토큰 '\(token)' 포함")
            }
        }
        return result
    }

    /// Existing test next to similar sources wins; otherwise `Tests/<Class>Tests.cs`.
    static func suggestedTestPath(for sourcePath: String, testFiles: [String]) -> String {
        let name = ((sourcePath as NSString).lastPathComponent as NSString).deletingPathExtension
        let directories = testFiles.filter { $0.split(separator: "/").dropLast().contains("Tests") }
        let directory = closestTestFile(to: sourcePath, in: directories)
            .map { ($0 as NSString).deletingLastPathComponent } ?? "Tests"
        let existing = Set(testFiles)
        let standard = "\(directory)/\(name)Tests.cs"
        guard !existing.contains(standard) else {
            var number = 1
            while true {
                let suffix = number == 1 ? "Diff" : "Diff\(number)"
                let path = "\(directory)/\(name)\(suffix)Tests.cs"
                if !existing.contains(path) { return path }
                number += 1
            }
        }
        return standard
    }

    static func closestTestFile(to sourcePath: String, in testFiles: [String]) -> String? {
        let source = sourcePath.split(separator: "/").dropLast()
        return testFiles.max { shared(source, $0) < shared(source, $1) }
    }

    private static func shared(_ source: ArraySlice<Substring>, _ test: String) -> Int {
        zip(source, test.split(separator: "/").dropLast()).prefix { $0 == $1 }.count
    }

    static func validationProject(sourceFiles: [String], testFiles: [String], framework: String) -> String {
        let includes = (sourceFiles + testFiles)
            .map { "    <Compile Include=\"\(xmlEscaped($0))\" />" }
            .joined(separator: "\n")
        return """
        <Project Sdk="Microsoft.NET.Sdk">
          <PropertyGroup>
            <TargetFramework>\(framework)</TargetFramework>
            <Nullable>disable</Nullable>
            <ImplicitUsings>disable</ImplicitUsings>
            <EnableDefaultCompileItems>false</EnableDefaultCompileItems>
            <IsPackable>false</IsPackable>
            <TreatWarningsAsErrors>false</TreatWarningsAsErrors>
          </PropertyGroup>
          <ItemGroup>
        \(includes)
          </ItemGroup>
          <ItemGroup>
            <PackageReference Include="Microsoft.NET.Test.Sdk" Version="17.14.1" />
            <PackageReference Include="NUnit" Version="3.14.0" />
            <PackageReference Include="NUnit3TestAdapter" Version="4.6.0" />
          </ItemGroup>
        </Project>
        """
    }

    /// Reads `<Counters … passed="3" failed="0" notExecuted="1" />` from a TRX file.
    /// The console summary is localized, so the TRX is the language-independent source.
    static func testCounts(inTRX xml: String) -> (failed: Int, passed: Int, skipped: Int)? {
        guard let counters = xml.range(of: #"<Counters[^>]*>"#, options: .regularExpression).map({ String(xml[$0]) }) else { return nil }
        func value(_ name: String) -> Int? {
            counters.range(of: "\(name)=\"(\\d+)\"", options: .regularExpression)
                .flatMap { Int(counters[$0].filter(\.isNumber)) }
        }
        guard let passed = value("passed"), let failed = value("failed") else { return nil }
        return (failed + (value("error") ?? 0), passed, value("notExecuted") ?? 0)
    }

    private static func xmlEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func tail(_ text: String, _ limit: Int = 4000) -> String {
        text.count <= limit ? text : String(text.suffix(limit))
    }

    // MARK: - dotnet validation

    /// Compiles the selected sources and runs the generated tests in an isolated project.
    static let dotnetValidator: Validator = { folder, sourceFiles, testFiles in
        let runner = ProcessRunner()
        let version = try runner.run("dotnet", arguments: ["--version"], timeout: 30).output
        guard let major = version.split(separator: ".").first.flatMap({ Int($0) }) else {
            throw CommandError.failed(.init(output: version, error: "dotnet 버전을 확인할 수 없습니다.", status: 1))
        }
        let project = (folder as NSString).appendingPathComponent("Validation.csproj")
        try validationProject(sourceFiles: sourceFiles, testFiles: testFiles, framework: "net\(major).0")
            .write(toFile: project, atomically: true, encoding: .utf8)

        let results = (folder as NSString).appendingPathComponent("results")
        var output = ""
        do {
            let result = try runner.run(
                "dotnet", arguments: ["test", project, "--nologo", "--logger", "trx;LogFileName=validation.trx", "--results-directory", results],
                workingDirectory: folder, timeout: 600
            )
            output = result.output + result.error
        } catch CommandError.failed(let result) {
            return ValidationOutcome(success: false, log: tail(result.output + result.error))
        } catch CommandError.timedOut {
            return ValidationOutcome(success: false, log: "dotnet test 시간이 초과되었습니다.")
        }
        // An empty or missing TRX cannot verify that any test ran.
        guard let trx = try? String(contentsOfFile: (results as NSString).appendingPathComponent("validation.trx"), encoding: .utf8),
              let counts = testCounts(inTRX: trx) else {
            return ValidationOutcome(success: false, log: tail(output))
        }
        if counts.failed > 0 { return ValidationOutcome(success: false, log: tail(output)) }
        if counts.passed == 0 { return ValidationOutcome(success: false, log: "실행된 테스트가 없습니다 (모두 건너뜀).\n" + tail(output)) }
        return ValidationOutcome(success: true, log: tail(output))
    }

    // MARK: - Workflow

    func verify(
        repository: RegisteredRepository,
        branch: RepositoryBranch,
        baseReference: String,
        developerName: String,
        select: Selector,
        generate: Generator,
        progress: @Sendable (String) -> Void
    ) throws -> UnitTestVerification {
        let path = repository.localPath
        let head = try git(["rev-parse", "--verify", "--end-of-options", "\(branch.reference)^{commit}"], at: path)
        guard head.hasPrefix(branch.sha) else {
            throw failure("브랜치가 목록과 달라졌습니다. 목록을 새로 고친 뒤 다시 시도하세요.")
        }
        try verifyRemoteHead(repository: repository, branch: branch, expected: head)
        let mergeBase = try git(["merge-base", baseReference, head], at: path)

        let statuses = try gitList(["diff", "--name-status", "-z", "--find-renames", "--diff-filter=AMR", mergeBase, head, "--", "*.cs"], at: path)
        var changed: [(source: String, paths: [String])] = []
        var entries = statuses.makeIterator()
        while let status = entries.next(), let first = entries.next() {
            if status.hasPrefix("R"), let destination = entries.next() {
                if !Self.isTestPath(destination) { changed.append((destination, [first, destination])) }
            } else if !Self.isTestPath(first) {
                changed.append((first, [first]))
            }
        }
        func noTargets(_ summary: String) -> UnitTestVerification {
            .init(outcome: .notApplicable, verifiedSHA: head, resultSHA: head, pushed: false, summary: summary, files: [])
        }
        guard !changed.isEmpty else { return noTargets("변경된 C# 소스가 없어 UnitTest 대상이 없습니다.") }

        let work = FileManager.default.temporaryDirectory.appendingPathComponent("PRReviewAssistant-unittest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let workspace = work.appendingPathComponent("checkout").path
        let outputBranch = "unittest/\(UUID().uuidString.lowercased())"
        progress("선택한 커밋에서 UnitTest 작업 브랜치를 체크아웃하는 중입니다.")
        try git(["worktree", "add", "-b", outputBranch, workspace, head], at: path)
        defer {
            _ = try? git(["worktree", "remove", "--force", workspace], at: path)
            _ = try? git(["branch", "-D", outputBranch], at: path)
        }

        var candidates: [(candidate: Candidate, paths: [String])] = []
        for start in stride(from: 0, to: changed.count, by: Self.selectionBatchSize) {
            let batch = changed[start..<min(start + Self.selectionBatchSize, changed.count)]
            progress("변경된 비즈니스 로직을 선별하는 중입니다 (\(batch.endIndex)/\(changed.count)).")
            let changes = try batch.map { entry in
                let diff = try git(["--literal-pathspecs", "diff", "--find-renames", "--no-ext-diff", "--no-textconv", "-U2", mergeBase, head, "--"] + entry.paths, at: path, trim: false)
                let excerpt = diff.count > 3000 ? String(diff.prefix(3000)) + "\n(이후 diff 생략)" : diff
                return Change(sourcePath: entry.source, diff: excerpt)
            }
            let pathsBySource = Dictionary(uniqueKeysWithValues: batch.map { ($0.source, $0.paths) })
            var seen: Set<String> = []
            for candidate in try select(workspace, mergeBase, changes) {
                guard let paths = pathsBySource[candidate.sourcePath], seen.insert(candidate.sourcePath).inserted,
                      (1...3).contains(candidate.priority), !candidate.behavior.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      candidate.behavior.count <= 1000 else {
                    throw failure("UnitTest 대상 선별 응답에 잘못된 경로, 동작 또는 우선순위가 있습니다.")
                }
                candidates.append((candidate, paths))
            }
        }
        guard !candidates.isEmpty else {
            return noTargets("변경된 C# 소스 \(changed.count)개에서 새 UnitTest가 필요한 비즈니스 로직을 찾지 못했습니다.")
        }

        let allFiles = Set(try gitList(["ls-tree", "-r", "--name-only", "-z", head], at: path))
        let testFiles = allFiles.filter { $0.hasSuffix(".cs") && Self.isTestPath($0) }.sorted()
        let prioritized = candidates.sorted {
            if $0.candidate.priority != $1.candidate.priority { return $0.candidate.priority > $1.candidate.priority }
            return $0.candidate.sourcePath < $1.candidate.sourcePath
        }
        var results: [UnitTestVerification.FileResult] = []
        var accepted: [UnitTestProposal.File] = []
        let targets = prioritized.prefix(Self.maxTargets)
        for (index, entry) in targets.enumerated() {
            let source = entry.candidate.sourcePath
            progress("\(index + 1)/\(targets.count) \(source) 테스트를 생성·검증하는 중입니다.")
            let text = try git(["show", "\(head):\(source)"], at: path, trim: false)
            let diff = try git(["--literal-pathspecs", "diff", "--find-renames", "--no-ext-diff", "--no-textconv", mergeBase, head, "--"] + entry.paths, at: path, trim: false)
            let style = Self.closestTestFile(to: source, in: testFiles)
            let target = Target(
                sourcePath: source, source: text, diff: String(diff.prefix(Self.maxSourceCharacters)),
                suggestedTestPath: Self.suggestedTestPath(for: source, testFiles: testFiles + accepted.map(\.path)),
                stylePath: style,
                styleSample: try style.map { String(try git(["show", "\(head):\($0)"], at: path, trim: false).prefix(6000)) },
                behavior: entry.candidate.behavior
            )
            results.append(try validateTarget(
                target, folder: work.appendingPathComponent("t\(index)").path, workspace: workspace,
                repositoryPath: path, head: head, tracked: allFiles, generate: generate, accepted: &accepted
            ))
        }

        var pushed = false
        var resultSHA = head
        if !accepted.isEmpty {
            progress("통과한 테스트 \(accepted.count)개를 새 브랜치에 커밋·푸시하는 중입니다.")
            try verifyRemoteHead(repository: repository, branch: branch, expected: head)
            let currentHead = try git(["rev-parse", "--verify", "--end-of-options", "\(branch.reference)^{commit}"], at: path)
            guard currentHead == head else { throw failure("검증 중 원본 브랜치가 변경되었습니다. 다시 시도하세요.") }
            let message = "[개발 - \(developerName)] UnitTest 추가: " + accepted.map { (($0.path as NSString).lastPathComponent as NSString).deletingPathExtension }.joined(separator: ", ")
            resultSHA = try commitAndPush(accepted, parent: head, message: message, repository: repository, branchName: outputBranch, workFolder: work.path)
            pushed = true
        }

        let failed = results.filter { $0.status == .failed }.count
        let passed = results.filter { $0.status == .passed }.count
        let outcome: UnitTestVerification.Outcome = failed > 0 ? .failed : (passed > 0 ? .passed : .notApplicable)
        let excluded = changed.count - candidates.count
        let deferred = candidates.count - targets.count
        let summary = "통과 \(passed)개 · 실패 \(failed)개 · 건너뜀 \(results.count - passed - failed)개 · 범위 밖 \(excluded)개 · 상한 초과 미처리 \(deferred)개" + (pushed ? " — 통과한 테스트를 \(repository.remoteName)/\(outputBranch)에 푸시했습니다." : "")
        return UnitTestVerification(outcome: outcome, verifiedSHA: head, resultSHA: resultSHA, pushed: pushed, summary: summary, files: results)
    }

    /// Up to `maxAttempts` generate → guard → validate rounds; failures feed the next prompt.
    private func validateTarget(
        _ target: Target, folder: String, workspace: String,
        repositoryPath: String, head: String, tracked: Set<String>,
        generate: Generator, accepted: inout [UnitTestProposal.File]
    ) throws -> UnitTestVerification.FileResult {
        func result(_ status: UnitTestVerification.FileResult.Status, _ detail: String, test: String? = nil) -> UnitTestVerification.FileResult {
            .init(sourcePath: target.sourcePath, testPath: test, status: status, detail: detail)
        }
        var previousError: String?
        for _ in 1...Self.maxAttempts {
            let proposal = try generate(.init(target: target, previousError: previousError, workspace: workspace))
            guard proposal.status == UnitTestProposal.generated else {
                return result(.skipped, proposal.reason.isEmpty ? "Agent가 UnitTest를 만들 수 없다고 판단했습니다 (\(proposal.status))." : proposal.reason)
            }
            let violations = Self.violations(of: proposal.files, existingPaths: tracked.union(accepted.map(\.path)))
            if !violations.isEmpty { return result(.failed, "정책 위반으로 폐기: " + violations.joined(separator: "; ")) }

            let dependencies = proposal.dependencies ?? []
            guard dependencies.count <= Self.maxDependencies, Set(dependencies).count == dependencies.count,
                  dependencies.allSatisfy({ $0 != target.sourcePath && $0.hasSuffix(".cs") && tracked.contains($0) && !Self.isTestPath($0) }) else {
                previousError = "의존 소스는 선택 커밋에 추적된 별도 C# 소스 최대 \(Self.maxDependencies)개여야 합니다."
                continue
            }

            let fileManager = FileManager.default
            try? fileManager.removeItem(atPath: folder)
            try fileManager.createDirectory(atPath: folder, withIntermediateDirectories: true)
            let sourceFile = "Source/" + (target.sourcePath as NSString).lastPathComponent
            var sourceFiles = [sourceFile]
            var testFiles: [String] = []
            try write(target.source, to: "\(folder)/\(sourceFile)")
            for (index, dependency) in dependencies.enumerated() {
                let relative = "Source/Dependencies/\(index).cs"
                let contents = try git(["show", "\(head):\(dependency)"], at: repositoryPath, trim: false)
                try write(contents, to: "\(folder)/\(relative)")
                sourceFiles.append(relative)
            }
            for (offset, file) in proposal.files.enumerated() {
                let relative = "Tests/\(offset)_" + (file.path as NSString).lastPathComponent
                try write(file.content, to: "\(folder)/\(relative)")
                testFiles.append(relative)
            }

            let outcome = try validator(folder, sourceFiles, testFiles)
            if outcome.success {
                accepted += proposal.files
                return result(.passed, outcome.log.isEmpty ? "검증 통과" : outcome.log, test: proposal.files.map(\.path).joined(separator: ", "))
            }
            previousError = outcome.log
        }
        return result(.failed, "\(Self.maxAttempts)회 시도 후 검증 실패:\n" + (previousError ?? ""))
    }

    private func write(_ text: String, to path: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Builds the commit from a temporary index so the work folder, its index and HEAD stay untouched.
    private func commitAndPush(
        _ files: [UnitTestProposal.File], parent: String, message: String,
        repository: RegisteredRepository, branchName: String, workFolder: String
    ) throws -> String {
        let path = repository.localPath
        let index = (workFolder as NSString).appendingPathComponent("index")
        _ = try git(["read-tree", parent], at: path, indexFile: index)
        for file in files {
            let blob = try runner.run("git", arguments: ["hash-object", "-w", "--stdin"], workingDirectory: path, input: file.content)
                .output.trimmingCharacters(in: .whitespacesAndNewlines)
            _ = try git(["update-index", "--add", "--cacheinfo", "100644,\(blob),\(file.path)"], at: path, indexFile: index)
        }
        let tree = try git(["write-tree"], at: path, indexFile: index)
        let commit = try git(["commit-tree", tree, "-p", parent, "-m", message], at: path)
        // An empty lease requires that the output branch does not already exist.
        _ = try git(["push", "--force-with-lease=refs/heads/\(branchName):", repository.remoteName, "\(commit):refs/heads/\(branchName)"], at: path)
        let pushedHead = try git(["ls-remote", repository.remoteName, "refs/heads/\(branchName)"], at: path).split(whereSeparator: { $0 == "\t" || $0 == " " }).first.map(String.init)
        guard pushedHead == commit else {
            throw failure("푸시 후 원격 브랜치 SHA를 확인하지 못했습니다.")
        }
        return commit
    }

    private func verifyRemoteHead(repository: RegisteredRepository, branch: RepositoryBranch, expected: String) throws {
        guard try remoteHead(repository: repository, branch: branch) == expected else {
            throw failure("원격 브랜치가 검토한 커밋과 다릅니다. 목록을 새로 고친 뒤 다시 시도하세요.")
        }
    }

    private func remoteHead(repository: RegisteredRepository, branch: RepositoryBranch) throws -> String? {
        try git(["ls-remote", repository.remoteName, "refs/heads/\(branch.name)"], at: repository.localPath)
            .split(whereSeparator: { $0 == "\t" || $0 == " " }).first.map(String.init)
    }

    @discardableResult
    private func git(_ arguments: [String], at path: String, indexFile: String? = nil, trim: Bool = true) throws -> String {
        let result: CommandResult
        if let indexFile {
            result = try runner.run("/usr/bin/env", arguments: ["GIT_INDEX_FILE=\(indexFile)", "/usr/bin/git"] + arguments, workingDirectory: path)
        } else {
            result = try runner.run("git", arguments: arguments, workingDirectory: path)
        }
        return trim ? result.output.trimmingCharacters(in: .whitespacesAndNewlines) : result.output
    }

    private func gitList(_ arguments: [String], at path: String) throws -> [String] {
        try git(arguments, at: path, trim: false).split(separator: "\0").map(String.init)
    }

    private func failure(_ message: String) -> CommandError {
        .failed(.init(output: "", error: message, status: 1))
    }
}
