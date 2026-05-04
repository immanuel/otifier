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
    // CLI binary has no bundle identifier — UNUserNotificationCenter would crash.
    // Fall back to osascript so the `otifier` CLI keeps working for diagnostics.
    guard Bundle.main.bundleIdentifier != nil else {
        showNotificationViaOsascript(otp: otp, source: source)
        return
    }

    _ = notificationDelegate

    let center = UNUserNotificationCenter.current()
    center.getNotificationSettings { settings in
        switch settings.authorizationStatus {
        case .notDetermined:
            center.requestAuthorization(options: [.alert, .sound]) { granted, error in
                if let error {
                    NSLog("Otifier: notification authorization error: \(error)")
                }
                if granted {
                    deliver(otp: otp, source: source)
                }
            }
        case .authorized, .provisional, .ephemeral:
            deliver(otp: otp, source: source)
        case .denied:
            NSLog("Otifier: notifications denied — skipping banner for \(otp)")
        @unknown default:
            deliver(otp: otp, source: source)
        }
    }
}

private func deliver(otp: String, source: String) {
    let content = UNMutableNotificationContent()
    content.title = "Verification Code Detected"
    content.subtitle = source
    content.body = "Code: \(otp) — copied to clipboard"
    content.sound = .default

    let request = UNNotificationRequest(
        identifier: UUID().uuidString,
        content: content,
        trigger: nil
    )
    UNUserNotificationCenter.current().add(request) { error in
        if let error {
            NSLog("Otifier: failed to post notification: \(error)")
        }
    }
}

private func showNotificationViaOsascript(otp: String, source: String) {
    let script = """
    display notification "Code: \(otp) — copied to clipboard" with title "OTP Detected" subtitle "\(source)" sound name "Glass"
    """
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", script]
    try? process.run()
}
