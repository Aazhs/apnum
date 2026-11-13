import ApnumAlarms
import ApnumCalendar
import ApnumCore
import ApnumNotes
import ApnumSky
import ApnumTimers
import SwiftUI

// MARK: - Upcoming items (shared by Today and the menu bar glance)

struct UpcomingItem: Identifiable {
    enum Kind { case alarm, event, timer }

    let id: String
    let kind: Kind
    let date: Date
    let title: String
    let detail: String?
    let color: Color
    let symbol: String
}

extension AppModel {
    /// Alarms, events and timer endings from now until the end of tomorrow, soonest first.
    func upcoming(from now: Date, limit: Int = 8) -> [UpcomingItem] {
        let cal = Calendar.current
        let horizon = cal.date(byAdding: .day, value: 2, to: cal.startOfDay(for: now)) ?? now
        var items: [UpcomingItem] = []

        for alarm in alarmList where alarm.isEnabled {
            guard let date = alarms.nextFireDate(for: alarm, after: now), date < horizon else { continue }
            items.append(UpcomingItem(
                id: "alarm-\(alarm.id)", kind: .alarm, date: date,
                title: alarm.label.isEmpty ? "Alarm" : alarm.label,
                detail: AlarmRepeat.summary(alarm.repeatDays), color: .orange, symbol: "alarm.fill"))
        }
        for event in upcomingEvents where !event.isAllDay && event.end > now && event.start < horizon {
            items.append(UpcomingItem(
                id: "event-\(event.id)", kind: .event, date: max(event.start, now),
                title: event.title, detail: event.location ?? event.calendarTitle,
                color: Color(hex: event.colorHex) ?? .accentColor, symbol: "calendar"))
        }
        for timer in timerList where timer.state == .running {
            guard let end = timer.endsAt else { continue }
            items.append(UpcomingItem(
                id: "timer-\(timer.id)", kind: .timer, date: end,
                title: timer.label.isEmpty ? "Timer" : timer.label,
                detail: "\(TimerFormat.string(timer.duration)) timer", color: .accentColor, symbol: "timer"))
        }
        return Array(items.sorted { $0.date < $1.date }.prefix(limit))
    }

    /// Open reminders due before the end of today, overdue first.
    func remindersDueToday(now: Date) -> [Reminder] {
        let end = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now)) ?? now
        return openReminders
            .filter { ($0.dueDate ?? .distantFuture) < end }
            .sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
    }
}

enum AlarmRepeat {
    static func summary(_ days: Set<Weekday>) -> String {
        let weekdays: Set<Weekday> = [.monday, .tuesday, .wednesday, .thursday, .friday]
        switch days {
        case []: return "Once"
        case Set(Weekday.allCases): return "Every day"
        case weekdays: return "Weekdays"
        case [.saturday, .sunday]: return "Weekends"
        default: return days.sorted { order($0) < order($1) }.map(\.shortName).joined(separator: ", ")
        }
    }

    /// Monday-first ordering for display.
    static func order(_ day: Weekday) -> Int { (day.rawValue + 5) % 7 }
}

// MARK: - Today

struct TodayView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("animatedSky") private var animatedSky = true

    /// Height of the living sky at the top of the page.
    private let heroHeight: CGFloat = 600

    var body: some View {
        TimelineView(.everyMinute) { context in
            let now = context.date
            ScrollView {
                VStack(spacing: 0) {
                    // The hero reads the previewed sky itself, so scrubbing time only re-evaluates it
                    // and not the day's panels below.
                    TodayHero(now: now, animatedSky: animatedSky, height: heroHeight)

                    // The day's details sit on the ground below the scene.
                    VStack(alignment: .leading, spacing: 18) {
                        GlassPanel("Your day", symbol: "sun.horizon") {
                            DayRibbon(now: now)
                                .frame(height: 150)
                        }
                        .frame(height: 220)

                        HStack(alignment: .top, spacing: 18) {
                            comingUp(now)
                            VStack(spacing: 18) {
                                nextAlarm(now)
                                timers
                                dueToday(now)
                            }
                            .frame(width: 320)
                        }

                        notes
                    }
                    .padding(.horizontal, 32)
                    .padding(.top, 22)
                    .padding(.bottom, 32)
                    .frame(maxWidth: 1180)
                    .frame(maxWidth: .infinity)
                    .environment(\.colorScheme, .dark)
                }
            }
            .scrollContentBackground(.hidden)
            .background(TodayGround().ignoresSafeArea())
            .ignoresSafeArea(edges: .top)
        }
        .navigationTitle("Today")
    }

    // MARK: Panels

    private func comingUp(_ now: Date) -> some View {
        let items = model.upcoming(from: now, limit: 6)
        return GlassPanel("Coming up", symbol: "clock") {
            if model.eventAccess != .granted && !model.isDemo {
                Button("Show my calendar") { Task { await model.requestCalendarAccess() } }
                    .buttonStyle(.pill)
            }
        } content: {
            if items.isEmpty {
                Text("Nothing else is scheduled until tomorrow night.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        UpcomingRow(item: item, now: now)
                        if index < items.count - 1 { Divider().padding(.leading, 112) }
                    }
                }
            }
        }
    }

    private func nextAlarm(_ now: Date) -> some View {
        GlassPanel("Next alarm", symbol: "alarm") {
            Button("Alarms") { model.section = .alarms }
                .buttonStyle(.link)
                .focusEffectDisabled()
        } content: {
            if let next = model.nextAlarm {
                VStack(alignment: .leading, spacing: 2) {
                    ClockText(next.date, size: 48, weight: .light)
                    Text(next.alarm.label.isEmpty ? "Alarm" : next.alarm.label)
                        .font(.headline)
                    Text("\(AlarmRepeat.summary(next.alarm.repeatDays)), \(ClockFormat.relative(to: next.date, from: now))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("No alarms are on.")
                    .foregroundStyle(.secondary)
                Button("New alarm") { model.section = .alarms }
                    .buttonStyle(.pill)
            }
        }
    }

    private var timers: some View {
        let active = model.timerList.filter { $0.state != .finished }
        return GlassPanel("Timers", symbol: "timer") {
            Button("All timers") { model.section = .timers }
                .buttonStyle(.link)
                .focusEffectDisabled()
        } content: {
            if active.isEmpty {
                Text("No timers running.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 10) {
                    ForEach(active.prefix(3)) { TodayTimerRow(timer: $0) }
                }
            }
            HStack(spacing: 8) {
                ForEach([5, 10, 25], id: \.self) { minutes in
                    Button("\(minutes) min") {
                        Task { await model.run("timer.start", ["minutes": .number(Double(minutes))]) }
                    }
                    .buttonStyle(.pill)
                }
            }
        }
    }

    private func dueToday(_ now: Date) -> some View {
        let due = model.remindersDueToday(now: now)
        return GlassPanel("Due today", symbol: "checklist") {
            Button("Reminders") { model.section = .reminders }
                .buttonStyle(.link)
                .focusEffectDisabled()
        } content: {
            if model.reminderAccess != .granted && !model.isDemo {
                Text("Allow Reminders access to see what's due.")
                    .foregroundStyle(.secondary)
            } else if due.isEmpty {
                Text("Nothing due. Enjoy it.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(due.prefix(5)) { DueReminderRow(reminder: $0, now: now) }
                }
            }
        }
    }

    private var notes: some View {
        let pinned = model.noteList.filter(\.pinned)
        let shown = Array((pinned.isEmpty ? model.noteList : pinned + model.noteList.filter { !$0.pinned }).prefix(3))
        return GlassPanel("Notes", symbol: "note.text") {
            Button("Notes") { model.section = .notes }
                .buttonStyle(.link)
                .focusEffectDisabled()
        } content: {
            if shown.isEmpty {
                Text("Notes you pin appear here.")
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 24) {
                ForEach(shown) { note in
                    Button {
                        model.focusNoteID = note.id
                        model.section = .notes
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(note.displayTitle).font(.headline).lineLimit(1)
                            Text(note.preview).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct TodayTimerRow: View {
    @Environment(AppModel.self) private var model
    let timer: CountdownTimer

    var body: some View {
        HStack(spacing: 12) {
            TimelineView(.periodic(from: .now, by: timer.state == .running ? 1 : 3600)) { context in
                let remaining = timer.remaining(at: context.date)
                let progress = timer.duration > 0 ? remaining / timer.duration : 0
                HStack(spacing: 12) {
                    ZStack {
                        Circle().stroke(.quaternary, lineWidth: 4)
                        Circle()
                            .trim(from: 0, to: progress)
                            .stroke(timer.state == .running ? Color.orange : .secondary, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 30, height: 30)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(TimerFormat.string(remaining))
                            .font(.clock(24, weight: .regular))
                            .monospacedDigit()
                        Text(timer.label.isEmpty ? "Timer" : timer.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            Button {
                let tool = timer.state == .running ? "timer.pause" : "timer.resume"
                Task { await model.run(tool, ["id": .string(timer.id.uuidString)]) }
            } label: {
                Label(timer.state == .running ? "Pause" : "Resume", systemImage: timer.state == .running ? "pause.fill" : "play.fill")
            }
            .buttonStyle(.circle(timer.state == .running ? .orange : .green, size: 34))
        }
    }
}

private struct UpcomingRow: View {
    let item: UpcomingItem
    let now: Date

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            ClockText(item.date, size: 22, weight: .regular)
                .frame(width: 98, alignment: .leading)
            Image(systemName: item.symbol)
                .font(.callout.weight(.semibold))
                .foregroundStyle(item.color)
                .frame(width: 28, height: 28)
                .background(item.color.opacity(0.14), in: .circle)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.body.weight(.medium)).lineLimit(1)
                if let detail = item.detail {
                    Text(detail).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text(Calendar.current.isDate(item.date, inSameDayAs: now) ? ClockFormat.relative(to: item.date, from: now) : "Tomorrow")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 10)
    }
}

private struct DueReminderRow: View {
    @Environment(AppModel.self) private var model
    let reminder: Reminder
    let now: Date

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button {
                Task { await model.run("reminders.complete", ["id": .string(reminder.id), "completed": true]) }
            } label: {
                Image(systemName: "circle")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Complete \(reminder.title)")
            VStack(alignment: .leading, spacing: 1) {
                Text(reminder.title).lineLimit(2)
                if let due = reminder.dueDate {
                    let overdue = due < now
                    Text(overdue
                        ? "Overdue since \(Calendar.current.isDate(due, inSameDayAs: now) ? ClockFormat.string(due) : due.formatted(.dateTime.weekday(.wide)))"
                        : "Due \(ClockFormat.string(due))")
                        .font(.caption)
                        .foregroundStyle(overdue ? .red : .secondary)
                }
            }
        }
    }
}


// MARK: - Hero

/// Below the scene the page continues in the colour of the ground.
private struct TodayGround: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let p = (model.previewScene ?? model.skyScene)?.palette {
            p.ground.mix(p.near, 0.3).color
        } else {
            Color(nsColor: .windowBackgroundColor)
        }
    }
}

/// The real sky over the pixel landscape, with the clock in it. The only part of Today that follows the
/// time-travel preview, split into small views that each read only what they show, so a scrub tick
/// re-evaluates the scene, the clock and the readout and nothing around them.
private struct TodayHero: View {
    @Environment(AppModel.self) private var model
    let now: Date
    let animatedSky: Bool
    let height: CGFloat

    var body: some View {
        ZStack(alignment: .top) {
            HeroScene(now: now, animated: animatedSky)
            HStack(alignment: .top, spacing: 18) {
                hero
                    .frame(maxWidth: .infinity, alignment: .leading)
                HeroReadout(now: now)
            }
            .padding(.horizontal, 32)
            .padding(.top, 70)
            .frame(maxWidth: 1180)
            .modifier(HeroColorScheme(now: now))
        }
        .frame(height: height)
        .clipped()
    }

    /// Date and a large clock straight on the sky, like a lock screen.
    private var hero: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 0) {
            HeroClock(now: now)
            Text(summary(now))
                .font(.title3.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.top, 2)
                .modifier(HeroHideWhilePreviewing())
            SkyTimeTravel(preview: $model.skyPreview, now: now)
                .frame(maxWidth: 520)
                .padding(.top, 14)
        }
    }

    private func summary(_ now: Date) -> String {
        var parts: [String] = []
        if let next = model.nextAlarm {
            parts.append("Your next alarm rings \(ClockFormat.relative(to: next.date, from: now))")
        } else {
            parts.append("No alarms set")
        }
        let endOfDay = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now)) ?? now
        let left = model.upcomingEvents.filter { !$0.isAllDay && $0.end > now && $0.start < endOfDay }.count
        switch left {
        case 0: parts.append("your calendar is clear for the rest of today")
        case 1: parts.append("1 event is left today")
        default: parts.append("\(left) events are left today")
        }
        return parts.joined(separator: ", and ") + "."
    }
}

private struct HeroScene: View {
    @Environment(AppModel.self) private var model
    let now: Date
    let animated: Bool

    var body: some View {
        if let scene = model.previewScene ?? model.skyScene {
            PixelSkyView(scene: scene, animated: animated)
        } else {
            SkyBackdrop(now: now)
        }
    }
}

private struct HeroClock: View {
    @Environment(AppModel.self) private var model
    let now: Date

    var body: some View {
        let preview = model.skyPreview
        let shown = preview ?? now
        VStack(alignment: .leading, spacing: 0) {
            Text(preview != nil ? "Previewing the sky" : shown.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                .font(.title2.weight(.semibold))
                .foregroundStyle(.secondary)
                .contentTransition(.opacity)
            ClockText(shown, size: 120, weight: .thin)
                .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
                .opacity(preview != nil ? 0.85 : 1)
        }
    }
}

private struct HeroReadout: View {
    @Environment(AppModel.self) private var model
    let now: Date

    var body: some View {
        if let summary = model.previewSummary ?? model.skySummary, let scene = model.previewScene ?? model.skyScene {
            SkyReadout(summary: summary, scene: scene, now: model.skyPreview ?? now)
                .frame(width: 340)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Light or dark text over the sky, following the previewed sky.
private struct HeroColorScheme: ViewModifier {
    @Environment(AppModel.self) private var model
    let now: Date

    func body(content: Content) -> some View {
        let dark = (model.previewScene ?? model.skyScene)?.isDark ?? Sky.isDark(atHour: Sky.hour(of: now))
        content.environment(\.colorScheme, dark ? .dark : .light)
    }
}

/// The "next alarm" line hides while previewing.
private struct HeroHideWhilePreviewing: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content.opacity(model.skyPreview != nil ? 0 : 1)
    }
}

// MARK: - Day ribbon

/// Today from midnight to midnight, painted as the sky, with events, alarms
/// and timers placed on Liquid Glass at their times.
struct DayRibbon: View {
    @Environment(AppModel.self) private var model
    let now: Date
    var compact = false

    private var dayStart: Date { Calendar.current.startOfDay(for: now) }
    private var radius: CGFloat { compact ? 14 : 26 }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width, height = geo.size.height
            let x = { (date: Date) -> CGFloat in
                CGFloat(min(max(date.timeIntervalSince(dayStart) / 86_400, 0), 1)) * width
            }
            ZStack(alignment: .topLeading) {
                if model.skyDayColors.count > 1 {
                    Rectangle().fill(LinearGradient(colors: model.skyDayColors.map(\.color), startPoint: .leading, endPoint: .trailing))
                } else {
                    Rectangle().fill(Sky.day)
                }

                // The part of the day that has passed sits in shadow.
                Rectangle()
                    .fill(.black.opacity(0.26))
                    .frame(width: x(now))

                if !compact {
                    ForEach([3, 6, 9, 12, 15, 18, 21], id: \.self) { hour in
                        let date = dayStart.addingTimeInterval(TimeInterval(hour * 3600))
                        Rectangle()
                            .fill(.white.opacity(0.22))
                            .frame(width: 1, height: 8)
                            .position(x: x(date), y: height - 30)
                        Text(date.formatted(.dateTime.hour()))
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.white.opacity(0.78))
                            .position(x: x(date), y: height - 15)
                    }
                }

                GlassEffectContainer(spacing: 6) {
                    ZStack(alignment: .topLeading) {
                        ForEach(lanes) { placed in
                            eventCapsule(placed, x: x, width: width, height: height)
                        }
                        ForEach(layout(markers, x: x, width: width)) { placed in
                            markerView(placed.marker, iconOnly: placed.iconOnly)
                                .position(x: placed.x, y: compact ? height / 2 : 26)
                        }
                    }
                    .frame(width: width, height: height, alignment: .topLeading)
                }

                // Now
                Capsule()
                    .fill(.white)
                    .frame(width: 2.5, height: height)
                    .shadow(color: .black.opacity(0.35), radius: 3)
                    .position(x: x(now), y: height / 2)
            }
            .clipShape(.rect(cornerRadius: radius))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Timeline of today")
    }

    // MARK: Events in lanes

    private struct PlacedEvent: Identifiable {
        let event: CalendarEvent
        let lane: Int
        var id: String { event.id }
    }

    private var todaysEvents: [CalendarEvent] {
        let end = dayStart.addingTimeInterval(86_400)
        return model.upcomingEvents
            .filter { !$0.isAllDay && $0.start < end && $0.end > dayStart }
            .sorted { $0.start < $1.start }
    }

    /// Greedy lane assignment so overlapping events stack; at most two lanes.
    private var lanes: [PlacedEvent] {
        var laneEnds: [Date] = []
        var placed: [PlacedEvent] = []
        for event in todaysEvents {
            if let lane = laneEnds.firstIndex(where: { $0 <= event.start }) {
                laneEnds[lane] = event.end
                placed.append(PlacedEvent(event: event, lane: lane))
            } else if laneEnds.count < 2 {
                laneEnds.append(event.end)
                placed.append(PlacedEvent(event: event, lane: laneEnds.count - 1))
            }
        }
        return placed
    }

    private func eventCapsule(_ placed: PlacedEvent, x: (Date) -> CGFloat, width: CGFloat, height: CGFloat) -> some View {
        let start = x(placed.event.start), end = x(placed.event.end)
        let w = max(end - start, compact ? 6 : 14)
        let h: CGFloat = compact ? 3 : 28
        let y: CGFloat = compact ? height - 6 - CGFloat(placed.lane) * 5 : 64 + CGFloat(placed.lane) * 36
        let tint = Color(hex: placed.event.colorHex) ?? .accentColor
        let help = "\(placed.event.title), \(ClockFormat.string(placed.event.start)) to \(ClockFormat.string(placed.event.end))"
        return Group {
            if compact {
                Capsule().fill(tint.opacity(0.9))
            } else {
                ZStack(alignment: .leading) {
                    if w >= 64 {
                        Text(placed.event.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                    }
                }
                .frame(width: w, height: h, alignment: .leading)
                .background(tint.opacity(0.78), in: .capsule)
                .glassEffect(.regular, in: .capsule)
                .help(help)
            }
        }
        .frame(width: w, height: h)
        .opacity(placed.event.end < now ? 0.55 : 1)
        .offset(x: start, y: y)
    }

    // MARK: Alarm and timer markers

    private struct Marker: Identifiable {
        let id: String
        let date: Date
        let symbol: String
        let label: String
    }

    private var markers: [Marker] {
        let end = dayStart.addingTimeInterval(86_400)
        var out: [Marker] = []
        for alarm in model.alarmList where alarm.isEnabled {
            guard let date = model.alarms.nextFireDate(for: alarm, after: dayStart), date < end else { continue }
            out.append(Marker(id: "a\(alarm.id)", date: date, symbol: "alarm.fill", label: ClockFormat.string(date)))
        }
        for timer in model.timerList where timer.state == .running {
            guard let date = timer.endsAt, date < end else { continue }
            out.append(Marker(id: "t\(timer.id)", date: date, symbol: "timer", label: timer.label.isEmpty ? "Timer" : timer.label))
        }
        return out
    }

    private struct PlacedMarker: Identifiable {
        let marker: Marker
        var x: CGFloat
        var iconOnly: Bool
        var width: CGFloat
        var id: String { marker.id }
    }

    /// Places markers left to right. A marker that would collide with the one
    /// before it drops its label; if it still collides it shifts right.
    private func layout(_ markers: [Marker], x: (Date) -> CGFloat, width: CGFloat) -> [PlacedMarker] {
        let gap: CGFloat = 6, icon: CGFloat = compact ? 18 : 28
        var placed: [PlacedMarker] = []
        // Left to right: drop the label if it would collide, then shift right if still needed.
        var lastRight: CGFloat = -.infinity
        for marker in markers.sorted(by: { $0.date < $1.date }) {
            let center = x(marker.date)
            let full = compact ? icon : CGFloat(marker.label.count) * 7 + 40
            var w = full, iconOnly = compact
            if center - full / 2 < lastRight + gap { w = icon; iconOnly = true }
            let c = max(max(center, lastRight + gap + w / 2), w / 2 + 6)
            placed.append(PlacedMarker(marker: marker, x: c, iconOnly: iconOnly, width: w))
            lastRight = c + w / 2
        }
        // Right to left: keep everything inside the ribbon, shrinking labels before shifting left.
        var limit = width - 6
        for i in placed.indices.reversed() {
            if placed[i].x + placed[i].width / 2 > limit, !placed[i].iconOnly {
                placed[i].iconOnly = true
                placed[i].width = icon
            }
            placed[i].x = min(placed[i].x, limit - placed[i].width / 2)
            limit = placed[i].x - placed[i].width / 2 - gap
        }
        return placed
    }

    @ViewBuilder
    private func markerView(_ marker: Marker, iconOnly: Bool) -> some View {
        if iconOnly {
            Image(systemName: marker.symbol)
                .font(.system(size: compact ? 9 : 12, weight: .bold))
                .frame(width: compact ? 18 : 28, height: compact ? 18 : 28)
                .glassEffect(.regular, in: .circle)
                .help(marker.label)
        } else {
            Label(marker.label, systemImage: marker.symbol)
                .font(.caption.weight(.semibold))
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 9)
                .frame(height: 28)
                .glassEffect(.regular, in: .capsule)
                .help(marker.label)
        }
    }
}
