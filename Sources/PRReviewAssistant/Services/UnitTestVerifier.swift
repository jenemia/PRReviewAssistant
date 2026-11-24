import Foundation

/// Pre-PR UnitTest step, ported from SpecGuard's generate → patch guard → validate flow.
///
/// The registered checkout is switched to the local UnitTest branch; agents read it and
/// tests that pass validation (in temporary projects) are left there uncommitted.
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
        /// Unity repositories validate against `UnityEngineShim` and may use UnityEngine in tests.
        var isUnityProject = false
        /// Spec mode: the spec the user picked is the primary source of expected values.
        var spec: SpecDocument?
        /// Branch mode: specs this branch's own commits changed; expected values come from here before the diff.
        var branchSpec: SpecDocument?
    }

    /// A spec document chosen in the Spec tab, read from the registered folder.
    struct SpecDocument: Sendable {
        let path: String
        let text: String
        let truncated: Bool
    }

    struct Change: Sendable {
        let sourcePath: String
        let diff: String
        /// Subjects of this branch's own (first-parent, non-merge) commits that touched the file.
        var commits: [String] = []
    }

    /// Proposal `verification` value for a test that copies source rules because the source cannot compile.
    static let replicaVerification = "replica"


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
    /// (workspace, spec, C# sources the spec names) → candidates; paths outside the tracked sources are dropped.
    typealias SpecSelector = @Sendable (String, SpecDocument, [String]) throws -> [Candidate]
    static let maxSpecCharacters = 30_000
    private static let maxReferencedSources = 40
    /// Branch mode reads at most this many spec folders, the ones the branch changed most.
    static let maxBranchSpecs = 4
    /// Headings whose sections hold expected values; kept first when a spec is cut to `maxSpecCharacters`.
    static let specSectionKeywords = ["수용", "테스트", "시나리오", "규칙", "예외", "경계", "검증", "qa", "acceptance", "test", "scenario", "rule"]
    typealias Generator = @Sendable (GenerationRequest) throws -> UnitTestProposal
    /// (temp folder, source files, test files) → outcome. Replaceable so tests need no .NET SDK.
    typealias Validator = @Sendable (String, [String], [String]) throws -> ValidationOutcome

    private let runner = ProcessRunner(defaultTimeout: 600)
    private let validator: Validator

    init(validator: @escaping Validator = UnitTestVerifier.dotnetValidator) {
        self.validator = validator
    }

    static let unsupportedMessage = "이 저장소에 C# 소스가 없어 UnitTest 생성을 쓸 수 없습니다. 현재 C#(NUnit, dotnet test) 프로젝트만 지원합니다."

    // MARK: - Pure rules (unit tested)

    static func isTestPath(_ path: String) -> Bool {
        let parts = path.split(separator: "/").map(String.init)
        let file = parts.last ?? path
        return parts.dropLast().contains { ["Tests", "Test", "EditModeTests", "PlayModeTests"].contains($0) }
            || file.hasSuffix("Tests.cs") || file.hasSuffix("Test.cs")
    }

    /// Test-only patch guard (SpecGuard `PatchGuard.CheckProposal`).
    /// `allowedDirectories` are test folders outside a `Tests` folder: the repository's UnitTest folder
    /// and folders that already hold `…Tests.cs` files (e.g. a Unity `TestCase/Editor`).
    static func violations(of files: [UnitTestProposal.File], existingPaths: Set<String>, allowsUnityEngine: Bool = false, allowedDirectories: Set<String> = []) -> [String] {
        let tokens = allowsUnityEngine ? forbiddenTokens.filter { $0 != "UnityEngine" } + ["UnityShim"] : forbiddenTokens
        var result: [String] = files.isEmpty ? ["생성 파일 없음"] : []
        for file in files {
            let path = file.path
            let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            if path.hasPrefix("/") || parts.contains("..") || parts.contains(".") || path.contains("\\") {
                result.append("\(path): 저장소 밖 경로")
            } else if !path.hasSuffix("Tests.cs") || !(parts.dropLast().contains("Tests") || allowedDirectories.contains(parts.dropLast().joined(separator: "/"))) {
                result.append("\(path): 허용된 테스트 경로가 아님 (…/Tests/…Tests.cs 또는 기존 테스트 폴더의 …Tests.cs)")
            } else if existingPaths.contains(path) {
                result.append("\(path): 기존 파일 덮어쓰기 금지")
            }
            for token in tokens where file.content.contains(token) {
                result.append("\(path): 금지 토큰 '\(token)' 포함")
            }
        }
        return result
    }

    /// The repository's UnitTest folder wins; then an existing test next to similar sources; otherwise `Tests/<Class>Tests.cs`.
    static func suggestedTestPath(for sourcePath: String, testFiles: [String], folder: String? = nil) -> String {
        let name = ((sourcePath as NSString).lastPathComponent as NSString).deletingPathExtension
        let directories = testFiles.filter { $0.split(separator: "/").dropLast().contains("Tests") }
        let directory = folder ?? closestTestFile(to: sourcePath, in: directories)
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

    /// C# sources a spec names in backticks, as a full path or a path/file-name suffix of a tracked source.
    static func referencedSources(in spec: String, sources: [String]) -> [String] {
        let tokens = spec.split(separator: "`", omittingEmptySubsequences: false).enumerated()
            .compactMap { $0.offset.isMultiple(of: 2) ? nil : $0.element.trimmingCharacters(in: .whitespaces) }
            .map { $0.hasPrefix("./") ? String($0.dropFirst(2)) : $0 }
            .filter { $0.hasSuffix(".cs") && !$0.contains(" ") }
        var result: [String] = []
        for token in tokens {
            for source in sources where (source == token || source.hasSuffix("/" + token)) && !result.contains(source) {
                result.append(source)
            }
        }
        return result.filter { !isTestPath($0) }
    }

    /// Cuts a Markdown document to about `limit` characters without dropping the sections that hold expected values.
    /// The text before the first heading comes first, then sections whose heading (or parent heading) names
    /// acceptance criteria, scenarios or rules, then the rest; kept sections stay in document order.
    /// Omitted headings are listed so the agent can read them from the file.
    static func specExcerpt(_ text: String, limit: Int) -> (text: String, truncated: Bool) {
        guard text.count > limit else { return (text, false) }
        var sections: [(heading: String, body: String, priority: Bool)] = []
        var priorityLevel: Int?
        var inFence = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("```") { inFence.toggle() }
            let level = inFence ? 0 : line.prefix { $0 == "#" }.count
            guard level > 0, line.dropFirst(level).first == " " else {
                if sections.isEmpty { sections.append(("", "", true)) }
                sections[sections.count - 1].body += line + "\n"
                continue
            }
            if let current = priorityLevel, level <= current { priorityLevel = nil }
            let heading = line.dropFirst(level).trimmingCharacters(in: .whitespaces)
            if priorityLevel == nil, specSectionKeywords.contains(where: { heading.lowercased().contains($0) }) { priorityLevel = level }
            sections.append((heading, line + "\n", priorityLevel != nil))
        }
        // The preamble (document map, summary) is first and counts as a priority section.
        let order = sections.indices.filter { $0 == 0 || sections[$0].priority } + sections.indices.filter { $0 != 0 && !sections[$0].priority }
        var remaining = limit
        var kept: [Int: String] = [:]
        for index in order {
            let body = sections[index].body
            if body.count <= remaining {
                kept[index] = body
                remaining -= body.count
            } else if sections[index].priority, remaining > 500 {
                kept[index] = String(body.prefix(remaining)) + "\n(이 섹션은 길이 제한으로 앞부분만 포함)\n"
                remaining = 0
            }
        }
        let omitted = sections.indices.filter { kept[$0] == nil }.map { sections[$0].heading }.filter { !$0.isEmpty }
        let note = omitted.isEmpty ? "" : "\n(길이 제한으로 생략한 섹션 \(omitted.count)개: " + omitted.prefix(40).joined(separator: " / ") + (omitted.count > 40 ? " / …" : "") + " — 필요하면 파일에서 직접 읽는다)\n"
        return (sections.indices.compactMap { kept[$0] }.joined() + note, true)
    }

    /// Each `spec.md` with the `qa.md` next to it, every file cut to its share of `limit`.
    /// `read` returns a repository-relative file's text, or nil when it does not exist.
    static func specDocument(specPaths: [String], limit: Int = maxSpecCharacters, read: (String) -> String?) -> (document: SpecDocument, raw: String)? {
        let files = specPaths.flatMap { [$0, (($0 as NSString).deletingLastPathComponent as NSString).appendingPathComponent("qa.md")] }
            .compactMap { path in read(path).map { (path: path, text: $0) } }
        guard !files.isEmpty else { return nil }
        let share = limit / files.count
        let excerpts = files.map { (path: $0.path, excerpt: specExcerpt($0.text, limit: share)) }
        let text = files.count == 1 ? excerpts[0].excerpt.text : excerpts.map { "=== 파일: \($0.path)\n\($0.excerpt.text)" }.joined(separator: "\n")
        let document = SpecDocument(path: specPaths.joined(separator: ", "), text: text, truncated: excerpts.contains { $0.excerpt.truncated })
        return (document, files.map(\.text).joined(separator: "\n"))
    }

    /// Spec documents for Markdown files a branch changed under the spec folders: the nearest `spec.md`
    /// at or above each changed file (inside a spec folder), the most-changed first.
    static func branchSpecPaths(changedDocuments: [String], trackedFiles: Set<String>, specFolders: [String]) -> [String] {
        let folders = Set(specFolders.map { $0.lowercased() })
        var counts: [String: Int] = [:]
        var order: [String] = []
        for document in changedDocuments where document.lowercased().hasSuffix(".md") {
            let directories = document.split(separator: "/").dropLast().map(String.init)
            guard let root = directories.firstIndex(where: { folders.contains($0.lowercased()) }) else { continue }
            let spec = stride(from: directories.count, to: root, by: -1).lazy
                .map { directories.prefix($0).joined(separator: "/") + "/spec.md" }
                .first { trackedFiles.contains($0) }
            guard let spec else { continue }
            if counts[spec] == nil { order.append(spec) }
            counts[spec, default: 0] += 1
        }
        return order.enumerated().sorted { (counts[$0.element]!, -$0.offset) > (counts[$1.element]!, -$1.offset) }.map(\.element)
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
        select: Selector,
        selectSpec: SpecSelector? = nil,
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
        let baseName = baseReference.hasPrefix("refs/remotes/") ? String(baseReference.dropFirst("refs/remotes/".count)) : baseReference
        func noTargets(_ summary: String) -> UnitTestVerification {
            .init(outcome: .notApplicable, verifiedSHA: head, resultSHA: head, pushed: false, summary: "기준 \(baseName) · " + summary, files: [])
        }

        // Specs this branch's own commits changed are the first source of expected values. A branch that changed
        // specs but no C# source (spec, QA and test work) gets its targets from those specs instead of the diff.
        let headFiles = Set(try gitList(["ls-tree", "-r", "--name-only", "-z", head], at: path))
        let ownDocuments = try git(["-c", "core.quotePath=false", "log", "--first-parent", "--no-merges", "--name-only", "--format=", "\(mergeBase)..\(head)", "--", "*.md"], at: path)
            .split(whereSeparator: \.isNewline).map(String.init)
        let specPaths = Array(Self.branchSpecPaths(changedDocuments: ownDocuments, trackedFiles: headFiles, specFolders: repository.effectiveSpecFolders).prefix(Self.maxBranchSpecs))
        let branchSpec = Self.specDocument(specPaths: specPaths) { try? git(["show", "\(head):\($0)"], at: path, trim: false) }
        func specTargets(_ reason: String) throws -> UnitTestVerification {
            guard let branchSpec, let selectSpec else { return noTargets(reason) }
            let sources = headFiles.filter { $0.hasSuffix(".cs") && !Self.isTestPath($0) }
            let referenced = Array(Self.referencedSources(in: branchSpec.raw, sources: sources.sorted()).prefix(Self.maxReferencedSources))
            var outside = 0
            let run = try runOnUnitTestBranch(
                repository: repository, sourceBranch: branch.name, head: head, mergeBase: nil, spec: branchSpec.document,
                generate: generate, progress: progress
            ) { path in
                progress("이 브랜치가 바꾼 spec에서 테스트할 규칙과 구현 소스를 찾는 중입니다.")
                let selected = try plannedSpecTargets(selectSpec(path, branchSpec.document, referenced), sources: sources)
                outside = selected.outside
                return selected.planned
            }
            return Self.specVerification(prefix: "기준 \(baseName) · \(reason) 브랜치 spec \(branchSpec.document.path)", spec: branchSpec.document, run: run, outside: outside, head: head)
        }
        guard !changed.isEmpty else { return try specTargets("변경된 C# 소스가 없어 UnitTest 대상이 없습니다.") }

        // Files that only arrived through merges of other branches are not this branch's work.
        let ownLog = try git(["-c", "core.quotePath=false", "log", "--first-parent", "--no-merges", "--name-only", "--format=%x01%s", "\(mergeBase)..\(head)", "--", "*.cs"], at: path, trim: false)
        var ownCommits: [String: [String]] = [:]
        for block in ownLog.split(separator: "\u{01}") {
            let lines = block.split(whereSeparator: \.isNewline).map(String.init)
            guard let subject = lines.first else { continue }
            for file in lines.dropFirst() where !file.isEmpty { ownCommits[file, default: []].append(subject) }
        }
        let mergedOnly = changed.filter { entry in entry.paths.allSatisfy { ownCommits[$0] == nil } }.count
        changed.removeAll { entry in entry.paths.allSatisfy { ownCommits[$0] == nil } }
        guard !changed.isEmpty else { return try specTargets("변경된 C# 소스 \(mergedOnly)개가 모두 다른 브랜치 병합으로 들어와 이 브랜치의 UnitTest 대상이 없습니다.") }

        let run = try runOnUnitTestBranch(
            repository: repository, sourceBranch: branch.name, head: head, mergeBase: mergeBase, spec: nil, branchSpec: branchSpec?.document,
            generate: generate, progress: progress
        ) { path in
            var planned: [Planned] = []
            for start in stride(from: 0, to: changed.count, by: Self.selectionBatchSize) {
                let batch = changed[start..<min(start + Self.selectionBatchSize, changed.count)]
                progress("변경된 비즈니스 로직을 선별하는 중입니다 (\(batch.endIndex)/\(changed.count)).")
                let changes = try batch.map { entry in
                    let diff = try git(["--literal-pathspecs", "diff", "--find-renames", "--no-ext-diff", "--no-textconv", "-U2", mergeBase, head, "--"] + entry.paths, at: path, trim: false)
                    let excerpt = diff.count > 3000 ? String(diff.prefix(3000)) + "\n(이후 diff 생략)" : diff
                    let commits = Array(Set(entry.paths.flatMap { ownCommits[$0] ?? [] })).sorted().prefix(5).map { String($0.prefix(160)) }
                    return Change(sourcePath: entry.source, diff: excerpt, commits: Array(commits))
                }
                let pathsBySource = Dictionary(uniqueKeysWithValues: batch.map { ($0.source, $0.paths) })
                var seen: Set<String> = []
                for candidate in try select(path, mergeBase, changes) {
                    guard let paths = pathsBySource[candidate.sourcePath], seen.insert(candidate.sourcePath).inserted,
                          Self.isValid(candidate) else {
                        throw failure("UnitTest 대상 선별 응답에 잘못된 경로, 동작 또는 우선순위가 있습니다.")
                    }
                    planned.append(.init(candidate: candidate, paths: paths))
                }
            }
            return planned
        }
        guard run.planned > 0 else {
            return noTargets("변경된 C# 소스 \(changed.count)개에서 새 UnitTest가 필요한 비즈니스 로직을 찾지 못했습니다." + run.note)
        }
        let failed = run.results.filter { $0.status == .failed }.count
        let passed = run.results.filter { $0.status == .passed }.count
        let outcome: UnitTestVerification.Outcome = failed > 0 ? .failed : (passed > 0 ? .passed : .notApplicable)
        let excluded = changed.count - run.planned
        let deferred = run.planned - run.results.count
        let summary = "기준 \(baseName) · 통과 \(passed)개 · 실패 \(failed)개 · 건너뜀 \(run.results.count - passed - failed)개 · 범위 밖 \(excluded)개 · 병합 유입 제외 \(mergedOnly)개 · 상한 초과 미처리 \(deferred)개"
            + (branchSpec.map { " · 기대값 spec \($0.document.path)" } ?? "") + run.note
        return UnitTestVerification(outcome: outcome, verifiedSHA: head, resultSHA: head, pushed: false, summary: summary, files: run.results)
    }

    /// Spec mode: the rules of one spec document pick the targets instead of a branch diff.
    /// The registered folder's current branch HEAD is the base of the local UnitTest branch.
    func verifySpec(
        repository: RegisteredRepository,
        specPath: String,
        select: SpecSelector,
        generate: Generator,
        progress: @Sendable (String) -> Void
    ) throws -> UnitTestVerification {
        let path = repository.localPath
        guard let current = try? git(["symbolic-ref", "--quiet", "--short", "HEAD"], at: path), !current.isEmpty else {
            throw failure("등록 폴더가 브랜치가 아닌 커밋(detached HEAD)에 있어 UnitTest 브랜치 이름을 정할 수 없습니다. 브랜치를 체크아웃한 뒤 다시 시도하세요.")
        }
        let head = try git(["rev-parse", "HEAD"], at: path)
        let parts = specPath.split(separator: "/", omittingEmptySubsequences: false)
        guard !specPath.hasPrefix("/"), !parts.contains(".."), specPath.hasSuffix(".md"),
              let loaded = Self.specDocument(specPaths: [specPath], read: { try? String(contentsOfFile: (path as NSString).appendingPathComponent($0), encoding: .utf8) }),
              FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent(specPath)) else {
            throw failure("spec 문서 `\(specPath)`를 읽을 수 없습니다. 목록을 새로 고친 뒤 다시 시도하세요.")
        }
        let spec = loaded.document
        let sources = Set(try gitList(["ls-tree", "-r", "--name-only", "-z", head], at: path).filter { $0.hasSuffix(".cs") && !Self.isTestPath($0) })
        let referenced = Array(Self.referencedSources(in: loaded.raw, sources: sources.sorted()).prefix(Self.maxReferencedSources))
        func noTargets(_ summary: String) -> UnitTestVerification {
            .init(outcome: .notApplicable, verifiedSHA: head, resultSHA: head, pushed: false, summary: "기준 \(current) · spec \(specPath) · " + summary, files: [])
        }

        // Selection reads the current branch as it is, so a spec without rules never switches the folder.
        progress("spec에서 테스트할 규칙과 구현 소스를 찾는 중입니다.")
        let selected = try plannedSpecTargets(select(path, spec, referenced), sources: sources)
        guard !selected.planned.isEmpty else {
            return noTargets("규칙 부족: spec에서 구현 소스와 연결할 테스트 규칙을 찾지 못했습니다." + (selected.outside > 0 ? " 저장소에 없는 경로 \(selected.outside)개 제외." : ""))
        }

        let run = try runOnUnitTestBranch(
            repository: repository, sourceBranch: current, head: head, mergeBase: nil, spec: spec,
            generate: generate, progress: progress
        ) { _ in selected.planned }
        return Self.specVerification(prefix: "기준 \(current) · spec \(specPath)", spec: spec, run: run, outside: selected.outside, head: head)
    }

    /// Spec candidates → targets; a path outside the tracked sources (or repeated) is counted, not planned.
    private func plannedSpecTargets(_ candidates: [Candidate], sources: Set<String>) throws -> (planned: [Planned], outside: Int) {
        var planned: [Planned] = []
        var outside = 0
        for candidate in candidates {
            guard Self.isValid(candidate) else { throw failure("UnitTest 대상 선별 응답에 잘못된 동작 또는 우선순위가 있습니다.") }
            guard sources.contains(candidate.sourcePath), !planned.contains(where: { $0.candidate.sourcePath == candidate.sourcePath }) else {
                outside += 1
                continue
            }
            planned.append(.init(candidate: candidate, paths: []))
        }
        return (planned, outside)
    }

    private static func specVerification(prefix: String, spec: SpecDocument, run: BranchRun, outside: Int, head: String) -> UnitTestVerification {
        let count = { (status: UnitTestVerification.FileResult.Status) in run.results.filter { $0.status == status }.count }
        let passed = count(.passed), failed = count(.failed), mismatched = count(.specMismatch)
        let outcome: UnitTestVerification.Outcome = failed + mismatched > 0 ? .failed : (passed > 0 ? .passed : .notApplicable)
        let rules = run.results.reduce(0) { $0 + ($1.rules?.count ?? 0) }
        let covered = run.results.filter { $0.status == .passed }.reduce(0) { $0 + ($1.rules?.count ?? 0) }
        let summary = "\(prefix) · 추출 규칙 \(rules)개 중 테스트 \(covered)개 · 통과 \(passed)개 · 실패 \(failed)개 · spec과 구현 불일치 \(mismatched)개 · 건너뜀 \(run.results.count - passed - failed - mismatched)개 · 저장소에 없는 경로 제외 \(outside)개 · 상한 초과 미처리 \(run.planned - run.results.count)개"
            + (spec.truncated ? " · spec이 길어 수용 기준·시나리오·규칙 구간 위주로 \(maxSpecCharacters)자만 사용" : "") + run.note
        return UnitTestVerification(outcome: outcome, verifiedSHA: head, resultSHA: head, pushed: false, summary: summary, files: run.results)
    }

    private struct Planned: Sendable {
        let candidate: Candidate
        /// Diff paths in branch mode; empty in spec mode, where the target gets no diff.
        let paths: [String]
    }

    private struct BranchRun {
        let planned: Int
        let results: [UnitTestVerification.FileResult]
        /// What was written to the UnitTest branch and whether the stash was re-applied.
        let note: String
    }

    private static func isValid(_ candidate: Candidate) -> Bool {
        (1...3).contains(candidate.priority) && !candidate.behavior.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && candidate.behavior.count <= 1000
    }

    /// Switches the registered folder to the local UnitTest branch of `sourceBranch` at `head`,
    /// plans targets there, then generates, validates and writes the passing tests (uncommitted).
    private func runOnUnitTestBranch(
        repository: RegisteredRepository, sourceBranch: String, head: String, mergeBase: String?, spec: SpecDocument?, branchSpec: SpecDocument? = nil,
        generate: Generator, progress: @Sendable (String) -> Void,
        plan: (String) throws -> [Planned]
    ) throws -> BranchRun {
        let path = repository.localPath
        // Validation projects only; the tests themselves are written into the registered checkout.
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("PRReviewAssistant-unittest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let outputBranch = ParentBranchRules.unitTestBranchName(for: sourceBranch, rules: repository.effectiveParentBranchRules)
        let outputRef = "refs/heads/\(outputBranch)"
        let current = try? git(["symbolic-ref", "--quiet", "--short", "HEAD"], at: path)
        // Switching must not touch the user's work. Untracked files survive a switch (git refuses one that would
        // overwrite them); other tracked changes are stashed and re-applied after the tests are written, except
        // tests of an earlier run on this UnitTest branch, which stay in place.
        let dirty = try dirtyPaths(at: path)
        let blocking = dirty.filter { !$0.untracked && !(current == outputBranch && Self.isTestPath($0.path)) }.map(\.path)
        var stashPending = false
        // A failed run still re-applies the stash; a conflict keeps the entry in `git stash list`.
        defer { if stashPending { _ = try? git(["stash", "pop"], at: path) } }
        func restoreStash() -> String {
            guard stashPending else { return "" }
            stashPending = false
            do {
                try git(["stash", "pop"], at: path)
                return " · 임시 보관한 변경을 다시 적용함"
            } catch {
                return " · 임시 보관한 변경을 다시 적용하지 못했습니다. git stash list에서 확인하세요."
            }
        }
        if !blocking.isEmpty {
            progress("커밋하지 않은 변경 \(blocking.count)개를 stash에 임시 보관하는 중입니다.")
            let before = try? git(["rev-parse", "--verify", "--quiet", "refs/stash"], at: path)
            do {
                try git(["--literal-pathspecs", "stash", "push", "-m", "PRReviewAssistant UnitTest \(outputBranch)", "--"] + blocking, at: path)
            } catch CommandError.failed(let result) {
                throw failure("등록 폴더의 커밋하지 않은 변경을 stash에 보관하지 못해 UnitTest 브랜치 \(outputBranch)로 전환할 수 없습니다.\n\(result.error)")
            }
            stashPending = (try? git(["rev-parse", "--verify", "--quiet", "refs/stash"], at: path)) != before
        }
        let localTip = current == outputBranch ? nil : try? git(["rev-parse", "--verify", "--quiet", "\(outputRef)^{commit}"], at: path)
        let remoteTip = current == outputBranch || localTip != nil ? nil : try git(["ls-remote", repository.remoteName, outputRef], at: path)
            .split(whereSeparator: { $0 == "\t" || $0 == " " }).first.map(String.init)
        if remoteTip != nil {
            try git(["fetch", "--no-tags", repository.remoteName, "+\(outputRef):refs/remotes/\(repository.remoteName)/\(outputBranch)"], at: path)
        }
        // An existing UnitTest branch that is behind only fast-forwards, which creates no commit. A diverged branch
        // would need a merge commit, so it is refused before switching and the folder stays as it was.
        let tip = current == outputBranch ? "HEAD" : (localTip ?? remoteTip ?? head)
        let containsHead = (try? git(["merge-base", "--is-ancestor", head, tip], at: path)) != nil
        guard containsHead || (try? git(["merge-base", "--is-ancestor", tip, head], at: path)) != nil else {
            throw failure("UnitTest 브랜치 \(outputBranch)에 \(sourceBranch)에 없는 커밋이 있어 최신으로 옮길 수 없습니다. 병합 커밋을 자동으로 만들지 않습니다. \(outputBranch)에서 \(sourceBranch)를 직접 병합한 뒤 다시 시도하세요.")
        }
        if current != outputBranch {
            progress(localTip == nil && remoteTip == nil ? "선택한 커밋에서 로컬 UnitTest 브랜치 \(outputBranch)를 만드는 중입니다." : "기존 UnitTest 브랜치 \(outputBranch)를 체크아웃하는 중입니다.")
            do {
                if localTip != nil {
                    try git(["switch", outputBranch], at: path)
                } else if remoteTip != nil {
                    try git(["switch", "-c", outputBranch, "--track", "\(repository.remoteName)/\(outputBranch)"], at: path)
                } else {
                    try git(["switch", "-c", outputBranch, head], at: path)
                }
            } catch CommandError.failed(let result) {
                throw failure("UnitTest 브랜치 \(outputBranch)를 체크아웃하지 못했습니다. 다른 작업 폴더에서 체크아웃 중인지 확인하세요.\n\(result.error)")
            }
        }
        if !containsHead {
            progress("UnitTest 브랜치 \(outputBranch)를 선택한 커밋으로 옮기는 중입니다.")
            do {
                try git(["merge", "--ff-only", head], at: path)
            } catch CommandError.failed(let result) {
                throw failure("UnitTest 브랜치 \(outputBranch)를 선택한 커밋으로 옮기지 못했습니다. 추적하지 않는 파일이 겹치는지 확인하세요.\n\(result.error)")
            }
        }
        let base = try git(["rev-parse", "HEAD"], at: path)
        // Tests this UnitTest branch added on top of the selected commit (committed or left uncommitted by an earlier run); only these may be changed or deleted.
        let ownedTests = Set(try gitList(["diff", "--name-only", "-z", "--diff-filter=AMR", head, base, "--", "*.cs"], at: path).filter(Self.isTestPath))
            .union(current == outputBranch ? dirty.map(\.path).filter { $0.hasSuffix(".cs") && Self.isTestPath($0) } : [])
        // The user's untracked files from another branch are never overwritten by generated tests.
        let untracked = current == outputBranch ? [] : Set(dirty.filter(\.untracked).map(\.path))

        let planned = try plan(path)
        guard !planned.isEmpty else { return BranchRun(planned: 0, results: [], note: restoreStash()) }

        let allFiles = Set(try gitList(["ls-tree", "-r", "--name-only", "-z", head], at: path))
        let testFiles = allFiles.filter { $0.hasSuffix(".cs") && Self.isTestPath($0) }.sorted()
        let isUnityProject = allFiles.contains { $0 == "ProjectSettings/ProjectVersion.txt" || $0.hasSuffix("/ProjectSettings/ProjectVersion.txt") }
        let testFolder = repository.unitTestFolder
        let testDirectories = Set(testFiles.filter { $0.hasSuffix("Tests.cs") }.map { ($0 as NSString).deletingLastPathComponent })
            .union(testFolder.map { [$0] } ?? [])
        let prioritized = planned.sorted {
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
            let diff = try mergeBase.map { mergeBase in
                try git(["--literal-pathspecs", "diff", "--find-renames", "--no-ext-diff", "--no-textconv", mergeBase, head, "--"] + entry.paths, at: path, trim: false)
            } ?? ""
            let style = Self.closestTestFile(to: source, in: testFiles)
            let target = Target(
                sourcePath: source, source: text, diff: String(diff.prefix(Self.maxSourceCharacters)),
                suggestedTestPath: Self.suggestedTestPath(for: source, testFiles: testFiles + accepted.map(\.path), folder: testFolder),
                stylePath: style,
                styleSample: try style.map { String(try git(["show", "\(head):\($0)"], at: path, trim: false).prefix(6000)) },
                behavior: entry.candidate.behavior,
                existingTests: ownedTests.subtracting(deleted).sorted(),
                isUnityProject: isUnityProject,
                spec: spec,
                branchSpec: branchSpec
            )
            results.append(try validateTarget(
                target, folder: work.appendingPathComponent("t\(index)").path, workspace: path,
                repositoryPath: path, head: head, tracked: allFiles, untracked: untracked, owned: ownedTests, testDirectories: testDirectories, generate: generate,
                accepted: &accepted, deleted: &deleted
            ))
        }

        if !accepted.isEmpty || !deleted.isEmpty {
            progress("통과한 테스트 \(accepted.count)개와 삭제 \(deleted.count)개를 로컬 \(outputBranch) 작업 트리에 반영하는 중입니다.")
            guard (try? git(["symbolic-ref", "--quiet", "--short", "HEAD"], at: path)) == outputBranch,
                  try git(["rev-parse", "HEAD"], at: path) == base else {
                throw failure("검증 중 등록 폴더의 브랜치가 바뀌어 테스트 파일을 쓰지 않았습니다. 다시 시도하세요.")
            }
            for file in accepted { try write(file.content, to: (path as NSString).appendingPathComponent(file.path)) }
            for deletion in deleted { try? FileManager.default.removeItem(atPath: (path as NSString).appendingPathComponent(deletion)) }
        }
        let written = accepted.isEmpty && deleted.isEmpty ? "" : " — 로컬 \(outputBranch) 브랜치에 테스트 \(accepted.count)개 추가·수정, \(deleted.count)개 삭제 (커밋하지 않음)."
        return BranchRun(planned: planned.count, results: results, note: written + restoreStash())
    }

    /// Up to `maxAttempts` generate → guard → validate rounds; failures feed the next prompt.
    private func validateTarget(
        _ target: Target, folder: String, workspace: String,
        repositoryPath: String, head: String, tracked: Set<String>, untracked: Set<String>, owned: Set<String>, testDirectories: Set<String>,
        generate: Generator, accepted: inout [UnitTestProposal.File], deleted: inout [String]
    ) throws -> UnitTestVerification.FileResult {
        var rules: [String]?
        func result(_ status: UnitTestVerification.FileResult.Status, _ detail: String, test: String? = nil) -> UnitTestVerification.FileResult {
            .init(sourcePath: target.sourcePath, testPath: test, status: status, detail: detail, rules: rules)
        }
        var previousError: String?
        // Spec mode only: the agent reports that the spec's expected values disagree with the implementation.
        var mismatch: String?
        for _ in 1...Self.maxAttempts {
            let proposal: UnitTestProposal
            do {
                proposal = try generate(.init(target: target, previousError: previousError, workspace: workspace))
            } catch let error as UnitTestProposal.ParseError {
                previousError = error.localizedDescription
                continue
            }
            if let extracted = proposal.businessRules, !extracted.isEmpty { rules = extracted.map(\.summary) }
            if target.spec != nil, let reported = proposal.specMismatch?.trimmingCharacters(in: .whitespacesAndNewlines), !reported.isEmpty {
                mismatch = reported
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
            let violations = Self.violations(of: proposal.files, existingPaths: tracked.union(untracked).union(accepted.map(\.path)).union(deleted), allowsUnityEngine: target.isUnityProject, allowedDirectories: testDirectories)
            if !violations.isEmpty { return result(.failed, "정책 위반으로 폐기: " + violations.joined(separator: "; ")) }

            let dependencies = proposal.dependencies ?? []
            guard dependencies.count <= Self.maxDependencies, Set(dependencies).count == dependencies.count,
                  dependencies.allSatisfy({ $0 != target.sourcePath && $0.hasSuffix(".cs") && tracked.contains($0) && !Self.isTestPath($0) }) else {
                previousError = "의존 소스는 선택 커밋에 추적된 별도 C# 소스 최대 \(Self.maxDependencies)개여야 합니다."
                continue
            }
            // A replica test compiles without the target source, so it must name the source it copies.
            let isReplica = proposal.verification == Self.replicaVerification
            let marker = "원본: \(target.sourcePath)"
            if isReplica, !proposal.files.allSatisfy({ $0.content.contains(marker) }) {
                previousError = "replica 테스트 파일에는 옮긴 로직 위에 `// \(marker)` 주석이 있어야 합니다."
                continue
            }

            let fileManager = FileManager.default
            try? fileManager.removeItem(atPath: folder)
            try fileManager.createDirectory(atPath: folder, withIntermediateDirectories: true)
            var sourceFiles: [String] = []
            var testFiles: [String] = []
            if !isReplica {
                let sourceFile = "Source/" + (target.sourcePath as NSString).lastPathComponent
                try write(target.source, to: "\(folder)/\(sourceFile)")
                sourceFiles.append(sourceFile)
            }
            if target.isUnityProject {
                try write(UnityEngineShim.source, to: "\(folder)/\(UnityEngineShim.path)")
                try write(UnityEngineShim.buildProps, to: "\(folder)/Directory.Build.props")
                sourceFiles.append(UnityEngineShim.path)
            }
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
                let log = outcome.log.isEmpty ? "검증 통과" : outcome.log
                let detail = isReplica ? "원본 로직 복제 검증: 원본을 컴파일할 수 없어 규칙을 테스트 안에 옮겨 검증했습니다. 원본이 바뀌면 이 테스트도 함께 고쳐야 합니다.\n" + log : log
                return result(.passed, detail, test: proposal.files.map(\.path).joined(separator: ", "))
            }
            previousError = outcome.log
        }
        if let mismatch {
            return result(.specMismatch, "spec과 구현 불일치: \(mismatch)\n\(Self.maxAttempts)회 시도 후 검증 실패:\n" + (previousError ?? ""))
        }
        return result(.failed, "\(Self.maxAttempts)회 시도 후 검증 실패:\n" + (previousError ?? ""))
    }

    private func write(_ text: String, to path: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Builds the commit from a temporary index so the work folder, its index and HEAD stay untouched.
    /// Paths with uncommitted changes, including untracked files (`git status --porcelain -z`).
    private func dirtyPaths(at path: String) throws -> [(path: String, untracked: Bool)] {
        var entries = try gitList(["status", "--porcelain=v1", "-z", "--untracked-files=all"], at: path).makeIterator()
        var paths: [(path: String, untracked: Bool)] = []
        while let entry = entries.next() {
            guard entry.count > 3 else { continue }
            paths.append((String(entry.dropFirst(3)), entry.hasPrefix("??")))
            if entry.first == "R" || entry.first == "C" { _ = entries.next() }
        }
        return paths
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
    private func git(_ arguments: [String], at path: String, trim: Bool = true) throws -> String {
        let result = try runner.run("git", arguments: arguments, workingDirectory: path)
        return trim ? result.output.trimmingCharacters(in: .whitespacesAndNewlines) : result.output
    }

    private func gitList(_ arguments: [String], at path: String) throws -> [String] {
        try git(arguments, at: path, trim: false).split(separator: "\0").map(String.init)
    }

    private func failure(_ message: String) -> CommandError {
        .failed(.init(output: "", error: message, status: 1))
    }
}
