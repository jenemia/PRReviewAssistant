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
        /// Tests a previous run put on the UnitTest branch; the agent may rewrite or delete them.
        var existingTests: [String] = []
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

    /// `sprint/s29/feature/christmas2026` → `sprint/s29/unittest/christmas2026`, `feature/x` → `unittest/x`.
    static func unitTestBranchName(for branchName: String) -> String {
        let parts = branchName.split(separator: "/").map(String.init)
        let prefix = parts.count >= 3 && parts[0] == "sprint" ? Array(parts.prefix(2)) : []
        let rest = Array(parts.dropFirst(prefix.count))
        return (prefix + ["unittest"] + (rest.count > 1 ? Array(rest.dropFirst()) : rest)).joined(separator: "/")
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
        let head: String
        do {
            head = try git(["rev-parse", "--verify", "--end-of-options", "\(branch.reference)^{commit}"], at: path)
        } catch CommandError.failed(let result) {
            throw failure("검증할 브랜치 '\(branch.name)'의 로컬 참조를 확인하지 못했습니다. 브랜치 목록을 새로 고치고 원격 브랜치가 남아 있는지 확인하세요.\n\(result.error)")
        }
        guard head.hasPrefix(branch.sha) else {
            throw failure("브랜치가 목록과 달라졌습니다. 목록을 새로 고친 뒤 다시 시도하세요.")
        }
        if branch.isRemote { try verifyRemoteHead(repository: repository, branch: branch, expected: head) }
        var mergeBase: String
        do {
            mergeBase = try git(["merge-base", baseReference, head], at: path)
        } catch CommandError.failed(let result) {
            throw failure("비교 기준 '\(baseReference)'을 찾거나 공통 조상을 확인할 수 없습니다. 기준 브랜치와 저장소 이력을 확인하세요.\n\(result.error)")
        }

        if mergeBase == head {
            let merges = try git(["rev-list", "--first-parent", "--merges", "--parents", baseReference], at: path)
            let matching = merges.split(whereSeparator: \.isNewline).compactMap { line -> String? in
                let commits = line.split(separator: " ").map(String.init)
                guard commits.count == 3, commits[2] == head else { return nil }
                return commits[1]
            }
            guard matching.count == 1 else {
                throw failure("병합 전 변경 범위를 Git 이력에서 유일하게 찾을 수 없습니다. 병합 커밋과 원본 브랜치가 보존되어 있는지 확인하세요.")
            }
            mergeBase = try git(["merge-base", matching[0], head], at: path)
        }

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
        let outputBranch = Self.unitTestBranchName(for: branch.name)
        let outputRef = "refs/heads/\(outputBranch)"
        let remoteTip = try git(["ls-remote", repository.remoteName, outputRef], at: path)
            .split(whereSeparator: { $0 == "\t" || $0 == " " }).first.map(String.init)
        let localTip = try? git(["rev-parse", "--verify", "--quiet", "\(outputRef)^{commit}"], at: path)
        if remoteTip != nil {
            try git(["fetch", "--no-tags", repository.remoteName, "+\(outputRef):refs/remotes/\(repository.remoteName)/\(outputBranch)"], at: path)
        }
        progress(localTip == nil && remoteTip == nil ? "선택한 커밋에서 UnitTest 작업 브랜치를 만드는 중입니다." : "기존 UnitTest 브랜치 \(outputBranch)를 체크아웃하는 중입니다.")
        do {
            if localTip != nil {
                try git(["worktree", "add", workspace, outputBranch], at: path)
            } else {
                try git(["worktree", "add", "-b", outputBranch, workspace, remoteTip ?? head], at: path)
            }
        } catch CommandError.failed(let result) {
            throw failure("UnitTest 브랜치 \(outputBranch)를 체크아웃하지 못했습니다. 다른 작업 폴더에서 체크아웃 중인지 확인하세요.\n\(result.error)")
        }
        // A pre-existing local branch is kept (moved only to what was pushed); one created here is removed.
        var finalLocalTip = localTip
        defer {
            _ = try? git(["worktree", "remove", "--force", workspace], at: path)
            if let finalLocalTip {
                _ = try? git(["update-ref", outputRef, finalLocalTip], at: path)
            } else {
                _ = try? git(["branch", "-D", outputBranch], at: path)
            }
        }
        if let remoteTip, let localTip, localTip != remoteTip,
           (try? git(["merge", "--ff-only", remoteTip], at: workspace)) == nil {
            throw failure("로컬 \(outputBranch)와 원격 브랜치가 갈라졌습니다. 한쪽으로 정리한 뒤 다시 시도하세요.")
        }
        if (try? git(["merge-base", "--is-ancestor", head, "HEAD"], at: workspace)) == nil {
            progress("선택한 커밋을 UnitTest 브랜치에 병합하는 중입니다.")
            do {
                try git(["merge", "--no-edit", "-m", "[개발 - \(developerName)] \(branch.name) 변경 병합", head], at: workspace)
            } catch {
                _ = try? git(["merge", "--abort"], at: workspace)
                throw failure("선택한 커밋을 UnitTest 브랜치 \(outputBranch)에 병합하지 못했습니다. 충돌을 정리한 뒤 다시 시도하세요.")
            }
        }
        let base = try git(["rev-parse", "HEAD"], at: workspace)
        // Tests this UnitTest branch added on top of the selected commit; only these may be changed or deleted.
        let ownedTests = Set(try gitList(["diff", "--name-only", "-z", "--diff-filter=AMR", head, base, "--", "*.cs"], at: path).filter(Self.isTestPath))

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
        var deleted: [String] = []
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
                behavior: entry.candidate.behavior,
                existingTests: ownedTests.subtracting(deleted).sorted()
            )
            results.append(try validateTarget(
                target, folder: work.appendingPathComponent("t\(index)").path, workspace: workspace,
                repositoryPath: path, head: head, tracked: allFiles, owned: ownedTests, generate: generate,
                accepted: &accepted, deleted: &deleted
            ))
        }

        var pushed = false
        var resultSHA = head
        if !accepted.isEmpty || !deleted.isEmpty {
            progress("통과한 테스트 \(accepted.count)개와 삭제 \(deleted.count)개를 UnitTest 브랜치에 커밋·푸시하는 중입니다.")
            if branch.isRemote { try verifyRemoteHead(repository: repository, branch: branch, expected: head) }
            let currentHead = try git(["rev-parse", "--verify", "--end-of-options", "\(branch.reference)^{commit}"], at: path)
            guard currentHead == head else { throw failure("검증 중 원본 브랜치가 변경되었습니다. 다시 시도하세요.") }
            func names(_ paths: [String]) -> String { paths.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension }.joined(separator: ", ") }
            let updatesExisting = !deleted.isEmpty || accepted.contains { ownedTests.contains($0.path) }
            let message = "[개발 - \(developerName)] UnitTest \(updatesExisting ? "갱신" : "추가"): " + names(accepted.map(\.path))
                + (deleted.isEmpty ? "" : (accepted.isEmpty ? "" : " / ") + "삭제 " + names(deleted))
            resultSHA = try commitAndPush(accepted, deleting: deleted, parent: base, expectedRemote: remoteTip, message: message, repository: repository, branchName: outputBranch, workFolder: work.path)
            if localTip != nil { finalLocalTip = resultSHA }
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
        repositoryPath: String, head: String, tracked: Set<String>, owned: Set<String>,
        generate: Generator, accepted: inout [UnitTestProposal.File], deleted: inout [String]
    ) throws -> UnitTestVerification.FileResult {
        func result(_ status: UnitTestVerification.FileResult.Status, _ detail: String, test: String? = nil) -> UnitTestVerification.FileResult {
            .init(sourcePath: target.sourcePath, testPath: test, status: status, detail: detail)
        }
        var previousError: String?
        for _ in 1...Self.maxAttempts {
            let proposal: UnitTestProposal
            do {
                proposal = try generate(.init(target: target, previousError: previousError, workspace: workspace))
            } catch let error as UnitTestProposal.ParseError {
                previousError = error.localizedDescription
                continue
            }
            guard proposal.status == UnitTestProposal.generated else {
                return result(.skipped, proposal.reason.isEmpty ? "Agent가 UnitTest를 만들 수 없다고 판단했습니다 (\(proposal.status))." : proposal.reason)
            }
            let deletions = proposal.deletions ?? []
            let written = Set(proposal.files.map(\.path))
            let acceptedPaths = Set(accepted.map(\.path))
            let invalidDeletions = deletions.filter { !owned.contains($0) || deleted.contains($0) || written.contains($0) || acceptedPaths.contains($0) }
            if !invalidDeletions.isEmpty {
                return result(.failed, "정책 위반으로 폐기: 이 UnitTest 브랜치가 만든 테스트만 삭제할 수 있음 (" + invalidDeletions.joined(separator: ", ") + ")")
            }
            if proposal.files.isEmpty, !deletions.isEmpty {
                deleted += deletions
                return result(.passed, "기존 UnitTest 삭제: " + (proposal.reason.isEmpty ? "변경 동작에 맞지 않음" : proposal.reason), test: deletions.joined(separator: ", "))
            }
            // Tests owned by this UnitTest branch are not in the selected commit, so they may be rewritten.
            let violations = Self.violations(of: proposal.files, existingPaths: tracked.union(accepted.map(\.path)).union(deleted))
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
                deleted += deletions
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
        _ files: [UnitTestProposal.File], deleting deletions: [String], parent: String, expectedRemote: String?, message: String,
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
        for deletion in deletions {
            _ = try git(["update-index", "--force-remove", "--", deletion], at: path, indexFile: index)
        }
        let tree = try git(["write-tree"], at: path, indexFile: index)
        let commit = try git(["commit-tree", tree, "-p", parent, "-m", message], at: path)
        // The lease pins the remote to what was checked out (empty: the branch must not exist yet).
        _ = try git(["push", "--force-with-lease=refs/heads/\(branchName):\(expectedRemote ?? "")", repository.remoteName, "\(commit):refs/heads/\(branchName)"], at: path)
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
