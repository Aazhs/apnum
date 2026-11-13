import ApnumCalendar
import ApnumCore
import SwiftUI

// Calendar, modelled on macOS Calendar: Day, Week and Month views, Today, back and forward.

private enum CalMode: String, CaseIterable, Identifiable {
    case day, week, month
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

private struct CalFetchKey: Hashable {
    var from: Date
    var to: Date
    var revision: Int
}

private struct CalNewEvent: Identifiable {
    let id = UUID()
    var start: Date
    var allDay: Bool
}

private let calHourHeight: CGFloat = 52
private let calGutter: CGFloat = 56

private extension Calendar {
    func calStartOfWeek(_ date: Date) -> Date {
        dateInterval(of: .weekOfYear, for: date)?.start ?? startOfDay(for: date)
    }
}

private func calKey(_ event: CalendarEvent, _ day: Date) -> String {
    "\(event.id)|\(event.start.timeIntervalSince1970)|\(day.timeIntervalSince1970)"
}

private func calTint(_ event: CalendarEvent) -> Color { Color(hex: event.colorHex) ?? .accentColor }

private func calTimeRange(_ start: Date, _ end: Date) -> String {
    let (a, am) = ClockFormat.parts(start)
    let (b, bm) = ClockFormat.parts(end)
    if let am, let bm, am == bm { return "\(a) – \(b) \(bm)" }
    if let am, let bm { return "\(a) \(am) – \(b) \(bm)" }
    return "\(a) – \(b)"
}

// MARK: - Screen

struct CalendarView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("calendarMode") private var modeRaw = CalMode.week.rawValue
    @State private var anchor = Date.now
    @State private var events: [CalendarEvent] = []
    @State private var slowLoading = false
    @State private var selected: CalendarEvent?
    @State private var popoverKey: String?
    @State private var newEvent: CalNewEvent?
    @State private var daylight = CalDaylightStore()

    private var cal: Calendar { .current }
    private var mode: CalMode { CalMode(rawValue: modeRaw) ?? .week }
    private var hasAccess: Bool { model.eventAccess == .granted || model.isDemo }

    /// The days the time grid shows, or the 42 days of the month grid.
    private var days: [Date] {
        switch mode {
        case .day: return [cal.startOfDay(for: anchor)]
        case .week:
            let start = cal.calStartOfWeek(anchor)
            return (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
        case .month:
            let first = cal.dateInterval(of: .month, for: anchor)?.start ?? anchor
            let start = cal.calStartOfWeek(first)
            return (0..<42).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
        }
    }

    private var fetchKey: CalFetchKey {
        let d = days
        let from = cal.date(byAdding: .day, value: -1, to: d.first ?? anchor) ?? anchor
        let to = cal.date(byAdding: .day, value: 2, to: d.last ?? anchor) ?? anchor
        return CalFetchKey(from: from, to: to, revision: model.calendarRevision)
    }

    private var title: String {
        switch mode {
        case .month: return anchor.formatted(.dateTime.month(.wide).year())
        case .day: return anchor.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
        case .week:
            guard let first = days.first, let last = days.last else { return "" }
            let sameMonth = cal.isDate(first, equalTo: last, toGranularity: .month)
            let sameYear = cal.isDate(first, equalTo: last, toGranularity: .year)
            if sameMonth {
                return "\(first.formatted(.dateTime.day())) – \(last.formatted(.dateTime.day().month(.wide).year()))"
            }
            if sameYear {
                return "\(first.formatted(.dateTime.day().month(.abbreviated))) – \(last.formatted(.dateTime.day().month(.abbreviated).year()))"
            }
            return "\(first.formatted(.dateTime.day().month(.abbreviated).year())) – \(last.formatted(.dateTime.day().month(.abbreviated).year()))"
        }
    }

    var body: some View {
        Group {
            if !hasAccess {
                CalAccessUnavailable()
            } else {
                content
                    .overlay(alignment: .topTrailing) {
                        if slowLoading { ProgressView().controlSize(.small).padding(10) }
                    }
            }
        }
        .navigationTitle(title)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $modeRaw) {
                    ForEach(CalMode.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 210)
                .disabled(!hasAccess)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { step(-1) } label: { Label("Previous", systemImage: "chevron.left") }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                    .help("Previous")
                Button("Today") { withAnimation(.smooth(duration: 0.2)) { anchor = .now } }
                Button { step(1) } label: { Label("Next", systemImage: "chevron.right") }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                    .help("Next")
                Button("New event", systemImage: "plus") { newEvent = CalNewEvent(start: defaultStart(), allDay: false) }
                    .keyboardShortcut("n", modifiers: .command)
            }
        }
        .disabled(false)
        .sheet(item: $newEvent) { request in CalNewEventSheet(start: request.start, allDay: request.allDay) }
        .task(id: fetchKey) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        let _ = { if daylight.location != model.skySettings?.location { daylight.location = model.skySettings?.location } }()
        switch mode {
        case .month:
            CalMonthGrid(
                days: days, month: anchor, events: events, selectedDay: cal.startOfDay(for: anchor),
                selected: $selected, popoverKey: $popoverKey,
                pickDay: { anchor = $0 }, daylight: daylight,
                openDay: { day in anchor = day; modeRaw = CalMode.day.rawValue })
        case .week, .day:
            CalTimeView(
                days: days, events: events, isDay: mode == .day, daylight: daylight, selected: $selected, popoverKey: $popoverKey,
                openDay: { day in anchor = day; modeRaw = CalMode.day.rawValue },
                newEvent: { start, allDay in newEvent = CalNewEvent(start: start, allDay: allDay) })
        }
    }

    private func defaultStart() -> Date {
        let base = cal.isDate(anchor, inSameDayAs: .now) ? Date.now : (cal.date(bySettingHour: 9, minute: 0, second: 0, of: anchor) ?? anchor)
        return cal.dateInterval(of: .hour, for: base)?.end ?? base
    }

    private func step(_ direction: Int) {
        let component: Calendar.Component = switch mode {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        }
        withAnimation(.smooth(duration: 0.2)) {
            anchor = cal.date(byAdding: component, value: direction, to: anchor) ?? anchor
        }
    }

    private func load() async {
        guard hasAccess else { return }
        let key = fetchKey
        let spinner = Task {
            try? await Task.sleep(for: .milliseconds(300))
            if !Task.isCancelled { slowLoading = true }
        }
        defer { spinner.cancel(); slowLoading = false }
        if let result = try? await model.calendar.events(from: key.from, to: key.to, calendarIDs: nil) {
            guard !Task.isCancelled else { return }
            events = result
            if let current = selected, !result.contains(current) { selected = nil; popoverKey = nil }
        }
    }
}

// MARK: - Week and Day

/// Header, all-day row and scrolling time grid for one or seven days.
private struct CalTimeView: View {
    let days: [Date]
    let events: [CalendarEvent]
    let isDay: Bool
    let daylight: CalDaylightStore
    @Binding var selected: CalendarEvent?
    @Binding var popoverKey: String?
    let openDay: (Date) -> Void
    let newEvent: (Date, Bool) -> Void
    @Environment(\.skyTheme) private var theme

    private var cal: Calendar { .current }

    var body: some View {
        GeometryReader { proxy in
            let showPane = isDay && proxy.size.width >= 900
            let paneWidth: CGFloat = showPane ? 300 : 0
            let gridWidth = proxy.size.width - paneWidth
            HStack(spacing: 0) {
                grid(width: gridWidth, usePopover: !showPane)
                if showPane {
                    Rectangle().fill(theme.edge).frame(width: 1)
                    CalDetailPane(event: selected)
                        .frame(width: paneWidth - 1)
                        .background(theme.isActive ? theme.panel : .clear)
                }
            }
        }
    }

    private func grid(width: CGFloat, usePopover: Bool) -> some View {
        let colW = max(40, (width - calGutter) / CGFloat(days.count))
        let perDay = days.map { eventsOn($0) }
        let allDay = perDay.map { $0.filter(\.isAllDay) }
        return VStack(spacing: 0) {
            CalDayHeader(days: days, colW: colW, openDay: openDay)
            CalAllDayRow(
                days: days, colW: colW, perDay: allDay, selected: $selected, popoverKey: $popoverKey,
                usePopover: usePopover, newEvent: newEvent)
            Rectangle().fill(theme.edge).frame(height: 1)
            CalHourGrid(
                days: days, colW: colW, daylight: daylight, perDay: perDay.map { $0.filter { !$0.isAllDay } },
                selected: $selected, popoverKey: $popoverKey, usePopover: usePopover, newEvent: newEvent)
        }
    }

    private func eventsOn(_ day: Date) -> [CalendarEvent] {
        let end = cal.date(byAdding: .day, value: 1, to: day) ?? day
        return events.filter { $0.start < end && $0.end > day || ($0.start == $0.end && $0.start >= day && $0.start < end) }
            .sorted { ($0.start, $0.title) < ($1.start, $1.title) }
    }
}

private struct CalDayHeader: View {
    @Environment(\.skyTheme) private var theme
    let days: [Date]
    let colW: CGFloat
    let openDay: (Date) -> Void

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: calGutter, height: 44)
            ForEach(days, id: \.self) { day in
                let isToday = Calendar.current.isDateInToday(day)
                HStack(spacing: 5) {
                    Text(day.formatted(.dateTime.weekday(.abbreviated)))
                        .font(.callout)
                        .foregroundStyle(isToday ? Color.red : .secondary)
                    Text(day.formatted(.dateTime.day()))
                        .font(.title3.weight(isToday ? .semibold : .regular))
                        .monospacedDigit()
                        .foregroundStyle(isToday ? Color.white : .primary)
                        .frame(minWidth: 28, minHeight: 28)
                        .background(isToday ? Color.red : .clear, in: .circle)
                }
                .frame(width: colW, height: 44)
                .background(Calendar.current.isDateInWeekend(day) ? Color.primary.opacity(0.03) : .clear)
                .contentShape(.rect)
                .onTapGesture(count: 2) { openDay(day) }
                .accessibilityLabel(day.formatted(.dateTime.weekday(.wide).day().month(.wide)))
            }
        }
        .frame(height: 44)
        .background(theme.isActive ? theme.panel : .clear)
    }
}

private struct CalAllDayRow: View {
    @Environment(\.skyTheme) private var theme
    let days: [Date]
    let colW: CGFloat
    let perDay: [[CalendarEvent]]
    @Binding var selected: CalendarEvent?
    @Binding var popoverKey: String?
    let usePopover: Bool
    let newEvent: (Date, Bool) -> Void

    var body: some View {
        let rows = min(3, max(1, perDay.map(\.count).max() ?? 0))
        let height = CGFloat(rows) * 22 + 6
        HStack(spacing: 0) {
            Text("all-day")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: calGutter - 8, alignment: .trailing)
                .padding(.trailing, 8)
                .frame(height: height, alignment: .top)
                .padding(.top, 5)
            ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                let items = perDay[index]
                let shown = items.count > rows ? Array(items.prefix(rows - 1)) : items
                VStack(spacing: 2) {
                    ForEach(shown) { event in
                        CalAllDayChip(event: event, day: day, selected: $selected, popoverKey: $popoverKey, usePopover: usePopover)
                    }
                    if items.count > shown.count {
                        Text("\(items.count - shown.count) more")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 6)
                            .frame(height: 20)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 2)
                .padding(.top, 3)
                .frame(width: colW, height: height, alignment: .top)
                .background(Calendar.current.isDateInWeekend(day) ? Color.primary.opacity(0.03) : .clear)
                .overlay(alignment: .leading) { Rectangle().fill(theme.edge).frame(width: 1) }
                .contentShape(.rect)
                .onTapGesture(count: 2) { newEvent(day, true) }
            }
        }
        .frame(height: height)
        .background(theme.isActive ? theme.panel : .clear)
    }
}

private struct CalAllDayChip: View {
    @Environment(\.colorScheme) private var scheme
    let event: CalendarEvent
    let day: Date
    @Binding var selected: CalendarEvent?
    @Binding var popoverKey: String?
    let usePopover: Bool

    var body: some View {
        let tint = calTint(event)
        let isSelected = selected == event
        Text(event.title)
            .font(.callout.weight(.medium))
            .lineLimit(1)
            .foregroundStyle(isSelected ? Color.white : tint.mix(with: scheme == .dark ? .white : .black, by: scheme == .dark ? 0.3 : 0.3))
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 20)
            .background(isSelected ? tint : tint.opacity(scheme == .dark ? 0.3 : 0.2), in: .rect(cornerRadius: 5))
            .contentShape(.rect)
            .onTapGesture {
                selected = event
                popoverKey = usePopover ? calKey(event, day) : nil
            }
            .calEventPopover(event: event, key: calKey(event, day), popoverKey: $popoverKey, selected: $selected)
    }
}

/// Hour labels, grid lines and event blocks, in a vertical scroll view.
private struct CalHourGrid: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.skyTheme) private var theme
    let days: [Date]
    let colW: CGFloat
    let daylight: CalDaylightStore
    let perDay: [[CalendarEvent]]
    @Binding var selected: CalendarEvent?
    @Binding var popoverKey: String?
    let usePopover: Bool
    let newEvent: (Date, Bool) -> Void

    private var cal: Calendar { .current }
    private var totalHeight: CGFloat { calHourHeight * 24 }

    var body: some View {
        ScrollViewReader { scroll in
            ScrollView(.vertical) {
                ZStack(alignment: .topLeading) {
                    // Scroll anchors, one per hour.
                    VStack(spacing: 0) {
                        ForEach(0..<24, id: \.self) { hour in
                            Color.clear.frame(height: calHourHeight).id(hour)
                        }
                    }
                    CalDaylightShade(days: days, colW: colW, hourHeight: calHourHeight, gutter: calGutter, store: daylight)
                    CalGridLines(colW: colW, weekend: days.map { cal.isDateInWeekend($0) }, edge: theme.edge)
                        .frame(width: calGutter + colW * CGFloat(days.count), height: totalHeight)
                        .contentShape(.rect)
                        .gesture(SpatialTapGesture(count: 2).onEnded { tap in addEvent(at: tap.location) })
                        .simultaneousGesture(SpatialTapGesture().onEnded { _ in selected = nil; popoverKey = nil })
                    hourLabels
                    ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                        let blocks = CalColumnLayout.place(perDay[index], day: day, calendar: cal)
                        ForEach(blocks) { block in
                            CalEventBlock(
                                event: block.event, day: day, height: block.height,
                                selected: $selected, popoverKey: $popoverKey, usePopover: usePopover)
                                .frame(width: block.width(in: colW), height: block.height)
                                .offset(x: calGutter + colW * CGFloat(index) + block.x(in: colW), y: block.y)
                        }
                    }
                    nowLine
                }
                .frame(width: calGutter + colW * CGFloat(days.count), height: totalHeight, alignment: .topLeading)
            }
            .scrollIndicators(.automatic)
            .onAppear { scrollToNow(scroll) }
        }
    }

    private var hourLabels: some View {
        ZStack(alignment: .topTrailing) {
            ForEach(1..<24, id: \.self) { hour in
                let date = cal.date(bySettingHour: hour, minute: 0, second: 0, of: .now) ?? .now
                Text(date.formatted(.dateTime.hour()))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: calGutter - 10, alignment: .trailing)
                    .offset(x: 0, y: CGFloat(hour) * calHourHeight - 7)
            }
        }
        .frame(width: calGutter, height: totalHeight, alignment: .topLeading)
    }

    private var nowLine: some View {
        TimelineView(.everyMinute) { context in
            let now = context.date
            if let index = days.firstIndex(where: { cal.isDate($0, inSameDayAs: now) }) {
                let y = CGFloat(now.timeIntervalSince(cal.startOfDay(for: now)) / 3600) * calHourHeight
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(Color.red).frame(width: colW, height: 1.5)
                        .offset(x: calGutter + colW * CGFloat(index), y: y - 0.75)
                    Circle().fill(Color.red).frame(width: 9, height: 9)
                        .offset(x: calGutter + colW * CGFloat(index) - 4.5, y: y - 4.5)
                    Text(ClockFormat.string(now))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.red)
                        .frame(width: calGutter - 10, alignment: .trailing)
                        .padding(.vertical, 1)
                        .background(theme.isActive ? theme.background : Color(nsColor: .windowBackgroundColor))
                        .offset(x: 0, y: y - 8)
                }
                .allowsHitTesting(false)
            }
        }
        .frame(width: calGutter + colW * CGFloat(days.count), height: totalHeight, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private func addEvent(at point: CGPoint) {
        let index = Int((point.x - calGutter) / colW)
        guard days.indices.contains(index), point.x >= calGutter else { return }
        let minutes = Int((point.y / calHourHeight * 60 / 15).rounded(.down)) * 15
        let start = cal.date(byAdding: .minute, value: min(minutes, 23 * 60 + 45), to: days[index]) ?? days[index]
        newEvent(start, false)
    }

    private func scrollToNow(_ scroll: ScrollViewProxy) {
        let hasToday = days.contains { cal.isDateInToday($0) }
        let hour = hasToday ? max(0, cal.component(.hour, from: .now) - 1) : 8
        scroll.scrollTo(hour, anchor: .top)
    }
}

private struct CalGridLines: View {
    let colW: CGFloat
    let weekend: [Bool]
    let edge: Color

    var body: some View {
        Canvas { context, size in
            let count = CGFloat(weekend.count)
            for (i, isWeekend) in weekend.enumerated() where isWeekend {
                let rect = CGRect(x: calGutter + colW * CGFloat(i), y: 0, width: colW, height: size.height)
                context.fill(Path(rect), with: .color(Color.primary.opacity(0.03)))
            }
            var hours = Path(), halves = Path()
            for h in 0...24 {
                let y = (CGFloat(h) * calHourHeight).rounded() + 0.5
                if h > 0 { hours.move(to: CGPoint(x: calGutter - 4, y: y)); hours.addLine(to: CGPoint(x: calGutter + colW * count, y: y)) }
                if h < 24 {
                    let hy = y + calHourHeight / 2
                    halves.move(to: CGPoint(x: calGutter, y: hy)); halves.addLine(to: CGPoint(x: calGutter + colW * count, y: hy))
                }
            }
            var verticals = Path()
            for i in 0...weekend.count {
                let x = (calGutter + colW * CGFloat(i)).rounded() + 0.5
                verticals.move(to: CGPoint(x: x, y: 0)); verticals.addLine(to: CGPoint(x: x, y: size.height))
            }
            context.stroke(halves, with: .color(edge.opacity(0.45)), lineWidth: 0.5)
            context.stroke(hours, with: .color(edge), lineWidth: 0.5)
            context.stroke(verticals, with: .color(edge), lineWidth: 0.5)
        }
    }
}

/// Where each timed event sits in a day column; overlapping events share the width.
private struct CalPlaced: Identifiable {
    let event: CalendarEvent
    let y: CGFloat
    let height: CGFloat
    let column: Int
    let columns: Int
    var id: String { "\(event.id)|\(event.start.timeIntervalSince1970)" }

    func width(in colW: CGFloat) -> CGFloat { max(8, (colW - 4) / CGFloat(columns) - 1.5) }
    func x(in colW: CGFloat) -> CGFloat { 2 + CGFloat(column) * (colW - 4) / CGFloat(columns) }
}

private enum CalColumnLayout {
    static func place(_ events: [CalendarEvent], day: Date, calendar cal: Calendar) -> [CalPlaced] {
        let next = cal.date(byAdding: .day, value: 1, to: day) ?? day
        struct Item { var event: CalendarEvent; var start: Date; var end: Date; var column = 0 }
        var items = events.map { e -> Item in
            let s = max(e.start, day), en = min(e.end, next)
            // Show at least ~22 pt so short events stay clickable.
            return Item(event: e, start: s, end: max(en, s.addingTimeInterval(22 / Double(calHourHeight) * 3600)))
        }
        items.sort { ($0.start, $0.end) < ($1.start, $1.end) }

        var result: [CalPlaced] = []
        var group: [Item] = []
        var groupEnd = Date.distantPast
        func flush() {
            guard !group.isEmpty else { return }
            var columnEnds: [Date] = []
            for i in group.indices {
                if let free = columnEnds.firstIndex(where: { $0 <= group[i].start }) {
                    group[i].column = free; columnEnds[free] = group[i].end
                } else {
                    group[i].column = columnEnds.count; columnEnds.append(group[i].end)
                }
            }
            for item in group {
                let y = CGFloat(item.start.timeIntervalSince(day) / 3600) * calHourHeight
                let h = CGFloat(item.end.timeIntervalSince(item.start) / 3600) * calHourHeight
                result.append(CalPlaced(event: item.event, y: y + 1, height: max(22, h - 2), column: item.column, columns: columnEnds.count))
            }
            group = []
        }
        for item in items {
            if item.start >= groupEnd { flush(); groupEnd = item.end } else { groupEnd = max(groupEnd, item.end) }
            group.append(item)
        }
        flush()
        return result
    }
}

private struct CalEventBlock: View {
    @Environment(\.colorScheme) private var scheme
    let event: CalendarEvent
    let day: Date
    let height: CGFloat
    @Binding var selected: CalendarEvent?
    @Binding var popoverKey: String?
    let usePopover: Bool

    var body: some View {
        let tint = calTint(event)
        let isSelected = selected == event
        let dark = scheme == .dark
        let text = isSelected ? Color.white : tint.mix(with: dark ? .white : .black, by: 0.3)
        VStack(alignment: .leading, spacing: 1) {
            Text(event.title).font(.callout.weight(.semibold)).lineLimit(height >= 52 ? 2 : 1)
            if height >= 40 {
                Text(calTimeRange(event.start, event.end)).font(.caption).lineLimit(1).opacity(0.85)
            }
        }
        .foregroundStyle(text)
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .padding(.top, 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(isSelected ? tint : tint.opacity(dark ? 0.32 : 0.18))
        .overlay(alignment: .leading) { Rectangle().fill(tint).frame(width: 3) }
        .clipShape(.rect(cornerRadius: 5))
        .contentShape(.rect(cornerRadius: 5))
        .onTapGesture {
            selected = event
            popoverKey = usePopover ? calKey(event, day) : nil
        }
        .calEventPopover(event: event, key: calKey(event, day), popoverKey: $popoverKey, selected: $selected)
    }
}

// MARK: - Month

private struct CalMonthGrid: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.skyTheme) private var theme
    let days: [Date]
    let month: Date
    let events: [CalendarEvent]
    let selectedDay: Date
    @Binding var selected: CalendarEvent?
    @Binding var popoverKey: String?
    let pickDay: (Date) -> Void
    let daylight: CalDaylightStore
    let openDay: (Date) -> Void

    private var cal: Calendar { .current }

    private var weekdayNames: [String] {
        let symbols = cal.shortWeekdaySymbols
        let first = cal.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    var body: some View {
        GeometryReader { proxy in
            let cellW = proxy.size.width / 7
            let headerH: CGFloat = 26
            let cellH = max(60, (proxy.size.height - headerH) / 6)
            let byDay = bucket()
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(weekdayNames, id: \.self) { name in
                        Text(name).font(.callout).foregroundStyle(.secondary)
                            .padding(.trailing, 9)
                            .frame(width: cellW, height: headerH, alignment: .trailing)
                    }
                }
                .background(theme.isActive ? theme.panel : .clear)
                ZStack(alignment: .topLeading) {
                    VStack(spacing: 0) {
                        ForEach(0..<6, id: \.self) { row in
                            HStack(spacing: 0) {
                                ForEach(0..<7, id: \.self) { col in
                                    let day = days[row * 7 + col]
                                    CalMonthCell(
                                        day: day, inMonth: cal.isDate(day, equalTo: month, toGranularity: .month),
                                        isSelected: cal.isDate(day, inSameDayAs: selectedDay),
                                        events: byDay[cal.startOfDay(for: day)] ?? [], lines: max(1, Int((cellH - 30) / 17)),
                                        daylightText: cal.isDateInToday(day) || cal.isDate(day, inSameDayAs: selectedDay) ? daylight.lengthText(day) : nil,
                                        selected: $selected, popoverKey: $popoverKey)
                                        .frame(width: cellW, height: cellH)
                                        .contentShape(.rect)
                                        .onTapGesture(count: 2) { openDay(day) }
                                        .onTapGesture { pickDay(day); selected = nil; popoverKey = nil }
                                }
                            }
                        }
                    }
                    Canvas { context, size in
                        var path = Path()
                        for r in 0...6 {
                            let y = (CGFloat(r) * cellH).rounded() + 0.5
                            path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y))
                        }
                        for c in 0...7 {
                            let x = (CGFloat(c) * cellW).rounded() + 0.5
                            path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height))
                        }
                        context.stroke(path, with: .color(theme.edge), lineWidth: 0.5)
                    }
                    .frame(width: proxy.size.width, height: cellH * 6)
                    .allowsHitTesting(false)
                }
            }
        }
    }

    private func bucket() -> [Date: [CalendarEvent]] {
        var result: [Date: [CalendarEvent]] = [:]
        for day in days {
            let start = cal.startOfDay(for: day)
            let end = cal.date(byAdding: .day, value: 1, to: start) ?? start
            let list = events.filter { $0.start < end && $0.end > start || ($0.start == $0.end && $0.start >= start && $0.start < end) }
                .sorted { ($0.isAllDay ? 0 : 1, $0.start, $0.title) < ($1.isAllDay ? 0 : 1, $1.start, $1.title) }
            if !list.isEmpty { result[start] = list }
        }
        return result
    }
}

private struct CalMonthCell: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.skyTheme) private var theme
    let day: Date
    let inMonth: Bool
    let isSelected: Bool
    let events: [CalendarEvent]
    let lines: Int
    let daylightText: String?
    @Binding var selected: CalendarEvent?
    @Binding var popoverKey: String?

    var body: some View {
        let cal = Calendar.current
        let isToday = cal.isDateInToday(day)
        let shown = events.count > lines ? Array(events.prefix(max(0, lines - 1))) : events
        VStack(spacing: 2) {
            HStack {
                Spacer()
                Text(cal.component(.day, from: day) == 1
                    ? day.formatted(.dateTime.day().month(.abbreviated))
                    : day.formatted(.dateTime.day()))
                    .font(.callout.weight(isToday ? .semibold : .regular))
                    .monospacedDigit()
                    .foregroundStyle(isToday ? Color.white : (inMonth ? Color.primary : Color.secondary.opacity(0.7)))
                    .padding(.horizontal, 6)
                    .frame(minWidth: 24, minHeight: 22)
                    .background(isToday ? Color.red : (isSelected ? Color.primary.opacity(0.12) : .clear), in: .capsule)
            }
            if let daylightText {
                HStack(spacing: 3) {
                    Spacer(minLength: 0)
                    Image(systemName: "sun.max").font(.system(size: 8))
                    Text(daylightText).font(.system(size: 9)).monospacedDigit()
                }
                .foregroundStyle(theme.isActive ? theme.glow.opacity(0.9) : Color.secondary)
                .padding(.trailing, 4)
            }
            ForEach(shown) { event in
                CalMonthLine(event: event, day: day, selected: $selected, popoverKey: $popoverKey)
            }
            if events.count > shown.count {
                Text("\(events.count - shown.count) more")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 6)
                    .frame(height: 15)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 3)
        .padding(.top, 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(isSelected ? theme.raised.opacity(theme.isActive ? 0.35 : 0.5) : (inMonth ? .clear : (theme.isActive ? theme.sidebar.opacity(0.3) : Color.primary.opacity(0.03))))
    }
}

private struct CalMonthLine: View {
    @Environment(\.colorScheme) private var scheme
    let event: CalendarEvent
    let day: Date
    @Binding var selected: CalendarEvent?
    @Binding var popoverKey: String?

    var body: some View {
        let tint = calTint(event)
        let isSelected = selected == event
        Group {
            if event.isAllDay {
                Text(event.title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? Color.white : tint.mix(with: scheme == .dark ? .white : .black, by: 0.3))
                    .padding(.horizontal, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 16)
                    .background(isSelected ? tint : tint.opacity(scheme == .dark ? 0.3 : 0.2), in: .rect(cornerRadius: 4))
            } else {
                HStack(spacing: 4) {
                    Circle().fill(tint).frame(width: 6, height: 6)
                    Text(ClockFormat.string(event.start)).foregroundStyle(isSelected ? Color.white.opacity(0.9) : .secondary)
                        .layoutPriority(1)
                    Text(event.title).fontWeight(.medium).foregroundStyle(isSelected ? Color.white : .primary)
                    Spacer(minLength: 0)
                }
                .font(.caption)
                .lineLimit(1)
                .padding(.horizontal, 5)
                .frame(height: 16)
                .background(isSelected ? Color.accentColor : .clear, in: .rect(cornerRadius: 4))
            }
        }
        .contentShape(.rect)
        .onTapGesture {
            selected = event
            popoverKey = calKey(event, day)
        }
        .calEventPopover(event: event, key: calKey(event, day), popoverKey: $popoverKey, selected: $selected)
    }
}

// MARK: - Event details

private extension View {
    func calEventPopover(event: CalendarEvent, key: String, popoverKey: Binding<String?>, selected: Binding<CalendarEvent?>) -> some View {
        popover(isPresented: Binding(
            get: { popoverKey.wrappedValue == key },
            set: { if !$0 && popoverKey.wrappedValue == key { popoverKey.wrappedValue = nil } })
        ) {
            CalEventDetails(event: event) { popoverKey.wrappedValue = nil; selected.wrappedValue = nil }
                .frame(width: 280)
                .padding(16)
        }
    }
}

private struct CalEventDetails: View {
    @Environment(AppModel.self) private var model
    let event: CalendarEvent
    let didDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 2).fill(calTint(event)).frame(width: 4)
                VStack(alignment: .leading, spacing: 3) {
                    Text(event.title).font(.headline).textSelection(.enabled)
                    Text(whenText).font(.callout).foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Circle().fill(calTint(event)).frame(width: 8, height: 8)
                Text(event.calendarTitle).font(.callout)
            }
            if let location = event.location, !location.isEmpty {
                Label(location, systemImage: "mappin.and.ellipse").font(.callout)
            }
            if let notes = event.notes, !notes.isEmpty {
                Text(notes).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Button("Delete event") {
                Task {
                    await model.run("calendar.event.delete", ["id": .string(event.id)])
                    didDelete()
                }
            }
            .buttonStyle(.pill(.red))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var whenText: String {
        let day = event.start.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
        if event.isAllDay { return "\(day), all day" }
        if Calendar.current.isDate(event.start, inSameDayAs: event.end) {
            return "\(day)\n\(calTimeRange(event.start, event.end))"
        }
        return "\(day) \(ClockFormat.string(event.start))\n\(event.end.formatted(.dateTime.weekday(.wide).day().month(.wide).year())) \(ClockFormat.string(event.end))"
    }
}

private struct CalDetailPane: View {
    let event: CalendarEvent?

    var body: some View {
        if let event {
            ScrollView {
                CalEventDetails(event: event) {}
                    .padding(20)
            }
        } else {
            Text("Select an event to see its details.")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - New event

private struct CalNewEventSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var allDay: Bool
    @State private var start: Date
    @State private var end: Date
    @State private var minutes = 60
    @State private var location = ""
    @State private var calendars: [CalendarInfo] = []
    @State private var calendarID: String?

    init(start: Date, allDay: Bool) {
        _start = State(initialValue: start)
        _end = State(initialValue: start.addingTimeInterval(3600))
        _allDay = State(initialValue: allDay)
    }

    private var canAdd: Bool { !title.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Title", text: $title)
                Toggle("All-day", isOn: $allDay)
                DatePicker("Starts", selection: $start, displayedComponents: allDay ? [.date] : [.date, .hourAndMinute])
                if !allDay {
                    Picker("Duration", selection: $minutes) {
                        ForEach([15, 30, 45, 60, 90, 120], id: \.self) { Text("\($0) minutes").tag($0) }
                        Text("Choose an end time").tag(0)
                    }
                    if minutes == 0 {
                        DatePicker("Ends", selection: $end, in: start..., displayedComponents: [.date, .hourAndMinute])
                    }
                }
                TextField("Location", text: $location)
                Picker("Calendar", selection: $calendarID) {
                    ForEach(calendars) { calendar in
                        Label {
                            Text(calendar.title)
                        } icon: {
                            Image(systemName: "circle.fill").foregroundStyle(Color(hex: calendar.colorHex) ?? .accentColor)
                        }
                        .tag(Optional(calendar.id))
                    }
                }
            }
            .formStyle(.grouped)
            HStack(spacing: 10) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.pill)
                    .keyboardShortcut(.cancelAction)
                Button("Add") { save() }
                    .buttonStyle(.pill(.accentColor))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAdd)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .frame(width: 440)
        .task {
            calendars = ((try? await model.calendar.calendars()) ?? []).filter(\.allowsModifications)
            if calendarID == nil { calendarID = calendars.first?.id }
        }
    }

    private func save() {
        guard canAdd else { return }
        var input: [String: JSONValue] = [
            "title": .string(title.trimmingCharacters(in: .whitespaces)),
            "start": .string(Self.iso(start)),
            "isAllDay": .bool(allDay),
        ]
        if !allDay {
            input["end"] = .string(Self.iso(minutes == 0 ? max(end, start) : start.addingTimeInterval(Double(minutes) * 60)))
        }
        if !location.trimmingCharacters(in: .whitespaces).isEmpty { input["location"] = .string(location) }
        if let calendarID { input["calendarID"] = .string(calendarID) }
        Task {
            await model.run("calendar.event.create", .object(input))
            dismiss()
        }
    }

    private static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        return f.string(from: date)
    }
}

// MARK: - Access

private struct CalAccessUnavailable: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    private var denied: Bool { model.eventAccess == .denied || model.eventAccess == .restricted }

    var body: some View {
        ContentUnavailableView {
            Label("Calendar access is off", systemImage: "calendar.badge.exclamationmark")
        } description: {
            Text("apnum shows and edits events in your Apple Calendar, including iCloud and Google accounts you have added to macOS.")
        } actions: {
            if denied {
                Button("Open System Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") { openURL(url) }
                }
                .buttonStyle(.pill(.accentColor))
            } else {
                Button("Allow access") { Task { await model.requestCalendarAccess() } }
                    .buttonStyle(.pill(.accentColor))
            }
        }
    }
}
