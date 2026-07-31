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
}
