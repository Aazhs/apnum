import Foundation

/// Planet positions from the JPL approximate Keplerian elements (Standish, valid
/// 1800–2050, error well under a degree for the naked-eye planets). Port of `planets.js`.
enum Planets {
    private struct Elements {
        // [value at J2000, change per Julian century]
        var a, e, I, L, w, O: (Double, Double)
    }

    private static let earth = Elements(
        a: (1.00000261, 0.00000562), e: (0.01671123, -0.00004392), I: (-0.00001531, -0.01294668),
        L: (100.46457166, 35999.37244981), w: (102.93768193, 0.32327364), O: (0, 0))

    private struct Planet {
        var name: String
        var elements: Elements
        var h: Double
        var brightest: Double
        var color: String
    }

    private static let all: [Planet] = [
        Planet(
            name: "Mercury",
            elements: Elements(
                a: (0.38709927, 0.00000037), e: (0.20563593, 0.00001906), I: (7.00497902, -0.00594749),
                L: (252.2503235, 149472.67411175), w: (77.45779628, 0.16047689), O: (48.33076593, -0.12534081)),
            h: -0.6, brightest: -1.2, color: "#e9dccb"),
        Planet(
            name: "Venus",
            elements: Elements(
                a: (0.72333566, 0.0000039), e: (0.00677672, -0.00004107), I: (3.39467605, -0.0007889),
                L: (181.9790995, 58517.81538729), w: (131.60246718, 0.00268329), O: (76.67984255, -0.27769418)),
            h: -4.4, brightest: -4.7, color: "#fffbe8"),
        Planet(
            name: "Mars",
            elements: Elements(
                a: (1.52371034, 0.00001847), e: (0.0933941, 0.00007882), I: (1.84969142, -0.00813131),
                L: (-4.55343205, 19140.30268499), w: (-23.94362959, 0.44441088), O: (49.55953891, -0.29257343)),
            h: -1.5, brightest: -2.9, color: "#ff9a6a"),
        Planet(
            name: "Jupiter",
            elements: Elements(
                a: (5.202887, -0.00011607), e: (0.04838624, -0.00013253), I: (1.30439695, -0.00183714),
                L: (34.39644051, 3034.74612775), w: (14.72847983, 0.21252668), O: (100.47390909, 0.20469106)),
            h: -9.4, brightest: -2.9, color: "#ffefd6"),
        Planet(
            name: "Saturn",
            elements: Elements(
                a: (9.53667594, -0.0012506), e: (0.05386179, -0.00050991), I: (2.48599187, 0.00193609),
                L: (49.95424423, 1222.49362201), w: (92.59887831, -0.41897216), O: (113.66242448, -0.28867794)),
            h: -8.9, brightest: -0.5, color: "#f2dca4"),
    ]

    struct Equatorial: Equatable {
        var name: String
        /// Degrees.
        var ra: Double
        var dec: Double
        var magnitude: Double
        var color: RGB
    }

    private static func heliocentric(_ el: Elements, _ t: Double) -> SIMD3<Double> {
        let rad = Astronomy.rad
        func v(_ p: (Double, Double)) -> Double { p.0 + p.1 * t }
        let a = v(el.a), e = v(el.e)
        let inc = v(el.I) * rad, o = v(el.O) * rad
        let w = (v(el.w) - v(el.O)) * rad
        var m = ((v(el.L) - v(el.w)).truncatingRemainder(dividingBy: 360) + 540).truncatingRemainder(dividingBy: 360) - 180
        m *= rad
        var ea = m + e * sin(m)
        for _ in 0..<6 { ea -= (ea - e * sin(ea) - m) / (1 - e * cos(ea)) }
        let xp = a * (cos(ea) - e)
        let yp = a * (1 - e * e).squareRoot() * sin(ea)
        let cw = cos(w), sw = sin(w), cO = cos(o), sO = sin(o), cI = cos(inc), sI = sin(inc)
        return SIMD3(
            (cw * cO - sw * sO * cI) * xp + (-sw * cO - cw * sO * cI) * yp,
            (cw * sO + sw * cO * cI) * xp + (-sw * sO + cw * cO * cI) * yp,
            sw * sI * xp + cw * sI * yp)
    }

    /// Right ascension and declination (degrees) plus a rough magnitude for each planet.
    static func positions(at date: Date) -> [Equatorial] {
        let rad = Astronomy.rad
        let obliquity = 23.43928 * rad
        let t = (date.timeIntervalSince1970 * 1000 / 86_400_000 + 2_440_587.5 - 2_451_545) / 36525
        let e = heliocentric(earth, t)
        return all.map { planet in
            let p = heliocentric(planet.elements, t)
            let x = p.x - e.x, y = p.y - e.y, z = p.z - e.z
            let ye = y * cos(obliquity) - z * sin(obliquity)
            let ze = y * sin(obliquity) + z * cos(obliquity)
            let r = (p.x * p.x + p.y * p.y + p.z * p.z).squareRoot()
            let delta = (x * x + y * y + z * z).squareRoot()
            return Equatorial(
                name: planet.name,
                ra: ((atan2(ye, x) / rad) + 360).truncatingRemainder(dividingBy: 360),
                dec: atan2(ze, (x * x + ye * ye).squareRoot()) / rad,
                magnitude: max(planet.brightest, planet.h + 5 * log10(r * delta)),
                color: RGB(hex: planet.color))
        }
    }

    static func visible(at date: Date, frame: SkyFrame) -> [SkyPlanet] {
        positions(at: date).compactMap { p in
            let v = SkyFrame.unitVector(ra: p.ra, dec: p.dec)
            guard frame.sinAltitude(v) > 0 else { return nil }
            return SkyPlanet(name: p.name, position: frame.position(v), magnitude: p.magnitude, color: p.color)
        }
    }
}
