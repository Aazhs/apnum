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
        PixelSkyHost(scene: scene, animated: animated && !reduceMotion)
            .accessibilityHidden(true)
    }
}

/// Hosts the scene in a plain layer-backed NSView driven by its own display link, so a frame costs a blit
/// and a texture swap instead of a SwiftUI update of the whole window.
private struct PixelSkyHost: NSViewRepresentable {
    let scene: SkyScene
    let animated: Bool

    func makeNSView(context: Context) -> PixelSkyNSView { PixelSkyNSView() }

    func updateNSView(_ view: PixelSkyNSView, context: Context) {
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
    private var scene: SkyScene?
    private var animated = true
    private var link: CADisplayLink?
    private var observers: [NSObjectProtocol] = []
    private var tracking: NSTrackingArea?
    private let ignoreFocus = ProcessInfo.processInfo.environment["APNUM_SKY_ALWAYS"] == "1"

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
    }

    required init?(coder: NSCoder) { fatalError("not used") }

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

    // MARK: Running state

    private var shouldRun: Bool {
        guard animated, let window, !isHiddenOrHasHiddenAncestor else { return false }
        if ignoreFocus { return true }
        return window.isKeyWindow && window.occlusionState.contains(.visible) && !window.isMiniaturized
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
        observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshRunning() }
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
        guard let out = renderer.render(scene: scene, size: bounds.size, now: Date(), animated: shouldRun) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let k = CGFloat(PixelRenderer.pixel)
        imageLayer.frame = CGRect(x: 0, y: bounds.height - CGFloat(out.height) * k, width: CGFloat(out.width) * k, height: CGFloat(out.height) * k)
        imageLayer.contents = out.image
        CATransaction.commit()
        updateBubble()
    }

    private func updateBubble() {
        guard let b = renderer.bubble() else {
            bubble.isHidden = true
            return
        }
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

    override func mouseMoved(with event: NSEvent) { renderer.hover(point: topLeft(event), size: bounds.size) }
    override func mouseDragged(with event: NSEvent) { renderer.hover(point: topLeft(event), size: bounds.size) }
    override func mouseExited(with event: NSEvent) { renderer.hover(point: nil, size: bounds.size) }

    override func mouseDown(with event: NSEvent) {
        renderer.tap(point: topLeft(event))
        drawFrame()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
