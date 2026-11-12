import ApnumTimers
import SwiftUI

// Controls shared by every screen, modelled on the macOS Clock app:
// wide pill buttons for actions, round icon buttons for quick starts,
// and a large segmented digit field for entering times.

// MARK: - Buttons

/// A capsule action button, like Clock's Cancel and Start.
/// `tint` nil gives the neutral grey; a tint gives a filled, white-label button.
struct PillButtonStyle: ButtonStyle {
    var tint: Color?
    var width: CGFloat?
    var height: CGFloat = 34

    func makeBody(configuration: Configuration) -> some View {
        PillBody(configuration: configuration, tint: tint, width: width, height: height)
    }

    private struct PillBody: View {
        @Environment(\.isEnabled) private var isEnabled
        let configuration: ButtonStyleConfiguration
        let tint: Color?
        let width: CGFloat?
        let height: CGFloat

        var body: some View {
            configuration.label
                .font(.body.weight(.semibold))
                .lineLimit(1)
                .foregroundStyle(tint == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(.white))
                .padding(.horizontal, width == nil ? 18 : 0)
                .frame(width: width, height: height)
                .background {
                    Capsule().fill(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.quaternary))
                }
                .overlay {
                    Capsule().fill(.black.opacity(configuration.isPressed ? 0.18 : 0))
                }
                .opacity(isEnabled ? 1 : 0.4)
                .contentShape(.capsule)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }
}

/// A round icon button with a tinted fill, like Clock's green play buttons.
struct CircleButtonStyle: ButtonStyle {
    var tint: Color = .green
    var size: CGFloat = 44

    func makeBody(configuration: Configuration) -> some View {
        CircleBody(configuration: configuration, tint: tint, size: size)
    }

    private struct CircleBody: View {
        @Environment(\.isEnabled) private var isEnabled
        let configuration: ButtonStyleConfiguration
        let tint: Color
        let size: CGFloat

        var body: some View {
            configuration.label
                .labelStyle(.iconOnly)
                .font(.system(size: size * 0.36, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .background(Circle().fill(tint.opacity(configuration.isPressed ? 0.32 : 0.2)))
                .opacity(isEnabled ? 1 : 0.4)
                .contentShape(.circle)
                .scaleEffect(configuration.isPressed ? 0.94 : 1)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }
}

extension ButtonStyle where Self == PillButtonStyle {
    /// Neutral grey pill (Cancel, Lap, Reset).
    static var pill: PillButtonStyle { PillButtonStyle() }
    /// Filled pill (Start in green, Stop in red, Save in the accent colour).
    static func pill(_ tint: Color, width: CGFloat? = nil) -> PillButtonStyle { PillButtonStyle(tint: tint, width: width) }
    static func pill(width: CGFloat) -> PillButtonStyle { PillButtonStyle(width: width) }
}

extension ButtonStyle where Self == CircleButtonStyle {
    static func circle(_ tint: Color = .green, size: CGFloat = 44) -> CircleButtonStyle { CircleButtonStyle(tint: tint, size: size) }
}

// MARK: - Digit field

/// A large segmented number field (`hr : min : sec` or `hour : minute`).
/// Click a segment and type digits, use the arrow keys, or click the chevrons.
/// Behaviour lives in `DigitEntry` (ApnumTimers), which is unit tested.
struct DigitField: View {
    @Binding var entry: DigitEntry
    let labels: [String]
    var size: CGFloat = 76
    var autofocus = false

    @FocusState private var focused: Bool
    @State private var hovering: Int?

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(entry.values.indices, id: \.self) { i in
                if i > 0 {
                    Text(":")
                        .font(.clock(size, weight: .thin))
                        .foregroundStyle(.secondary)
                        .padding(.bottom, size * 0.1)
                }
                segment(i)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.quinary))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(focused ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.08), lineWidth: focused ? 2 : 1)
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(phases: .down, action: handle)
        .onAppear { if autofocus { focused = true } }
        .accessibilityElement(children: .contain)
    }

    private func segment(_ i: Int) -> some View {
        let isActive = focused && entry.active == i
        let showChevrons = hovering == i || isActive
        return VStack(spacing: 0) {
            Text(labels[i])
                .font(.callout)
                .foregroundStyle(.secondary)
            chevron("chevron.up", visible: showChevrons) { entry.focus(i); entry.step(1); focused = true }
            Text(String(format: "%02d", entry.values[i]))
                .font(.clock(size, weight: .thin))
                .monospacedDigit()
                .padding(.horizontal, 8)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(isActive ? Color.accentColor.opacity(0.22) : .clear)
                }
                .contentShape(.rect)
                .onTapGesture {
                    entry.focus(i)
                    focused = true
                }
            chevron("chevron.down", visible: showChevrons) { entry.focus(i); entry.step(-1); focused = true }
        }
        .onHover { hovering = $0 ? i : (hovering == i ? nil : hovering) }
        .accessibilityElement()
        .accessibilityLabel(labels[i])
        .accessibilityValue("\(entry.values[i])")
        .accessibilityAdjustableAction { direction in
            entry.focus(i)
            entry.step(direction == .increment ? 1 : -1)
        }
    }

    private func chevron(_ symbol: String, visible: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 44, height: 18)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .opacity(visible ? 1 : 0)
        .accessibilityHidden(true)
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .upArrow: entry.step(1); return .handled
        case .downArrow: entry.step(-1); return .handled
        case .leftArrow: entry.retreat(); return .handled
        case .rightArrow: entry.advance(); return .handled
        case .delete, .deleteForward: entry.backspace(); return .handled
        case .tab:
            if press.modifiers.contains(.shift) {
                guard entry.active > 0 else { return .ignored }
                entry.retreat()
            } else {
                guard entry.active < entry.values.count - 1 else { return .ignored }
                entry.advance()
            }
            return .handled
        default:
            if let digit = Int(press.characters), press.characters.count == 1 {
                entry.type(digit)
                return .handled
            }
            return .ignored
        }
    }
}

// MARK: - Panels and backdrop

/// A Liquid Glass panel: the building block of Today and the menu bar glance.
struct GlassPanel<Content: View, Accessory: View>: View {
    var title: String?
    var symbol: String?
    var padding: CGFloat = 20
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    init(
        _ title: String? = nil, symbol: String? = nil, padding: CGFloat = 20,
        @ViewBuilder accessory: () -> Accessory = { EmptyView() }, @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.symbol = symbol
        self.padding = padding
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let title {
                HStack(alignment: .firstTextBaseline) {
                    if let symbol {
                        Label(title, systemImage: symbol).font(.headline)
                    } else {
                        Text(title).font(.headline)
                    }
                    Spacer(minLength: 8)
                    accessory
                }
            }
            content
        }
        .padding(padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassEffect(.regular, in: .rect(cornerRadius: 28, style: .continuous))
    }
}

/// The sky at a given time, full bleed: a vertical gradient from the colour
/// overhead to the horizon, a glow where the sun (or moon) is, and a few stars at night.
struct SkyBackdrop: View {
    let now: Date

    var body: some View {
        let hour = Sky.hour(of: now)
        GeometryReader { geo in
            ZStack {
                LinearGradient(
                    colors: [Sky.shade(Sky.color(atHour: hour), by: 0.72), Sky.color(atHour: hour), Sky.color(atHour: hour + 1.2)],
                    startPoint: .top, endPoint: .bottom)

                // Sun by day, moon by night, travelling across the top of the sky.
                let daylight = hour >= 6 && hour <= 19
                let progress = daylight ? (hour - 6) / 13 : ((hour + 24 - 19).truncatingRemainder(dividingBy: 24)) / 11
                let x = geo.size.width * (0.08 + 0.84 * progress)
                let y = geo.size.height * (0.12 + 0.18 * pow(2 * progress - 1, 2))
                let radius: CGFloat = daylight ? 420 : 240
                Circle()
                    .fill(RadialGradient(
                        colors: [Color.white.opacity(daylight ? 0.5 : 0.2), Color.white.opacity(0)],
                        center: .center, startRadius: 0, endRadius: radius))
                    .frame(width: radius * 2, height: radius * 2)
                    .position(x: x, y: y)

                if Sky.isDark(atHour: hour) {
                    Canvas { context, size in
                        var rng = SeededRandom(seed: 7)
                        for _ in 0..<70 {
                            let p = CGPoint(x: rng.next() * size.width, y: rng.next() * size.height * 0.6)
                            let r = 0.6 + rng.next() * 1.1
                            context.fill(Path(ellipseIn: CGRect(x: p.x, y: p.y, width: r, height: r)), with: .color(.white.opacity(0.25 + rng.next() * 0.45)))
                        }
                    }
                }
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// Deterministic random numbers so the stars don't move between redraws.
private struct SeededRandom {
    var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> CGFloat {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return CGFloat(state >> 11) / CGFloat(1 << 53)
    }
}
