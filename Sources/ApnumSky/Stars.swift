import Foundation

/// Turns fixed points on the celestial sphere into local altitude and azimuth
/// for one instant and place. Takes precomputed unit vectors, so each point
/// costs a few multiplies (the site's `starTransform` without the per-point trig).
struct SkyFrame {
    let sinPhi: Double, cosPhi: Double, sinLst: Double, cosLst: Double

    init(date: Date, location: GeoLocation) {
        let d = Astronomy.days(date)
        let lst = Astronomy.siderealTime(d, Astronomy.rad * -location.longitude)
        let phi = Astronomy.rad * location.latitude
        sinPhi = sin(phi); cosPhi = cos(phi); sinLst = sin(lst); cosLst = cos(lst)
    }

    /// Unit vector of an (RA, Dec) in degrees.
    static func unitVector(ra: Double, dec: Double) -> SIMD3<Double> {
        let cd = cos(dec * Astronomy.rad)
        return SIMD3(cd * cos(ra * Astronomy.rad), cd * sin(ra * Astronomy.rad), sin(dec * Astronomy.rad))
    }

    /// Sine of the altitude; positive means above the horizon.
    @inline(__always) func sinAltitude(_ v: SIMD3<Double>) -> Double {
        sinPhi * v.z + cosPhi * (v.x * cosLst + v.y * sinLst)
    }

    func position(_ v: SIMD3<Double>) -> HorizontalPosition {
        let cosDecCosH = v.x * cosLst + v.y * sinLst
        let cosDecSinH = v.x * sinLst - v.y * cosLst
        return HorizontalPosition(
            altitude: asin(max(-1, min(1, sinPhi * v.z + cosPhi * cosDecCosH))),
            azimuth: atan2(cosDecSinH, cosDecCosH * sinPhi - v.z * cosPhi))
    }

    func position(ra: Double, dec: Double) -> HorizontalPosition { position(Self.unitVector(ra: ra, dec: dec)) }
}

/// The bright stars the site labels (RA, Dec in degrees).
let namedStars: [(name: String, ra: Double, dec: Double)] = [
    ("Sirius", 101.29, -16.72), ("Canopus", 95.99, -52.7), ("Arcturus", 213.92, 19.18),
    ("Vega", 279.23, 38.78), ("Capella", 79.17, 46.0), ("Rigel", 78.63, -8.2),
    ("Procyon", 114.83, 5.22), ("Betelgeuse", 88.79, 7.41), ("Achernar", 24.43, -57.24),
    ("Altair", 297.7, 8.87), ("Aldebaran", 68.98, 16.51), ("Antares", 247.35, -26.43),
    ("Spica", 201.3, -11.16), ("Pollux", 116.33, 28.03), ("Fomalhaut", 344.41, -29.62),
    ("Deneb", 310.36, 45.28), ("Regulus", 152.09, 11.97),
]

/// Star and constellation data, decoded once from the bundled JSON.
final class SkyCatalog: Sendable {
    struct Star: Sendable {
        var vector: SIMD3<Double>
        var magnitude: Double
        var colorIndex: Double
        var name: String?
    }

    struct Figure: Sendable {
        var id: String
        var name: String
        var lines: [[SIMD3<Double>]]
        var wiki: String?
    }

    let stars: [Star]
    let figures: [Figure]

    static let shared = SkyCatalog()

    private struct RawFigure: Decodable {
        var id: String
        var name: String
        var lines: [[[Double]]]
        var wiki: String?
    }

    private init() {
        func load<T: Decodable>(_ name: String, as type: T.Type) -> T? {
            guard let url = Bundle.module.url(forResource: name, withExtension: "json"),
                let data = try? Data(contentsOf: url)
            else { return nil }
            return try? JSONDecoder().decode(T.self, from: data)
        }

        var stars = (load("stars", as: [[Double]].self) ?? []).compactMap { row -> Star? in
            guard row.count >= 4 else { return nil }
            return Star(vector: SkyFrame.unitVector(ra: row[0], dec: row[1]), magnitude: row[2], colorIndex: row[3], name: nil)
        }
        // Name each labelled star by the closest catalogue entry within 0.2 degrees.
        let cosLimit = cos(0.2 * Astronomy.rad)
        for named in namedStars {
            let v = SkyFrame.unitVector(ra: named.ra, dec: named.dec)
            var best: (index: Int, dot: Double)?
            for (i, s) in stars.enumerated() {
                let dot = dot3(s.vector, v)
                if dot >= cosLimit, dot > (best?.dot ?? 0) { best = (i, dot) }
            }
            if let best { stars[best.index].name = named.name }
        }
        self.stars = stars

        figures = (load("constellations", as: [RawFigure].self) ?? []).map { raw in
            Figure(
                id: raw.id, name: raw.name,
                lines: raw.lines.map { line in
                    line.compactMap { $0.count >= 2 ? SkyFrame.unitVector(ra: $0[0], dec: $0[1]) : nil }
                },
                wiki: raw.wiki)
        }
    }

    func visibleStars(_ frame: SkyFrame) -> [SkyStar] {
        var out: [SkyStar] = []
        out.reserveCapacity(stars.count / 2)
        for s in stars where frame.sinAltitude(s.vector) > 0 {
            out.append(
                SkyStar(position: frame.position(s.vector), magnitude: s.magnitude, colorIndex: s.colorIndex, name: s.name))
        }
        return out
    }

    /// Stick figures in horizontal coordinates; only runs of consecutive vertices that are all above the horizon.
    func visibleFigures(_ frame: SkyFrame) -> [ConstellationFigure] {
        var out: [ConstellationFigure] = []
        for figure in figures {
            var lines: [[HorizontalPosition]] = []
            for line in figure.lines {
                var run: [HorizontalPosition] = []
                for v in line {
                    if frame.sinAltitude(v) > 0 {
                        run.append(frame.position(v))
                    } else {
                        if run.count > 1 { lines.append(run) }
                        run = []
                    }
                }
                if run.count > 1 { lines.append(run) }
            }
            if !lines.isEmpty { out.append(ConstellationFigure(id: figure.id, name: figure.name, lines: lines, wiki: figure.wiki)) }
        }
        return out
    }
}

private func dot3(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
    let p = a * b
    return p.x + p.y + p.z
}
