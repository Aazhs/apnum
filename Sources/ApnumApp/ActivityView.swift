import ApnumCore
import SwiftUI

/// Activity: what actions ran recently, and the tools every caller can use.
struct ActivityView: View {
    private enum Part: String, CaseIterable, Identifiable {
        case recent = "Recent", tools = "Tools"
        var id: String { rawValue }
    }

    @Environment(AppModel.self) private var model
    @State private var part: Part = .recent
    @State private var loaded: [AuditEntry] = []

    var body: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $part) {
                ForEach(Part.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .padding(.horizontal, 10).padding(.vertical, 8)
            Divider()
            switch part {
            case .recent: recent
            case .tools: ToolsList(tools: model.tools)
            }
        }
        .task {
            // The model only refreshes activity after an action, so load the existing log once.
            if model.recentActivity.isEmpty { loaded = await model.audit.recent(limit: 100) }
        }
    }

    private var entries: [AuditEntry] { model.recentActivity.isEmpty ? loaded : model.recentActivity }

    @ViewBuilder private var recent: some View {
        if entries.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "list.bullet.rectangle").font(.largeTitle).foregroundStyle(.secondary)
                Text("No activity yet").font(.headline)
                Text("Actions you, agents and your phone take appear here.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Spacer()
            }
            .frame(maxWidth: .infinity).padding()
        } else {
            List(entries) { ActivityRow(entry: $0) }.listStyle(.plain)
        }
    }
}

private struct ActivityRow: View {
    let entry: AuditEntry

    private var icon: (name: String, color: Color, label: String) {
        switch entry.outcome {
        case .ok: ("checkmark.circle.fill", .green, "Succeeded")
        case .denied: ("nosign", .orange, "Denied")
        case .error: ("xmark.circle.fill", .red, "Failed")
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon.name).foregroundStyle(icon.color).accessibilityLabel(icon.label)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(entry.tool).font(.system(.callout, design: .monospaced)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(entry.date, format: .relative(presentation: .numeric))
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Text(entry.caller)
                    Text("\(entry.durationMs) ms")
                }
                .font(.caption).foregroundStyle(.secondary)
                if entry.outcome != .ok, let message = entry.message, !message.isEmpty {
                    Text(message).font(.caption).foregroundStyle(icon.color).lineLimit(3)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

private struct ToolsList: View {
    let tools: [ToolDescriptor]
    @State private var expanded: Set<String> = []

    private var groups: [(domain: String, tools: [ToolDescriptor])] {
        let dict = Dictionary(grouping: tools) { String($0.name.split(separator: ".").first ?? "") }
        return dict.keys.sorted().map { ($0, dict[$0]!.sorted { $0.name < $1.name }) }
    }

    var body: some View {
        List {
            Text("\(tools.count) tools available to agents (MCP coming soon)")
                .font(.callout).foregroundStyle(.secondary)
            ForEach(groups, id: \.domain) { group in
                SwiftUI.Section(group.domain) {
                    ForEach(group.tools, id: \.name) { tool in
                        ToolRow(tool: tool, isExpanded: expanded.contains(tool.name)) {
                            if expanded.contains(tool.name) { expanded.remove(tool.name) } else { expanded.insert(tool.name) }
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
    }
}

private struct ToolRow: View {
    let tool: ToolDescriptor
    let isExpanded: Bool
    let toggle: () -> Void

    private var tierColor: Color {
        switch tool.tier {
        case .read: .green
        case .write: .orange
        case .dangerous: .red
        }
    }

    private var schemaText: String {
        guard let data = try? JSONCoding.prettyEncoder.encode(tool.inputSchema) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: toggle) {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2).foregroundStyle(.secondary).frame(width: 10).padding(.top, 4)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(tool.name).font(.system(.callout, design: .monospaced))
                            Spacer(minLength: 4)
                            Text(tool.tier.rawValue).font(.caption2.weight(.medium))
                                .foregroundStyle(tierColor)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(tierColor.opacity(0.15), in: Capsule())
                        }
                        Text(tool.summary).font(.caption).foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(isExpanded ? "Hides the input schema" : "Shows the input schema")

            if isExpanded {
                ScrollView(.horizontal) {
                    Text(schemaText)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(6)
                }
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.vertical, 2)
    }
}
