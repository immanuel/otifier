import SwiftUI
import AppKit
import ApplicationServices

struct OTPEntry: Identifiable {
    let id = UUID()
    let code: String
    let source: String
    let timestamp: Date

    var timeAgo: String {
        let seconds = Int(Date().timeIntervalSince(timestamp))
        if seconds < 60 { return "\(seconds)s ago" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        return "\(minutes / 60)h ago"
    }
}

@MainActor
class AppState: ObservableObject {
    @Published var isMonitoring = true
    @Published var recentOTPs: [OTPEntry] = []
    @Published var hasAccessibilityPermission = false
    @Published var statusMessage = "Starting..."

    private var notifWatcher: NotificationWatcher?
    private var cleanupTimer: Timer?
    private var permissionPollTimer: Timer?

    init() {
        startMonitoring()
        // Delay permission check — AX system may not be ready at init
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.checkPermissions()
            self?.promptForAccessibilityIfNeeded()
        }
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.cleanupOldOTPs()
            }
        }
    }

    func checkPermissions() {
        hasAccessibilityPermission = AXIsProcessTrusted()
    }

    func startMonitoring() {
        guard isMonitoring else { return }

        let watcher = NotificationWatcher()
        watcher.onOTPDetected = { [weak self] otp, source in
            Task { @MainActor in
                self?.addOTP(code: otp, source: "Notification")
            }
        }
        watcher.start()
        notifWatcher = watcher
        statusMessage = "Monitoring"
    }

    func stopMonitoring() {
        notifWatcher?.stop()
        notifWatcher = nil
        statusMessage = "Stopped"
    }

    func toggleMonitoring() {
        isMonitoring.toggle()
        if isMonitoring {
            startMonitoring()
        } else {
            stopMonitoring()
        }
    }

    func addOTP(code: String, source: String) {
        if recentOTPs.contains(where: { $0.code == code && Date().timeIntervalSince($0.timestamp) < 60 }) {
            return
        }

        let entry = OTPEntry(code: code, source: source, timestamp: Date())
        recentOTPs.insert(entry, at: 0)

        if recentOTPs.count > 10 {
            recentOTPs = Array(recentOTPs.prefix(10))
        }

        copyToClipboard(code)
        showNotification(otp: code, source: source)
    }

    func copyOTP(_ entry: OTPEntry) {
        copyToClipboard(entry.code)
    }

    private func cleanupOldOTPs() {
        recentOTPs.removeAll { Date().timeIntervalSince($0.timestamp) > 600 }
    }

    func requestAccessibility() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.checkPermissions()
        }
        startPollingForPermission()
    }

    func promptForAccessibilityIfNeeded() {
        guard !AXIsProcessTrusted() else { return }

        let alert = NSAlert()
        alert.messageText = "Otifier needs Accessibility access"
        alert.informativeText = """
            Otifier reads notification banners to detect OTP codes \
            and copy them to your clipboard automatically. \
            Without Accessibility permission, it can't see notifications.
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")

        NSApp.activate(ignoringOtherApps: true)

        if alert.runModal() == .alertFirstButtonReturn {
            requestAccessibility()
        }
    }

    private func startPollingForPermission() {
        permissionPollTimer?.invalidate()
        let deadline = Date().addingTimeInterval(10 * 60)
        permissionPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else { timer.invalidate(); return }
                if AXIsProcessTrusted() {
                    self.hasAccessibilityPermission = true
                    self.notifWatcher?.stop()
                    self.startMonitoring()
                    timer.invalidate()
                    self.permissionPollTimer = nil
                } else if Date() > deadline {
                    timer.invalidate()
                    self.permissionPollTimer = nil
                }
            }
        }
    }
}
