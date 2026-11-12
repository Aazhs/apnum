import ApnumAlarms
import ApnumCalendar
import ApnumCore
import AppKit
import ServiceManagement
import SwiftUI
import UserNotifications

/// The standard Settings window: General, Alarms, Permissions and About.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            AlarmSettingsTab()
                .tabItem { Label("Alarms", systemImage: "alarm") }
            PermissionSettings()
                .tabItem { Label("Permissions", systemImage: "hand.raised") }
            AboutSettings()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .scenePadding()
        .frame(width: 520)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage("showInMenuBar") private var showInMenuBar = true
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Show in menu bar", isOn: $showInMenuBar)
            } footer: {
                Text("Shows the next alarm and running timers in the menu bar.")
            }

            Section {
                Toggle("Open at login", isOn: Binding(
                    get: { loginStatus == .enabled || loginStatus == .requiresApproval },
                    set: setLogin))
                if loginStatus == .requiresApproval {
                    Label("Approve apnum in System Settings, under General, Login Items.", systemImage: "exclamationmark.circle")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let loginError {
                    Label(loginError, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.orange)
                }
            } footer: {
                Text("Alarms can only ring while apnum is running.")
            }

            Section {
                LabeledContent("Data folder") {
                    Button("Show data folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([model.paths.root])
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func setLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
        }
        loginStatus = SMAppService.mainApp.status
    }
}

// MARK: - Alarms

private struct AlarmSettingsTab: View {
    @Environment(AppModel.self) private var model
    @State private var syncing = false

    private var mirrorOn: Bool { model.alarmSettings.mirrorToClockApp }

    var body: some View {
        Form {
            Section {
                Toggle("Mirror alarms to the Clock app", isOn: Binding(
                    get: { mirrorOn },
                    set: { value in Task { await model.setAlarmSettings(AlarmSettings(mirrorToClockApp: value)) } }))
            } footer: {
                Text("When on, the Clock app rings your alarms instead of apnum, so they also sound on this Mac while apnum is closed. apnum keeps the two in step using a Shortcut.")
            }

            if mirrorOn {
                Section {
                    LabeledContent("Shortcut") {
                        Text(ClockAppMirror.shortcutName).textSelection(.enabled)
                    }
                    LabeledContent("Status") {
                        HStack {
                            if syncing { ProgressView().controlSize(.small) }
                            Button("Sync now") {
                                syncing = true
                                Task {
                                    await model.run("alarm.mirror.sync")
                                    syncing = false
                                }
                            }
                            .disabled(syncing)
                        }
                    }
                    if let error = model.alarmMirrorError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                } footer: {
                    if let url = URL(string: "https://github.com/Aazhs/apnum/blob/main/docs/clock-shortcuts.md") {
                        Link("How to set up the Shortcut", destination: url)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Permissions

private struct PermissionSettings: View {
    @Environment(AppModel.self) private var model
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined

    var body: some View {
        Form {
            Section {
                LabeledContent("Notifications") {
                    switch notificationStatus {
                    case .authorized, .provisional, .ephemeral:
                        granted
                    case .denied:
                        openSettings("Privacy_Notifications")
                    default:
                        Button("Allow access") {
                            Task {
                                _ = await model.ringer.requestNotificationPermission()
                                await refreshNotifications()
                            }
                        }
                    }
                }
                accessRow("Calendar", model.eventAccess, pane: "Privacy_Calendars")
                accessRow("Reminders", model.reminderAccess, pane: "Privacy_Reminders")
                LabeledContent("Accessibility") {
                    openSettings("Privacy_Accessibility")
                }
            } footer: {
                Text("Notifications show alarms and timers that finish. Calendar and Reminders fill Today and the Calendar and Reminders pages. Accessibility lets apnum send media keys: play and pause, next and previous.")
            }
        }
        .formStyle(.grouped)
        .task { await refreshNotifications() }
    }

    private var granted: some View {
        Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
    }

    private func accessRow(_ title: String, _ state: AccessState, pane: String) -> some View {
        LabeledContent(title) {
            switch state {
            case .granted: granted
            case .denied, .restricted, .writeOnly: openSettings(pane)
            case .notDetermined: Button("Allow access") { Task { await model.requestCalendarAccess() } }
            }
        }
    }

    private func openSettings(_ pane: String) -> some View {
        Button("Open System Settings") {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func refreshNotifications() async {
        guard Bundle.main.bundleIdentifier != nil, Bundle.main.bundleURL.pathExtension == "app" else { return }
        notificationStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
}

// MARK: - About

private struct AboutSettings: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 6) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable()
                        .frame(width: 72, height: 72)
                    Text("apnum").font(.title2.weight(.semibold))
                    Text("Version \(version)").font(.callout).foregroundStyle(.secondary)
                    Text("Alarms, timers, notes, calendar and Mac control in one place, ready for agents and your phone.")
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .padding(.top, 4)
                    Text("MIT licensed").font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            Section {
                if let repo = URL(string: "https://github.com/Aazhs/apnum") {
                    LabeledContent("Source code") { Link("github.com/Aazhs/apnum", destination: repo) }
                }
                if let license = URL(string: "https://github.com/Aazhs/apnum/blob/main/LICENSE") {
                    LabeledContent("License") { Link("MIT License", destination: license) }
                }
            }
        }
        .formStyle(.grouped)
    }
}
