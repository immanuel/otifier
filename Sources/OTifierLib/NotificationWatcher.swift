import Cocoa
import ApplicationServices

/// Watches for macOS notification banners via the Accessibility API
/// and extracts OTP codes from their text content.
class NotificationWatcher {
    private var pollTimer: Timer?
    private var lastSeenTexts = Set<String>()
    private let maxCacheSize = 50
    private var lastPermissionCheck = Date.distantPast
    private let permissionCheckInterval: TimeInterval = 5
    var onOTPDetected: ((String, String) -> Void)?  // (otp, sourceText)
    /// Called once if Accessibility permission is revoked while running.
    /// The watcher stops itself before invoking this.
    var onAXPermissionLost: (() -> Void)?

    init() {}

    /// The AX element for the Notification Center process
    private func getNotificationCenterApp() -> AXUIElement? {
        let runningApps = NSWorkspace.shared.runningApplications
        for app in runningApps {
            if let name = app.localizedName,
               (name.contains("NotificationCenter") || name.contains("Notification Center") || app.bundleIdentifier == "com.apple.notificationcenterui") {
                return AXUIElementCreateApplication(app.processIdentifier)
            }
        }
        return nil
    }

    /// Recursively walk the AX tree and collect all text values
    private func collectTexts(from element: AXUIElement, depth: Int = 0, maxDepth: Int = 15) -> [String] {
        guard depth < maxDepth else { return [] }
        var texts: [String] = []

        let textAttributes: [String] = [
            kAXValueAttribute as String,
            kAXTitleAttribute as String,
            kAXDescriptionAttribute as String,
            kAXHelpAttribute as String,
            kAXRoleDescriptionAttribute as String,
        ]

        for attr in textAttributes {
            var value: AnyObject?
            let result = AXUIElementCopyAttributeValue(element, attr as CFString, &value)
            if result == .success, let str = value as? String, !str.isEmpty {
                texts.append(str)
            }
        }

        var children: AnyObject?
        let childResult = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
        if childResult == .success, let childArray = children as? [AXUIElement] {
            for child in childArray {
                texts.append(contentsOf: collectTexts(from: child, depth: depth + 1, maxDepth: maxDepth))
            }
        }

        return texts
    }

    /// Get text from all Notification Center windows and children (banner notifications)
    private func getNotificationTexts() -> [String] {
        guard let ncApp = getNotificationCenterApp() else { return [] }

        var allTexts: [String] = []

        // Check windows (banners appear as windows on some macOS versions)
        var windowsValue: AnyObject?
        if AXUIElementCopyAttributeValue(ncApp, kAXWindowsAttribute as CFString, &windowsValue) == .success,
           let windows = windowsValue as? [AXUIElement] {
            for window in windows {
                allTexts.append(contentsOf: collectTexts(from: window))
            }
        }

        // Also check direct children (banners may appear here on newer macOS)
        if allTexts.isEmpty {
            var childrenValue: AnyObject?
            if AXUIElementCopyAttributeValue(ncApp, kAXChildrenAttribute as CFString, &childrenValue) == .success,
               let children = childrenValue as? [AXUIElement] {
                for child in children {
                    // Skip the menu bar — we only want notification content
                    var roleValue: AnyObject?
                    AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleValue)
                    if let role = roleValue as? String, role == "AXMenuBar" { continue }
                    allTexts.append(contentsOf: collectTexts(from: child, maxDepth: 10))
                }
            }
        }

        return allTexts
    }

    func start() {
        // 1.5s strikes a balance between responsiveness (banners stay on
        // screen ~5s) and battery — every poll walks a chunk of the AX tree.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.pollNotifications()
        }
    }

    private func pollNotifications() {
        // Throttled re-check of AX permission. If the user revokes it mid-run,
        // shut down the timer and let AppState surface the permission CTA.
        if Date().timeIntervalSince(lastPermissionCheck) >= permissionCheckInterval {
            lastPermissionCheck = Date()
            if !AXIsProcessTrusted() {
                stop()
                onAXPermissionLost?()
                return
            }
        }

        let texts = getNotificationTexts()
        guard !texts.isEmpty else { return }

        let combined = texts.joined(separator: " | ")
        guard !lastSeenTexts.contains(combined) else { return }

        lastSeenTexts.insert(combined)
        if lastSeenTexts.count > maxCacheSize {
            lastSeenTexts.removeFirst()
        }

        let fullText = texts.joined(separator: " ")
        if let otp = extractOTP(from: fullText) {
            onOTPDetected?(otp, fullText)
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
}
