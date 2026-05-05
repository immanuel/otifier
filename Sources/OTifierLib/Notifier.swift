import Foundation
import UserNotifications

private final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

private let notificationDelegate: NotificationDelegate = {
    let delegate = NotificationDelegate()
    UNUserNotificationCenter.current().delegate = delegate
    return delegate
}()

func showNotification(otp: String, source: String) {
    _ = notificationDelegate

    let center = UNUserNotificationCenter.current()
    center.getNotificationSettings { settings in
        switch settings.authorizationStatus {
        case .notDetermined:
            center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                if granted {
                    deliver(otp: otp, source: source)
                }
            }
        case .authorized, .provisional, .ephemeral:
            deliver(otp: otp, source: source)
        case .denied:
            break
        @unknown default:
            deliver(otp: otp, source: source)
        }
    }
}

private func deliver(otp: String, source: String) {
    // Deliberately omit the OTP digits from the notification — macOS persists
    // delivered notifications in Notification Center history (and on disk under
    // ~/Library/Group Containers/group.com.apple.usernoted/), so digits here
    // would linger after dismissal. The code is already on the clipboard.
    let content = UNMutableNotificationContent()
    content.title = "Verification code copied"
    content.body = "Paste it where you need it."
    content.sound = .default

    let request = UNNotificationRequest(
        identifier: UUID().uuidString,
        content: content,
        trigger: nil
    )
    UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
}
