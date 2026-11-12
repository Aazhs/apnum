import ApnumAlarms
import ApnumCalendar
import ApnumCore
import ApnumNotes
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

    var body: some View {
        ScrollView {
            TimelineView(.everyMinute) { context in
                let now = context.date
                VStack(alignment: .leading, spacing: 30) {
                    header(now)
                    DayRibbon(now: now)
                        .frame(height: 172)
                    HStack(alignment: .top, spacing: 40) {
                        comingUp(now)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        VStack(alignment: .leading, spacing: 32) {
                            dueToday(now)
                            notes
                        }
                        .frame(width: 300, alignment: .leading)
                    }
                }
                .padding(.horizontal, 36)
                .padding(.top, 20)
                .padding(.bottom, 36)
                .frame(maxWidth: 1100, alignment: .leading)
            }
        }
        .navigationTitle("Today")
    }

    // MARK: Header

    private func header(_ now: Date) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(now.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                .font(.title2.weight(.medium))
                .foregroundStyle(.secondary)
            ClockText(now, size: 88, weight: .thin)
            Text(summary(now))
                .font(.title3)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
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

    // MARK: Coming up

    private func comingUp(_ now: Date) -> some View {
        let items = model.upcoming(from: now)
        return VStack(alignment: .leading, spacing: 14) {
            PageHeading("Coming up")
            if items.isEmpty {
                Text("Nothing else is scheduled until tomorrow night.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        UpcomingRow(item: item, now: now)
                        if index < items.count - 1 { Divider().padding(.leading, 112) }
                    }
                }
            }
            if model.eventAccess != .granted && !model.isDemo {
                Button {
                    Task { await model.requestCalendarAccess() }
                } label: {
                    Label("Show my calendar here", systemImage: "calendar.badge.plus")
                }
                .buttonStyle(.glass)
                .padding(.top, 4)
            }
        }
    }

    // MARK: Side column

    private func dueToday(_ now: Date) -> some View {
        let due = model.remindersDueToday(now: now)
        return VStack(alignment: .leading, spacing: 12) {
            PageHeading("Due today") {
                if !due.isEmpty {
                    Button("All reminders") { model.section = .reminders }
                        .buttonStyle(.link)
                        .font(.callout)
                }
            }
            if model.reminderAccess != .granted && !model.isDemo {
                Text("Allow Reminders access to see what's due.")
                    .font(.callout).foregroundStyle(.secondary)
            } else if due.isEmpty {
                Text("Nothing due. Enjoy it.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(due.prefix(5)) { reminder in
                    DueReminderRow(reminder: reminder, now: now)
                }
            }
        }
    }

    private var notes: some View {
        let pinned = model.noteList.filter(\.pinned)
        let shown = Array((pinned.isEmpty ? model.noteList : pinned).prefix(3))
        return VStack(alignment: .leading, spacing: 12) {
            PageHeading(pinned.isEmpty ? "Recent notes" : "Pinned notes")
            if shown.isEmpty {
                Button {
                    model.section = .notes
                } label: {
                    Label("Write a note", systemImage: "square.and.pencil")
                }
                .buttonStyle(.glass)
            }
            ForEach(shown) { note in
                Button {
                    model.focusNoteID = note.id
                    model.section = .notes
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(note.displayTitle).font(.headline).lineLimit(1)
                        Text(note.preview).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
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
                    Text(overdue ? "Overdue since \(due.formatted(.dateTime.weekday().hour().minute()))" : "Due \(ClockFormat.string(due))")
                        .font(.caption)
                        .foregroundStyle(overdue ? .red : .secondary)
                }
            }
        }
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
                Rectangle().fill(Sky.day)

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
                            eventCapsule(placed, x: x, width: width)
                        }
                        ForEach(markers) { marker in
                            markerView(marker)
                                .position(x: min(max(x(marker.date), 18), width - 18), y: compact ? height / 2 : 26)
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

    private func eventCapsule(_ placed: PlacedEvent, x: (Date) -> CGFloat, width: CGFloat) -> some View {
        let start = x(placed.event.start), end = x(placed.event.end)
        let w = max(end - start, compact ? 6 : 30)
        let h: CGFloat = compact ? 8 : 30
        let y: CGFloat = compact ? 6 + CGFloat(placed.lane) * 10 : 62 + CGFloat(placed.lane) * 38
        let tint = Color(hex: placed.event.colorHex) ?? .accentColor
        return Group {
            if compact {
                Capsule().fill(tint.opacity(0.9))
            } else {
                Text(placed.event.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .frame(width: w, height: h, alignment: .leading)
                    .glassEffect(.regular.tint(tint.opacity(0.55)), in: .capsule)
                    .help("\(placed.event.title), \(ClockFormat.string(placed.event.start)) to \(ClockFormat.string(placed.event.end))")
            }
        }
        .frame(width: w, height: h)
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

    @ViewBuilder
    private func markerView(_ marker: Marker) -> some View {
        if compact {
            Image(systemName: marker.symbol)
                .font(.system(size: 9, weight: .bold))
                .frame(width: 18, height: 18)
                .glassEffect(.regular, in: .circle)
        } else {
            Label(marker.label, systemImage: marker.symbol)
                .font(.caption.weight(.semibold))
                .labelStyle(.titleAndIcon)
                .padding(.horizontal, 9)
                .frame(height: 26)
                .glassEffect(.regular, in: .capsule)
                .help(marker.label)
        }
    }
}
