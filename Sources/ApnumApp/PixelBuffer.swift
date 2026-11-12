import ApnumSky
import CoreGraphics
import Foundation

// Pixel plumbing for the sky scene: premultiplied RGBA8 layers stored as plain
// UInt32 arrays (BGRA in memory, the layout Core Animation consumes without converting), a few colour helpers, and the seeded noise the website uses.

@inline(__always) func pxRGBA(_ r: Int, _ g: Int, _ b: Int, _ a: Int = 255) -> UInt32 {
    UInt32(truncatingIfNeeded: b) | UInt32(truncatingIfNeeded: g) << 8
        | UInt32(truncatingIfNeeded: r) << 16 | UInt32(truncatingIfNeeded: a) << 24
}

@inline(__always) func channel8(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }

extension RGB {
    /// Opaque packed pixel.
    var packed: UInt32 { pxRGBA(channel8(r), channel8(g), channel8(b)) }
    static let white = RGB(1, 1, 1)
}

/// `src` over `dst`, `src` an opaque RGB pixel with coverage `a` (0...255); `dst` premultiplied.
@inline(__always) func blendOver(_ dst: UInt32, _ src: UInt32, _ a: Int) -> UInt32 {
    if a >= 255 { return src | 0xFF00_0000 }
    if a <= 0 { return dst }
    let ia = 255 - a
    let r = (Int(src & 255) * a + Int(dst & 255) * ia + 127) / 255
    let g = (Int((src >> 8) & 255) * a + Int((dst >> 8) & 255) * ia + 127) / 255
    let b = (Int((src >> 16) & 255) * a + Int((dst >> 16) & 255) * ia + 127) / 255
    let al = (255 * a + Int(dst >> 24) * ia + 127) / 255
    return pxRGBA(b, g, r, al)  // r is the low (blue) byte here
}

/// Premultiplied `src` (scaled by `m`/255) over premultiplied `dst`.
@inline(__always) func blendPremultiplied(_ dst: UInt32, _ src: UInt32, _ m: Int) -> UInt32 {
    let sa = Int(src >> 24) * m / 255
    let ia = 255 - sa
    let r = Int(src & 255) * m / 255 + Int(dst & 255) * ia / 255
    let g = Int((src >> 8) & 255) * m / 255 + Int((dst >> 8) & 255) * ia / 255
    let b = Int((src >> 16) & 255) * m / 255 + Int((dst >> 16) & 255) * ia / 255
    let a = sa + Int(dst >> 24) * ia / 255
    return pxRGBA(min(b, 255), min(g, 255), min(r, 255), min(a, 255))  // r is the low (blue) byte here
}

struct PixelLayer {
    let width: Int
    let height: Int
    var data: [UInt32]

    init(width: Int, height: Int, fill: UInt32 = 0) {
        self.width = max(1, width)
        self.height = max(1, height)
        data = [UInt32](repeating: fill, count: self.width * self.height)
    }

    @inline(__always) mutating func set(_ x: Int, _ y: Int, _ rgb: UInt32) {
        guard x >= 0, y >= 0, x < width, y < height else { return }
        data[y * width + x] = rgb | 0xFF00_0000
    }

    /// Alpha-blends one pixel (`alpha` 0...255).
    @inline(__always) mutating func plot(_ x: Int, _ y: Int, _ rgb: UInt32, _ alpha: Int = 255) {
        guard x >= 0, y >= 0, x < width, y < height else { return }
        let i = y * width + x
        data[i] = blendOver(data[i], rgb, alpha)
    }

    mutating func fillRect(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ rgb: UInt32, _ alpha: Int = 255) {
        guard w > 0, h > 0 else { return }
        let x0 = max(0, x), x1 = min(width, x + w), y0 = max(0, y), y1 = min(height, y + h)
        guard x0 < x1, y0 < y1 else { return }
        for yy in y0..<y1 {
            var i = yy * width + x0
            for _ in x0..<x1 {
                data[i] = blendOver(data[i], rgb, alpha)
                i += 1
            }
        }
    }

    /// Filled disc with a per-pixel shader (website `disc`): `shade(nx, ny)` returns a colour and a 0...1 coverage.
    mutating func disc(_ cx: Int, _ cy: Int, _ r: Int, alpha: Double, shade: (Double, Double) -> (UInt32, Double)?) {
        guard r > 0 else { return }
        for y in -r...r {
            let half = (Double(r * r - y * y)).squareRoot()
            let n = Int(half.rounded())
            guard n > 0 else { continue }
            for x in -n..<n {
                guard let (rgb, cover) = shade(half > 0 ? (Double(x) + 0.5) / half : 0, Double(y) / Double(r)) else { continue }
                plot(cx + x, cy + y, rgb, Int((alpha * cover * 255).rounded()))
            }
        }
    }

    /// Draws this layer onto `dst` with its origin at (ox, oy), skipping rows above `fromRow`.
    func blit(into dst: inout PixelLayer, ox: Int, oy: Int, alpha: Int = 255, fromRow: Int = 0) {
        let sy0 = max(fromRow, -oy), sy1 = min(height, dst.height - oy)
        let sx0 = max(0, -ox), sx1 = min(width, dst.width - ox)
        guard sy0 < sy1, sx0 < sx1 else { return }
        let dw = dst.width, sw = width
        data.withUnsafeBufferPointer { s in
            dst.data.withUnsafeMutableBufferPointer { d in
                for sy in sy0..<sy1 {
                    var si = sy * sw + sx0
                    var di = (sy + oy) * dw + sx0 + ox
                    for _ in sx0..<sx1 {
                        let p = s[si]
                        let a = p >> 24
                        if a != 0 {
                            d[di] = (a == 255 && alpha == 255) ? p : blendPremultiplied(d[di], p, alpha)
                        }
                        si += 1
                        di += 1
                    }
                }
            }
        }
    }

    func makeImage(opaque: Bool = false) -> CGImage? {
        let bytes = data.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let provider = CGDataProvider(data: bytes as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: pixelDisplaySpace,
            bitmapInfo: CGBitmapInfo(rawValue: (opaque ? CGImageAlphaInfo.noneSkipFirst : CGImageAlphaInfo.premultipliedFirst).rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

/// The website's `seededNoise` (Park-Miller), so landscapes come out the same.
struct PixelNoise {
    private var s: Int
    init(seed: Int) { s = max(1, seed) }
    mutating func next() -> Double {
        s = (s * 16807) % 2_147_483_647
        return Double(s - 1) / 2_147_483_646
    }
}

/// Stable pseudo-random 0..<1 from two numbers.
func pixelHash(_ a: Double, _ b: Double) -> Double {
    let v = sin(a * 127.1 + b * 311.7) * 43758.5453
    return v - v.rounded(.down)
}

/// Plain random numbers for the things that are allowed to differ every run (rain, meteors).
struct PixelRandom {
    private var g = SystemRandomNumberGenerator()
    mutating func unit() -> Double { Double.random(in: 0..<1, using: &g) }
}

/// The display's own colour space, so Core Animation does not convert every frame on the CPU.
let pixelDisplaySpace: CGColorSpace = CGDisplayCopyColorSpace(CGMainDisplayID())
