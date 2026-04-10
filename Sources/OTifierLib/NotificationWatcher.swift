import Cocoa
import ApplicationServices

/// Watches for macOS notification banners via the Accessibility API
/// and extracts OTP codes from their text content.
class NotificationWatcher {
    private var pollTimer: Timer?
    private var lastSeenTexts = Set<String>()
    private let maxCacheSize = 50
    var onOTPDetected: ((String, String) -> Void)?  // (otp, sourceText)

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

    /// Dump the full AX tree for debugging
    func dumpAXTree(element: AXUIElement, depth: Int = 0, maxDepth: Int = 10) {
        guard depth < maxDepth else { return }
        let indent = String(repeating: "  ", count: depth)

        var roleValue: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue)
        let role = (roleValue as? String) ?? "unknown"

        var subRoleValue: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subRoleValue)
        let subRole = (subRoleValue as? String) ?? ""

        var titleValue: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleValue)
        let title = (titleValue as? String) ?? ""

        var valValue: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valValue)
        let val = (valValue as? String) ?? ""

        var descValue: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &descValue)
        let desc = (descValue as? String) ?? ""

        print("\(indent)[\(role)] subrole=\(subRole) title=\(title) value=\(val) desc=\(desc)")

        var children: AnyObject?
        let childResult = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
        if childResult == .success, let childArray = children as? [AXUIElement] {
            for child in childArray {
                dumpAXTree(element: child, depth: depth + 1, maxDepth: maxDepth)
            }
        }
    }

    /// Test if AX access actually works by making a real AX call.
    /// More reliable than AXIsProcessTrustedWithOptions which is flaky with ad-hoc signing.
    func hasAXAccess() -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &value)
        return result == .success || result == .noValue
    }

    func start() {
        if hasAXAccess() {
            print("[NotificationWatcher] Accessibility access confirmed")
        } else {
            print("[NotificationWatcher] Accessibility permission required!")
            print("  Go to: System Settings > Privacy & Security > Accessibility")
            print("  Add and enable this app (or Terminal if running via swift)")
        }

        // List notification-related processes
        let runningApps = NSWorkspace.shared.runningApplications
        for app in runningApps {
            if let name = app.localizedName,
               let bundleId = app.bundleIdentifier,
               (name.lowercased().contains("notification") || bundleId.contains("notification") || bundleId.contains("usernoted")) {
                print("[NotificationWatcher] Found: \(name) (\(bundleId)) pid=\(app.processIdentifier)")
            }
        }

        // Register for distributed notifications
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(
            forName: nil, object: nil, queue: .main
        ) { notification in
            let name = notification.name.rawValue
            if name.lowercased().contains("notification") || name.lowercased().contains("alert") || name.lowercased().contains("banner") {
                print("[NotificationWatcher] DistributedNotification: \(name)")
                if let userInfo = notification.userInfo {
                    print("  userInfo: \(userInfo)")
                }
            }
        }

        // Poll for notification banners
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.pollNotifications()
        }

        // Initial AX tree dump after short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.dumpNotificationCenter()
        }

        print("[NotificationWatcher] Started, polling every 0.5s")
    }

    private func pollNotifications() {
        let texts = getNotificationTexts()
        guard !texts.isEmpty else { return }

        let combined = texts.joined(separator: " | ")
        guard !lastSeenTexts.contains(combined) else { return }

        lastSeenTexts.insert(combined)
        if lastSeenTexts.count > maxCacheSize {
            lastSeenTexts.removeFirst()
        }

        print("[NotificationWatcher] Notification detected: \(texts)")

        let fullText = texts.joined(separator: " ")
        if let otp = extractOTP(from: fullText) {
            print("[NotificationWatcher] OTP found: \(otp)")
            onOTPDetected?(otp, fullText)
        }
    }

    private func dumpNotificationCenter() {
        print("[NotificationWatcher] Dumping Notification Center AX tree...")
        guard let ncApp = getNotificationCenterApp() else {
            print("[NotificationWatcher] No Notification Center process found (expected if no banners visible)")
            return
        }
        dumpAXTree(element: ncApp)
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
}
