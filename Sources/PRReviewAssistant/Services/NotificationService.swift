import UserNotifications
import OSLog

final class NotificationService: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.supercent.pr-review-assistant", category: "Notifications")
    private let logLock = NSLock()
    private let diagnosticsURL: URL = {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PRReviewAssistant", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("notification-diagnostics.log")
    }()

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func requestAuthorization() async -> String {
        let center = UNUserNotificationCenter.current()
        let initialSettings = await center.notificationSettings()
        if initialSettings.authorizationStatus == .notDetermined {
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .badge, .sound])
                logger.notice("Authorization prompt completed; granted=\(granted, privacy: .public)")
                record("Authorization prompt completed; granted=\(granted)")
            } catch {
                logger.error("Authorization request failed: \(error.localizedDescription, privacy: .public)")
                record("Authorization request failed: \(error.localizedDescription)")
            }
        }
        return await authorizationSummary()
    }

    func isAuthorizationUndecided() async -> Bool {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .notDetermined
    }

    func authorizationSummary() async -> String {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        let summary: String
        switch settings.authorizationStatus {
        case .authorized: summary = "알림 허용됨"
        case .provisional: summary = "알림 임시 허용됨"
        case .denied: summary = "알림이 macOS 설정에서 꺼져 있습니다"
        case .notDetermined: summary = "알림 권한을 아직 선택하지 않았습니다"
        case .ephemeral: summary = "알림이 임시 권한으로 허용되었습니다"
        @unknown default: summary = "알림 권한 상태를 알 수 없습니다"
        }
        logger.notice("Authorization status: \(summary, privacy: .public); alert=\(settings.alertSetting.rawValue, privacy: .public); sound=\(settings.soundSetting.rawValue, privacy: .public)")
        record("Authorization status: \(summary); alert=\(settings.alertSetting.rawValue); sound=\(settings.soundSetting.rawValue)")
        return summary
    }

    /// macOS suppresses a notification by default while its app is frontmost.
    /// Keep showing it because refreshes are commonly performed in the open app.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
    func deliverNewReview(for pullRequest: PullRequest, count: Int, eventID: String) async -> String {
        // A PR's HEAD SHA can remain the same across several reviewer comments.
        // Use the newest comment ID so each newly received batch gets its own banner.
        return await deliver(
            .newReview(for: pullRequest, count: count),
            identifier: "review-\(pullRequest.repository)-\(pullRequest.number)-\(eventID)",
            description: "review \(pullRequest.repository)#\(pullRequest.number)"
        )
    }

    func deliverNewPullRequest(_ pullRequest: PullRequest) async -> String {
        return await deliver(
            .newPullRequest(pullRequest),
            identifier: "pull-request-\(pullRequest.repository)-\(pullRequest.number)",
            description: "pull request \(pullRequest.repository)#\(pullRequest.number)"
        )
    }

    func deliverApproval(for pullRequest: PullRequest) async -> String {
        await deliver(
            .approved(pullRequest),
            identifier: "approval-\(pullRequest.repository)-\(pullRequest.number)-\(pullRequest.headSHA)",
            description: "approval \(pullRequest.repository)#\(pullRequest.number)"
        )
    }

    func deliverTestNotification() async -> String {
        await deliver(.notificationTest, identifier: "notification-test-\(UUID().uuidString)", description: "test notification")
    }

    func deliverAppUpdate(version: String) async -> String {
        await deliver(.appUpdate(version: version), identifier: "app-update-\(version)", description: "app update \(version)")
    }

    private func deliver(_ message: PetBubbleContent, identifier: String, description: String) async -> String {
        let content = UNMutableNotificationContent()
        content.title = message.title
        content.subtitle = message.subtitle
        content.body = message.body
        content.sound = .default
        return await schedule(UNNotificationRequest(identifier: identifier, content: content, trigger: nil), description: description)
    }

    private func schedule(_ request: UNNotificationRequest, description: String) async -> String {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            let message = "알림을 보내지 못했습니다: \(await authorizationSummary())"
            logger.error("\(message, privacy: .public)")
            record(message)
            return message
        }
        do {
            try await UNUserNotificationCenter.current().add(request)
            let message = "알림 요청을 전달했습니다: \(description)"
            logger.notice("\(message, privacy: .public), id=\(request.identifier, privacy: .public)")
            record("\(message), id=\(request.identifier)")
            return message
        } catch {
            let message = "알림 전달 실패: \(error.localizedDescription)"
            logger.error("\(message, privacy: .public)")
            record(message)
            return message
        }
    }

    private func record(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: .now)) \(message)\n"
        logLock.lock()
        defer { logLock.unlock() }
        if FileManager.default.fileExists(atPath: diagnosticsURL.path) {
            if let handle = try? FileHandle(forWritingTo: diagnosticsURL) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
                try? handle.close()
            }
        } else {
            try? Data(line.utf8).write(to: diagnosticsURL, options: .atomic)
        }
    }
}
