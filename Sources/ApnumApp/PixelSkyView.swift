import ApnumSky
import AppKit
import QuartzCore
import SwiftUI

/// The living pixel-art sky (ported from aarshj.me). Fills its frame; scene pixels are 4 pt, scaled
/// nearest-neighbour by the GPU. Pauses when hidden, when the window is not key or covered, and under
/// Reduce Motion (a single static frame).
struct PixelSkyView: View {
    let scene: SkyScene
    var animated: Bool = true
    /// Points per scene pixel (4 matches aarshj.me; use 2 for small views).
    var pixelSize: Int = PixelRenderer.pixel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Debug (APNUM_PREVIEW=sky): sun altitude from APNUM_SKY_ALT, weather kind from APNUM_SKY_WEATHER.
    static func debugPreview() -> PixelSkyView {
        let env = ProcessInfo.processInfo.environment
        let kind = env["APNUM_SKY_WEATHER"].flatMap(WeatherKind.init(rawValue:)) ?? .clear
        let weather = SkyWeather(kind: kind, cloudCover: kind == .clear ? 0.2 : 0.5, temperatureC: 20, windKmh: 8, isLive: false)
        return PixelSkyView(scene: .sample(
            sunAltitudeDegrees: env["APNUM_SKY_ALT"].flatMap(Double.init) ?? 20, moonPhase: 0.35, weather: weather))
    }

    var body: some View {
        PixelSkyHost(scene: scene, animated: animated && !reduceMotion, pixelSize: pixelSize)
            .accessibilityHidden(true)
    }
}

/// Hosts the scene in a plain layer-backed NSView driven by its own display link, so a frame costs a blit
/// and a texture swap instead of a SwiftUI update of the whole window.
private struct PixelSkyHost: NSViewRepresentable {
    let scene: SkyScene
    let animated: Bool
    let pixelSize: Int

    func makeNSView(context: Context) -> PixelSkyNSView { PixelSkyNSView() }

    func updateNSView(_ view: PixelSkyNSView, context: Context) {
        view.setPixelSize(pixelSize)
        view.configure(scene: scene, animated: animated)
    }

    static func dismantleNSView(_ view: PixelSkyNSView, coordinator: ()) {
        view.shutDown()
    }
}

/// Lets clicks fall through the speech bubble.
private final class BubbleLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
private final class PixelSkyNSView: NSView {
    private let renderer = PixelRenderer()
    private let imageLayer = CALayer()
    private let bubble = BubbleLabel(labelWithString: "")
    private let tipLabel = BubbleLabel(labelWithString: "")
    private let hud = BubbleLabel(labelWithString: "")
    private var konami = KonamiDetector()
    private var shiftMonitor: Any?
    private var scene: SkyScene?
    private var animated = true
    private var link: CADisplayLink?
    private var observers: [NSObjectProtocol] = []
    private var tracking: NSTrackingArea?
    private let ignoreFocus = ProcessInfo.processInfo.environment["APNUM_SKY_ALWAYS"] == "1"

    func setPixelSize(_ size: Int) {
        guard size != renderer.scale, size > 0 else { return }
        renderer.scale = size
        needsDisplay = true
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.black.cgColor
        imageLayer.magnificationFilter = .nearest
        imageLayer.minificationFilter = .nearest
        imageLayer.contentsGravity = .resize
        imageLayer.isOpaque = true
        imageLayer.anchorPoint = .zero
        layer?.addSublayer(imageLayer)

        bubble.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        bubble.textColor = NSColor(red: 0.16, green: 0.11, blue: 0.18, alpha: 1)
        bubble.alignment = .center
        bubble.wantsLayer = true
        bubble.layer?.backgroundColor = NSColor(red: 1, green: 0.97, blue: 0.9, alpha: 1).cgColor
        bubble.layer?.borderColor = NSColor(red: 0.16, green: 0.11, blue: 0.18, alpha: 1).cgColor
        bubble.layer?.borderWidth = 2
        bubble.layer?.cornerRadius = 3
        bubble.isHidden = true
        addSubview(bubble)

        styleSmall(tipLabel, text: NSColor(red: 0.16, green: 0.11, blue: 0.18, alpha: 1), fill: NSColor(red: 1, green: 0.97, blue: 0.9, alpha: 0.95))
        styleSmall(hud, text: NSColor(red: 1, green: 0.84, blue: 0.48, alpha: 1), fill: NSColor(red: 0.08, green: 0.06, blue: 0.12, alpha: 0.75))
        addSubview(tipLabel)
        addSubview(hud)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func styleSmall(_ label: NSTextField, text: NSColor, fill: NSColor) {
        label.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        label.textColor = text
        label.alignment = .center
        label.wantsLayer = true
        label.layer?.backgroundColor = fill.cgColor
        label.layer?.borderColor = text.withAlphaComponent(0.85).cgColor
        label.layer?.borderWidth = 1
        label.layer?.cornerRadius = 2
        label.isHidden = true
    }

    func configure(scene: SkyScene, animated: Bool) {
        self.scene = scene
        self.animated = animated
        refreshRunning()
        drawFrame()
    }

    func shutDown() {
        stopLink()
        removeObservers()
    }

    private func removeShiftMonitor() {
        if let shiftMonitor { NSEvent.removeMonitor(shiftMonitor) }
        shiftMonitor = nil
    }

    // MARK: Running state

    private var shouldRun: Bool {
        guard animated, let window, !isHiddenOrHasHiddenAncestor else { return false }
        if ignoreFocus { return true }
        return window.isKeyWindow && window.occlusionState.contains(.visible) && !window.isMiniaturized
    }

    private func windowStateChanged() {
        if window?.isKeyWindow != true { setShift(false) }
        refreshRunning()
    }

    private func refreshRunning() {
        if shouldRun {
            guard link == nil else { return }
            let l = displayLink(target: self, selector: #selector(tick))
            l.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: 20, preferred: 20)
            l.add(to: .main, forMode: .common)
            link = l
        } else {
            stopLink()
        }
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick() { drawFrame() }

    private func removeObservers() {
        removeShiftMonitor()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeObservers()
        guard let window else {
            stopLink()
            return
        }
        let names: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
        ]
        shiftMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            MainActor.assumeIsolated {
                if let self, event.window === self.window { self.setShift(event.modifierFlags.contains(.shift)) }
            }
            return event
        }
        observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.windowStateChanged() }
            }
        }
        refreshRunning()
        drawFrame()
    }

    override func viewDidHide() {
        super.viewDidHide()
        refreshRunning()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        refreshRunning()
    }

    override func layout() {
        super.layout()
        drawFrame()
    }

    // MARK: Drawing

    private func drawFrame() {
        guard let scene, bounds.width > 1, bounds.height > 1 else { return }
        guard let out = Perf.measure("frame", threshold: 4, { renderer.render(scene: scene, size: bounds.size, now: Date(), animated: shouldRun) }) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let k = CGFloat(renderer.scale)
        imageLayer.frame = CGRect(x: 0, y: bounds.height - CGFloat(out.height) * k, width: CGFloat(out.width) * k, height: CGFloat(out.height) * k)
        imageLayer.contents = out.image
        CATransaction.commit()
        updateBubble()
        updateTip()
    }

    private func setShift(_ held: Bool) {
        guard held != renderer.shiftHeld else { return }
        renderer.setShift(held)
        if link == nil { drawFrame() }
    }

    private func updateTip() {
        if let t = renderer.tip {
            tipLabel.stringValue = t.text
            tipLabel.sizeToFit()
            let w = tipLabel.frame.width + 10, h = tipLabel.frame.height + 4
            let x = min(max(CGFloat(t.x) + 12, 2), max(2, bounds.width - w - 2))
            let y = min(max(bounds.height - CGFloat(t.y) + 10 - h, 2), max(2, bounds.height - h - 2))
            tipLabel.frame = CGRect(x: x, y: y, width: w, height: h)
            tipLabel.isHidden = false
        } else {
            tipLabel.isHidden = true
        }
        if let text = renderer.hudText() {
            hud.stringValue = text
            hud.sizeToFit()
            let w = hud.frame.width + 12, h = hud.frame.height + 6
            hud.frame = CGRect(x: 8, y: bounds.height - h - 8, width: w, height: h)
            hud.isHidden = false
        } else {
            hud.isHidden = true
        }
    }

    private func updateBubble() {
        guard let b = renderer.bubble() else {
            bubble.isHidden = true
            return
        }
        let red = renderer.horrorState.red
        bubble.textColor = red ? NSColor(red: 1, green: 0.35, blue: 0.31, alpha: 1) : NSColor(red: 0.16, green: 0.11, blue: 0.18, alpha: 1)
        bubble.layer?.backgroundColor = (red ? NSColor(red: 0.06, green: 0.02, blue: 0.05, alpha: 1) : NSColor(red: 1, green: 0.97, blue: 0.9, alpha: 1)).cgColor
        bubble.layer?.borderColor = (red ? NSColor(red: 0.6, green: 0.12, blue: 0.12, alpha: 1) : NSColor(red: 0.16, green: 0.11, blue: 0.18, alpha: 1)).cgColor
        bubble.stringValue = b.text
        bubble.sizeToFit()
        var size = bubble.frame.size
        size.width += 16
        size.height += 10
        let x = min(max(b.x - size.width / 2, 4), max(4, bounds.width - size.width - 4))
        bubble.frame = CGRect(x: x, y: bounds.height - b.y + 4, width: size.width, height: size.height)
        bubble.isHidden = false
    }

    // MARK: Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    private func topLeft(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: p.x, y: bounds.height - p.y)
    }

    private func pointerMoved(_ point: CGPoint?) {
        renderer.hover(point: point, size: bounds.size)
        // While paused nothing redraws on its own; only the overlays need it.
        if link == nil, renderer.overlayOn || renderer.tip != nil || !tipLabel.isHidden { drawFrame() }
    }

    override func mouseMoved(with event: NSEvent) { pointerMoved(topLeft(event)) }
    override func mouseDragged(with event: NSEvent) { pointerMoved(topLeft(event)) }
    override func mouseExited(with event: NSEvent) { pointerMoved(nil) }

    override func mouseDown(with event: NSEvent) {
        // Clicking the scene is what lets it hear the Konami keys; nothing else ever pulls focus here.
        window?.makeFirstResponder(self)
        renderer.hover(point: topLeft(event), size: bounds.size)
        if event.modifierFlags.contains(.shift), let url = renderer.hoveredConstellationURL() {
            NSWorkspace.shared.open(url)
            return
        }
        renderer.tap(point: topLeft(event))
        drawFrame()
    }

    // MARK: Keyboard (easter eggs)

    override var acceptsFirstResponder: Bool { true }

    override func flagsChanged(with event: NSEvent) {
        setShift(event.modifierFlags.contains(.shift))
        super.flagsChanged(with: event)
    }

    override func keyDown(with event: NSEvent) {
        guard !event.modifierFlags.contains(.command), let key = konamiKey(event) else {
            konami = KonamiDetector()
            super.keyDown(with: event)
            return
        }
        if konami.feed(key), shouldRun { renderer.startGame() }
    }

    private func konamiKey(_ event: NSEvent) -> KonamiDetector.Key? {
        switch event.keyCode {
        case 126: return .up
        case 125: return .down
        case 123: return .left
        case 124: return .right
        default: break
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "b": return .b
        case "a": return .a
        default: return nil
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
