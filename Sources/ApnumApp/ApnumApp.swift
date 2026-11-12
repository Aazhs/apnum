import ApnumCore
import SwiftUI

@main
struct ApnumApp: App {
    @State private var model = AppModel()
    @AppStorage("showInMenuBar") private var showInMenuBar = true

    var body: some Scene {
        Window("apnum", id: "main") {
            MainView()
                .environment(model)
                .task { await model.start() }
        }
        .defaultSize(width: 1100, height: 740)
        .windowToolbarStyle(.unified)
        .commands { AppCommands(model: model) }

        MenuBarExtra(isInserted: $showInMenuBar) {
            MenuBarGlance()
                .environment(model)
                .task { await model.start() }
        } label: {
            Image(systemName: model.ringing.isEmpty ? "sun.horizon" : "alarm.waves.left.and.right.fill")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

// MARK: - Navigation

enum AppSection: String, CaseIterable, Identifiable {
    case today, alarms, timers, calendar, reminders, notes, activity

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: "Today"
        case .alarms: "Alarms"
        case .timers: "Timers"
        case .calendar: "Calendar"
        case .reminders: "Reminders"
        case .notes: "Notes"
        case .activity: "Activity"
        }
    }

    var symbol: String {
        switch self {
        case .today: "sun.horizon"
        case .alarms: "alarm"
        case .timers: "timer"
        case .calendar: "calendar"
        case .reminders: "checklist"
        case .notes: "note.text"
        case .activity: "point.3.connected.trianglepath.dotted"
        }
    }

    /// Sidebar groups, in order.
    static let groups: [(title: String, sections: [AppSection])] = [
        ("Time", [.today, .alarms, .timers]),
        ("Plan", [.calendar, .reminders]),
        ("Write", [.notes]),
        ("Agents", [.activity]),
    ]

    /// ⌘1 … ⌘7
    var shortcut: KeyEquivalent { KeyEquivalent(Character(String((Self.allCases.firstIndex(of: self) ?? 0) + 1))) }
}

struct MainView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $model.section) {
                ForEach(AppSection.groups, id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.sections) { section in
                            Label(section.title, systemImage: section.symbol)
                                .badge(badge(for: section))
                                .tag(section)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            detail(for: model.section)
                .frame(minWidth: 560, minHeight: 480)
                .overlay(alignment: .top) {
                    VStack(spacing: 8) {
                        ForEach(model.ringing) { RingingBanner(request: $0) }
                    }
                    .frame(maxWidth: 560)
                    .padding(.top, 12)
                    .padding(.horizontal, 20)
                    .animation(.spring(duration: 0.35), value: model.ringing)
                }
                .overlay(alignment: .bottom) {
                    if let error = model.lastError {
                        ErrorToast(message: error) { model.lastError = nil }
                            .padding(.bottom, 16)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.easeOut(duration: 0.2), value: model.lastError)
        }
    }

    @ViewBuilder
    private func detail(for section: AppSection) -> some View {
        if ProcessInfo.processInfo.environment["APNUM_PREVIEW"] == "glance" {
            // Debug only (scripts/snapshot.sh glance): the menu bar window can't be captured directly.
            MenuBarGlance()
                .background(.background, in: .rect(cornerRadius: 16))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            sectionView(section)
        }
    }

    @ViewBuilder
    private func sectionView(_ section: AppSection) -> some View {
        switch section {
        case .today: TodayView()
        case .alarms: AlarmsView()
        case .timers: TimersView()
        case .calendar: CalendarView()
        case .reminders: RemindersView()
        case .notes: NotesView()
        case .activity: ActivityView()
        }
    }

    private func badge(for section: AppSection) -> Int {
        switch section {
        case .timers: model.timerList.filter { $0.state == .running || $0.state == .ringing }.count
        case .reminders: model.openReminders.filter { ($0.dueDate ?? .distantFuture) < Calendar.current.startOfDay(for: .now).addingTimeInterval(86_400) }.count
        default: 0
        }
    }
}

/// A dismissible error line on glass at the bottom of the window.
struct ErrorToast: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text(message).font(.callout).lineLimit(3)
            Button("Dismiss", action: dismiss).buttonStyle(.glass).controlSize(.small)
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
        .frame(maxWidth: 560)
    }
}

struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandMenu("Go") {
            ForEach(AppSection.allCases) { section in
                Button(section.title) { model.section = section }
                    .keyboardShortcut(section.shortcut, modifiers: .command)
            }
        }
    }
}
