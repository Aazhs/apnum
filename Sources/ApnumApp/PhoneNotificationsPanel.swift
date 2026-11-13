import ApnumCore
import ApnumLink
import SwiftUI

/// What is on the phone's notification shade, with a dismiss button on each. Exact duplicates collapse into one row.
struct PhoneNotificationsPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.skyTheme) private var theme

    struct Group: Identifiable {
        let first: PhoneNotification
        let keys: [String]
        var id: String { first.key }
        var count: Int { keys.count }
    }

    /// Same app, title and text become one row with a count (the newest one shown).
    static func grouped(_ items: [PhoneNotification]) -> [Group] {
        var order: [String] = []
        var groups: [String: [PhoneNotification]] = [:]
        for item in items {
            let signature = [item.app, item.title, item.text].joined(separator: "\u{1F}")
            if groups[signature] == nil { order.append(signature) }
            groups[signature, default: []].append(item)
        }
        return order.compactMap { signature in
            guard let list = groups[signature], let newest = list.max(by: { $0.posted < $1.posted }) else { return nil }
            return Group(first: newest, keys: list.map(\.key))
        }
    }

    var body: some View {
        let groups = Self.grouped(model.phone.notifications)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                PageHeading("Notifications")
                Spacer()
                if !groups.isEmpty, model.hasTool("phone.notifications.clear") {
                    Button("Clear all") { Task { await model.clearPhoneNotifications() } }
                        .buttonStyle(.link)
                        .font(.callout)
                }
            }
            if groups.isEmpty {
                Text("Nothing on the phone right now.").foregroundStyle(.secondary).padding(.vertical, 16)
            } else {
                let shown = Array(groups.prefix(8))
                VStack(spacing: 0) {
                    ForEach(shown) { group in
                        row(group)
                        if group.id != shown.last?.id { Divider() }
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .skyPanel(theme)
    }

    private func row(_ group: Group) -> some View {
        let item = group.first
        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.app).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(PhoneTime.short(item.posted)).font(.caption).foregroundStyle(.tertiary)
                    if group.count > 1 {
                        Text("\(group.count)")
                            .font(.caption2.weight(.semibold))
                            .monospacedDigit()
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.primary.opacity(0.12)))
                            .help("\(group.count) identical notifications")
                    }
                }
                Text(item.title).font(.callout.weight(.semibold)).lineLimit(1)
                if !item.text.isEmpty { Text(item.text).font(.callout).foregroundStyle(.secondary).lineLimit(2) }
            }
            Spacer(minLength: 4)
            Button {
                Task { for key in group.keys { await model.run("phone.notifications.dismiss", ["key": .string(key)]) } }
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary).imageScale(.large)
            }
            .buttonStyle(.plain)
            .help("Dismiss on the phone")
            .disabled(!model.hasTool("phone.notifications.dismiss"))
        }
        .padding(.vertical, 9)
    }
}

/// Dial a number or a contact, see recent calls, and see or end the current call.
struct PhoneCallsPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.skyTheme) private var theme
    @State private var number = ""
    @State private var suggestions: [Suggestion] = []
    @State private var recent = AppModel.RecentCalls()
    @State private var searching = false

    struct Suggestion: Identifiable, Equatable {
        let name: String
        let number: String
        var id: String { name + number }
    }

    private var call: PhoneCall { model.phone.call }
    private var query: String { number.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PageHeading("Calls")
            if call.state != "idle" { current }
            HStack(spacing: 8) {
                TextField("Number or contact", text: $number)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                    .background(Capsule().fill(theme.isActive ? theme.raised.opacity(0.5) : Color.primary.opacity(0.07)))
                    .onSubmit { dial(query) }
                Button("Call") { dial(query) }
                    .buttonStyle(.pill(.green))
                    .disabled(query.isEmpty || !model.hasTool("phone.call.dial"))
            }
            if query.isEmpty { recentList } else { matches }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .skyPanel(theme)
        .task(id: number) { await search() }
        .task(id: model.phone.call.state) { if query.isEmpty { recent = await model.recentCalls() } }
    }

    // MARK: Recent

    @ViewBuilder
    private var recentList: some View {
        if !recent.calls.isEmpty {
            Text("Recent").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(recent.calls.prefix(6)) { entry in
                    recentRow(entry)
                    if entry.id != recent.calls.prefix(6).last?.id { Divider() }
                }
            }
        } else if let message = recent.message {
            Text(message).font(.callout).foregroundStyle(.secondary)
        } else {
            Text("Calls go through the phone. Start typing a name to search its contacts.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func icon(_ kind: PhoneCallLogEntry.Kind) -> (name: String, tint: Color) {
        switch kind {
        case .incoming: ("phone.arrow.down.left", .secondary)
        case .outgoing: ("phone.arrow.up.right", .secondary)
        case .missed: ("phone.arrow.down.left", .red)
        }
    }

    private func recentRow(_ entry: PhoneCallLogEntry) -> some View {
        let symbol = icon(entry.kind)
        return HStack(spacing: 10) {
            Button { number = entry.number } label: {
                HStack(spacing: 10) {
                    Image(systemName: symbol.name).foregroundStyle(symbol.tint).frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.title).font(.callout.weight(.medium)).lineLimit(1)
                            .foregroundStyle(entry.kind == .missed ? Color.red : Color.primary)
                        if entry.contactName != nil { Text(entry.number).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    Spacer(minLength: 4)
                    Text(PhoneTime.short(entry.date)).font(.caption).foregroundStyle(.tertiary)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            callButton(entry.number)
        }
        .padding(.vertical, 6)
    }

    private func callButton(_ target: String) -> some View {
        Button { dial(target) } label: {
            Image(systemName: "phone.circle.fill").foregroundStyle(.green).imageScale(.large)
        }
        .buttonStyle(.plain)
        .help("Call \(target)")
        .disabled(!model.hasTool("phone.call.dial"))
    }

    // MARK: Matches

    @ViewBuilder
    private var matches: some View {
        if !suggestions.isEmpty {
            VStack(spacing: 0) {
                ForEach(suggestions.prefix(5)) { s in
                    HStack(spacing: 10) {
                        Button { number = s.number } label: {
                            HStack {
                                Text(s.name).font(.callout.weight(.medium)).lineLimit(1)
                                Spacer(minLength: 4)
                                Text(s.number).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        callButton(s.number)
                    }
                    .padding(.vertical, 6)
                }
            }
        } else if !searching, call.state == "idle", number.contains(where: \.isLetter) {
            Text("No matching contacts.").font(.callout).foregroundStyle(.secondary)
        }
    }

    private var current: some View {
        HStack(spacing: 12) {
            Image(systemName: call.state == "ringing" ? "phone.arrow.down.left.fill" : "phone.fill")
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 1) {
                Text(call.contactName ?? call.number ?? "Unknown number").font(.callout.weight(.semibold))
                Text(call.state == "ringing" ? "Ringing" : "On a call").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(call.state == "ringing" ? "Decline" : "End") { Task { await model.run("phone.call.end", .object([:])) } }
                .buttonStyle(.pill(.red))
        }
        .padding(12)
        .background(.green.opacity(0.12), in: .rect(cornerRadius: 12, style: .continuous))
    }

    private func dial(_ target: String) {
        let value = target.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return }
        Task {
            if await model.run("phone.call.dial", ["number": .string(value)]) != nil { number = "" }
        }
    }

    /// Debounced: the task is cancelled by the next keystroke, so only a pause of 250 ms reaches the phone.
    private func search() async {
        guard query.count >= 2 || (query.count == 1 && query.first?.isLetter == true) else {
            suggestions = []
            return
        }
        searching = true
        defer { searching = false }
        try? await Task.sleep(for: .milliseconds(250))
        if Task.isCancelled { return }
        guard let out = await model.searchContacts(query), !Task.isCancelled else { return }
        suggestions = Self.suggestions(from: out)
    }

    static func suggestions(from output: JSONValue) -> [Suggestion] {
        var list: [JSONValue] = []
        if case .array(let a) = output { list = a }
        if case .object(let o) = output { for key in o.keys.sorted() { if case .array(let a)? = o[key] { list = a; break } } }
        return list.flatMap { contact -> [Suggestion] in
            guard case .string(let name)? = contact["name"] else { return [] }
            guard case .array(let numbers)? = contact["numbers"] else { return [] }
            return numbers.compactMap { value in
                if case .string(let n) = value { return Suggestion(name: name, number: n) }
                if case .string(let n)? = value["number"] { return Suggestion(name: name, number: n) }
                return nil
            }
        }
    }
}
