import SwiftUI
import AppKit
import ApplicationServices
import ServiceManagement

private let launchAtLoginPromptShownKey = "launchAtLoginPromptShown"
private let otpKeywordsKey = "otpKeywords"
private let legacyCustomOTPKeywordsKey = "customOTPKeywords"
private let legacyBuiltInOTPKeywordsKey = "builtInOTPKeywords"

struct OTPEntry: Identifiable {
    let id = UUID()
    let code: String
    let sourceKey: String
    let timestamp: Date

    @MainActor
    func timeAgo(using localization: LocalizationManager) -> String {
        let seconds = Int(Date().timeIntervalSince(timestamp))
        if seconds < 60 { return localization.text("time.seconds_ago", seconds) }
        let minutes = seconds / 60
        if minutes < 60 { return localization.text("time.minutes_ago", minutes) }
        return localization.text("time.hours_ago", minutes / 60)
    }
}

struct UnrecognizedOTPEntry: Identifiable {
    let id = UUID()
    let text: String
    let candidates: [String]
    let timestamp: Date

    var preview: String {
        let collapsed = text
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard collapsed.count > 90 else { return collapsed }
        return String(collapsed.prefix(90)) + "…"
    }
}

@MainActor
class AppState: ObservableObject {
    let localization = LocalizationManager()

    @Published var isMonitoring = true
    @Published var recentOTPs: [OTPEntry] = []
    @Published var recentUnrecognized: [UnrecognizedOTPEntry] = []
    @Published var hasAccessibilityPermission = false
    @Published var launchAtLoginEnabled = false
    @Published var statusMessageKey = "status.starting"
    @Published var otpKeywords: [String] = defaultOTPKeywords
    @Published var isShowingRuleEditor = false

    private var notifWatcher: NotificationWatcher?
    private var cleanupTimer: Timer?
    private var permissionPollTimer: Timer?
    private let dragPanelController = AccessibilityDragPanelController()

    init() {
        let defaults = UserDefaults.standard
        if let savedKeywords = defaults.stringArray(forKey: otpKeywordsKey) {
            otpKeywords = savedKeywords
        } else {
            let legacyBuiltIn = defaults.stringArray(forKey: legacyBuiltInOTPKeywordsKey) ?? defaultOTPKeywords
            let legacyCustom = defaults.stringArray(forKey: legacyCustomOTPKeywordsKey) ?? []
            otpKeywords = normalizedKeywords(from: (legacyBuiltIn + legacyCustom).joined(separator: "\n"))
            defaults.set(otpKeywords, forKey: otpKeywordsKey)
            defaults.removeObject(forKey: legacyBuiltInOTPKeywordsKey)
            defaults.removeObject(forKey: legacyCustomOTPKeywordsKey)
        }
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
        watcher.onOTPDetected = { [weak self] otp, _ in
            Task { @MainActor in
                self?.addOTP(code: otp, sourceKey: "source.notification")
            }
        }
        watcher.onAXPermissionLost = { [weak self] in
            Task { @MainActor in
                self?.handleAXPermissionLost()
            }
        }
        watcher.onUnrecognizedText = { [weak self] text, candidates in
            Task { @MainActor in
                self?.addUnrecognized(text: text, candidates: candidates)
            }
        }
        watcher.updateKeywords(otpKeywords)
        watcher.start()
        notifWatcher = watcher
        statusMessageKey = "status.monitoring"
    }

    private func handleAXPermissionLost() {
        // Watcher has already invalidated its timer; clear our reference
        // and let the menu's permission CTA take over.
        notifWatcher = nil
        hasAccessibilityPermission = false
        statusMessageKey = "status.permission_required"
    }

    func stopMonitoring() {
        notifWatcher?.stop()
        notifWatcher = nil
        statusMessageKey = "status.stopped"
    }

    func toggleMonitoring() {
        isMonitoring.toggle()
        if isMonitoring {
            startMonitoring()
        } else {
            stopMonitoring()
        }
    }

    func addOTP(code: String, sourceKey: String) {
        if recentOTPs.contains(where: { $0.code == code && Date().timeIntervalSince($0.timestamp) < 60 }) {
            return
        }

        let entry = OTPEntry(code: code, sourceKey: sourceKey, timestamp: Date())
        recentOTPs.insert(entry, at: 0)

        if recentOTPs.count > 10 {
            recentOTPs = Array(recentOTPs.prefix(10))
        }

        copyToClipboard(code)
        showNotification(
            title: localization.text("notification.copied.title"),
            body: localization.text("notification.copied.body")
        )
    }

    func copyOTP(_ entry: OTPEntry) {
        copyToClipboard(entry.code)
    }

    func acceptCandidate(_ code: String, from entry: UnrecognizedOTPEntry) {
        recentUnrecognized.removeAll { $0.id == entry.id }
        addOTP(code: code, sourceKey: "source.manual")
    }

    func promptToAddRule(for entry: UnrecognizedOTPEntry) {
        let alert = NSAlert()
        alert.messageText = localization.text("alert.add_rule.title")
        alert.informativeText = localization.text("alert.add_rule.message")
        alert.alertStyle = .informational
        alert.addButton(withTitle: localization.text("alert.add_rule.confirm"))
        alert.addButton(withTitle: localization.text("common.cancel"))

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = localization.text("alert.add_rule.placeholder")
        alert.accessoryView = field

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        addKeyword(field.stringValue)

        if let code = extractOTP(from: entry.text, keywords: otpKeywords) {
            recentUnrecognized.removeAll { $0.id == entry.id }
            addOTP(code: code, sourceKey: "source.keyword_rule")
        }
    }

    private func addKeyword(_ rawKeyword: String) {
        let keyword = rawKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return }
        guard !otpKeywords.contains(where: { $0.caseInsensitiveCompare(keyword) == .orderedSame }) else {
            return
        }
        otpKeywords.append(keyword)
        persistKeywords()
    }

    private func persistKeywords() {
        UserDefaults.standard.set(otpKeywords, forKey: otpKeywordsKey)
        updateWatcherKeywords()
    }

    func promptToEditKeywords() {
        let alert = NSAlert()
        alert.messageText = localization.text("alert.edit_keywords.title")
        alert.informativeText = localization.text("alert.edit_keywords.message")
        alert.alertStyle = .informational
        alert.addButton(withTitle: localization.text("alert.edit_keywords.confirm"))
        alert.addButton(withTitle: localization.text("common.cancel"))

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 380, height: 180))
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        let textView = NSTextView(frame: scrollView.bounds)
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.string = otpKeywords.joined(separator: "\n")
        scrollView.documentView = textView
        alert.accessoryView = scrollView

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        otpKeywords = normalizedKeywords(from: textView.string)
        persistKeywords()
    }

    func resetKeywords() {
        let alert = NSAlert()
        alert.messageText = localization.text("alert.reset_keywords.title")
        alert.informativeText = localization.text("alert.reset_keywords.message")
        alert.alertStyle = .warning
        alert.addButton(withTitle: localization.text("alert.reset_keywords.confirm"))
        alert.addButton(withTitle: localization.text("common.cancel"))

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        otpKeywords = defaultOTPKeywords
        persistKeywords()
    }

    private func normalizedKeywords(from text: String) -> [String] {
        let separators = CharacterSet(charactersIn: ",，\n\r")
        var seen = Set<String>()
        return text.components(separatedBy: separators).compactMap { component in
            let keyword = component.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !keyword.isEmpty else { return nil }
            let identity = keyword.lowercased()
            guard seen.insert(identity).inserted else { return nil }
            return keyword
        }
    }

    private func updateWatcherKeywords() {
        notifWatcher?.updateKeywords(otpKeywords)
    }

    private func addUnrecognized(text: String, candidates: [String]) {
        guard !candidates.isEmpty else { return }
        if recentUnrecognized.contains(where: { $0.text == text }) { return }

        recentUnrecognized.insert(
            UnrecognizedOTPEntry(text: text, candidates: candidates, timestamp: Date()),
            at: 0
        )
        if recentUnrecognized.count > 5 {
            recentUnrecognized = Array(recentUnrecognized.prefix(5))
        }
    }

    private func cleanupOldOTPs() {
        // Codes are short-lived secrets; keep them in the menu just long
        // enough for the user to re-copy if their first paste went somewhere
        // wrong. 2 min is long enough for that and short enough to reduce
        // shoulder-surfing risk if the menu is left open.
        recentOTPs.removeAll { Date().timeIntervalSince($0.timestamp) > 120 }
        // Unrecognized notification text is deliberately memory-only and has the
        // same short lifetime as recognized codes.
        recentUnrecognized.removeAll { Date().timeIntervalSince($0.timestamp) > 120 }
    }

    func requestAccessibility() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            self.dragPanelController.show(
                message: self.localization.text("accessibility.drag_instruction")
            )
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.checkPermissions()
        }
        startPollingForPermission()
    }

    func promptForAccessibilityIfNeeded() {
        guard !AXIsProcessTrusted() else { return }

        let alert = NSAlert()
        alert.messageText = localization.text("alert.accessibility.title")
        alert.informativeText = localization.text("alert.accessibility.message")
        alert.alertStyle = .warning
        alert.addButton(withTitle: localization.text("menu.open_system_settings"))
        alert.addButton(withTitle: localization.text("common.not_now"))

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
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = localization.text(
                enabled ? "alert.launch_error.enable" : "alert.launch_error.disable"
            )
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.addButton(withTitle: localization.text("common.ok"))
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
        refreshLaunchAtLoginStatus()
    }

    func promptForLaunchAtLoginIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: launchAtLoginPromptShownKey) else { return }
        guard SMAppService.mainApp.status != .enabled else { return }

        defaults.set(true, forKey: launchAtLoginPromptShownKey)

        let alert = NSAlert()
        alert.messageText = localization.text("alert.launch_prompt.title")
        alert.informativeText = localization.text("alert.launch_prompt.message")
        alert.alertStyle = .informational
        alert.addButton(withTitle: localization.text("alert.launch_prompt.confirm"))
        alert.addButton(withTitle: localization.text("common.not_now"))

        NSApp.activate(ignoringOtherApps: true)

        if alert.runModal() == .alertFirstButtonReturn {
            setLaunchAtLogin(true)
        }
    }
}
