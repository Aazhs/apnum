import ApnumLink
import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Pairing: an invitation, then a QR code, the typed code and the steps.
struct PhonePairingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.skyTheme) private var theme

    var body: some View {
        ScrollView {
            panel
                .padding(28)
                .frame(maxWidth: 460)
                .skyPanel(theme, cornerRadius: 26)
                .padding(.vertical, 28)
                .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var panel: some View {
        if let safety = model.pairingSafety {
            safetyNumber(safety)
        } else if let offer = model.pairingOffer {
            offerBody(offer)
        } else {
            invitation
        }
    }

    private var invitation: some View {
        VStack(spacing: 18) {
            Image(systemName: "smartphone")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(theme.isActive ? theme.glow : Color.accentColor)
            Text("Pair your phone").font(.title.weight(.semibold))
            Text("Read its messages and one-time codes, see notifications, make calls and share the clipboard, from this Mac and from your agents. Nothing leaves your network.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Pair a phone") { Task { await model.beginPairing() } }
                .buttonStyle(.pill(.accentColor))
                .controlSize(.large)
            if let fingerprint = model.linkFingerprint {
                Text("This Mac's key: \(fingerprint)").font(.caption).foregroundStyle(.tertiary).monospaced()
            }
        }
    }

    private func offerBody(_ offer: PairingOffer) -> some View {
        VStack(spacing: 20) {
            Text("Pair your phone").font(.title2.weight(.semibold))

            PhoneQRTile(text: offer.uri).frame(width: 224, height: 224)

            VStack(spacing: 4) {
                Text(Self.grouped(offer.code))
                    .font(.system(size: 40, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .textSelection(.enabled)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let left = Int(offer.expiresAt.timeIntervalSince(context.date).rounded(.down))
                    if left > 0 {
                        Text("Expires in \(left / 60):\(String(format: "%02d", left % 60))")
                            .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                    } else {
                        Text("This code has expired.").font(.callout).foregroundStyle(.orange)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                step(1, "Install apnum on your Android phone.")
                step(2, "Open it and choose Pair with a Mac.")
                step(3, "Scan this code, or type the eight digits.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text("This Mac's key: \(offer.fingerprint)").font(.caption).foregroundStyle(.tertiary).monospaced()

            HStack(spacing: 10) {
                Button("Cancel") { Task { await model.cancelPairing() } }.buttonStyle(.pill)
                if offer.expiresAt < Date() {
                    Button("New code") { Task { await model.beginPairing() } }.buttonStyle(.pill(.accentColor))
                }
            }
        }
    }

    private func safetyNumber(_ number: String) -> some View {
        VStack(spacing: 18) {
            ProgressView().controlSize(.small)
            Text("Check this number").font(.title2.weight(.semibold))
            Text("Your phone shows the same six digits. If they match, confirm on the phone.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Text(Self.grouped(number, every: 3))
                .font(.system(size: 52, weight: .medium, design: .rounded))
                .monospacedDigit()
            Button("Cancel") { Task { await model.cancelPairing() } }.buttonStyle(.pill)
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(theme.isActive ? theme.accent : Color.accentColor))
            Text(text).font(.callout)
        }
    }

    static func grouped(_ digits: String, every n: Int = 4) -> String {
        stride(from: 0, to: digits.count, by: n)
            .map { String(digits.dropFirst($0).prefix(n)) }
            .joined(separator: " ")
    }
}

/// A QR code on a white rounded tile, drawn without smoothing so every module is sharp.
struct PhoneQRTile: View {
    let text: String

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white)
            if let image = Self.image(for: text) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .padding(18)
            }
        }
        .accessibilityLabel("Pairing QR code")
    }

    static func image(for text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scale = (600 / output.extent.width).rounded(.down)
        let big = output.samplingNearest().transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = CIContext().createCGImage(big, from: big.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
