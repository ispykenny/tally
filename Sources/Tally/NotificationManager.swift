import AppKit
import UserNotifications

/// Posts local notifications for new PRs and opens the PR when one is clicked.
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    private var available = false

    func setup() {
        // UNUserNotificationCenter requires a real app bundle; guard so the
        // bare `swift run` binary doesn't crash during development.
        guard Bundle.main.bundleIdentifier != nil else { return }
        available = true
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func postNewPR(_ pr: PullRequest) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = "New PR in \(pr.repoFullName)"
        content.subtitle = "#\(pr.number) by \(pr.user?.login ?? "unknown")"
        content.body = pr.title
        content.sound = .default
        content.userInfo = ["url": pr.htmlURL.absoluteString]

        let request = UNNotificationRequest(
            identifier: "tally-pr-\(pr.id)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    // Show banners even while the app is frontmost.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    // Clicking the notification opens the PR on github.com.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let urlString = response.notification.request.content.userInfo["url"] as? String,
           let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
        completionHandler()
    }
}
