import ApnumSky
import Foundation

private let bayer4: [Double] = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5].map { ($0 + 0.5) / 16 }
private let skyTopAltitude = 82.0

extension PixelRenderer {
    /// Sky projection shared by sun, moon, stars and Milky Way: azimuth maps linearly across a 240 degree
    /// view facing south (east on the left), altitude 0...82 degrees up from the horizon at 0.68 H.
    func skyXY(_ body: HorizontalPosition) -> (x: Double, y: Double, alt: Double) {
        let horizon = Double(H) * 0.68
        let alt = body.altitudeDegrees
        let x = Double(W) * (0.5 + (body.azimuth / (2 * .pi / 3)) * 0.5)
        return (x, horizon - (alt / skyTopAltitude) * horizon, alt)
    }

    func project(_ body: HorizontalPosition) -> (x: Int, y: Int) {
        let p = skyXY(body)
        return (Int(p.x.rounded()), Int(max(Double(H) * 0.06, p.y).rounded()))
    }

    func bakeSkyLayer(_ scene: SkyScene) {
        var layer = PixelLayer(width: W, height: H, fill: 0xFF00_0000)
        drawBands(into: &layer)
        drawMilkyWay(into: &layer, scene)
        drawSun(into: &layer, scene)
        drawMoon(into: &layer, scene)
        skyLayer = layer
    }

    /// Blend the palette stops into 18 steps, then pick between neighbours with a 4x4 Bayer pattern: smooth
    /// to the eye, crisp pixels underneath.
    private func drawBands(into layer: inout PixelLayer) {
        let stops: [(Double, RGB)] = [(0, palette.skyTop), (0.38, palette.sky), (0.6, palette.skyLow), (0.74, palette.haze), (1, palette.haze)]
        func colour(at t: Double) -> RGB {
            var i = 0
            while i < stops.count - 2 && t > stops[i + 1].0 { i += 1 }
            let (a0, c0) = stops[i], (a1, c1) = stops[i + 1]
            return c0.mix(c1, min(max((t - a0) / (a1 - a0), 0), 1))
        }
        let steps = 18
        let levels = (0...steps).map { colour(at: Double($0) / Double(steps)).packed }
        for y in 0..<H {
            let pos = Double(y) / Double(H) * Double(steps)
            let lo = min(steps, Int(pos.rounded(.down)))
            let hi = min(steps, lo + 1)
            let frac = pos - Double(lo)
            for x in 0..<W {
                layer.data[y * W + x] = frac > bayer4[(y & 3) * 4 + (x & 3)] ? levels[hi] : levels[lo]
            }
        }
    }

    private func drawMilkyWay(into layer: inout PixelLayer, _ scene: SkyScene) {
        let blood = scene.bloodMoon > 0
        let moonWash = scene.moon.altitude > 0 && !blood ? scene.moonFraction * 0.9 : 0
        let strength = night * night * (1 - moonWash) * max(0, 1 - overcast * 1.3)
        guard strength >= 0.05 else { return }
        let px = RGB(hex: "#d9d2ff").packed
        for point in scene.milkyWay {
            let p = skyXY(point.position)
            guard p.alt >= 2, p.x >= 0, p.x < Double(W), p.y >= 0 else { continue }
            let a = (0.05 + 0.1 * point.weight) * strength * min(1, p.alt / 15)
            layer.plot(Int(p.x.rounded()), Int(p.y.rounded()), px, Int((a * 255).rounded()))
        }
    }

    private func drawSun(into layer: inout PixelLayer, _ scene: SkyScene) {
        guard scene.sun.altitude >= -0.05 else { return }
        let (x, y) = project(scene.sun)
        let alt = scene.sunAltitudeDegrees
        let low = min(max(1 - alt / 12, 0), 1)
        let r = Int((Double(min(W, H)) * (0.07 + 0.03 * low)).rounded())
        let core = RGB(hex: low > 0.5 ? "#ffd9a0" : "#fff6e3").packed
        let veil = max(0.15, 1 - max(0, overcast - 0.5) * 1.7)
        let haze = palette.haze.packed
        for (rr, a) in [(r + 6, 0.12), (r + 3, 0.22)] {
            layer.disc(x, y, rr, alpha: a * veil) { _, _ in (haze, 1) }
        }
        layer.disc(x, y, r, alpha: veil) { _, _ in (core, 1) }
    }

    static func moonColour(altitudeDegrees alt: Double, blood: Double) -> RGB {
        if blood > 0 { return RGB(hex: "#fff6e3").mix(RGB(hex: "#b83a24"), blood) }
        if alt < 4 { return RGB(hex: "#ff8a4c").mix(RGB(hex: "#ffc27a"), max(0, alt) / 4) }
        if alt < 14 { return RGB(hex: "#ffc27a").mix(RGB(hex: "#fff6e3"), (alt - 4) / 10) }
        return RGB(hex: "#fff6e3")
    }

    private func drawMoon(into layer: inout PixelLayer, _ scene: SkyScene) {
        guard scene.moon.altitude >= -0.05 else { return }
        let (x, y) = project(scene.moon)
        let r = Int((Double(min(W, H)) * (scene.supermoon ? 0.095 : 0.075)).rounded())
        let lit = Self.moonColour(altitudeDegrees: scene.moon.altitudeDegrees, blood: scene.bloodMoon)
        let glow: RGB? = scene.bloodMoon > 0 ? RGB(hex: "#c4402a") : scene.supermoon ? lit : nil
        if let glow, night > 0.2 {
            let strength = scene.bloodMoon > 0 ? scene.bloodMoon : 1
            let g = glow.packed
            for (rr, a) in [(r + 7, 0.08), (r + 3, 0.16)] {
                layer.disc(x, y, rr, alpha: a * night * strength) { _, _ in (g, 1) }
            }
        }
        // Terminator: k runs 1 (new) to -1 (full) and back.
        let k = cos(2 * .pi * scene.moonPhase)
        let waxing = scene.moonPhase < 0.5
        let dark = night > 0.3 ? RGB(90 / 255, 84 / 255, 130 / 255).packed : nil
        let litPx = lit.packed
        let marePx = RGB(lit.r * 0.88, lit.g * 0.88, lit.b * 0.88).packed
        let alpha = (0.55 + 0.45 * night) * max(0.15, 1 - max(0, overcast - 0.5) * 1.7)
        layer.disc(x, y, r, alpha: alpha) { nx, ny in
            let isLit = waxing ? nx > k : nx < -k
            if !isLit { return dark.map { ($0, 0.3) } }
            let mare = (nx + 0.3) * (nx + 0.3) + (ny + 0.2) * (ny + 0.2) < 0.06
                || (nx - 0.25) * (nx - 0.25) + (ny - 0.35) * (ny - 0.35) < 0.04
            return (mare ? marePx : litPx, 1)
        }
    }

    // MARK: Stars and planets

    func placeStars(_ scene: SkyScene) {
        stars = []
        planets = []
        guard night > 0.02 else { return }
        let blood = scene.bloodMoon > 0
        let glare = scene.moon.altitude > 0 && !blood ? scene.moonFraction * 1.6 : 0
        // Naked-eye limit: about magnitude 5 on a dark night, less with a bright moon or cloud.
        let limit = night * 5 - glare - overcast * 4.5
        let clear = max(0, 1 - overcast * 1.1)
        if clear > 0.1 {
            for pl in scene.planets {
                let p = skyXY(pl.position)
                guard p.alt >= 1, p.alt <= skyTopAltitude, p.x >= 0, p.x < Double(W) else { continue }
                let need = pl.magnitude < -3 ? 0.04 : 0.15
                guard night >= need else { continue }
                let a = min(1, (night - need) * 3 + 0.4) * min(1, p.alt / 6) * clear
                planets.append(Planet(x: Int(p.x.rounded()), y: Int(p.y.rounded()), a: a, color: pl.color.packed, mag: pl.magnitude, name: pl.name))
            }
        }
        for s in scene.stars where s.magnitude <= limit {
            let p = skyXY(s.position)
            guard p.alt >= 1, p.alt <= skyTopAltitude, p.x >= 0, p.x < Double(W) else { continue }
            let fade = min(1, p.alt / 10)
            let key1 = s.colorIndex, key2 = s.magnitude
            stars.append(Star(
                x: Int(p.x.rounded()), y: Int(p.y.rounded()),
                a: max(0.18, min(1, (limit - s.magnitude) / 1.8)) * night * fade,
                color: s.color.packed, big: s.magnitude < 1.3,
                // Scintillation grows with the air the light crosses; about a third of stars visibly twinkle.
                tw: pixelHash(key1, key2) < 0.35 ? 0.18 + 0.5 * pow(1 - p.alt / skyTopAltitude, 2) : 0.04,
                f1: 2.1 + pixelHash(key2, key1) * 3.2, f2: 5.3 + pixelHash(key1 + 1, key2) * 4.1,
                p: pixelHash(key2 + 2, key1) * 100, name: s.name))
        }
    }

    func drawStars() {
        guard !stars.isEmpty || !planets.isEmpty else { return }
        let t = time
        for s in stars {
            let n = 0.6 * sin(t * s.f1 + s.p) + 0.4 * sin(t * s.f2 + s.p * 1.7)
            let tw = animatedFrames ? max(0, 1 - s.tw * (0.5 + 0.5 * n)) : 1
            let a = s.a * tw
            frame.plot(s.x, s.y, s.color, Int((a * 255).rounded()))
            if s.big {
                let c = Int((a * 0.4 * 255).rounded())
                frame.plot(s.x - 1, s.y, s.color, c)
                frame.plot(s.x + 1, s.y, s.color, c)
                frame.plot(s.x, s.y - 1, s.color, c)
                frame.plot(s.x, s.y + 1, s.color, c)
            }
        }
        for p in planets {
            frame.plot(p.x, p.y, p.color, Int((p.a * 255).rounded()))
            if p.mag < -1.5 {
                let c = Int((p.a * 0.5 * 255).rounded())
                for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] { frame.plot(p.x + dx, p.y + dy, p.color, c) }
            }
            if p.mag < -3.5 {
                let c = Int((p.a * 0.2 * 255).rounded())
                for (dx, dy) in [(-2, 0), (2, 0), (0, -2), (0, 2)] { frame.plot(p.x + dx, p.y + dy, p.color, c) }
            }
        }
    }
}
