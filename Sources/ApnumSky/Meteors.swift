import Foundation

/// Annual meteor showers and their timing. Port of `meteors.js`; sources are the IMO
/// Working List of Visual Meteor Showers and IMO Meteor Shower Calendar.
enum Meteors {
    struct Shower: Sendable {
        var key: String
        var name: String
        var start: (month: Int, day: Int)
        var peak: (month: Int, day: Int)
        var end: (month: Int, day: Int)
        var zhr: Double
        /// Radiant, degrees.
        var ra: Double
        var dec: Double
    }

    struct Active: Equatable {
        var key: String
        var name: String
        var zhr: Double
        var ra: Double
        var dec: Double
        var strength: Double
    }

    static let showers: [Shower] = [
        Shower(key: "quadrantids", name: "Quadrantids", start: (12, 28), peak: (1, 3), end: (1, 12), zhr: 110, ra: 230, dec: 49),
        Shower(key: "lyrids", name: "Lyrids", start: (4, 14), peak: (4, 22), end: (4, 30), zhr: 18, ra: 271, dec: 34),
        Shower(key: "eta-aquariids", name: "Eta Aquariids", start: (4, 19), peak: (5, 6), end: (5, 28), zhr: 50, ra: 338, dec: -1),
        Shower(
            key: "southern-delta-aquariids", name: "Southern Delta Aquariids", start: (7, 12), peak: (7, 30), end: (8, 23), zhr: 25,
            ra: 339, dec: -16),
        Shower(key: "perseids", name: "Perseids", start: (7, 17), peak: (8, 12), end: (8, 24), zhr: 100, ra: 49, dec: 58),
        Shower(key: "draconids", name: "Draconids", start: (10, 6), peak: (10, 8), end: (10, 10), zhr: 10, ra: 262, dec: 54),
        Shower(key: "orionids", name: "Orionids", start: (10, 2), peak: (10, 21), end: (11, 7), zhr: 20, ra: 95, dec: 16),
        Shower(key: "southern-taurids", name: "Southern Taurids", start: (9, 10), peak: (11, 5), end: (11, 20), zhr: 5, ra: 52, dec: 14),
        Shower(key: "northern-taurids", name: "Northern Taurids", start: (10, 20), peak: (11, 12), end: (12, 10), zhr: 5, ra: 58, dec: 22),
        Shower(key: "leonids", name: "Leonids", start: (11, 6), peak: (11, 17), end: (11, 30), zhr: 15, ra: 152, dec: 22),
        Shower(key: "geminids", name: "Geminids", start: (12, 4), peak: (12, 14), end: (12, 20), zhr: 150, ra: 112, dec: 33),
        Shower(key: "ursids", name: "Ursids", start: (12, 17), peak: (12, 22), end: (12, 26), zhr: 10, ra: 217, dec: 76),
    ]

    /// Falloff exponent per shower: strength = (1 − |days from peak| / halfWidth) ^ power.
    private static let power: [String: Double] = [
        "quadrantids": 4, "perseids": 3, "geminids": 3, "draconids": 3,
        "southern-taurids": 1.5, "northern-taurids": 1.5, "orionids": 1.5,
    ]

    private static let yearDays = 365.0
    private static let cumulative = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334]

    /// Day of a fixed non-leap year, so showers wrap round new year.
    static func dayOfYear(_ month: Int, _ day: Int) -> Double { Double(cumulative[month - 1] + day - 1) }

    /// Signed shortest distance a − b on the year circle.
    static func circDiff(_ a: Double, _ b: Double) -> Double {
        let half = yearDays / 2
        let x = (a - b + half).truncatingRemainder(dividingBy: yearDays)
        return (x + yearDays).truncatingRemainder(dividingBy: yearDays) - half
    }

    /// Local calendar day of year for a clock `utcOffsetHours` ahead of UTC; Feb 29 counts as Feb 28.
    static func localDayOfYear(_ date: Date, utcOffsetHours: Double) -> Double {
        let local = date.timeIntervalSince1970 + utcOffsetHours * 3600
        let (_, m, d) = Astronomy.civilFromDays(Int((local / 86400).rounded(.down)))
        return dayOfYear(m, m == 2 && d == 29 ? 28 : d)
    }

    static func strength(_ s: Shower, doy: Double) -> Double {
        let peak = dayOfYear(s.peak.month, s.peak.day)
        let before = circDiff(peak, dayOfYear(s.start.month, s.start.day))
        let after = circDiff(dayOfYear(s.end.month, s.end.day), peak)
        let d = circDiff(doy, peak)
        let width = d < 0 ? before : after
        let t = abs(d) / max(width, 1)
        if t > 1 { return 0 }
        return pow(1 - t, power[s.key] ?? 2)
    }

    /// The shower that should dominate the sky on `date`, or nil if none is active.
    static func active(at date: Date, utcOffsetHours: Double) -> Active? {
        let doy = localDayOfYear(date, utcOffsetHours: utcOffsetHours)
        var best: Active?
        var bestScore = 0.0
        for s in showers {
            let st = strength(s, doy: doy)
            let score = s.zhr * st
            if st > 0 && score > bestScore {
                bestScore = score
                best = Active(key: s.key, name: s.name, zhr: s.zhr, ra: s.ra, dec: s.dec, strength: st)
            }
        }
        return best
    }

    /// Expected visible meteors per minute: 0.3 sporadic background plus ZHR/12, capped at 8.
    static func perMinute(_ shower: Active?) -> Double {
        min(8, 0.3 + ((shower?.zhr ?? 0) * (shower?.strength ?? 0)) / 12)
    }
}
