import ApnumSky
import CoreGraphics
import Foundation

/// Draws the whole pixel scene into a small buffer. Static layers (sky, ranges, ground and props, fog,
/// cloud shapes) are baked when the scene, size or light side changes; each frame only composites them
/// and moves the animated bits. All state lives here so the SwiftUI view stays a thin shell.
@MainActor
final class PixelRenderer {
    /// Scene pixels are this many points wide.
    static let pixel = 4
    /// Points per scene pixel; smaller for small views such as the menu bar glance.
    var scale = PixelRenderer.pixel
    /// Fixed so the landscape is the same on every launch.
    static let rangeSeed = 8_675_309

    struct Output {
        var image: CGImage
        var width: Int
        var height: Int
    }

    struct Fingerprint: Equatable {
        var width: Int, height: Int
        var palette: SkyPalette
        var sunAlt: Int, sunAz: Int, moonAlt: Int, moonAz: Int
        var phase: Int
        var kind: WeatherKind
        var cloud: Int, wind: Int
        var stars: Int, planets: Int, milky: Int
        var blood: Int
        var supermoon: Bool
        var horror = false
    }

    struct Star {
        var x: Int, y: Int
        var a: Double
        var color: UInt32
        var big: Bool
        var tw: Double, f1: Double, f2: Double, p: Double
        var name: String? = nil
    }

    struct Planet {
        var x: Int, y: Int
        var a: Double
        var color: UInt32
        var mag: Double
        var name = ""
    }

    struct Meteor {
        var x: Double, y: Double, vx: Double, vy: Double
        var life: Double, maxLife: Double
        var bright: Bool
    }

    struct Drop {
        var x: Double, y: Double, v: Double
        var len: Int
    }

    struct Splash {
        var x: Int
        var life: Double
    }

    struct Bolt {
        var path: [(Int, Int)]
        var life: Double
    }

    struct Fly {
        var hx: Double, hy: Double, x: Double, y: Double
        var vx = 0.0, vy = 0.0
        var p: Double
    }

    struct Wisp {
        var x: Double, y: Int, w: Int, v: Double
    }

    struct Player {
        var x = 40.0, y = 0.0, vx = 0.0, vy = 0.0
        var facing = 1.0
        var step = 0.0
        var grounded = true
        var wanderUntil = 0.0
        var target: Double?
        var goSit = false, sitting = false
        var sitUntil = 0.0
    }

    // Geometry
    var W = 0
    var H = 0
    var groundY: Int { Int((Double(H) * 0.94).rounded()) }

    // The scene
    var scene: SkyScene?
    var fingerprint: Fingerprint?
    var palette = SkyPalette.forSunAltitude(0)
    var night = 0.0
    var overcast = 0.0
    var wet = 0.0
    var wind = 8.0
    var weatherKind = WeatherKind.clear
    var lightFromLeft = true

    // Baked layers
    var skyLayer = PixelLayer(width: 1, height: 1)
    var groundLayer = PixelLayer(width: 1, height: 1)
    var fogLayer = PixelLayer(width: 1, height: 1)
    var frame = PixelLayer(width: 1, height: 1)
    var ranges: [PixelRange] = []
    var rangeLayers: [PixelLayer] = []
    let rangePad = 24
    let rangeDepth: [Double] = [0.2, 0.4, 0.7, 1]
    var propItems: [PixelProp] = []
    var grassEdge: [Int] = []
    var lighting: PixelLighting?
    var lampForced: Bool?

    // Animated state
    var clouds: [PixelCloud] = []
    var cloudKey = ""
    var stars: [Star] = []
    var planets: [Planet] = []
    var meteors: [Meteor] = []
    var radiant: (x: Double, y: Double)?
    var drops: [Drop] = []
    var splashes: [Splash] = []
    var bolt: Bolt?
    var nextBolt = 0.0
    var flies: [Fly] = []
    var wisps: [Wisp] = []
    var fogOn = false
    var fogStrength = 0.0
    var fogColour = RGB(hex: "#dfe4ea")
    var player = Player()
    var waveUntil = 0.0
    var sayText: String?
    var sayUntil = 0.0
    var userControlUntil = 0.0
    var goLamp = false

    // Easter eggs (see PixelRenderer+Extras.swift)
    var shiftHeld = false
    var debugConstellations = ProcessInfo.processInfo.environment["APNUM_SKY_DEBUG"] == "constellations"
    var constellations: [ProjectedConstellation] = []
    var hoverConstellation: Int?
    var tip: (text: String, x: Double, y: Double)?
    var game = FireflyGame()
    var horror = false
    var horrorChecked = -1
    var horrorState = HorrorState()

    // Interaction
    var pointerX = 0.5
    var pointerY = 0.4
    var pointerActive = false
    var cam = 0.0

    // Time
    var time = 0.0
    var lastNow: Date?
    var random = PixelRandom()
    var animatedFrames = false

    // MARK: Frame

    /// Renders one frame for `size` points. When `animated` is false the scene holds still.
    func render(scene newScene: SkyScene, size: CGSize, now: Date, animated: Bool) -> Output? {
        let w = max(80, Int((size.width / CGFloat(scale)).rounded(.up)))
        let h = max(60, Int((size.height / CGFloat(scale)).rounded(.up)))
        scene = newScene
        refreshHorror(now: now)
        let print = Self.fingerprint(of: newScene, width: w, height: h, horror: horror)
        if w != W || h != H {
            W = w
            H = h
            build()
        }
        if print != fingerprint {
            fingerprint = print
            Perf.measure("bake") { bake() }
        }
        var dt = 0.0
        if let last = lastNow { dt = min(0.05, max(0, now.timeIntervalSince(last))) }
        lastNow = now
        animatedFrames = animated
        if animated {
            time += dt
            step(dt)
        }
        composite()
        guard let image = frame.makeImage(opaque: true) else { return nil }
        return Output(image: image, width: W, height: H)
    }

    static func fingerprint(of s: SkyScene, width: Int, height: Int, horror: Bool = false) -> Fingerprint {
        func q(_ rad: Double) -> Int { Int((rad * 180 / .pi * 10).rounded()) }
        return Fingerprint(
            width: width, height: height, palette: s.palette,
            sunAlt: q(s.sun.altitude), sunAz: q(s.sun.azimuth), moonAlt: q(s.moon.altitude), moonAz: q(s.moon.azimuth),
            phase: Int((s.moonPhase * 1000).rounded()), kind: s.weather.kind,
            cloud: Int((s.weather.cloudCover * 100).rounded()), wind: Int(s.weather.windKmh.rounded()),
            stars: s.stars.count, planets: s.planets.count, milky: s.milkyWay.count,
            blood: Int((s.bloodMoon * 100).rounded()), supermoon: s.supermoon, horror: horror)
    }

    // MARK: Build (size changes)

    private func build() {
        let len = W + rangePad * 2
        let h = Double(H)
        let configs = [
            PixelRangeConfig(base: h * 0.7, amp: h * 0.1, scale: 70, rough: 0.45, sharp: 1.2),
            PixelRangeConfig(base: h * 0.77, amp: h * 0.13, scale: 110, rough: 0.42, sharp: 1.5, rim: true),
            PixelRangeConfig(base: h * 0.85, amp: h * 0.07, scale: 90, rough: 0.4, sharp: 1.1),
            PixelRangeConfig(base: h * 0.91, amp: h * 0.045, scale: 70, rough: 0.4, sharp: 1),
        ]
        ranges = configs.enumerated().map { PixelRange(width: len, config: $1, seed: Self.rangeSeed + $0) }
        propItems = pixelLayoutProps(width: W)
        var rand = PixelNoise(seed: 1234)
        grassEdge = (0..<W).map { x in
            let n = sin(Double(x) * 0.21) + sin(Double(x) * 0.07 + 2) + (rand.next() < 0.12 ? 1.6 : 0)
            return max(0, Int(n.rounded()))
        }
        let count = max(24, Int((Double(W) / 9).rounded()))
        flies = (0..<count).map { i in
            let hx = (Double(i) + rand.next() * 0.8) / Double(count) * Double(W)
            let hy = h * (0.3 + rand.next() * 0.62)
            return Fly(hx: hx, hy: hy, x: hx, y: hy, p: rand.next() * 10)
        }
        player.y = Double(groundY - PixelCharacter.height)
        player.x = min(player.x, Double(W - 10))
        frame = PixelLayer(width: W, height: H)
        cloudKey = ""
    }

    // MARK: Bake (scene changes)

    private func bake() {
        guard let scene = tintedScene else { return }
        palette = scene.palette
        night = scene.night
        overcast = scene.overcast
        wet = scene.wet
        weatherKind = scene.weather.kind
        wind = scene.weather.windKmh
        // A switched lamp goes back to automatic once it agrees with the time of day.
        if let forced = lampForced, forced == (night > 0.08) { lampForced = nil }

        let source = scene.sun.altitude > 0 ? scene.sun : scene.moon.altitude > 0 ? scene.moon : nil
        lightFromLeft = source.map { project($0).x < W / 2 } ?? true

        bakeSkyLayer(scene)
        placeStars(scene)
        placeConstellations(scene)
        makeClouds()
        makeRain()
        bakeMountains()
        bakeGround()
        bakeFog()
        radiant = scene.meteorRadiant.map { r in
            let p = skyXY(r)
            return (p.x, p.y)
        }
        updateHover()
    }

    private func bakeMountains() {
        let p = palette
        let specs: [(RGB, RGB, Int)] = [
            (p.far, p.far.mix(p.mid, 0.25), 6),
            (p.peak, p.peakShade, 12),
            (p.mid, p.mid.mix(p.ground, 0.3), 8),
            (p.near, p.near.mix(p.ground, 0.35), 6),
        ]
        rangeLayers = zip(ranges, specs).map { range, spec in
            range.bake(height: H, color: spec.0, shade: spec.1, rimColor: p.rim, depth: spec.2, lightFromLeft: lightFromLeft)
        }
    }

    /// Ground strip and scenery, lit for the time of day and weather.
    func bakeGround() {
        guard let scene = tintedScene else { return }
        var layer = PixelLayer(width: W, height: H)
        let gy = groundY
        let ground = palette.ground.packed
        layer.fillRect(0, gy, W, H - gy, ground)
        for x in 0..<min(W, grassEdge.count) where grassEdge[x] > 0 {
            layer.fillRect(x, gy - grassEdge[x], 1, grassEdge[x], ground)
        }
        let light = PixelLighting(scene: scene, props: propItems, groundY: gy, lampForced: lampForced)
        pixelDrawProps(into: &layer, items: propItems, groundY: gy, light: light)
        lighting = light
        groundLayer = layer
    }

    /// Fog: see-through bands that thicken towards the valleys, plus a few long wisps that drift sideways.
    private func bakeFog() {
        fogStrength = weatherKind == .fog ? 1 : wet > 0 ? 0.3 : 0
        fogOn = fogStrength > 0
        guard fogOn else {
            wisps = []
            return
        }
        fogColour = palette.haze.mix(RGB(hex: "#e4e8ee"), 0.45 - night * 0.3)
        var layer = PixelLayer(width: W, height: H)
        let px = fogColour.packed
        let y0 = Int((Double(H) * 0.58).rounded())
        var y = y0
        while y < H {
            let a = min(1, Double(y - y0) / (Double(H) * 0.28)) * 0.32 * fogStrength
            layer.fillRect(0, y, W, 2, px, Int((a * 255).rounded()))
            y += 2
        }
        fogLayer = layer
        var rand = PixelNoise(seed: 99)
        wisps = (0..<(Int((6 * fogStrength).rounded()) + 2)).map { _ in
            Wisp(
                x: rand.next() * Double(W), y: Int((Double(H) * (0.6 + rand.next() * 0.25)).rounded()),
                w: Int((30 + rand.next() * 70).rounded()), v: 1 + rand.next() * 2)
        }
    }

    /// More, bigger, faster clouds as cover and wind rise; the layout survives re-bakes so clouds do not jump.
    private func makeClouds() {
        guard let scene else { return }
        let cover = scene.weather.cloudCover
        let thin = 1 - 0.65 * night
        let count = max(1, Int((Double(W) / 70 * thin).rounded()))
            + Int((cover * cover * (Double(W) / 20) * (1 - 0.4 * night)).rounded())
        let key = "\(W)x\(H)/\(count)/\(Int(cover * 20))/\(Int(wind / 4))"
        if key != cloudKey {
            cloudKey = key
            var rand = PixelNoise(seed: 777)
            let windy = 1 + wind / 20
            clouds = (0..<count).map { i in
                let w = Int((18 + rand.next() * (30 + cover * 40)).rounded())
                return PixelCloud(
                    x: rand.next() * Double(W + 60) - 30, y: Int((Double(H) * (0.04 + rand.next() * 0.38)).rounded()), w: w,
                    h: Int((Double(w) * 0.42).rounded()) + 4, seed: 1 + Int(rand.next() * 1e6),
                    v: (1.2 + rand.next() * 2.4 + Double(i) * 0.05) * windy,
                    image: PixelLayer(width: 1, height: 1))
            }
        }
        let light = palette.cloudLight.mix(.white, 0.25 * (1 - night))
        let shade = palette.cloud.mix(palette.skyTop, 0.35)
        for i in clouds.indices {
            clouds[i].image = pixelBakeCloud(
                w: clouds[i].w, h: clouds[i].h, seed: clouds[i].seed, light: light, body: palette.cloud, shade: shade)
        }
    }

    private func makeRain() {
        let rate: Double = [.drizzle: 0.25, .rain: 0.6, .storm: 1][weatherKind] ?? 0
        var rand = PixelNoise(seed: 4321)
        drops = (0..<Int((Double(W) * 0.5 * rate).rounded())).map { _ in
            Drop(
                x: rand.next() * Double(W), y: rand.next() * Double(H),
                v: weatherKind == .drizzle ? 55 + rand.next() * 25 : 100 + rand.next() * 60,
                len: weatherKind == .drizzle ? 1 : 2 + Int(rand.next().rounded()))
        }
        splashes = []
    }

    // MARK: Composite

    private func composite() {
        frame.data = skyLayer.data
        drawStars()
        drawConstellations()
        for c in clouds { c.image.blit(into: &frame, ox: Int(c.x.rounded()), oy: c.y) }
        drawMeteors()
        drawRange(0)
        drawRange(1)
        if fogOn { drawFog(255) }
        drawRange(2)
        drawRange(3)
        if fogOn { drawFog(102) }
        groundLayer.blit(into: &frame, ox: 0, oy: 0)
        drawPlayer()
        drawFlies()
        drawGame()
        drawRain()
        drawHorror()
    }

    private func drawRange(_ i: Int) {
        guard i < rangeLayers.count else { return }
        let offset = Int((Double(rangePad) + cam * rangeDepth[i] * -Double(rangePad)).rounded())
        rangeLayers[i].blit(into: &frame, ox: -offset, oy: 0, fromRow: max(0, ranges[i].minTop))
    }

    private func drawFog(_ alpha: Int) {
        fogLayer.blit(into: &frame, ox: 0, oy: 0, alpha: alpha)
        let px = fogColour.packed
        let a = Int((0.14 * fogStrength * Double(alpha) / 255 * 255).rounded())
        for w in wisps {
            let x = Int(w.x.rounded())
            frame.fillRect(x, w.y, w.w, 2, px, a)
            frame.fillRect(x + 6, w.y - 1, max(0, w.w - 12), 1, px, a)
        }
    }

    // MARK: Per-frame update

    private func step(_ dt: Double) {
        cam += (pointerX - 0.5 - cam) * (1 - exp(-dt * 4))
        for i in clouds.indices {
            clouds[i].x += clouds[i].v * dt
            if clouds[i].x > Double(W + 10) { clouds[i].x = Double(-clouds[i].w - 10) }
        }
        updateMeteors(dt)
        updateGame(dt)
        updateHorror(dt)
        updatePlayer(dt)
        if night > 0.01 { updateFlies(dt) }
        updateRain(dt)
        for i in wisps.indices {
            wisps[i].x += wisps[i].v * dt
            if wisps[i].x > Double(W) { wisps[i].x = Double(-wisps[i].w) }
        }
    }
}
