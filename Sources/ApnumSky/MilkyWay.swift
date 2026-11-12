import Foundation

/// The Milky Way as a cloud of faint points along the real galactic plane, densest
/// towards the core in Sagittarius, with the dark Great Rift (the site's generator,
/// with the same seed and random sequence).
enum MilkyWay {
    struct Point: Sendable {
        var ra: Double  // degrees
        var dec: Double  // degrees
        var vector: SIMD3<Double>
        var core: Double
    }

    static let count = 5000

    /// Generated once.
    static let points: [Point] = generate()

    static func generate() -> [Point] {
        let rad = Astronomy.rad
        var seed = 4242
        func rand() -> Double {
            seed = (seed * 16807) % 2_147_483_647
            return Double(seed - 1) / 2_147_483_646
        }
        func gauss() -> Double {
            let a = rand()
            let b = rand()
            return (-2 * log(a + 1e-9)).squareRoot() * cos(2 * Double.pi * b)
        }
        let raG = rad * 192.85948
        let decG = rad * 27.12825
        let lNcp = rad * 122.93192
        var pts: [Point] = []
        pts.reserveCapacity(count)
        while pts.count < count {
            let lDeg = rand() * 360
            let core = pow(cos(rad * lDeg / 2), 2)
            if rand() > 0.35 + 0.65 * core { continue }
            let bDeg = gauss() * (4 + 7 * core)
            if (lDeg < 60 || lDeg > 330) && abs(bDeg - 0.8) < 1.6 && rand() < 0.8 { continue }
            let l = rad * lDeg
            let b = rad * bDeg
            let dec = asin(sin(b) * sin(decG) + cos(b) * cos(decG) * cos(lNcp - l))
            let ra =
                raG
                + atan2(
                    cos(b) * sin(lNcp - l),
                    sin(b) * cos(decG) - cos(b) * sin(decG) * cos(lNcp - l))
            let raDeg = ((ra / rad).truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
            let decDeg = dec / rad
            pts.append(Point(ra: raDeg, dec: decDeg, vector: SkyFrame.unitVector(ra: raDeg, dec: decDeg), core: core))
        }
        return pts
    }

    static func visible(_ frame: SkyFrame) -> [MilkyWayPoint] {
        var out: [MilkyWayPoint] = []
        out.reserveCapacity(points.count / 2)
        for p in points where frame.sinAltitude(p.vector) > 0 {
            out.append(MilkyWayPoint(position: frame.position(p.vector), weight: p.core))
        }
        return out
    }
}
