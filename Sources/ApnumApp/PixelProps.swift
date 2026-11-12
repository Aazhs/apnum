import ApnumSky
import Foundation

// Ground scenery as pixel sprites (aarshj.me props.js). Each sprite is drawn in
// true daytime colours, then lit for the scene: warmed at golden hour, sunk into
// the night palette after dark, and lit warm by the lamp when it is on.

typealias PixelSprite = [[UInt8]]

func pixelSprite(_ rows: [String]) -> PixelSprite { rows.map { Array($0.utf8) } }

private let dayColours: [UInt8: RGB] = {
    let table: [(Character, String)] = [
        ("L", "#8fc46a"), ("M", "#5f9e4a"), ("D", "#3d7038"), ("T", "#7a5234"), ("t", "#553723"),
        ("C", "#3f444e"), ("G", "#dfe5ea"), ("P", "#6b7280"), ("p", "#474c57"), ("W", "#b07a4c"),
        ("w", "#7e5434"), ("I", "#3a3f4a"), ("F", "#b8865a"), ("f", "#8a5f3c"), ("K", "#9aa0a6"),
        ("k", "#6f757b"), ("R", "#e46a6a"), ("Y", "#f2c94c"), ("V", "#f5f0e6"), ("g", "#5f9e4a"),
        ("S", "#c08a58"), ("s", "#7e5434"),
    ]
    var out: [UInt8: RGB] = [:]
    for (k, hex) in table { out[k.asciiValue ?? 0] = RGB(hex: hex) }
    return out
}()

private func makeTree() -> PixelSprite {
    let w = 27, canopyH = 21
    let clusters: [(Double, Double, Double)] = [
        (13, 9, 7.5), (6.5, 12, 5.5), (20, 12, 5.5), (9.5, 5.5, 4.8), (17, 5.5, 4.8), (13, 14, 6.5), (3.5, 15, 3.2), (23, 15, 3.2),
    ]
    var rows: [[UInt8]] = []
    for y in 0..<canopyH {
        var row: [UInt8] = []
        for x in 0..<w {
            var best: (Double, Double, Double)?
            var bestD = 1.0
            for c in clusters {
                let d = hypot(Double(x) + 0.5 - c.0, Double(y) + 0.5 - c.1) / c.2
                if d < bestD {
                    bestD = d
                    best = c
                }
            }
            guard let b = best else {
                row.append(46)  // "."
                continue
            }
            let nx = (Double(x) + 0.5 - b.0) / b.2, ny = (Double(y) + 0.5 - b.1) / b.2
            let light = -(nx * 0.6 + ny * 0.8) - (y > canopyH - 5 ? 0.5 : 0)
            let speck = (x * 7 + y * 3) % 11 == 0
            let ch: Character = light > 0.38 ? (speck ? "M" : "L") : light < -0.28 ? (speck ? "M" : "D") : (speck ? "D" : "M")
            row.append(ch.asciiValue ?? 46)
        }
        rows.append(row)
    }
    let trunk = [
        "..........tT..T...........", "...........tTT............", "...........tTT............",
        "...........tTT............", "...........tTT............", "...........tTTT...........",
        "..........ttTTT...........", ".........tt...TT..........",
    ]
    return rows + pixelSprite(trunk.map { $0.padding(toLength: w, withPad: ".", startingAt: 0) })
}

enum PixelSprites {
    static let tree = makeTree()
    static let bush = pixelSprite(["..LLLM...", ".LMMMMMD.", "LMMMMMDDD", ".DDDDDDD."])
    static let lamp = pixelSprite(
        [".CCC.", "CGGGC", ".GGG.", "..C.."] + Array(repeating: "..P..", count: 13) + [".pPp.", "ppPpp"])
    static let bench = pixelSprite([
        ".WWWWWWWWWWW.", ".w.........w.", ".WWWWWWWWWWW.", "WWWWWWWWWWWWW", "wwwwwwwwwwwww", ".I.........I.",
        ".I.........I.", "II.........II",
    ])
    static let sign = pixelSprite(["SSSSSSSS.", "SwSSwSSSS", "SSSSSSSS.", "...ss....", "...ss....", "...ss....", "...ss....", "..ssss..."])
    static let rock = pixelSprite([".KKK.", "KKKKk", "kkkkk"])
    static let flowers = pixelSprite([".R...V..", "RYR.VYV.", "MMDMMMDM"])
    static let tuft = pixelSprite(["g.g", "ggg"])

    static func fence(_ length: Int) -> PixelSprite {
        var rows = [String](repeating: "", count: 7)
        for x in 0...max(0, length) {
            let post = x % 6 == 0
            rows[0] += post ? "F" : "."
            rows[1] += "F"
            rows[2] += post ? "f" : "."
            rows[3] += "F"
            rows[4] += post ? "f" : "."
            rows[5] += post ? "F" : "."
            rows[6] += post ? "f" : "."
        }
        return pixelSprite(rows)
    }

    static let umbrella = pixelSprite(["..RRRRR..", ".RRRRRRR.", "RRRRRRRRR", "....I....", "....I...."])
    static let umbrellaRed = RGB(hex: "#e46a6a")
    static let umbrellaIron = RGB(hex: "#3a3f4a")
}

struct PixelProp {
    var sprite: PixelSprite
    var x: Int
    var lamp = false
    var bench = false

    var width: Int { sprite.first?.count ?? 0 }

    func box(groundY: Int) -> (x0: Int, x1: Int, y0: Int, y1: Int) {
        (x, x + width, groundY - sprite.count, groundY)
    }
}

/// Lay out the scene for the current width. Narrow screens get fewer pieces.
func pixelLayoutProps(width W: Int) -> [PixelProp] {
    func at(_ f: Double) -> Int { Int((Double(W) * f).rounded()) }
    var items: [PixelProp] = [
        PixelProp(sprite: PixelSprites.sign, x: at(0.03)),
        PixelProp(sprite: PixelSprites.tuft, x: at(0.14)),
        PixelProp(sprite: PixelSprites.flowers, x: at(0.2)),
        PixelProp(sprite: PixelSprites.bush, x: at(0.3)),
        PixelProp(sprite: PixelSprites.rock, x: at(0.42)),
        PixelProp(sprite: PixelSprites.tuft, x: at(0.47)),
        PixelProp(sprite: PixelSprites.lamp, x: at(0.58), lamp: true),
        PixelProp(sprite: PixelSprites.tree, x: at(0.735)),
        PixelProp(sprite: PixelSprites.flowers, x: at(0.715)),
        PixelProp(sprite: PixelSprites.bush, x: at(0.845)),
    ]
    if W >= 160 {
        items.append(PixelProp(sprite: PixelSprites.bench, x: at(0.58) + 5, bench: true))
        items.append(PixelProp(sprite: PixelSprites.fence(min(30, at(0.08))), x: at(0.9)))
        items.append(PixelProp(sprite: PixelSprites.rock, x: at(0.685)))
    }
    return items
}

func pixelBenchSeat(_ items: [PixelProp], groundY: Int) -> (x: Int, seatY: Int)? {
    guard let bench = items.first(where: \.bench) else { return nil }
    return (bench.x + 3, groundY - PixelSprites.bench.count + 3)
}

/// One lighting model for scenery and the character.
struct PixelLighting {
    var night: Double, overcast: Double, dim: Double, golden: Double, wet: Double
    var ambient: RGB
    var lampColour = RGB(hex: "#ffd98a")
    var lampOn = false
    var glow = 0.0
    var lampX = -999.0, lampY = 0.0

    private static let warm = RGB(255 / 255, 176 / 255, 112 / 255)
    private static let reach = 22.0

    init(scene: SkyScene, props: [PixelProp], groundY: Int, lampForced: Bool?) {
        night = scene.night
        overcast = scene.overcast
        dim = scene.dim
        golden = scene.golden
        wet = scene.wet
        ambient = scene.palette.near
        if let lamp = props.first(where: \.lamp) {
            lampOn = lampForced ?? (night > 0.08)
            glow = lampOn ? max(night, 0.5) : 0
            lampX = Double(lamp.x + 2)
            lampY = Double(groundY - PixelSprites.lamp.count + 1)
        }
    }

    func colour(_ base: RGB, x: Int, y: Int, strength: Double = 1) -> RGB {
        let darken = min(0.9, 0.06 + 0.8 * dim + 0.45 * wet)
        var c = base.mix(Self.warm, golden * 0.28)
        let lum = c.luminance
        c = c.mix(RGB(lum, lum, lum), overcast * 0.45)
        c = c.mix(ambient, darken * strength)
        if lampOn {
            let d = hypot(Double(x) - lampX, Double(y) - lampY)
            if d < Self.reach { c = c.mix(lampColour, pow(1 - d / Self.reach, 2) * 0.6 * glow) }
        }
        return c
    }

    func colour(_ sprite: UInt8, x: Int, y: Int, strength: Double = 1) -> UInt32 {
        colour(dayColours[sprite] ?? .white, x: x, y: y, strength: strength).packed
    }
}

/// Draws the lamp glow and every prop into `layer`.
func pixelDrawProps(into layer: inout PixelLayer, items: [PixelProp], groundY: Int, light: PixelLighting) {
    if light.lampOn {
        let lx = Int(light.lampX), ly = Int(light.lampY)
        let glowPx = light.lampColour.packed
        for (r, a) in [(16, 0.05), (11, 0.07), (6, 0.11)] {
            let alpha = Int((a * light.glow * 255).rounded())
            for y in -r...r {
                let half = Int((Double(r * r - y * y)).squareRoot().rounded())
                layer.fillRect(lx - half, ly + y, half * 2 + 1, 1, glowPx, alpha)
            }
        }
        let a = Int((0.22 * light.glow * 255).rounded())
        layer.fillRect(lx - 10, groundY, 21, 1, glowPx, a)
        layer.fillRect(lx - 6, groundY + 1, 13, 1, glowPx, a)
    }
    for it in items {
        let y0 = groundY - it.sprite.count
        for (ry, row) in it.sprite.enumerated() {
            for (rx, key) in row.enumerated() where key != 46 {
                if key == 71 && it.lamp {  // "G"
                    layer.set(it.x + rx, y0 + ry, light.lampOn ? light.lampColour.packed : (dayColours[71] ?? .white).packed)
                } else {
                    layer.set(it.x + rx, y0 + ry, light.colour(key, x: it.x + rx, y: y0 + ry))
                }
            }
        }
    }
}
