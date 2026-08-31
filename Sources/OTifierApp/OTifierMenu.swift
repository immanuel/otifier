import SwiftUI

struct OTifierMenu: View {
    @ObservedObject var state: AppState
    @EnvironmentObject private var localization: LocalizationManager

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

            if !state.recentUnrecognized.isEmpty {
                Divider()
                UnrecognizedPanel(state: state)
            }

            Divider()

            Button {
                state.isShowingRuleEditor.toggle()
            } label: {
                HStack {
                    Label(localization.text("menu.rules.title"), systemImage: "text.badge.checkmark")
                    Spacer()
                    Image(systemName: state.isShowingRuleEditor ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)

            if state.isShowingRuleEditor {
                RulesPanel(state: state)
            }

            Divider()

            Menu {
                ForEach(localization.availableLanguages) { language in
                    Button {
                        localization.setLanguage(language.code)
                    } label: {
                        HStack {
                            Text(language.name)
                            if language.code == localization.selectedLanguageCode {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack {
                    Label(localization.text("menu.language"), systemImage: "globe")
                    Spacer()
                    Text(currentLanguageName)
                        .foregroundStyle(.secondary)
                }
            }
            .menuStyle(.borderlessButton)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Divider()

            Toggle(isOn: Binding(
                get: { state.launchAtLoginEnabled },
                set: { state.setLaunchAtLogin($0) }
            )) {
                Text(localization.text("menu.launch_at_login"))
            }
            .toggleStyle(.checkbox)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Divider()

            Button(localization.text("menu.quit")) {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 5)

            Text(localization.text("menu.version", appVersion))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 8)
        }
        .frame(width: 340)
        .onAppear {
            state.checkPermissions()
            state.refreshLaunchAtLoginStatus()
        }
    }

    private var currentLanguageName: String {
        localization.availableLanguages.first {
            $0.code == localization.selectedLanguageCode
        }?.name ?? localization.selectedLanguageCode
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }
}

struct UnrecognizedPanel: View {
    @ObservedObject var state: AppState
    @EnvironmentObject private var localization: LocalizationManager

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(localization.text("menu.unrecognized.title"))
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(state.recentUnrecognized) { entry in
                VStack(alignment: .leading, spacing: 5) {
                    Text(entry.preview)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(entry.candidates, id: \.self) { candidate in
                                Button(candidate) {
                                    state.acceptCandidate(candidate, from: entry)
                                }
                                .font(.system(.caption, design: .monospaced, weight: .semibold))
                                .controlSize(.small)
                            }

                            Button(localization.text("menu.unrecognized.add_rule")) {
                                state.promptToAddRule(for: entry)
                            }
                            .controlSize(.small)
                        }
                    }
                }
                .padding(7)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
            }

            Text(localization.text("menu.unrecognized.privacy"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

struct RulesPanel: View {
    @ObservedObject var state: AppState
    @EnvironmentObject private var localization: LocalizationManager

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(localization.text("menu.rules.keywords"))
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(state.otpKeywords.joined(separator: "  ·  "))
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
            }

            HStack(spacing: 8) {
                Button(localization.text("menu.rules.edit_keywords")) {
                    state.promptToEditKeywords()
                }
                .controlSize(.small)

                Button(localization.text("menu.rules.reset_keywords")) {
                    state.resetKeywords()
                }
                .controlSize(.small)
                .disabled(state.otpKeywords == defaultOTPKeywords)
            }

        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }
}

struct MonitoringPanel: View {
    @ObservedObject var state: AppState
    @EnvironmentObject private var localization: LocalizationManager

    var body: some View {
        if state.recentOTPs.isEmpty {
            VStack(spacing: 4) {
                Text(localization.text("menu.no_codes"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(localization.text(state.statusMessageKey))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
        } else {
            Text(localization.text("menu.recent_codes"))
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
    @EnvironmentObject private var localization: LocalizationManager

    var body: some View {
        VStack(spacing: 8) {
            Text(localization.text("menu.permission.title"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(localization.text("menu.permission.description"))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Button(localization.text("menu.open_system_settings")) {
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
    @EnvironmentObject private var localization: LocalizationManager

    var body: some View {
        Button(action: onCopy) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.code)
                        .font(.system(.title3, design: .monospaced, weight: .semibold))
                    Text("\(localization.text(entry.sourceKey)) · \(entry.timeAgo(using: localization))")
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
