import Foundation
import Testing
@testable import PRReviewAssistant

@Suite("Process runner")
struct ProcessRunnerTests {
    @Test("시간 제한을 넘긴 에이전트 명령을 실패로 돌려준다")
    func timesOutLongRunningCommand() throws {
        let runner = ProcessRunner()

        var timedOut = false
        do {
            _ = try runner.run("/bin/sleep", arguments: ["2"], timeout: 0.05)
        } catch CommandError.timedOut(let command) {
            timedOut = command == "/bin/sleep"
        }
        #expect(timedOut)
    }

    @Test("출력이 있는 명령도 종료 전부터 읽어 완료한다")
    func collectsOutputWithoutWaitingForExitFirst() throws {
        let runner = ProcessRunner()
        let result = try runner.run("/usr/bin/seq", arguments: ["1", "10000"], timeout: 2)

        #expect(result.output.hasPrefix("1\n2\n"))
        #expect(result.output.contains("10000\n"))
    }

    @Test("입력을 다 읽기 전에 끝나는 명령이 앱을 종료시키지 않는다")
    func childExitingBeforeReadingInputDoesNotKillProcess() throws {
        let input = String(repeating: "x", count: 300_000)
        let result = try ProcessRunner().run("/usr/bin/true", arguments: [], input: input, timeout: 5)
        #expect(result.status == 0)
    }

    @Test("입력을 읽지 않는 명령도 시간 제한을 지킨다")
    func timeoutAppliesWhileInputIsBlocked() {
        let input = String(repeating: "x", count: 300_000)
        let start = Date()
        #expect(throws: CommandError.self) {
            _ = try ProcessRunner().run("/bin/sleep", arguments: ["6"], input: input, timeout: 0.2)
        }
        #expect(Date().timeIntervalSince(start) < 4)
    }

    @Test("호출에 시간 제한이 없으면 기본 시간 제한을 쓴다")
    func usesDefaultTimeout() {
        let start = Date()
        #expect(throws: CommandError.self) {
            _ = try ProcessRunner(defaultTimeout: 0.1).run("/bin/sleep", arguments: ["6"])
        }
        #expect(Date().timeIntervalSince(start) < 4)
    }

    @Test("종료 요청을 무시하는 명령은 강제 종료한다")
    func killsCommandIgnoringTermination() {
        let start = Date()
        #expect(throws: CommandError.self) {
            _ = try ProcessRunner().run("/bin/sh", arguments: ["-c", "trap '' TERM; exec /bin/sleep 20"], timeout: 0.1)
        }
        #expect(Date().timeIntervalSince(start) < 10)
    }
}
