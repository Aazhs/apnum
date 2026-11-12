import ApnumAlarms
import ApnumCalendar
import ApnumCore
import AppKit
import ServiceManagement
import SwiftUI
import UserNotifications

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var loginError: String?
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    @State private var syncing = false

    var body: some View {
        Form {
            alarmsSection
            generalSection
            permissionsSection
            aboutSection
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .task { await refreshNotifications() }
    }

    // MARK: Alarms

    private var alarmsSection: some View {
        Section("Alarms") {
            Toggle("Mirror alarms to the Clock app", isOn: Binding(
                get: { model.alarmSettings.mirrorToClockApp },
                set: { value in Task { await model.setAlarmSettings(AlarmSettings(mirrorToClockApp: value)) } }))
            Text("apnum then stops ringing alarms on this Mac and the Clock app rings them instead. This uses a Shortcut named \"\(ClockAppMirror.shortcutName)\".")
                .font(.caption)
                .foregroundStyle(.secondary)
            if model.alarmSettings.mirrorToClockApp {
                HStack {
                    Text("Shortcut: \(ClockAppMirror.shortcutName)").font(.callout)
                    Spacer()
                    Button("Sync now") {
                        syncing = true
                        Task {
                            await model.run("alarm.mirror.sync")
                            syncing = false
                        }
                    }
                    .disabled(syncing)
                }
                if let error = model.alarmMirrorError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    // MARK: General

    private var generalSection: some View {
        Section("General") {
            Toggle("Open at login", isOn: Binding(
                get: { loginStatus == .enabled || loginStatus == .requiresApproval },
                set: setLogin))
            if loginStatus == .requiresApproval {
                Text("Approve apnum in System Settings > General > Login Items.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let loginError {
                Label(loginError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            LabeledContent("Data folder") {
                Button("Show data folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([model.paths.root])
                }
            }
        }
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

    // MARK: Permissions

    private var permissionsSection: some View {
        Section("Permissions") {
            LabeledContent("Notifications") {
                switch notificationStatus {
                case .authorized, .provisional, .ephemeral:
                    granted
                case .denied:
                    openSettings("Privacy_Notifications", title: "Open System Settings")
                default:
                    Button("Grant") {
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
                openSettings("Privacy_Accessibility", title: "Open System Settings")
            }
            Text("Accessibility access lets apnum send media keys (play/pause, next, previous).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var granted: some View {
        Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
    }

    private func accessRow(_ title: String, _ state: AccessState, pane: String) -> some View {
        LabeledContent(title) {
            switch state {
            case .granted: granted
            case .denied, .restricted, .writeOnly: openSettings(pane, title: "Open System Settings")
            case .notDetermined: Button("Grant") { Task { await model.requestCalendarAccess() } }
            }
        }
    }

    private func openSettings(_ pane: String, title: String) -> some View {
        Button(title) {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func refreshNotifications() async {
        guard Bundle.main.bundleIdentifier != nil, Bundle.main.bundleURL.pathExtension == "app" else { return }
        notificationStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    // MARK: About

    private var aboutSection: some View {
        Section("About") {
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
            LabeledContent("apnum", value: version)
            Text("MIT licensed · open source").foregroundStyle(.secondary)
        }
    }
}
