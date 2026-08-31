import Cocoa
import ApplicationServices

private let notificationCenterBundleID = "com.apple.notificationcenterui"
private let axMessagingTimeout: Float = 0.5
private let observerBackstopInterval: TimeInterval = 4
private let fallbackPollInterval: TimeInterval = 1
private let fullScanSafetyInterval: TimeInterval = 30

private let notificationObserverCallback: AXObserverCallback = { _, _, _, refcon in
    guard let refcon else { return }
    let watcher = Unmanaged<NotificationWatcher>.fromOpaque(refcon).takeUnretainedValue()
    watcher.notificationCenterDidChange()
}

/// A privacy-preserving description of a Notification Center window. It only
/// contains geometry and window identifiers; notification text is never cached.
struct NotificationWindowFingerprint: Equatable {
    let values: [String]
}

/// Decides when the comparatively expensive Accessibility-tree scan is needed.
/// Window changes trigger a scan plus one follow-up (banner contents may be
/// populated just after the window is created); otherwise only a safety scan is
/// allowed through.
struct NotificationScanGate {
    private(set) var previousFingerprint: NotificationWindowFingerprint?
    private(set) var followUpScansRemaining = 0
    private(set) var lastScanAt = Date.distantPast

    mutating func shouldScan(
        fingerprint: NotificationWindowFingerprint,
        now: Date,
        safetyInterval: TimeInterval = fullScanSafetyInterval
    ) -> Bool {
        if previousFingerprint != fingerprint {
            previousFingerprint = fingerprint
            followUpScansRemaining = 1
            lastScanAt = now
            return true
        }

        if followUpScansRemaining > 0 {
            followUpScansRemaining -= 1
            lastScanAt = now
            return true
        }

        if now.timeIntervalSince(lastScanAt) >= safetyInterval {
            lastScanAt = now
            return true
        }

        return false
    }

    mutating func recordEventScan(at date: Date) {
        lastScanAt = date
    }

    mutating func reset() {
        previousFingerprint = nil
        followUpScansRemaining = 0
        lastScanAt = .distantPast
    }
}

/// Watches macOS notification banners through the Accessibility API and
/// extracts OTP codes from their text content.
///
/// Accessibility calls are synchronous IPC. Notification Center can be slow or
/// temporarily unresponsive, so all AX work is isolated on a utility queue and
/// given a short messaging timeout. The UI thread therefore remains responsive
/// even if Notification Center does not answer.
// Mutable monitoring state is serialized on workerQueue. Callback properties are
// configured before start() and only read by that queue.
final class NotificationWatcher: @unchecked Sendable {
    private let workerQueue = DispatchQueue(
        label: "com.otifier.notification-watcher",
        qos: .utility,
        autoreleaseFrequency: .workItem
    )

    // The properties below are confined to workerQueue.
    private var pollSource: DispatchSourceTimer?
    private var eventScanWorkItem: DispatchWorkItem?
    private var axObserver: AXObserver?
    private var observedApplication: AXUIElement?
    private var observedPID: pid_t?
    private var isRunning = false
    private var scanGate = NotificationScanGate()
    private var lastSeenTexts: [String] = []
    private var lastPermissionCheck = Date.distantPast

    private let maxCacheSize = 50
    private let permissionCheckInterval: TimeInterval = 10
    private let maxTreeDepth = 12
    private let maxElementsPerScan = 250

    var onOTPDetected: ((String, String) -> Void)?  // (otp, sourceText)
    /// Called once if Accessibility permission is revoked while running.
    /// The watcher stops itself before invoking this.
    var onAXPermissionLost: (() -> Void)?

    func start() {
        workerQueue.async { [weak self] in
            guard let self, !self.isRunning else { return }
            self.isRunning = true
            self.scanGate.reset()
            self.lastPermissionCheck = .distantPast

            // A global process timeout also applies to child AX elements created
            // while traversing Notification Center's hierarchy.
            let systemWideElement = AXUIElementCreateSystemWide()
            _ = AXUIElementSetMessagingTimeout(systemWideElement, axMessagingTimeout)

            self.refreshNotificationCenterConnection()
            self.startBackstopTimer()
            self.pollNotificationsIfNeeded(force: true)
        }
    }

    func stop() {
        workerQueue.async { [weak self] in
            self?.stopOnWorkerQueue()
        }
    }

    deinit {
        pollSource?.setEventHandler {}
        pollSource?.cancel()
        eventScanWorkItem?.cancel()
        removeAXObserver()
    }

    private func stopOnWorkerQueue() {
        guard isRunning else { return }
        isRunning = false

        pollSource?.setEventHandler {}
        pollSource?.cancel()
        pollSource = nil
        eventScanWorkItem?.cancel()
        eventScanWorkItem = nil
        removeAXObserver()
        observedPID = nil
        scanGate.reset()
    }

    private func startBackstopTimer() {
        pollSource?.setEventHandler {}
        pollSource?.cancel()

        let interval = axObserver == nil ? fallbackPollInterval : observerBackstopInterval
        let timer = DispatchSource.makeTimerSource(queue: workerQueue)
        timer.schedule(
            deadline: .now() + interval,
            repeating: interval,
            leeway: .milliseconds(Int(interval * 200))
        )
        timer.setEventHandler { [weak self] in
            self?.pollNotificationsIfNeeded(force: false)
        }
        pollSource = timer
        timer.resume()
    }

    /// Called by the AX observer's main-run-loop callback. Actual processing is
    /// coalesced and dispatched to the utility queue.
    fileprivate func notificationCenterDidChange() {
        workerQueue.async { [weak self] in
            guard let self, self.isRunning else { return }

            // One banner can create several AX elements. Debouncing collapses
            // that burst into a single tree traversal after text is populated.
            self.eventScanWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in
                guard let self, self.isRunning else { return }
                self.scanGate.recordEventScan(at: Date())
                self.performNotificationScan()
            }
            self.eventScanWorkItem = item
            self.workerQueue.asyncAfter(deadline: .now() + .milliseconds(200), execute: item)
        }
    }

    private func pollNotificationsIfNeeded(force: Bool) {
        guard isRunning else { return }

        let now = Date()
        if now.timeIntervalSince(lastPermissionCheck) >= permissionCheckInterval {
            lastPermissionCheck = now
            if !AXIsProcessTrusted() {
                let callback = onAXPermissionLost
                stopOnWorkerQueue()
                callback?()
                return
            }
        }

        if observedPID == nil || NSRunningApplication(processIdentifier: observedPID!)?.isTerminated != false {
            let previouslyObserved = observedPID
            refreshNotificationCenterConnection()
            if observedPID != previouslyObserved {
                startBackstopTimer()
            }
        }

        guard let pid = observedPID else { return }
        let fingerprint = notificationWindowFingerprint(for: pid)
        let gateRequestedScan = scanGate.shouldScan(fingerprint: fingerprint, now: now)
        if force || gateRequestedScan {
            performNotificationScan()
        }
    }

    private func refreshNotificationCenterConnection() {
        removeAXObserver()
        observedPID = NSRunningApplication
            .runningApplications(withBundleIdentifier: notificationCenterBundleID)
            .first?
            .processIdentifier

        guard let pid = observedPID else { return }

        let application = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetMessagingTimeout(application, axMessagingTimeout)
        // Retain the application element even if this macOS version does not
        // support the observer notifications; the window-change timer then acts
        // as the compatibility fallback.
        observedApplication = application

        var newObserver: AXObserver?
        guard AXObserverCreate(pid, notificationObserverCallback, &newObserver) == .success,
              let observer = newObserver else { return }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let notifications = [
            kAXCreatedNotification as CFString,
            kAXWindowCreatedNotification as CFString,
        ]
        var registeredNotifications = 0
        for notification in notifications {
            let result = AXObserverAddNotification(observer, application, notification, refcon)
            if result == .success || result == .notificationAlreadyRegistered {
                registeredNotifications += 1
            }
        }

        guard registeredNotifications > 0 else { return }

        axObserver = observer
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .commonModes
        )
    }

    private func removeAXObserver() {
        if let observer = axObserver {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(observer),
                .commonModes
            )
        }
        axObserver = nil
        observedApplication = nil
    }

    private func notificationWindowFingerprint(for pid: pid_t) -> NotificationWindowFingerprint {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return NotificationWindowFingerprint(values: [])
        }

        let values = windows.compactMap { info -> String? in
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? NSNumber,
                  ownerPID.int32Value == pid,
                  let windowNumber = info[kCGWindowNumber as String] as? NSNumber else {
                return nil
            }

            let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0
            let boundsDescription: String
            if let boundsDictionary = info[kCGWindowBounds as String] as? [String: Any],
               let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary) {
                boundsDescription = "\(Int(bounds.minX)),\(Int(bounds.minY)),\(Int(bounds.width)),\(Int(bounds.height))"
            } else {
                boundsDescription = ""
            }
            return "\(windowNumber.intValue):\(layer):\(alpha):\(boundsDescription)"
        }.sorted()

        return NotificationWindowFingerprint(values: values)
    }

    private func performNotificationScan() {
        guard let application = observedApplication else { return }
        let texts = getNotificationTexts(from: application)
        guard !texts.isEmpty else { return }

        let combined = texts.joined(separator: " | ")
        guard !lastSeenTexts.contains(combined) else { return }

        lastSeenTexts.append(combined)
        if lastSeenTexts.count > maxCacheSize {
            lastSeenTexts.removeFirst()
        }

        let fullText = texts.joined(separator: " ")
        if let otp = extractOTP(from: fullText) {
            onOTPDetected?(otp, fullText)
        }
    }

    /// Reads the six attributes needed for extraction in one cross-process IPC
    /// call per element and caps traversal work so a malformed or very large AX
    /// tree cannot monopolize the worker indefinitely.
    private func collectTexts(from root: AXUIElement, maxDepth: Int) -> [String] {
        let attributes: [CFString] = [
            kAXValueAttribute as CFString,
            kAXTitleAttribute as CFString,
            kAXDescriptionAttribute as CFString,
            kAXHelpAttribute as CFString,
            kAXRoleDescriptionAttribute as CFString,
            kAXChildrenAttribute as CFString,
        ]

        var result: [String] = []
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var index = 0
        var visited = Set<CFHashCode>()

        while index < queue.count && visited.count < maxElementsPerScan {
            let (element, depth) = queue[index]
            index += 1
            guard depth < maxDepth else { continue }

            let identity = CFHash(element)
            guard visited.insert(identity).inserted else { continue }

            var copiedValues: CFArray?
            let copyResult = AXUIElementCopyMultipleAttributeValues(
                element,
                attributes as CFArray,
                [],
                &copiedValues
            )
            guard copyResult == .success, let values = copiedValues as? [Any] else { continue }

            for value in values.prefix(5) {
                if let text = value as? String, !text.isEmpty {
                    result.append(text)
                }
            }

            if values.count > 5, let children = values[5] as? [AXUIElement] {
                queue.append(contentsOf: children.map { ($0, depth + 1) })
            }
        }

        return result
    }

    private func children(of element: AXUIElement, attribute: CFString) -> [AXUIElement] {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private func getNotificationTexts(from application: AXUIElement) -> [String] {
        var allTexts: [String] = []

        // Banners are windows on most macOS releases. Scan windows first so the
        // node budget is spent on the most likely notification content.
        for window in children(of: application, attribute: kAXWindowsAttribute as CFString) {
            allTexts.append(contentsOf: collectTexts(from: window, maxDepth: maxTreeDepth))
        }

        // On newer releases banners may instead appear as direct children.
        if allTexts.isEmpty {
            for child in children(of: application, attribute: kAXChildrenAttribute as CFString) {
                var roleValue: AnyObject?
                _ = AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleValue)
                if let role = roleValue as? String, role == "AXMenuBar" { continue }
                allTexts.append(contentsOf: collectTexts(from: child, maxDepth: min(maxTreeDepth, 10)))
            }
        }

        return allTexts
    }
}
