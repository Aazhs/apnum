import ApnumSky
import Foundation

// The four procedural mountain ranges, ported from aarshj.me: layered smooth
// value noise (fBm) stretched to a height band, shaded away from the light.

struct PixelRangeConfig {
    var base: Double, amp: Double, scale: Double, rough: Double, sharp: Double
    var rim = false
}

struct PixelRange {
    var height: [Int]
    var smooth: [Double]
    var rim: Bool
    var minTop: Int

    init(width: Int, config cfg: PixelRangeConfig, seed: Int) {
        var rand = PixelNoise(seed: seed)
        let lattice = (0..<4096).map { _ in rand.next() }
        func noise(_ x: Double) -> Double {
            let f = x.rounded(.down)
            let i = Int(f)
            let t = (1 - cos((x - f) * .pi)) / 2
            return lattice[i & 4095] * (1 - t) + lattice[(i + 1) & 4095] * t
        }
        let offset = rand.next() * 1000
        var vals = [Double](repeating: 0, count: width)
        for x in 0..<width {
            var v = 0.0, amp = 1.0, freq = 1 / cfg.scale, total = 0.0
            for _ in 0..<4 {
                v += amp * noise((Double(x) + offset) * freq)
                total += amp
                amp *= cfg.rough
                freq *= 2.03
            }
            vals[x] = v / total
        }
        let lo = vals.min() ?? 0, hi = vals.max() ?? 1
        let span = (hi - lo) == 0 ? 1 : hi - lo
        let h: [Int] = vals.map { Int((cfg.base - cfg.amp * pow(($0 - lo) / span, cfg.sharp)).rounded()) }
        height = h
        smooth = (0..<width).map { x in
            var sum = 0.0, n = 0.0
            for k in max(0, x - 6)...min(width - 1, x + 6) {
                sum += Double(h[k])
                n += 1
            }
            return sum / n
        }
        rim = cfg.rim
        minTop = height.min() ?? 0
    }

    /// Solid body, a dithered shadow band under the ridge on slopes facing away
    /// from the light, and a faint lit rim on slopes facing it.
    func bake(height H: Int, color: RGB, shade: RGB, rimColor: RGB, depth: Int, lightFromLeft: Bool) -> PixelLayer {
        let width = height.count
        var layer = PixelLayer(width: width, height: H)
        let body = color.packed, shadePx = shade.packed, rimPx = rimColor.packed
        let dir = lightFromLeft ? 1.0 : -1.0
        for x in 0..<width {
            let top = max(0, height[x])
            if top < H { layer.fillRect(x, top, 1, H - top, body) }
            let slope = ((smooth[min(width - 1, x + 3)] - smooth[max(0, x - 3)]) / 6) * dir
            if slope > 0.05 {
                let d = min(depth, Int((Double(depth) * min(1, slope * 2.2)).rounded()))
                for k in 0..<max(d, 0) {
                    if Double(k) > Double(d) * 0.6 && (x + top + k) % 2 != 0 { continue }
                    layer.set(x, top + k, shadePx)
                }
            } else if rim && slope < -0.05 {
                layer.plot(x, top, rimPx, 64)
            }
        }
        return layer
    }
}
