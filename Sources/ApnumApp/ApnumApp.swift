import ApnumCore
import SwiftUI

@main
struct ApnumApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            RootView()
                .environment(model)
                .task { await model.start() }
        } label: {
            Image(systemName: model.ringing.isEmpty ? "bolt.horizontal.circle" : "alarm.waves.left.and.right.fill")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

enum AppSection: String, CaseIterable, Identifiable {
    case alarms, timers, notes, agenda, activity

    var id: String { rawValue }

    var title: String {
        switch self {
        case .alarms: "Alarms"
        case .timers: "Timers"
        case .notes: "Notes"
        case .agenda: "Agenda"
        case .activity: "Activity"
        }
    }

    var symbol: String {
        switch self {
        case .alarms: "alarm"
        case .timers: "timer"
        case .notes: "note.text"
        case .agenda: "calendar"
        case .activity: "list.bullet.rectangle"
        }
    }
}

/// The menu bar window: ringing banner, section picker, the section, and an error line.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("section") private var section: AppSection = .alarms

    var body: some View {
        VStack(spacing: 0) {
            ForEach(model.ringing) { request in
                RingingBanner(request: request)
            }

            Picker("Section", selection: $section) {
                ForEach(AppSection.allCases) { s in
                    Image(systemName: s.symbol).help(s.title).tag(s)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)

            Divider()

            Group {
                switch section {
                case .alarms: AlarmsView()
                case .timers: TimersView()
                case .notes: NotesView()
                case .agenda: AgendaView()
                case .activity: ActivityView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            if let error = model.lastError {
                Divider()
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error).font(.caption).lineLimit(3)
                    Spacer()
                    Button("Dismiss") { model.lastError = nil }
                        .buttonStyle(.borderless).font(.caption)
                }
                .padding(8)
            }

            Divider()
            HStack {
                SettingsLink { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless)
                    .help("Settings")
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.borderless)
                    .keyboardShortcut("q")
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .frame(width: 380, height: 540)
    }
}

/// Shown at the top of the window while an alarm or timer rings.
struct RingingBanner: View {
    @Environment(AppModel.self) private var model
    let request: RingRequest

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: request.kind == .alarm ? "alarm.waves.left.and.right.fill" : "timer")
                .font(.title2)
                .symbolEffect(.pulse)
            VStack(alignment: .leading, spacing: 2) {
                Text(request.title).font(.headline).lineLimit(1)
                Text(request.body).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if request.canSnooze {
                Button("Snooze") { Task { await model.snooze(request) } }
            }
            Button("Stop") { Task { await model.stopRinging(request) } }
                .buttonStyle(.borderedProminent)
        }
        .padding(10)
        .background(.orange.opacity(0.15))
    }
}
