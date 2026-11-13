import ApnumCore
import ApnumLink
import SwiftUI

/// What is on the phone's notification shade, with a dismiss button on each.
struct PhoneNotificationsPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.skyTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PageHeading("Notifications")
            if model.phone.notifications.isEmpty {
                Text("Nothing on the phone right now.").foregroundStyle(.secondary).padding(.vertical, 16)
            } else {
                VStack(spacing: 0) {
                    ForEach(model.phone.notifications.prefix(8)) { item in
                        row(item)
                        if item.id != model.phone.notifications.prefix(8).last?.id { Divider() }
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .skyPanel(theme)
    }

    private func row(_ item: PhoneNotification) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.app).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(PhoneTime.short(item.posted)).font(.caption).foregroundStyle(.tertiary)
                }
                Text(item.title).font(.callout.weight(.semibold)).lineLimit(1)
                if !item.text.isEmpty { Text(item.text).font(.callout).foregroundStyle(.secondary).lineLimit(2) }
            }
            Spacer(minLength: 4)
            Button {
                Task { await model.run("phone.notifications.dismiss", ["key": .string(item.key)]) }
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

/// Dial a number or a contact, and see or end the current call.
struct PhoneCallsPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.skyTheme) private var theme
    @State private var number = ""
    @State private var suggestions: [Suggestion] = []

    struct Suggestion: Identifiable, Equatable {
        let name: String
        let number: String
        var id: String { name + number }
    }

    private var call: PhoneCall { model.phone.call }

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
                    .onSubmit(dial)
                Button("Call", action: dial)
                    .buttonStyle(.pill(.green))
                    .disabled(number.trimmingCharacters(in: .whitespaces).isEmpty || !model.hasTool("phone.call.dial"))
            }
            if !suggestions.isEmpty {
                VStack(spacing: 0) {
                    ForEach(suggestions.prefix(4)) { s in
                        Button { number = s.number; suggestions = [] } label: {
                            HStack {
                                Text(s.name).font(.callout.weight(.medium))
                                Spacer()
                                Text(s.number).font(.callout).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 6)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else if call.state == "idle" {
                Text("Calls go through the phone. Start typing a name to search its contacts.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .skyPanel(theme)
        .task(id: number) { await search() }
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

    private func dial() {
        let value = number.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return }
        Task {
            if await model.run("phone.call.dial", ["number": .string(value)]) != nil { number = "" }
        }
    }

    private func search() async {
        let query = number.trimmingCharacters(in: .whitespaces)
        guard query.count >= 2, query.contains(where: \.isLetter), model.hasTool("phone.contacts.search") else {
            suggestions = []
            return
        }
        try? await Task.sleep(for: .milliseconds(250))
        if Task.isCancelled { return }
        guard let out = await model.run("phone.contacts.search", ["query": .string(query)]) else { return }
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
