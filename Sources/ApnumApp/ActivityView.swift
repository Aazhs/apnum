import ApnumCore
import SwiftUI

/// Activity: what has been done, and what agents and the phone are able to do.
struct ActivityView: View {
    private enum Part: String, CaseIterable, Identifiable {
        case recent = "Recent", tools = "Tools"
        var id: String { rawValue }
    }

    @Environment(AppModel.self) private var model
    @State private var part: Part = .recent
    @State private var selectedTool: String?

    var body: some View {
        Group {
            switch part {
            case .recent: RecentTable(entries: model.recentActivity)
            case .tools: ToolsList(tools: model.tools, selection: $selectedTool)
            }
        }
        .navigationTitle("Activity")
        .navigationSubtitle("\(model.tools.count) tools available to agents")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $part) {
                    ForEach(Part.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
    }
}

// MARK: - Recent

private struct RecentTable: View {
    @Environment(\.skyTheme) private var theme
    let entries: [AuditEntry]

    var body: some View {
        if entries.isEmpty {
            ContentUnavailableView(
                "No activity yet", systemImage: "clock.arrow.circlepath",
                description: Text("Every action taken by you, your agents or your phone is recorded here. Inputs are never stored."))
        } else {
            Table(entries) {
                TableColumn("Time") { entry in
                    Text(Self.relative(entry.date))
                        .foregroundStyle(.secondary)
                        .help(entry.date.formatted(date: .complete, time: .standard))
                }
                .width(min: 80, ideal: 100)
                TableColumn("Action") { entry in
                    Text(entry.tool).font(.system(.body, design: .monospaced))
                }
                .width(min: 140, ideal: 200)
                TableColumn("Caller") { entry in
                    Text(Self.callerName(entry.caller))
                }
                .width(min: 80, ideal: 110)
                TableColumn("Result") { entry in
                    ResultLabel(entry: entry)
                }
                .width(min: 110, ideal: 140)
                TableColumn("Duration") { entry in
                    Text("\(entry.durationMs) ms")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .width(min: 60, ideal: 80)
            }
            .scrollContentBackground(theme.isActive ? .hidden : .automatic)
            .alternatingRowBackgrounds(theme.isActive ? .disabled : .enabled)
            .background(theme.isActive ? theme.background : Color.clear)
        }
    }

    private static let formatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    static func relative(_ date: Date) -> String {
        if abs(date.timeIntervalSinceNow) < 5 { return "Just now" }
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    static func callerName(_ caller: String) -> String {
        if caller == "ui" { return "You" }
        if caller == "system" { return "apnum" }
        if caller == "cli" { return "Command line" }
        for prefix in ["agent:", "phone:"] where caller.hasPrefix(prefix) {
            let name = String(caller.dropFirst(prefix.count))
            return name == "claude-code" ? "Claude Code" : name
        }
        return caller
    }
}

private struct ResultLabel: View {
    let entry: AuditEntry

    var body: some View {
        switch entry.outcome {
        case .ok:
            Label("Done", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .denied:
            Label("Needs approval", systemImage: "hand.raised.fill")
                .foregroundStyle(.orange)
                .help(entry.message ?? "This action needs your approval.")
        case .error:
            Label("Failed", systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
                .help(entry.message ?? "The action failed.")
        }
    }
}

// MARK: - Tools

private struct ToolGroup: Identifiable {
    let title: String
    let tools: [ToolDescriptor]
    var id: String { title }

    static let order = ["alarm", "timer", "stopwatch", "note", "calendar", "reminders", "mac", "shortcuts", "phone", "link"]

    static func title(forDomain domain: String) -> String {
        switch domain {
        case "alarm": "Alarms"
        case "timer", "stopwatch": "Timers"
        case "note": "Notes"
        case "calendar": "Calendar"
        case "reminders": "Reminders"
        case "mac": "Mac"
        case "shortcuts": "Shortcuts"
        case "phone": "Phone"
        case "link": "Phone link"
        default: domain.prefix(1).uppercased() + domain.dropFirst()
        }
    }

    static func groups(_ tools: [ToolDescriptor]) -> [ToolGroup] {
        let grouped = Dictionary(grouping: tools) { title(forDomain: String($0.name.split(separator: ".").first ?? "")) }
        func rank(_ title: String) -> Int {
            order.firstIndex { Self.title(forDomain: $0) == title } ?? order.count
        }
        return grouped
            .map { ToolGroup(title: $0.key, tools: $0.value.sorted { $0.name < $1.name }) }
            .sorted { (rank($0.title), $0.title) < (rank($1.title), $1.title) }
    }
}

private struct ToolsList: View {
    @Environment(\.skyTheme) private var theme
    let tools: [ToolDescriptor]
    @Binding var selection: String?

    private var selected: ToolDescriptor? { tools.first { $0.name == selection } }

    var body: some View {
        List(selection: $selection) {
            ForEach(ToolGroup.groups(tools)) { group in
                Section(group.title) {
                    ForEach(group.tools, id: \.name) { tool in
                        ToolRow(tool: tool).tag(tool.name)
                            .listRowSeparatorTint(theme.edge)
                            .listRowBackground(
                                selection == tool.name && theme.isActive
                                    ? RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.raised.opacity(0.7)).padding(.horizontal, 4)
                                    : nil)
                    }
                }
            }
            Text("Agent access over MCP is coming next.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .listRowSeparator(.hidden)
                .selectionDisabled()
        }
        .scrollContentBackground(theme.isActive ? .hidden : .automatic)
        .background(theme.isActive ? theme.background : Color.clear)
        .inspector(isPresented: Binding(get: { selected != nil }, set: { if !$0 { selection = nil } })) {
            if let selected {
                ToolInspector(tool: selected)
                    .inspectorColumnWidth(min: 280, ideal: 340, max: 460)
            }
        }
    }
}

private struct ToolRow: View {
    let tool: ToolDescriptor

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(tool.name).font(.system(.body, design: .monospaced))
                Text(tool.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            TierBadge(tier: tool.tier)
        }
        .padding(.vertical, 3)
    }
}

// MARK: Inspector

private struct Parameter: Identifiable {
    let name: String
    let type: String
    let required: Bool
    let detail: String?
    let facts: [String]
    var id: String { name }

    static func parse(_ schema: JSONValue) -> [Parameter] {
        guard case .object(let props)? = schema["properties"] else { return [] }
        var required = Set<String>()
        if case .array(let items)? = schema["required"] {
            for case .string(let s) in items { required.insert(s) }
        }
        return props.keys.sorted().map { key in
            let p = props[key] ?? .null
            var facts: [String] = []
            if case .array(let values)? = p["enum"] {
                let names = values.compactMap { value -> String? in
                    if case .string(let s) = value { return s }
                    return nil
                }
                if !names.isEmpty { facts.append("One of " + names.joined(separator: ", ")) }
            }
            switch (number(p["minimum"]), number(p["maximum"])) {
            case let (l?, h?):
                // Skip when the description already states the range ("Hour, 0-23").
                if case .string(let d)? = p["description"], d.contains("\(l)-\(h)") { break }
                facts.append("From \(l) to \(h)")
            case let (l?, nil): facts.append("At least \(l)")
            case let (nil, h?): facts.append("At most \(h)")
            default: break
            }
            if case .string(let f)? = p["format"] { facts.append("Format: \(f)") }
            var description: String?
            if case .string(let d)? = p["description"] { description = d }
            return Parameter(name: key, type: typeName(p), required: required.contains(key), detail: description, facts: facts)
        }
    }

    private static func number(_ v: JSONValue?) -> String? {
        guard case .number(let n)? = v else { return nil }
        return n.rounded() == n ? String(Int(n)) : String(n)
    }

    private static func typeName(_ p: JSONValue) -> String {
        guard case .string(let t)? = p["type"] else { return "any" }
        if t == "array", let items = p["items"] { return "list of \(typeName(items))" }
        return t
    }
}

private struct ToolInspector: View {
    @Environment(\.skyTheme) private var theme
    let tool: ToolDescriptor
    @State private var showSchema = false

    private var parameters: [Parameter] { Parameter.parse(tool.inputSchema) }

    private var tierMeaning: String {
        switch tool.tier {
        case .read: "Only reads data."
        case .write: "Changes data on this Mac."
        case .dangerous: "Acts outside apnum or can't be undone. Agents must ask first."
        }
    }

    private var prettySchema: String {
        guard let data = try? JSONCoding.prettyEncoder.encode(tool.inputSchema) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(tool.name)
                        .font(.system(.title3, design: .monospaced, weight: .semibold))
                        .textSelection(.enabled)
                    Text(tool.summary).foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    TierBadge(tier: tool.tier)
                    Text(tierMeaning).font(.callout)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Input").font(.headline)
                    if parameters.isEmpty {
                        Text("Takes no input.").foregroundStyle(.secondary)
                    } else {
                        ForEach(parameters) { p in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text(p.name).font(.system(.callout, design: .monospaced, weight: .medium))
                                    Text(p.type).font(.caption).foregroundStyle(.secondary)
                                    Spacer(minLength: 0)
                                    Text(p.required ? "Required" : "Optional")
                                        .font(.caption)
                                        .foregroundStyle(p.required ? .primary : .tertiary)
                                }
                                if let detail = p.detail {
                                    Text(detail).font(.callout).foregroundStyle(.secondary)
                                }
                                ForEach(p.facts, id: \.self) { fact in
                                    Text(fact).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            if p.id != parameters.last?.id { Rectangle().fill(theme.edge).frame(height: 1) }
                        }
                    }
                }

                DisclosureGroup("JSON schema", isExpanded: $showSchema) {
                    Text(prettySchema)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 6)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(theme.isActive ? theme.panel : Color.clear)
    }
}
