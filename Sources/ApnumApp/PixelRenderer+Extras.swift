import ApnumSky
import CoreGraphics
import Foundation

// The scene's easter eggs and interactive extras: constellations on Shift, hover names, the Konami firefly
// game and the rare late-night horror mode. Everything here is idle (and free) unless it is switched on.

struct ProjectedConstellation {
    struct Point {
        var x: Double, y: Double, alt: Double
    }
    var name: String
    var wiki: String?
    var lines: [[Point]]
}

struct FireflyGame {
    struct Orb {
        var x: Double, y: Double, p: Double
    }
    var on = false
    var until = 0.0
    var score = 0
    var orbs: [Orb] = []
    static let bestKey = "apnumFireflyBest"
    static let duration = 30.0
    static let orbCount = 5
}

struct HorrorState {
    var whisperAt = 0.0
    var whisperIndex = 0
    var glitchUntil = 0.0
    var nextGlitch = 0.0
    var flickerOff = false
    /// The current speech bubble is a whisper (drawn red).
    var red = false
}

extension PixelRenderer {
    /// Drawn once per launch: horror happens on about one launch in fifty, and only between 2:00 and 3:59.
    static let horrorRoll = Double.random(in: 0..<1)
    static let horrorForced = ProcessInfo.processInfo.environment["APNUM_HORROR"] == "1"

    // MARK: Constellations

    var overlayOn: Bool { shiftHeld || debugConstellations }

    /// Projects the visible stick figures into scene pixels (called when the scene changes).
    func placeConstellations(_ scene: SkyScene) {
        constellations = []
        hoverConstellation = nil
        guard night > 0.02 else { return }
        constellations = scene.constellations.map { fig in
            ProjectedConstellation(
                name: fig.name, wiki: fig.wiki,
                lines: fig.lines.map { line in
                    line.map { pos in
                        let p = skyXY(pos)
                        return ProjectedConstellation.Point(x: p.x, y: p.y, alt: p.alt)
                    }
                })
        }
    }

    /// Calls `body` for every drawable segment (both ends above the horizon, not wrapped across the view).
    private func forEachSegment(_ c: ProjectedConstellation, _ body: (ProjectedConstellation.Point, ProjectedConstellation.Point) -> Void) {
        for line in c.lines where line.count > 1 {
            for i in 1..<line.count {
                let a = line[i - 1], b = line[i]
                if a.alt < 0 || b.alt < 0 || abs(a.x - b.x) > Double(W) * 0.5 { continue }
                body(a, b)
            }
        }
    }

    private func drawLines(_ c: ProjectedConstellation, alpha: Double) {
        let px = RGB(hex: "#a9b8ff").packed
        let a = Int((alpha * 255).rounded())
        guard a > 0 else { return }
        forEachSegment(c) { p, q in
            let n = max(Int(abs(q.x - p.x).rounded()), Int(abs(q.y - p.y).rounded()), 1)
            var k = 0
            while k <= n {
                let t = Double(k) / Double(n)
                frame.plot(Int((p.x + (q.x - p.x) * t).rounded()), Int((p.y + (q.y - p.y) * t).rounded()), px, a)
                k += 2
            }
        }
    }

    func drawConstellations() {
        guard overlayOn, night > 0.01 else { return }
        for c in constellations { drawLines(c, alpha: 0.22 * night) }
        if let i = hoverConstellation, i < constellations.count { drawLines(constellations[i], alpha: 0.5 * night) }
    }

    private func distance(_ x: Double, _ y: Double, to c: ProjectedConstellation) -> Double {
        var best = Double.infinity
        forEachSegment(c) { p, q in
            let dx = q.x - p.x, dy = q.y - p.y
            let len2 = dx * dx + dy * dy
            let t = len2 > 0 ? min(1, max(0, ((x - p.x) * dx + (y - p.y) * dy) / len2)) : 0
            best = min(best, hypot(x - (p.x + dx * t), y - (p.y + dy * t)))
        }
        return best
    }

    // MARK: Hover names

    /// Finds what the pointer is on: a planet or named bright star, else (with Shift) a constellation.
    func updateHover() {
        hoverConstellation = nil
        tip = nil
        guard pointerActive, W > 0 else {
            debugHighlight()
            return
        }
        let lx = pointerX * Double(W), ly = pointerY * Double(H)
        let k = Double(scale)
        var best: (d: Double, text: String, x: Double, y: Double)?
        func consider(_ x: Int, _ y: Int, _ name: String) {
            let d = hypot(Double(x) - lx, Double(y) - ly)
            if d < 3, d < (best?.d ?? .infinity) { best = (d, name, Double(x), Double(y)) }
        }
        for p in planets where !p.name.isEmpty { consider(p.x, p.y, p.name) }
        for s in stars { if let name = s.name { consider(s.x, s.y, name) } }
        if let best {
            tip = (best.text, best.x * k, best.y * k)
            return
        }
        guard overlayOn, night > 0.3, overcast < 0.85 else { return }
        var nearest: (d: Double, i: Int)?
        for (i, c) in constellations.enumerated() {
            let d = distance(lx, ly, to: c)
            if d < 4, d < (nearest?.d ?? .infinity) { nearest = (d, i) }
        }
        if let nearest {
            hoverConstellation = nearest.i
            tip = (constellations[nearest.i].name, lx * k, ly * k)
        }
    }

    /// Shift state from the view; true when the drawing or label changed.
    func setShift(_ held: Bool) {
        guard held != shiftHeld else { return }
        shiftHeld = held
        updateHover()
    }

    /// The Wikipedia article of the constellation under the pointer (Shift-click).
    func hoveredConstellationURL() -> URL? {
        guard let i = hoverConstellation, i < constellations.count, let wiki = constellations[i].wiki else { return nil }
        return URL(string: "https://en.wikipedia.org/wiki/" + wiki)
    }

    /// Debug (APNUM_SKY_DEBUG=constellations): the overlay is on and one figure is highlighted with its label.
    func debugHighlight() {
        guard debugConstellations, hoverConstellation == nil, !constellations.isEmpty else { return }
        let i = constellations.indices.max { constellations[$0].lines.count < constellations[$1].lines.count } ?? 0
        hoverConstellation = i
        if let line = constellations[i].lines.first, let p = line.dropFirst(line.count / 2).first {
            tip = (constellations[i].name, p.x * Double(scale), p.y * Double(scale))
        }
    }

    // MARK: Firefly game

    func startGame() {
        guard !game.on else { return }
        standUp()
        player.target = nil
        game.on = true
        game.until = time + FireflyGame.duration
        game.score = 0
        game.orbs = (0..<FireflyGame.orbCount).map { _ in spawnOrb() }
        say("Catch the fireflies! Click to walk.", seconds: 3.5)
    }

    private func spawnOrb() -> FireflyGame.Orb {
        FireflyGame.Orb(
            x: 6 + random.unit() * Double(max(1, W - 12)), y: Double(groundY) - 6 - random.unit() * 20, p: random.unit() * 6)
    }

    func updateGame(_ dt: Double) {
        guard game.on else { return }
        userControlUntil = time + 1
        let cx = player.x + 4, cy = player.y + 5
        let floorY = Double(groundY)
        for i in game.orbs.indices {
            var o = game.orbs[i]
            // A slow lazy drift, different for every orb.
            o.x = min(Double(W) - 4, max(4, o.x + cos(time * 0.6 + o.p * 2.3) * 7 * dt))
            o.y = min(floorY - 5, max(floorY - 26, o.y + sin(time * 0.8 + o.p * 1.7) * 5 * dt))
            if abs(o.x - cx) < 5, abs(o.y - cy) < 7 {
                game.score += 1
                o = spawnOrb()
            }
            game.orbs[i] = o
        }
        if time > game.until {
            game.on = false
            let defaults = UserDefaults.standard
            let best = max(defaults.integer(forKey: FireflyGame.bestKey), game.score)
            defaults.set(best, forKey: FireflyGame.bestKey)
            say("\(game.score) \(game.score == 1 ? "firefly" : "fireflies")! Best: \(best)", seconds: 4.5)
        }
    }

    /// The gold HUD text while a game runs.
    func hudText() -> String? {
        guard game.on else { return nil }
        return "\(game.score) caught, \(max(0, Int((game.until - time).rounded(.up))))s left"
    }

    func drawGame() {
        guard game.on else { return }
        let glow = RGB(hex: horror ? "#ff5a4f" : "#ffe9a8").packed
        let core = RGB(hex: horror ? "#ff8a7a" : "#ffd77a").packed
        for o in game.orbs {
            let pulse = 0.6 + 0.4 * sin(time * 6 + o.p)
            let x = Int(o.x.rounded()), y = Int(o.y.rounded())
            frame.fillRect(x - 2, y - 2, 5, 5, glow, Int((0.25 * pulse * 255).rounded()))
            frame.fillRect(x - 1, y - 1, 2, 2, core)
        }
    }

    // MARK: Horror

    func refreshHorror(now: Date) {
        let bucket = Int(now.timeIntervalSince1970 / 30)
        guard bucket != horrorChecked else { return }
        horrorChecked = bucket
        let active = HorrorMode.isActive(now: now, roll: Self.horrorRoll, forced: Self.horrorForced)
        guard active != horror else { return }
        horror = active
        horrorState = HorrorState(whisperAt: time + 2.5, nextGlitch: time + 4)
    }

    /// The scene with the palette drained towards a sick red when horror is on.
    var tintedScene: SkyScene? {
        guard var s = scene else { return nil }
        if horror { s.palette = s.palette.weatherTinted(overcast: 0.5, wet: 0.4).bloodTinted(0.45) }
        return s
    }

    func updateHorror(_ dt: Double) {
        guard horror else { return }
        if time > horrorState.whisperAt, !game.on {
            let lines = HorrorMode.whispers
            say(lines[horrorState.whisperIndex % lines.count], seconds: 4.2, red: true)
            horrorState.whisperIndex += 1
            horrorState.whisperAt = time + 9 + random.unit() * 6
        }
        horrorState.flickerOff = random.unit() < (horrorState.flickerOff ? 0.5 : 0.04)
        if time > horrorState.nextGlitch {
            horrorState.glitchUntil = time + 0.12 + random.unit() * 0.12
            horrorState.nextGlitch = time + 4 + random.unit() * 6
        }
    }

    func drawHorror() {
        guard horror else { return }
        if horrorState.flickerOff, let lamp = propItems.first(where: { $0.lamp }) {
            frame.fillRect(lamp.x - 14, groundY - 34, 33, 34, RGB(hex: "#05020a").packed, 153)
        }
        // Glitch slices only happen while animating, so Reduce Motion never sees them.
        guard animatedFrames, time < horrorState.glitchUntil else { return }
        for _ in 0..<4 {
            let y = Int(random.unit() * Double(H))
            let h = 1 + Int(random.unit() * 4)
            let dx = Int(((random.unit() - 0.5) * 10).rounded())
            guard dx != 0 else { continue }
            for yy in y..<min(H, y + h) {
                let row = Array(frame.data[(yy * W)..<((yy + 1) * W)])
                for x in 0..<W {
                    let sx = x - dx
                    if sx >= 0, sx < W { frame.data[yy * W + x] = row[sx] }
                }
            }
        }
        frame.fillRect(0, 0, W, H, RGB(hex: "#ff2a2a").packed, 15)
    }
}
