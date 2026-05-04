import SwiftUI

struct OTifierMenu: View {
    @ObservedObject var state: AppState
    @ObservedObject var updater: UpdaterController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Otifier")
                    .font(.headline)
                Spacer()
                if state.hasAccessibilityPermission {
                    Toggle("", isOn: Binding(
                        get: { state.isMonitoring },
                        set: { _ in state.toggleMonitoring() }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            Divider()

            if state.hasAccessibilityPermission {
                MonitoringPanel(state: state)
            } else {
                PermissionPanel(state: state)
            }

            Divider()

            Toggle(isOn: Binding(
                get: { state.launchAtLoginEnabled },
                set: { state.setLaunchAtLogin($0) }
            )) {
                Text("Launch at Login")
            }
            .toggleStyle(.checkbox)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Divider()

            Button("Check for Updates…") {
                updater.checkForUpdates()
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Divider()

            Button("Quit Otifier") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 280)
        .onAppear {
            state.checkPermissions()
            state.refreshLaunchAtLoginStatus()
        }
    }
}

struct MonitoringPanel: View {
    @ObservedObject var state: AppState

    var body: some View {
        if state.recentOTPs.isEmpty {
            VStack(spacing: 4) {
                Text("No OTP codes detected yet")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(state.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
        } else {
            Text("Recent Codes")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 4)

            ForEach(state.recentOTPs) { entry in
                OTPRow(entry: entry) {
                    state.copyOTP(entry)
                }
            }
            .padding(.bottom, 4)
        }
    }
}

struct PermissionPanel: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 8) {
            Text("Accessibility permission required")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Otifier needs Accessibility access to read notification banners and detect OTP codes.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Button("Open System Settings") {
                state.requestAccessibility()
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .padding(.horizontal, 12)
    }
}

struct OTPRow: View {
    let entry: OTPEntry
    let onCopy: () -> Void

    var body: some View {
        Button(action: onCopy) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.code)
                        .font(.system(.title3, design: .monospaced, weight: .semibold))
                    Text("\(entry.source) · \(entry.timeAgo)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "doc.on.doc")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
