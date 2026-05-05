import SwiftUI
import AppKit
import ApplicationServices
import ServiceManagement

private let launchAtLoginPromptShownKey = "launchAtLoginPromptShown"

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
    @Published var launchAtLoginEnabled = false
    @Published var statusMessage = "Starting..."

    private var notifWatcher: NotificationWatcher?
    private var cleanupTimer: Timer?
    private var permissionPollTimer: Timer?
    private let dragPanelController = AccessibilityDragPanelController()

    init() {
        refreshLaunchAtLoginStatus()
        // Defer starting the watcher until we know permission is granted —
        // calling AX APIs without permission triggers macOS's own system prompt,
        // which would appear on top of our custom NSAlert.
        hasAccessibilityPermission = AXIsProcessTrusted()
        if hasAccessibilityPermission {
            startMonitoring()
        }
        // Delay permission flow — AX system may not be ready at init
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            self.checkPermissions()
            if self.hasAccessibilityPermission {
                if self.notifWatcher == nil { self.startMonitoring() }
                self.promptForLaunchAtLoginIfNeeded()
            } else {
                self.promptForAccessibilityIfNeeded()
            }
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
        guard notifWatcher == nil else { return }   // idempotent — don't spawn duplicates

        let watcher = NotificationWatcher()
        watcher.onOTPDetected = { [weak self] otp, source in
            Task { @MainActor in
                self?.addOTP(code: otp, source: "Notification")
            }
        }
        watcher.onAXPermissionLost = { [weak self] in
            Task { @MainActor in
                self?.handleAXPermissionLost()
            }
        }
        watcher.start()
        notifWatcher = watcher
        statusMessage = "Monitoring"
    }

    private func handleAXPermissionLost() {
        // Watcher has already invalidated its timer; clear our reference
        // and let the menu's permission CTA take over.
        notifWatcher = nil
        hasAccessibilityPermission = false
        statusMessage = "Accessibility permission required"
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.dragPanelController.show()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.checkPermissions()
        }
        startPollingForPermission()
    }

    func promptForAccessibilityIfNeeded() {
        guard !AXIsProcessTrusted() else { return }

        let alert = NSAlert()
        alert.messageText = "Allow Otifier to read notification banners?"
        alert.informativeText = """
            Otifier requires Accessibility permission to read notification banners and copy verification codes to your clipboard.
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Not Now")

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
                    self.stopMonitoring()
                    self.startMonitoring()
                    timer.invalidate()
                    self.permissionPollTimer = nil
                    self.dragPanelController.hide()
                    self.promptForLaunchAtLoginIfNeeded()
                } else if Date() > deadline {
                    timer.invalidate()
                    self.permissionPollTimer = nil
                    self.dragPanelController.hide()
                }
            }
        }
    }

    func refreshLaunchAtLoginStatus() {
        launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        if enabled {
            try? SMAppService.mainApp.register()
        } else {
            try? SMAppService.mainApp.unregister()
        }
        refreshLaunchAtLoginStatus()
    }

    func promptForLaunchAtLoginIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: launchAtLoginPromptShownKey) else { return }
        guard SMAppService.mainApp.status != .enabled else { return }

        defaults.set(true, forKey: launchAtLoginPromptShownKey)

        let alert = NSAlert()
        alert.messageText = "Launch Otifier on restart?"
        alert.informativeText = """
            Verification codes can arrive at any time, so Otifier is most \
            useful when it's already running. You can change this anytime \
            from the menu.
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Launch on restart")
        alert.addButton(withTitle: "Not Now")

        NSApp.activate(ignoringOtherApps: true)

        if alert.runModal() == .alertFirstButtonReturn {
            setLaunchAtLogin(true)
        }
    }
}
