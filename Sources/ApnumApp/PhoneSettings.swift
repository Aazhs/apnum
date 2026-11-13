import ApnumLink
import SwiftUI

/// Settings > Phone: the link switch, code handling, what the phone may do, and the paired device.
struct PhoneSettingsTab: View {
    @Environment(\.skyTheme) private var theme
    @Environment(AppModel.self) private var model
    @State private var confirmingUnpair = false

    var body: some View {
        Form {
            Section {
                Toggle("Connect to my phone", isOn: Binding(
                    get: { model.linkSettings.enabled },
                    set: { value in Task { await model.setLink(enabled: value) } }))
                Toggle("Copy one-time codes automatically", isOn: Binding(
                    get: { model.linkSettings.autoCopyCodes },
                    set: { value in Task { await model.setLink(autoCopyCodes: value) } }))
            } footer: {
                Text("When a text with a code arrives on the phone, apnum shows a notification and, if this is on, puts the code on the clipboard.")
            }
            .themedRows(theme)

            if let device = model.pairedDevice {
                Section {
                    Toggle("Allow dangerous actions from this phone", isOn: Binding(
                        get: { device.trustDangerous },
                        set: { value in Task { await model.setLink(trustDangerous: value) } }))
                } footer: {
                    Label {
                        Text("Dangerous actions include sleeping or locking the Mac and running Shortcuts. Turn this on only if you trust everyone who can use the phone and the phone itself.")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
                .themedRows(theme)

                Section {
                    LabeledContent("Device", value: device.name)
                    if let os = device.os { LabeledContent("System", value: os) }
                    LabeledContent("Paired", value: device.pairedAt.formatted(date: .abbreviated, time: .omitted))
                    if let fingerprint = model.linkFingerprint {
                        LabeledContent("This Mac's key") { Text(fingerprint).monospaced().textSelection(.enabled) }
                    }
                    LabeledContent("Phone's key") {
                        Text(device.fingerprint ?? "Unknown").monospaced().textSelection(.enabled)
                    }
                    LabeledContent("") {
                        Button("Unpair", role: .destructive) { confirmingUnpair = true }
                    }
                }
                .themedRows(theme)
            } else {
                Section {
                    Text("No phone is paired. Open the Phone section to pair one.").foregroundStyle(.secondary)
                    if let fingerprint = model.linkFingerprint {
                        LabeledContent("This Mac's key") { Text(fingerprint).monospaced().textSelection(.enabled) }
                    }
                }
                .themedRows(theme)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Unpair this phone?", isPresented: $confirmingUnpair) {
            Button("Unpair", role: .destructive) { Task { await model.unpairPhone() } }
        } message: {
            Text("It will have to be paired again before it can connect.")
        }
    }
}
