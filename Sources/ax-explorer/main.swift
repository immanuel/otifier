import Cocoa
import ApplicationServices

func dumpAXTree(element: AXUIElement, depth: Int = 0, maxDepth: Int = 8) {
    guard depth < maxDepth else {
        let indent = String(repeating: "  ", count: depth)
        print("\(indent)... (max depth reached)")
        return
    }
    let indent = String(repeating: "  ", count: depth)

    var roleValue: AnyObject?
    AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue)
    let role = (roleValue as? String) ?? "?"

    var titleValue: AnyObject?
    AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleValue)
    let title = (titleValue as? String) ?? ""

    var valValue: AnyObject?
    AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valValue)
    let val = (valValue as? String) ?? ""

    var descValue: AnyObject?
    AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &descValue)
    let desc = (descValue as? String) ?? ""

    var line = "\(indent)[\(role)]"
    if !title.isEmpty { line += " title=\"\(title)\"" }
    if !val.isEmpty { line += " value=\"\(val)\"" }
    if !desc.isEmpty { line += " desc=\"\(desc)\"" }
    print(line)

    var children: AnyObject?
    let childResult = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
    if childResult == .success, let childArray = children as? [AXUIElement] {
        for child in childArray {
            dumpAXTree(element: child, depth: depth + 1, maxDepth: maxDepth)
        }
    }
}

// Check permissions
let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
let trusted = AXIsProcessTrustedWithOptions(options)
if !trusted {
    print("Accessibility permission required!")
    print("  System Settings > Privacy & Security > Accessibility > Terminal")
    exit(1)
}

// Parse arguments
let args = CommandLine.arguments
let watchMode = args.contains("--watch")
let watchDuration: TimeInterval = {
    if let idx = args.firstIndex(of: "--watch"), idx + 1 < args.count,
       let secs = TimeInterval(args[idx + 1]) {
        return secs
    }
    return 10
}()

print("AX Explorer — Notification Processes\n")

let apps = NSWorkspace.shared.runningApplications
let interesting = apps.filter { app in
    let name = (app.localizedName ?? "").lowercased()
    let bundle = (app.bundleIdentifier ?? "").lowercased()
    return name.contains("notification") || bundle.contains("notification") || bundle.contains("usernoted")
}

if interesting.isEmpty {
    print("No notification-related processes found.")
    print("UI apps:")
    for app in apps where app.activationPolicy == .regular {
        print("  \(app.localizedName ?? "?") (\(app.bundleIdentifier ?? "?")) pid=\(app.processIdentifier)")
    }
} else {
    for app in interesting {
        print("--- \(app.localizedName ?? "?") (\(app.bundleIdentifier ?? "?")) pid=\(app.processIdentifier) ---")
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        dumpAXTree(element: axApp)
        print()
    }
}

// System-wide focused app
print("--- System-wide focused app ---")
let systemWide = AXUIElementCreateSystemWide()
var focusedApp: AnyObject?
AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &focusedApp)
if let focused = focusedApp {
    dumpAXTree(element: focused as! AXUIElement, maxDepth: 4)
}

if watchMode {
    print("\nWatching for \(Int(watchDuration))s... (trigger a notification now)")

    let startTime = Date()
    var seen = Set<String>()

    let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
        if Date().timeIntervalSince(startTime) > watchDuration {
            print("\nWatch complete.")
            exit(0)
        }

        // Check for NotificationCenter windows
        for app in NSWorkspace.shared.runningApplications {
            guard let name = app.localizedName,
                  (name.contains("NotificationCenter") || name.contains("Notification Center") ||
                   app.bundleIdentifier == "com.apple.notificationcenterui") else { continue }

            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            var windowsValue: AnyObject?
            let result = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsValue)
            guard result == .success, let windows = windowsValue as? [AXUIElement] else { continue }

            for window in windows {
                // Collect all text from this window
                func collectTexts(_ el: AXUIElement, _ depth: Int = 0) -> [String] {
                    guard depth < 15 else { return [] }
                    var texts: [String] = []
                    for attr in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] as [CFString] {
                        var v: AnyObject?
                        if AXUIElementCopyAttributeValue(el, attr, &v) == .success, let s = v as? String, !s.isEmpty {
                            texts.append(s)
                        }
                    }
                    var children: AnyObject?
                    if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &children) == .success,
                       let arr = children as? [AXUIElement] {
                        for child in arr { texts.append(contentsOf: collectTexts(child, depth + 1)) }
                    }
                    return texts
                }

                let texts = collectTexts(window)
                let key = texts.joined(separator: "|")
                if !key.isEmpty && !seen.contains(key) {
                    seen.insert(key)
                    print("  [NEW] \(texts)")
                }
            }
        }
    }
    _ = timer  // keep reference
    RunLoop.main.run()
} else {
    print("\nTip: use --watch [seconds] to continuously monitor for notifications")
}
