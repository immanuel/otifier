import AppKit
import SwiftUI
import ApplicationServices

private let systemSettingsBundleID = "com.apple.systempreferences"
private let panelWidth: CGFloat = 440
private let panelHeight: CGFloat = 100
// Negative = panel overlaps the bottom of the System Settings window, matching
// the visual tether seen in apps like BoltAI and Codex Computer Use.
private let gapBelowSettings: CGFloat = -34

@MainActor
final class AccessibilityDragPanelController: NSObject {
    private var panel: NSPanel?
    private var trackingTimer: Timer?
    private var missingWindowSince: Date?

    func show() {
        if panel != nil {
            reposition()
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let hosting = NSHostingView(rootView: DragPanelContent())
        hosting.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)
        panel.contentView = hosting

        self.panel = panel

        if let position = computePanelOrigin() {
            panel.setFrameOrigin(position)
        } else {
            // Fallback: bottom-center of main screen
            if let screen = NSScreen.main {
                let x = screen.frame.midX - panelWidth / 2
                let y = screen.frame.minY + 120
                panel.setFrameOrigin(NSPoint(x: x, y: y))
            }
        }

        panel.orderFrontRegardless()
        startTracking()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appTerminated(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )
    }

    func hide() {
        stopTracking()
        panel?.orderOut(nil)
        panel = nil
        NotificationCenter.default.removeObserver(self)
    }

    private func startTracking() {
        stopTracking()
        missingWindowSince = nil
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reposition() }
        }
        RunLoop.main.add(timer, forMode: .common)
        trackingTimer = timer
    }

    private func stopTracking() {
        trackingTimer?.invalidate()
        trackingTimer = nil
    }

    private func reposition() {
        guard let panel else { return }
        if let origin = computePanelOrigin() {
            missingWindowSince = nil
            if panel.frame.origin != origin {
                panel.setFrameOrigin(origin)
            }
        } else {
            let now = Date()
            if let since = missingWindowSince {
                if now.timeIntervalSince(since) > 2 {
                    hide()
                }
            } else {
                missingWindowSince = now
            }
        }
    }

    private func computePanelOrigin() -> NSPoint? {
        guard let bounds = systemSettingsWindowBounds() else { return nil }
        // CGWindow bounds use top-left origin in screen coords; AppKit uses bottom-left.
        guard let screen = NSScreen.screens.first else { return nil }
        let screenHeight = screen.frame.maxY
        let settingsBottomY = screenHeight - (bounds.origin.y + bounds.size.height)
        // Align with the right detail pane (the apps list), not the whole window —
        // System Settings' sidebar is ~215pt wide.
        let sidebarWidth: CGFloat = 215
        let rightPaneCenterX = bounds.minX + sidebarWidth + (bounds.width - sidebarWidth) / 2
        let x = rightPaneCenterX - panelWidth / 2
        let y = settingsBottomY - panelHeight - gapBelowSettings
        return NSPoint(x: x, y: y)
    }

    private func systemSettingsWindowBounds() -> CGRect? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        var best: (CGRect, Int)?
        for info in list {
            guard let owner = info[kCGWindowOwnerName as String] as? String,
                  owner == "System Settings" || owner == "System Preferences" else { continue }
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { continue }
            // Skip tiny utility windows
            if rect.width < 400 || rect.height < 300 { continue }
            let area = Int(rect.width * rect.height)
            if best == nil || area > best!.1 {
                best = (rect, area)
            }
        }
        return best?.0
    }

    @objc private func appTerminated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == systemSettingsBundleID else { return }
        Task { @MainActor in self.hide() }
    }
}

private let arrowBlue = Color(red: 0x54 / 255.0, green: 0xB6 / 255.0, blue: 0xFF / 255.0)

private struct DragPanelContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(arrowBlue)
                Text("Drag Otifier to the list above to allow Accessibility")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }

            DraggableRow()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
        .padding(2)
    }
}

private struct DraggableRow: NSViewRepresentable {
    func makeNSView(context: Context) -> DraggableRowView {
        DraggableRowView()
    }
    func updateNSView(_ nsView: DraggableRowView, context: Context) {}
}

final class DraggableRowView: NSView, NSDraggingSource {
    private let imageView = NSImageView()
    private let label = NSTextField(labelWithString: "Otifier")
    private var trackingArea: NSTrackingArea?
    private var isHovering = false {
        didSet { if isHovering != oldValue { needsDisplay = true } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous

        let icon = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        icon.size = NSSize(width: 32, height: 32)
        imageView.image = icon
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)

        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 48),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 32),
            imageView.heightAnchor.constraint(equalToConstant: 32),
            label.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
        ])

        updateBackground()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = trackingArea { removeTrackingArea(area) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        NSCursor.openHand.set()
        updateBackground()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        NSCursor.arrow.set()
        updateBackground()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    private func updateBackground() {
        let fillAlpha: CGFloat = isHovering ? 0.14 : 0.05
        let borderAlpha: CGFloat = isHovering ? 0.22 : 0.0
        layer?.backgroundColor = NSColor.white.withAlphaComponent(fillAlpha).cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(borderAlpha).cgColor
        layer?.borderWidth = isHovering ? 1 : 0
    }

    override func mouseDown(with event: NSEvent) {
        let url = Bundle.main.bundleURL as NSURL
        let item = NSDraggingItem(pasteboardWriter: url)
        let icon = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        icon.size = NSSize(width: 48, height: 48)
        let dragFrame = NSRect(
            x: imageView.frame.midX - 24,
            y: imageView.frame.midY - 24,
            width: 48,
            height: 48
        )
        item.setDraggingFrame(dragFrame, contents: icon)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        switch context {
        case .outsideApplication: return .copy
        case .withinApplication: return []
        @unknown default: return .copy
        }
    }
}
