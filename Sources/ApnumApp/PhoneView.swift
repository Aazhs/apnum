import ApnumLink
import SwiftUI

/// The Phone screen: pairing, the offline state, or the connected phone's messages, notifications and calls.
struct PhoneView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.skyTheme) private var theme

    var body: some View {
        content
            .navigationTitle("Phone")
            .navigationSubtitle(subtitle)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var subtitle: String {
        switch model.linkStatus {
        case .off: "Link is off"
        case .notPaired: "Not paired"
        case .waitingForPhone: model.pairedDevice.map { "\($0.name) is offline" } ?? "Offline"
        case .connected(let device, _):
            model.phone.ringingIDs.isEmpty ? "\(device.name) is connected" : "\(device.name) is connected. Ringing on your phone"
        }
    }

    @ViewBuilder
    private var content: some View {
        if case .off = model.linkStatus {
            ContentUnavailableView {
                Label("The phone link is off", systemImage: "smartphone")
            } description: {
                Text("Turn it on to pair a phone and see its messages and notifications here.")
            } actions: {
                Button("Turn on") { Task { await model.setLink(enabled: true) } }.buttonStyle(.pill(.accentColor))
            }
        } else if model.pairingOffer != nil || model.pairingSafety != nil {
            PhonePairingView()
        } else {
            switch model.linkStatus {
            case .notPaired, .off: PhonePairingView()
            case .waitingForPhone: PhoneOfflineView()
            case .connected(let device, let since): PhoneConnectedView(device: device, since: since)
            }
        }
    }
}

/// Paired, but the phone is not reachable right now.
private struct PhoneOfflineView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.skyTheme) private var theme

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "smartphone")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            VStack(spacing: 6) {
                Text(model.pairedDevice?.name ?? "Your phone").font(.title2.weight(.semibold))
                if let seen = model.pairedDevice?.lastSeen {
                    Text("Last seen \(seen.formatted(.relative(presentation: .named)))").foregroundStyle(.secondary)
                } else {
                    Text("Waiting for it to connect").foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Label("Be on the same Wi-Fi, or connect the Mac to the phone's hotspot.", systemImage: "wifi")
                Label("Keep the apnum app running on the phone.", systemImage: "app.badge.checkmark")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button("Pair a different phone") { Task { await model.beginPairing() } }.buttonStyle(.pill)
                Button("Unpair") { Task { await model.unpairPhone() } }.buttonStyle(.pill(.red))
            }
        }
        .padding(32)
        .frame(maxWidth: 440)
        .skyPanel(theme, cornerRadius: 24)
    }
}
