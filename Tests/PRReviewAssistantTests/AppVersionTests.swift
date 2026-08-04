import Foundation
import Testing
@testable import PRReviewAssistant

@Suite("앱 버전 비교")
struct AppVersionTests {
    @Test("GitHub Release v 접두어를 포함한 버전을 비교한다")
    func comparesReleaseTags() {
        #expect(AppVersion("0.2.1") < AppVersion("v0.3.0"))
        #expect(AppVersion("0.2.1") == AppVersion("v0.2.1"))
        #expect(!AppVersion("release-candidate").isValid)
    }

    @Test("업데이트 확인은 한국 시간 10시부터 3시간 간격으로 예약한다")
    func schedulesKoreanBusinessHours() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = UpdateCheckSchedule.timeZone
        let morning = calendar.date(from: DateComponents(year: 2026, month: 8, day: 4, hour: 9, minute: 40))!
        let afternoon = calendar.date(from: DateComponents(year: 2026, month: 8, day: 4, hour: 16, minute: 1))!
        let evening = calendar.date(from: DateComponents(year: 2026, month: 8, day: 4, hour: 19, minute: 1))!

        #expect(calendar.component(.hour, from: UpdateCheckSchedule.nextDate(after: morning)) == 10)
        #expect(calendar.component(.hour, from: UpdateCheckSchedule.nextDate(after: afternoon)) == 19)
        let nextDay = UpdateCheckSchedule.nextDate(after: evening)
        #expect(calendar.component(.day, from: nextDay) == 5)
        #expect(calendar.component(.hour, from: nextDay) == 10)
    }
}
