import ApnumSky
import Foundation

// The little hoodie character and the baked cloud shapes.

enum PixelCharacter {
    // 0 empty, 1 hair, 2 skin, 3 hoodie, 4 pants, 5 shoe, 6 eye
    static let idle = pixelSprite([
        "..1111..", ".111111.", ".122221.", ".126262.", "..2222..", ".333333.", "33333333", "2.3333.2", "..4444..", "..4..4..", "..5..5..",
    ])
    static let walk = pixelSprite([
        "..1111..", ".111111.", ".122221.", ".126262.", "..2222..", ".333333.", "33333333", "2.3333.2", "..4444..", ".4....4.", ".5....5.",
    ])
    static let arms = pixelSprite([
        "2.1111.2", "21111112", "31222213", "3126262.", ".32222..", ".333333.", "..3333..", "..3333..", "..4444..", "..4..4..", "..5..5..",
    ])
    static let sit = pixelSprite([
        "..1111..", ".111111.", ".122221.", ".126262.", "..2222..", ".333333.", "33333333", "2.3333.2", ".444444.", ".....44.", ".....55.",
    ])
    static let colours: [UInt8: RGB] = [
        49: RGB(hex: "#2a1b2e"), 50: RGB(hex: "#f2c9a8"), 51: RGB(hex: "#8fd3c9"), 52: RGB(hex: "#3f2740"),
        53: RGB(hex: "#1b1120"), 54: RGB(hex: "#2a1b2e"),
    ]
    static let height = idle.count

    static let lines = [
        "Hi! Good to see you.",
        "Click the lamp. Or the bench.",
        "Hold still, I like the quiet bit.",
        "The fireflies follow your cursor.",
        "I watch the real sky, you know.",
        "Nice day for a walk.",
    ]
}

struct PixelCloud {
    var x: Double
    var y: Int
    var w: Int
    var h: Int
    var seed: Int
    var v: Double
    var image: PixelLayer
}

/// Overlapping round puffs on a flat base: lit on top, shaded underneath, with a dithered soft edge.
func pixelBakeCloud(w: Int, h: Int, seed: Int, light: RGB, body: RGB, shade: RGB) -> PixelLayer {
    var layer = PixelLayer(width: w, height: h)
    var rand = PixelNoise(seed: seed)
    let n = 3 + Int(rand.next() * 3)
    var puffs: [(Double, Double, Double)] = []
    for i in 0..<n {
        let centre = 1 - abs(Double(i) / Double(n - 1) - 0.5) * 2
        let r = min((Double(h) - 2) / 1.75, Double(h) * (0.28 + 0.24 * centre + rand.next() * 0.08))
        puffs.append((
            Double(w) * (0.16 + 0.68 * Double(i) / Double(n - 1)) + (rand.next() - 0.5) * 3,
            Double(h) - 2 - r * 0.7, r))
    }
    let lightPx = light.packed, bodyPx = body.packed, shadePx = shade.packed
    for y in 0..<h {
        for x in 0..<w {
            var inside = false, rim = true, top = false
            for (px, py, r) in puffs {
                let d = hypot(Double(x) + 0.5 - px, Double(y) + 0.5 - py)
                if d < r {
                    inside = true
                    if d < r - 1 { rim = false }
                    if Double(y) + 0.5 < py - r * 0.35 { top = true }
                }
            }
            if !inside || (rim && (x + y) % 2 != 0) { continue }
            layer.set(x, y, y >= h - 2 ? shadePx : top ? lightPx : bodyPx)
        }
    }
    return layer
}
