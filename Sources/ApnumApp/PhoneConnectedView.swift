import ApnumLink
import SwiftUI

/// Short relative times for message lists: "now", "3m", "5h", "Yesterday", "12 Oct".
enum PhoneTime {
    static func short(_ date: Date, now: Date = .now) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "Now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86_400, Calendar.current.isDate(date, inSameDayAs: now) { return "\(Int(seconds / 3600))h" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}

/// The connected phone: a header with quick actions, the latest code, messages, notifications and calls.
struct PhoneConnectedView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.skyTheme) private var theme
    let device: PairedDevice
    let since: Date

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PhoneHeader(device: device, since: since)
                if let code = model.phone.latestCode, Date().timeIntervalSince(code.date) < 600 {
                    PhoneCodePanel(code: code)
                }
                PhoneMessagesPanel()
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 20, alignment: .top)], alignment: .leading, spacing: 20) {
                    PhoneNotificationsPanel()
                    PhoneCallsPanel()
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await model.refreshPhone() }
    }
}

// MARK: - Header

private struct PhoneHeader: View {
    @Environment(AppModel.self) private var model
    @Environment(\.skyTheme) private var theme
    let device: PairedDevice
    let since: Date

    private var batterySymbol: String {
        guard let level = model.phone.battery else { return "battery.50percent" }
        if model.phone.charging == true { return "battery.100percent.bolt" }
        switch level {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    private var batteryTint: Color {
        if model.phone.charging == true { return .green }
        return (model.phone.battery ?? 100) < 20 ? .red : .secondary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(systemName: "smartphone")
                    .font(.title2)
                    .frame(width: 48, height: 48)
                    .background(Circle().fill(theme.raised.opacity(theme.isActive ? 0.7 : 0.3)))
                VStack(alignment: .leading, spacing: 3) {
                    Text(device.name).font(.title2.weight(.semibold))
                    HStack(spacing: 6) {
                        Circle().fill(.green).frame(width: 7, height: 7)
                        Text([device.os, "Connected"].compactMap { $0 }.joined(separator: ", "))
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
                Spacer(minLength: 12)
                HStack(spacing: 16) {
                    if let level = model.phone.battery {
                        Label {
                            Text("\(level)%").monospacedDigit()
                        } icon: {
                            Image(systemName: batterySymbol).foregroundStyle(batteryTint)
                        }
                        .help(model.phone.charging == true ? "Charging" : "On battery")
                    }
                    if let network = model.phone.network {
                        Label(network, systemImage: "wifi").lineLimit(1)
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            ViewThatFits(in: .horizontal) {
                actions
                VStack(alignment: .leading, spacing: 8) { actions }
            }
        }
        .padding(20)
        .skyPanel(theme)
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 10) { actionButtons }
    }

    @ViewBuilder
    private var actionButtons: some View {
        Button { Task { await model.run("phone.ring", .object([:])) } } label: {
            Label("Find my phone", systemImage: "bell.and.waves.left.and.right")
        }
        .buttonStyle(.pill)
        .disabled(!model.hasTool("phone.ring"))
        Button { Task { await model.sendClipboardToPhone() } } label: {
            Label("Send clipboard", systemImage: "arrow.up.doc.on.clipboard")
        }
        .buttonStyle(.pill)
        .disabled(!model.hasTool("phone.clipboard.set"))
        Button { Task { await model.getPhoneClipboard() } } label: {
            Label("Get phone clipboard", systemImage: "arrow.down.doc")
        }
        .buttonStyle(.pill)
        .disabled(!model.hasTool("phone.clipboard.get"))
    }
}

// MARK: - Latest code

private struct PhoneCodePanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.skyTheme) private var theme
    let code: PhoneCode
    @State private var copied = false

    var body: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Latest code").font(.callout).foregroundStyle(.secondary)
                Text(code.code)
                    .font(.system(size: 36, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .textSelection(.enabled)
                Text("From \(code.from), \(code.date.formatted(.relative(presentation: .named)))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task {
                    await model.copyToClipboard(code.code)
                    copied = true
                    try? await Task.sleep(for: .seconds(2))
                    copied = false
                }
            } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.pill(theme.isActive ? theme.accent : .accentColor, width: 110))
            .controlSize(.large)
        }
        .padding(16)
        .skyPanel(theme)
    }
}
