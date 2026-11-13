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
            ThemedRoot { MenuBarGlance() }
                .environment(model)
                .task { await model.start() }
        } label: {
            Image(systemName: model.ringing.isEmpty ? "sun.horizon" : "alarm.waves.left.and.right.fill")
        }
        .menuBarExtraStyle(.window)

        Settings {
            ThemedRoot { SettingsView() }
                .environment(model)
        }
    }
}

// MARK: - Navigation

enum AppSection: String, CaseIterable, Identifiable {
    case today, alarms, stopwatch, timers, calendar, reminders, notes, phone, activity

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: "Today"
        case .alarms: "Alarms"
        case .stopwatch: "Stopwatch"
        case .timers: "Timers"
        case .calendar: "Calendar"
        case .reminders: "Reminders"
        case .notes: "Notes"
        case .phone: "Phone"
        case .activity: "Activity"
        }
    }

    var symbol: String {
        switch self {
        case .today: "sun.horizon"
        case .alarms: "alarm"
        case .stopwatch: "stopwatch"
        case .timers: "timer"
        case .calendar: "calendar"
        case .reminders: "checklist"
        case .notes: "note.text"
        case .phone: "smartphone"
        case .activity: "point.3.connected.trianglepath.dotted"
        }
    }

    /// Sidebar groups, in order.
    static let groups: [(title: String, sections: [AppSection])] = [
        ("Time", [.today, .alarms, .stopwatch, .timers]),
        ("Plan", [.calendar, .reminders]),
        ("Write", [.notes]),
        ("Phone", [.phone]),
        ("Agents", [.activity]),
    ]

    /// ⌘1 … ⌘9
    var shortcut: KeyEquivalent { KeyEquivalent(Character(String((Self.allCases.firstIndex(of: self) ?? 0) + 1))) }
}

struct MainView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("tintWithSky") private var tintWithSky = true

    var body: some View {
        @Bindable var model = model
        let theme = model.theme(enabled: tintWithSky)
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
            .scrollContentBackground(theme.isActive ? .hidden : .automatic)
            .safeAreaInset(edge: .bottom) {
                // The little world is always in view: a still of the scene under the sidebar.
                if theme.isActive, let scene = model.skyScene {
                    PixelSkyView(scene: scene, animated: false, pixelSize: 2)
                        .frame(height: 124)
                        .clipShape(.rect(cornerRadius: 14, style: .continuous))
                        .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(theme.edge, lineWidth: 1) }
                        .padding(10)
                        .help(model.skySummary.map { "\($0.skyName) in \($0.placeName)" } ?? "")
                }
            }
            .background(theme.isActive ? theme.sidebar : Color.clear)
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            detail(for: model.section)
                .skyPage(theme)
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
        .tint(theme.isActive ? theme.accent : nil)
        .environment(\.skyTheme, theme)
        .containerBackground(theme.isActive ? theme.background : Color(nsColor: .windowBackgroundColor), for: .window)
        .preferredColorScheme(theme.isActive ? .dark : nil)
        .animation(.linear(duration: 1.5), value: theme)
    }

    @ViewBuilder
    private func detail(for section: AppSection) -> some View {
        if ProcessInfo.processInfo.environment["APNUM_PREVIEW"] == "glance" {
            // Debug only (scripts/snapshot.sh glance): the menu bar window can't be captured directly.
            MenuBarGlance()
                .background(.background, in: .rect(cornerRadius: 16))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if ProcessInfo.processInfo.environment["APNUM_PREVIEW"] == "sky" {
            PixelSkyView.debugPreview()
        } else {
            sectionView(section)
        }
    }

    @ViewBuilder
    private func sectionView(_ section: AppSection) -> some View {
        switch section {
        case .today: TodayView()
        case .alarms: AlarmsView()
        case .stopwatch: StopwatchView()
        case .timers: TimersView()
        case .calendar: CalendarView()
        case .reminders: RemindersView()
        case .notes: NotesView()
        case .phone: PhoneView()
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
            Button("Dismiss", action: dismiss).buttonStyle(.pill)
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

/// Applies the sky theme to a secondary window (Settings, the menu bar glance).
struct ThemedRoot<Content: View>: View {
    @Environment(AppModel.self) private var model
    @AppStorage("tintWithSky") private var tintWithSky = true
    @ViewBuilder var content: Content

    var body: some View {
        let theme = model.theme(enabled: tintWithSky)
        content
            .skyPage(theme)
            .tint(theme.isActive ? theme.accent : nil)
            .environment(\.skyTheme, theme)
            .preferredColorScheme(theme.isActive ? .dark : nil)
    }
}
