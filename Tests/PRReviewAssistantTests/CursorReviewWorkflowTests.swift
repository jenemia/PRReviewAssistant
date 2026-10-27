import Foundation
import Testing
@testable import PRReviewAssistant

@Suite("Role-based review workflow")
struct CursorReviewWorkflowTests {
    private final class Commands: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [[String]] = []
        var failRole: String?
        var emptyRole: String?
        var stderrRole: String?
        var stderrMessage = "Workspace Trust Required"
        var warning = ""
        var responseOverride: String?
        var changesHeadAfterSummary = false

        var calls: [[String]] {
            lock.lock()
            defer { lock.unlock() }
            return recorded
        }

        func run(_ executable: String, _ arguments: [String], _ directory: String, _ timeout: TimeInterval) throws -> CommandResult {
            let output = try commandOutput(executable, arguments, directory, timeout)
            if executable == "cursor", !arguments.contains("--trust"), let stderrRole,
               arguments.last?.contains("담당 역할: \(stderrRole)\n") == true {
                return .init(output: "", error: stderrMessage, status: 0)
            }
            if executable == "cursor" {
                let data = try JSONSerialization.data(withJSONObject: [
                    "type": "result", "subtype": "success", "is_error": false,
                    "result": output, "session_id": "test-session"
                ])
                return .init(output: responseOverride ?? String(decoding: data, as: UTF8.self), error: warning, status: 0)
            }
            return .init(output: output, error: "", status: 0)
        }

        private func commandOutput(_ executable: String, _ arguments: [String], _ directory: String, _ timeout: TimeInterval) throws -> String {
            lock.lock()
            defer { lock.unlock() }
            recorded.append([executable] + arguments)
            if executable == "git" {
                if arguments.first == "merge-base" { return "merge-sha\n" }
                if arguments.last == "main^{commit}" { return "base-sha\n" }
                if changesHeadAfterSummary, recorded.contains(where: { $0.last?.contains("담당: 리뷰 통합.") == true }) { return "changed-sha\n" }
                return "head-sha\n"
            }
            let prompt = arguments.last ?? ""
            let role = prompt.components(separatedBy: "\n").first(where: { $0.hasPrefix("담당 역할: ") })?.replacingOccurrences(of: "담당 역할: ", with: "") ?? "summary"
            if failRole == role { throw CommandError.timedOut(role) }
            if emptyRole == role { return " \n" }
            return "evidence-from-\(role)"
        }
    }

    private func rolesDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for role in ["spec-search-agent", "structure-agent", "code-reviewer", "maintenance-reviewer", "scope-guard", "risk-guard"] {
            try "global-guidance-\(role)".write(to: directory.appendingPathComponent("\(role).md"), atomically: true, encoding: .utf8)
        }
        return directory
    }

    @Test("브랜치는 조사 완료 후 리뷰하고 모든 근거를 통합한다")
    func branchStagesShareEvidence() async throws {
        let directory = try rolesDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let commands = Commands()
        let workflow = CursorReviewWorkflow(agentsDirectory: directory, runCommand: commands.run)
        let output = try await workflow.run(preset: .branch, directory: "/repo", headReference: "feature", expectedSHA: "head-sha", baseReference: "main", context: "branch", outputInstructions: "branch-format", trustWorkspace: true, model: "chosen-model")
        #expect(output == "evidence-from-summary")
        let calls = commands.calls.filter { $0.first == "cursor" }
        #expect(calls.count == 5)
        let research = calls.prefix(2).compactMap(\.last).joined()
        #expect(research.contains("담당 역할: spec-search-agent"))
        #expect(research.contains("담당 역할: structure-agent"))
        for call in calls.dropFirst(2).prefix(2) {
            let prompt = try #require(call.last)
            #expect(prompt.contains("evidence-from-spec-search-agent"))
            #expect(prompt.contains("evidence-from-structure-agent"))
        }
        let reviews = calls.dropFirst(2).prefix(2).compactMap(\.last).joined()
        #expect(reviews.contains("global-guidance-code-reviewer"))
        #expect(reviews.contains("global-guidance-scope-guard"))
        #expect(reviews.contains("global-guidance-risk-guard"))
        let summary = try #require(calls.last?.last)
        #expect(summary.contains("evidence-from-code-reviewer"))
        #expect(summary.contains("evidence-from-maintenance-reviewer"))
        #expect(summary.contains("MERGE_BASE: merge-sha"))
        #expect(summary.contains("branch-format"))
        for call in calls {
            #expect(call.contains("--trust"))
            #expect(call.contains("chosen-model"))
            #expect(call.contains("ask"))
            #expect(call.contains("json"))
            #expect(!call.contains("plan"))
        }
    }

    @Test("코멘트는 구조 조사와 구현 검토만 배정하고 타당성 판단을 전달한다")
    func commentsUseFocusedPreset() async throws {
        let directory = try rolesDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let commands = Commands()
        let workflow = CursorReviewWorkflow(agentsDirectory: directory, runCommand: commands.run)
        _ = try await workflow.run(preset: .comments, directory: "/repo", headReference: "HEAD", expectedSHA: "head-sha", context: "ID: review-42", outputInstructions: "comment-format", trustWorkspace: false, model: "")
        let calls = commands.calls.filter { $0.first == "cursor" }
        #expect(calls.count == 3)
        let review = try #require(calls[1].last)
        #expect(review.contains("담당 역할: code-reviewer"))
        #expect(review.contains("evidence-from-structure-agent"))
        #expect(review.contains("지적의 타당성"))
        #expect(review.contains("제안한 수정의 적절성"))
        #expect(review.contains("ID: review-42"))
        #expect(calls.allSatisfy { !$0.contains("--trust") && !$0.contains("--model") })
        #expect(!commands.calls.contains { $0.contains("merge-base") })
    }

    @Test("코멘트 카드의 최초 검토도 역할별 흐름과 기존 응답 형식을 사용한다")
    func cardReviewUsesWorkflow() async throws {
        let directory = try rolesDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let commands = Commands()
        let agent = CursorAgent(reviewWorkflow: CursorReviewWorkflow(agentsDirectory: directory, runCommand: commands.run))
        let card = AgentReviewCard(repository: "example/repo", pullRequestNumber: 1, commentID: "review-42", commentAuthor: "reviewer", commentBody: "전체 원문", sectionTitle: "경쟁조건", sectionBody: "선택한 섹션만 검토", title: "검토 카드")
        let output = try await agent.ask(repositoryPath: "/repo", pullRequest: PullRequest.samples[0], card: card, question: "수용 여부를 확인해줘", trustWorkspace: true, model: "chosen-model", reviewsComment: true)
        #expect(output == "evidence-from-summary")
        let calls = commands.calls.filter { $0.first == "cursor" }
        #expect(calls.count == 3)
        let summary = try #require(calls.last?.last)
        #expect(summary.contains("코멘트 ID: review-42"))
        #expect(summary.contains("선택한 섹션만 검토"))
        #expect(!summary.contains("전체 원문"))
        #expect(summary.contains("## 현재 동작과 이유"))
        #expect(summary.contains("코드 원문과 코드 블록은 기본적으로 표시하지 마라"))
        #expect(!summary.contains("수정할 파일·클래스·메서드와 변경 방향"))
        #expect(summary.contains("## 대응 계획"))
        #expect(summary.contains("## 검증 계획"))
        #expect(summary.contains("지적의 타당성과 수정안 적절성"))
    }

    @Test("필수 전역 역할이 없으면 모델 호출 전에 중단한다")
    func missingRoleStopsBeforeAgentCalls() async throws {
        let directory = try rolesDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.removeItem(at: directory.appendingPathComponent("maintenance-reviewer.md"))
        let commands = Commands()
        let workflow = CursorReviewWorkflow(agentsDirectory: directory, runCommand: commands.run)
        await #expect(throws: (any Error).self) {
            try await workflow.run(preset: .branch, directory: "/repo", headReference: "feature", expectedSHA: "head-sha", baseReference: "main", context: "", outputInstructions: "", trustWorkspace: false, model: "")
        }
        #expect(!commands.calls.contains { $0.first == "cursor" })
    }

    @Test("담당 실패 시 후속 단계와 통합을 실행하지 않는다")
    func failedStageDoesNotProduceSummary() async throws {
        let directory = try rolesDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let commands = Commands()
        commands.failRole = "structure-agent"
        let workflow = CursorReviewWorkflow(agentsDirectory: directory, runCommand: commands.run)
        await #expect(throws: (any Error).self) {
            try await workflow.run(preset: .comments, directory: "/repo", headReference: "HEAD", expectedSHA: "head-sha", context: "", outputInstructions: "", trustWorkspace: false, model: "")
        }
        #expect(commands.calls.filter { $0.first == "cursor" }.count == 1)
    }

    @Test("검토 중 head가 변경되면 통합 결과를 반환하지 않는다")
    func changedHeadRejectsResult() async throws {
        let directory = try rolesDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let commands = Commands()
        commands.changesHeadAfterSummary = true
        let workflow = CursorReviewWorkflow(agentsDirectory: directory, runCommand: commands.run)
        await #expect(throws: (any Error).self) {
            try await workflow.run(preset: .comments, directory: "/repo", headReference: "HEAD", expectedSHA: "head-sha", context: "", outputInstructions: "", trustWorkspace: false, model: "")
        }
        #expect(commands.calls.filter { $0.first == "cursor" }.count == 3)
    }

    @Test("빈 담당 응답은 완료로 처리하지 않는다")
    func emptyReportStopsWorkflow() async throws {
        let directory = try rolesDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let commands = Commands()
        commands.emptyRole = "code-reviewer"
        let workflow = CursorReviewWorkflow(agentsDirectory: directory, runCommand: commands.run)
        await #expect(throws: (any Error).self) {
            try await workflow.run(preset: .comments, directory: "/repo", headReference: "HEAD", expectedSHA: "head-sha", context: "", outputInstructions: "", trustWorkspace: false, model: "")
        }
        #expect(commands.calls.filter { $0.first == "cursor" }.count == 2)
    }

    @Test("종료 코드가 0이어도 stderr의 승인·인증 요청과 담당 단계를 보존한다", arguments: [
        "Workspace Trust Required", "Authentication required", "Approval required"
    ])
    func preservesStderrDiagnostic(message: String) async throws {
        let directory = try rolesDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let commands = Commands()
        commands.stderrRole = "structure-agent"
        commands.stderrMessage = message
        let workflow = CursorReviewWorkflow(agentsDirectory: directory, runCommand: commands.run)
        do {
            _ = try await workflow.run(preset: .comments, directory: "/repo", headReference: "HEAD", expectedSHA: "head-sha", context: "", outputInstructions: "", trustWorkspace: false, model: "")
            Issue.record("승인 요청을 완료된 리뷰로 처리했습니다.")
        } catch {
            #expect(error.localizedDescription.contains(message))
            #expect(error.localizedDescription.contains("structure-agent 단계 실패"))
            #expect(!error.localizedDescription.contains("빈 리뷰 결과"))
        }
        #expect(commands.calls.filter { $0.first == "cursor" }.count == 1)
    }

    @Test("신뢰 승인 후 재시도는 모든 담당에 trust를 전달해 완료한다")
    func retriesAfterTrustApproval() async throws {
        let directory = try rolesDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let commands = Commands()
        commands.stderrRole = "structure-agent"
        let workflow = CursorReviewWorkflow(agentsDirectory: directory, runCommand: commands.run)
        await #expect(throws: (any Error).self) {
            try await workflow.run(preset: .comments, directory: "/repo", headReference: "HEAD", expectedSHA: "head-sha", context: "", outputInstructions: "", trustWorkspace: false, model: "")
        }
        let output = try await workflow.run(preset: .comments, directory: "/repo", headReference: "HEAD", expectedSHA: "head-sha", context: "", outputInstructions: "", trustWorkspace: true, model: "")
        #expect(output == "evidence-from-summary")
        let calls = commands.calls.filter { $0.first == "cursor" }
        #expect(calls.count == 4)
        #expect(calls.dropFirst().allSatisfy { $0.contains("--trust") })
    }

    @Test("정상 응답에 stderr 경고가 있어도 리뷰는 완료한다")
    func warningDoesNotDiscardValidOutput() async throws {
        let directory = try rolesDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let commands = Commands()
        commands.warning = "Warning: update available"
        let workflow = CursorReviewWorkflow(agentsDirectory: directory, runCommand: commands.run)
        let output = try await workflow.run(preset: .comments, directory: "/repo", headReference: "HEAD", expectedSHA: "head-sha", context: "", outputInstructions: "", trustWorkspace: false, model: "")
        #expect(output == "evidence-from-summary")
        #expect(commands.calls.filter { $0.first == "cursor" }.count == 3)
    }

    @Test("미완료·실패·도구 이벤트와 비JSON 응답을 리뷰 본문으로 사용하지 않는다", arguments: [
        "progress only",
        #"{"type":"result","subtype":"success","is_error":true,"result":"failed"}"#,
        #"{"type":"result","subtype":"error","is_error":false,"result":"failed"}"#,
        #"{"type":"tool_call","subtype":"success","is_error":false,"result":"plan text"}"#
    ])
    func rejectsInvalidCompletion(response: String) async throws {
        let directory = try rolesDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let commands = Commands()
        commands.responseOverride = response
        let workflow = CursorReviewWorkflow(agentsDirectory: directory, runCommand: commands.run)
        await #expect(throws: (any Error).self) {
            try await workflow.run(preset: .comments, directory: "/repo", headReference: "HEAD", expectedSHA: "head-sha", context: "", outputInstructions: "", trustWorkspace: true, model: "")
        }
        #expect(commands.calls.filter { $0.first == "cursor" }.count == 1)
    }

    @Test("JSON의 최종 본문이 없으면 담당 단계와 세션 ID를 안내한다")
    func emptyFinalReportIncludesSession() async throws {
        let directory = try rolesDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let commands = Commands()
        commands.responseOverride = #"{"type":"result","subtype":"success","is_error":false,"result":"","session_id":"session-for-diagnostics"}"#
        let workflow = CursorReviewWorkflow(agentsDirectory: directory, runCommand: commands.run)
        do {
            _ = try await workflow.run(preset: .comments, directory: "/repo", headReference: "HEAD", expectedSHA: "head-sha", context: "", outputInstructions: "", trustWorkspace: true, model: "")
            Issue.record("최종 보고서 없이 성공 처리했습니다.")
        } catch {
            #expect(error.localizedDescription.contains("structure-agent 단계 실패"))
            #expect(error.localizedDescription.contains("session-for-diagnostics"))
            #expect(error.localizedDescription.contains("최종 리뷰 본문"))
        }
        #expect(commands.calls.filter { $0.first == "cursor" }.count == 1)
    }

    @Test("실제 Git에서 대상 브랜치를 고정하고 현재 브랜치와 작업 파일을 보존한다")
    func realGitSnapshotDoesNotCheckout() async throws {
        let directory = try rolesDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = directory.appendingPathComponent("repository")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        let runner = ProcessRunner()
        func git(_ arguments: [String]) throws -> String {
            try runner.run("git", arguments: arguments, workingDirectory: repository.path).output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        _ = try git(["init", "-b", "main"])
        _ = try git(["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "--allow-empty", "-m", "base"])
        _ = try git(["switch", "-c", "feature"])
        _ = try git(["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "--allow-empty", "-m", "head"])
        let head = try git(["rev-parse", "HEAD"])
        _ = try git(["switch", "main"])
        let marker = repository.appendingPathComponent("uncommitted.txt")
        try "keep working tree".write(to: marker, atomically: true, encoding: .utf8)
        let commands = Commands()
        let workflow = CursorReviewWorkflow(agentsDirectory: directory) { executable, arguments, path, timeout in
            if executable == "git" {
                return try runner.run(executable, arguments: arguments, workingDirectory: path, timeout: timeout)
            }
            return try commands.run(executable, arguments, path, timeout)
        }
        _ = try await workflow.run(preset: .branch, directory: repository.path, headReference: "feature", expectedSHA: String(head.prefix(12)), baseReference: "main", context: "", outputInstructions: "", trustWorkspace: false, model: "")
        #expect(try git(["branch", "--show-current"]) == "main")
        #expect(try String(contentsOf: marker, encoding: .utf8) == "keep working tree")
        #expect(commands.calls.allSatisfy { $0.last?.contains("HEAD: feature @ \(head)") == true })

        let callsBeforeStaleRequest = commands.calls.count
        await #expect(throws: (any Error).self) {
            try await workflow.run(preset: .branch, directory: repository.path, headReference: "feature", expectedSHA: "main", baseReference: "main", context: "", outputInstructions: "", trustWorkspace: false, model: "")
        }
        #expect(commands.calls.count == callsBeforeStaleRequest)
    }
}
