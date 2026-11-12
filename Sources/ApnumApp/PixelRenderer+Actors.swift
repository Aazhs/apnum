import ApnumSky
import CoreGraphics
import Foundation

// Everything that moves: meteors, rain and lightning, fireflies, the character, and pointer interaction.

extension PixelRenderer {
    // MARK: Meteors

    func updateMeteors(_ dt: Double) {
        let rate = scene?.meteorsPerMinute ?? 0
        if night > 0.5, overcast < 0.6, meteors.count < 8, random.unit() < rate / 60 * dt {
            let x = random.unit() * Double(W)
            let y = Double(H) * (0.05 + random.unit() * 0.4)
            var dx = random.unit() < 0.5 ? 1.0 : -1.0, dy = 0.5
            if let r = radiant, random.unit() < 0.85 {
                dx = x - r.x
                dy = y - r.y
            }
            let len = hypot(dx, dy)
            let speed = 110 + random.unit() * 60
            let life = 0.6 + random.unit() * 0.5
            meteors.append(Meteor(
                x: x, y: y, vx: dx / max(len, 0.001) * speed, vy: dy / max(len, 0.001) * speed, life: life, maxLife: life,
                bright: random.unit() < 0.3))
        }
        for i in meteors.indices {
            meteors[i].x += meteors[i].vx * dt
            meteors[i].y += meteors[i].vy * dt
            meteors[i].life -= dt
        }
        meteors.removeAll { $0.life <= 0 }
    }

    func drawMeteors() {
        let px = RGB(hex: "#fff6e3").packed
        let vis = max(night, 0.45)
        for m in meteors {
            let fade = min(1, m.life / (m.maxLife * 0.4)) * vis
            let sp = hypot(m.vx, m.vy)
            let trail = m.bright ? 16 : 11
            for i in 0..<trail {
                let a = (1 - Double(i) / Double(trail)) * fade
                frame.plot(
                    Int((m.x - m.vx / sp * Double(i) * 1.4).rounded()), Int((m.y - m.vy / sp * Double(i) * 1.4).rounded()), px,
                    Int((a * 255).rounded()))
            }
            if m.bright {
                let a = Int((fade * 0.5 * 255).rounded())
                frame.plot(Int(m.x.rounded()) - 1, Int(m.y.rounded()), px, a)
                frame.plot(Int(m.x.rounded()), Int(m.y.rounded()) - 1, px, a)
            }
        }
    }

    // MARK: Rain and lightning

    func updateRain(_ dt: Double) {
        guard !drops.isEmpty else { return }
        let gy = Double(groundY)
        let slant = wind / 60
        for i in drops.indices {
            drops[i].y += drops[i].v * dt
            drops[i].x += drops[i].v * dt * slant
            if drops[i].y >= gy {
                if splashes.count < 60 { splashes.append(Splash(x: Int(drops[i].x.rounded()), life: 0.14)) }
                drops[i].y = -random.unit() * 20
                drops[i].x = random.unit() * Double(W + 20) - 20
            }
        }
        for i in splashes.indices { splashes[i].life -= dt }
        splashes.removeAll { $0.life <= 0 }
        if weatherKind == .storm {
            if nextBolt == 0 { nextBolt = time + 4 + random.unit() * 8 }
            if time > nextBolt {
                var path = [(Int((Double(W) * (0.15 + random.unit() * 0.7)).rounded()), Int((Double(H) * 0.06).rounded()))]
                while Double(path[path.count - 1].1) < Double(H) * 0.6 {
                    let (px, py) = path[path.count - 1]
                    path.append((px + Int((random.unit() * 8 - 4).rounded()), py + 3 + Int((random.unit() * 4).rounded())))
                }
                bolt = Bolt(path: path, life: 0.2)
                nextBolt = time + 5 + random.unit() * 12
            }
            if var b = bolt {
                b.life -= dt
                bolt = b.life <= 0 ? nil : b
            }
        }
    }

    func drawRain() {
        if let b = bolt {
            frame.fillRect(0, 0, W, H, RGB(hex: "#e8ecff").packed, Int((0.12 * b.life / 0.2 * 255).rounded()))
            let bolt = RGB(hex: "#f4f1ff").packed
            let a = Int((min(1, b.life * 8) * 255).rounded())
            for i in 1..<b.path.count {
                let (x0, y0) = b.path[i - 1], (x1, y1) = b.path[i]
                let n = max(abs(x1 - x0), abs(y1 - y0), 1)
                for k in 0...n {
                    frame.plot(x0 + (x1 - x0) * k / n, y0 + (y1 - y0) * k / n, bolt, a)
                }
            }
        }
        guard !drops.isEmpty else { return }
        let gy = groundY
        let px = RGB(hex: "#c4d2e6").packed
        let a = Int(((0.38 - night * 0.12) * 255).rounded())
        for d in drops { frame.fillRect(Int(d.x.rounded()), Int(d.y.rounded()), 1, d.len, px, a) }
        for s in splashes {
            let sa = Int((s.life / 0.14 * 0.5 * 255).rounded())
            frame.plot(s.x - 1, gy - 1, px, sa)
            frame.plot(s.x + 1, gy - 1, px, sa)
        }
    }

    // MARK: Fireflies

    func updateFlies(_ dt: Double) {
        let px = pointerX * Double(W), py = pointerY * Double(H)
        let t = time
        for i in flies.indices {
            var f = flies[i]
            let wobble = sin(t * 1.5 + f.p)
            var ax = cos(t * 0.7 + f.p * 3) * 6 + (f.hx - f.x) * 0.15
            var ay = wobble * 6 + (f.hy - f.y) * 0.15
            if pointerActive {
                let dx = px - f.x, dy = py - f.y
                let d = max(hypot(dx, dy), 0.001)
                if d < 60 {
                    ax += dx / d * 30
                    ay += dy / d * 30
                }
            }
            f.vx = (f.vx + ax * dt) * 0.96
            f.vy = (f.vy + ay * dt) * 0.96
            f.x = (f.x + f.vx * dt * 4 + Double(W)).truncatingRemainder(dividingBy: Double(W))
            f.y = max(Double(H) * 0.25, min(Double(H - 2), f.y + f.vy * dt * 4))
            flies[i] = f
        }
    }

    func drawFlies() {
        let dark = min(1, night * 1.5) * (1 - wet * 0.8)
        guard dark > 0.01 else { return }
        let px = RGB(hex: horror ? "#ff5a4f" : "#ffe9a8").packed
        for f in flies {
            let flicker = 0.45 + 0.55 * abs(sin(time * 3 + f.p))
            frame.plot(Int(f.x.rounded()), Int(f.y.rounded()), px, Int((min(1, dark * flicker) * 255).rounded()))
        }
    }

    // MARK: Character

    func standUp() {
        player.sitting = false
        player.goSit = false
    }

    private var characterFloor: Double { Double(groundY - PixelCharacter.height) }

    func updatePlayer(_ dt: Double) {
        let t = time
        if player.sitting {
            if t > player.sitUntil || t < userControlUntil {
                standUp()
                player.y = characterFloor
                player.wanderUntil = t + 1.5
            } else {
                player.vx = 0
                return
            }
        }
        var dir = 0.0
        if let target = player.target {
            let dx = target - player.x
            if abs(dx) < 1.5 {
                player.target = nil
                if player.goSit, let seat = pixelBenchSeat(propItems, groundY: groundY), player.grounded {
                    player.sitting = true
                    player.goSit = false
                    player.x = Double(seat.x)
                    player.y = Double(seat.seatY - 9)
                    player.sitUntil = t + 6 + random.unit() * 8
                    userControlUntil = 0
                    return
                }
                if goLamp {
                    goLamp = false
                    player.facing = 1
                }
            } else {
                dir = dx > 0 ? 1 : -1
            }
        } else if t > player.wanderUntil {
            if horror {
                // Trapped: drifts to the edge of the screen and stays there.
                player.target = random.unit() < 0.5 ? 2 : Double(W - 10)
                player.goSit = false
            } else if let seat = pixelBenchSeat(propItems, groundY: groundY), t > userControlUntil, random.unit() < 0.25 {
                player.target = Double(seat.x)
                player.goSit = true
            } else {
                player.target = random.unit() < 0.5 ? nil : 8 + random.unit() * Double(W - 20)
                player.goSit = false
            }
            player.wanderUntil = t + (horror ? 12 : 2.5) + random.unit() * (horror ? 8 : 4)
        }
        player.vx = dir * (horror ? 12 : 34)
        if dir != 0 { player.facing = dir }
        player.x = max(2, min(Double(W - 10), player.x + player.vx * dt))
        player.vy += 220 * dt
        player.y += player.vy * dt
        if player.y >= characterFloor {
            player.y = characterFloor
            player.vy = 0
            player.grounded = true
        }
        if dir != 0 && player.grounded { player.step += dt * 8 }
    }

    private func jump() {
        if player.sitting {
            standUp()
            player.y = characterFloor
        }
        if player.grounded {
            player.vy = -78
            player.grounded = false
        }
    }

    func drawPlayer() {
        let moving = player.vx != 0
        var rows = moving && player.grounded && Int(player.step) % 2 == 1 ? PixelCharacter.walk : PixelCharacter.idle
        if player.sitting {
            rows = PixelCharacter.sit
        } else if time < waveUntil {
            rows = Int(time / 0.2) % 2 == 1 ? PixelCharacter.arms : PixelCharacter.idle
        }
        let px = Int(player.x.rounded()), py = Int(player.y.rounded())
        let flip = player.facing < 0
        for (ry, row) in rows.enumerated() {
            for rx in 0..<row.count {
                let c = row[flip ? row.count - 1 - rx : rx]
                guard c != 46, let base = PixelCharacter.colours[c] else { continue }
                frame.set(px + rx, py + ry, lit(base, px + rx, py + ry))
            }
        }
        if wet > 0 {
            let umbrella = PixelSprites.umbrella
            for (ry, row) in umbrella.enumerated() {
                for (rx, c) in row.enumerated() where c != 46 {
                    let base = c == 82 ? PixelSprites.umbrellaRed : PixelSprites.umbrellaIron
                    let ux = px - 1 + rx, uy = py - umbrella.count + ry
                    frame.set(ux, uy, lit(base, ux, uy))
                }
            }
        }
    }

    /// The character uses the scene's light, a little brighter so it stays readable.
    private func lit(_ c: RGB, _ x: Int, _ y: Int) -> UInt32 {
        guard let lighting else { return c.packed }
        return lighting.colour(c, x: x, y: y, strength: 0.75).packed
    }

    // MARK: Pointer

    func hover(point: CGPoint?, size: CGSize) {
        guard let point, size.width > 0, size.height > 0 else {
            pointerActive = false
            updateHover()
            return
        }
        pointerX = min(max(Double(point.x / size.width), 0), 1)
        pointerY = min(max(Double(point.y / size.height), 0), 1)
        pointerActive = true
        updateHover()
    }

    func say(_ text: String, seconds: Double = 3, red: Bool = false) {
        horrorState.red = red
        sayText = text
        sayUntil = time + seconds
    }

    /// Speech bubble anchor in points, while one is showing.
    func bubble() -> (text: String, x: CGFloat, y: CGFloat)? {
        guard let text = sayText, time < sayUntil else { return nil }
        let k = CGFloat(scale)
        return (text, CGFloat(player.x + 4) * k, CGFloat(player.y - (wet > 0 ? 6 : 1)) * k)
    }

    private func hitPlayer(_ x: Double, _ y: Double) -> Bool {
        x >= player.x - 1 && x <= player.x + 9 && y >= player.y - 1 && y <= player.y + 12
    }

    private func hitProp(_ x: Double, _ y: Double) -> PixelProp? {
        propItems.first { it in
            guard it.bench || it.lamp else { return false }
            let b = it.box(groundY: groundY)
            return x >= Double(b.x0 - 1) && x <= Double(b.x1 + 1) && y >= Double(b.y0 - 2) && y <= Double(b.y1 + 1)
        }
    }

    /// A click at `point` (points, inside `size`). Returns true when the scene changed while it was not animating.
    func tap(point: CGPoint) {
        let sx = Double(point.x) / Double(scale), sy = Double(point.y) / Double(scale)
        if !hitPlayer(sx, sy) { sayText = nil }
        if hitPlayer(sx, sy) {
            let line = PixelCharacter.lines[Int(random.unit() * Double(PixelCharacter.lines.count)) % PixelCharacter.lines.count]
            waveUntil = time + 1.6
            say(line)
            return
        }
        player.wanderUntil = time + 8
        userControlUntil = time + 3
        if let prop = hitProp(sx, sy) {
            standUp()
            if prop.bench {
                player.target = pixelBenchSeat(propItems, groundY: groundY).map { Double($0.x) }
                player.goSit = true
            } else {
                // Flip the switch right away; the character wanders over to admire it.
                let on = lighting?.lampOn ?? false
                lampForced = !on
                bakeGround()
                player.target = Double(prop.x - 6)
            }
            return
        }
        standUp()
        player.target = max(2, min(Double(W - 10), sx - 4))
        jump()
    }
}
