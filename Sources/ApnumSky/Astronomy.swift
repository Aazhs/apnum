import Foundation

// Sun and moon position, moon phase and special moons. A port of the sky model on
// aarshj.me (`sky.js`), whose formulas follow SunCalc by Vladimir Agafonkin (BSD-2),
// accurate to well under a degree.

enum Astronomy {
    static let rad = Double.pi / 180
    static let dayMs = 86_400_000.0
    static let j1970 = 2_440_588.0
    static let j2000 = 2_451_545.0
    static let obliquity = rad * 23.4397

    /// Days since J2000 (SunCalc `toDays`).
    static func days(_ date: Date) -> Double {
        date.timeIntervalSince1970 * 1000 / dayMs - 0.5 + j1970 - j2000
    }

    static func rightAscension(_ l: Double, _ b: Double) -> Double {
        atan2(sin(l) * cos(obliquity) - tan(b) * sin(obliquity), cos(l))
    }

    static func declination(_ l: Double, _ b: Double) -> Double {
        asin(sin(b) * cos(obliquity) + cos(b) * sin(obliquity) * sin(l))
    }

    static func azimuth(_ h: Double, _ phi: Double, _ dec: Double) -> Double {
        atan2(sin(h), cos(h) * sin(phi) - tan(dec) * cos(phi))
    }

    static func altitude(_ h: Double, _ phi: Double, _ dec: Double) -> Double {
        asin(sin(phi) * sin(dec) + cos(phi) * cos(dec) * cos(h))
    }

    static func siderealTime(_ d: Double, _ lw: Double) -> Double {
        rad * (280.16 + 360.9856235 * d) - lw
    }

    struct Equatorial {
        var ra: Double
        var dec: Double
        var dist: Double = 0
    }

    static func sunCoords(_ d: Double) -> Equatorial {
        let m = rad * (357.5291 + 0.98560028 * d)
        let c = rad * (1.9148 * sin(m) + 0.02 * sin(2 * m) + 0.0003 * sin(3 * m))
        let l = m + c + rad * 102.9372 + Double.pi
        return Equatorial(ra: rightAscension(l, 0), dec: declination(l, 0))
    }

    static func moonCoords(_ d: Double) -> Equatorial {
        let l0 = rad * (218.316 + 13.176396 * d)
        let m = rad * (134.963 + 13.064993 * d)
        let f = rad * (93.272 + 13.22935 * d)
        let l = l0 + rad * 6.289 * sin(m)
        let b = rad * 5.128 * sin(f)
        return Equatorial(ra: rightAscension(l, b), dec: declination(l, b), dist: 385_001 - 20_905 * cos(m))
    }

    /// Azimuth is measured from south, positive towards west.
    static func position(_ c: Equatorial, _ d: Double, latitude: Double, longitude: Double) -> HorizontalPosition {
        let lw = rad * -longitude
        let phi = rad * latitude
        let h = siderealTime(d, lw) - c.ra
        return HorizontalPosition(altitude: altitude(h, phi, c.dec), azimuth: azimuth(h, phi, c.dec))
    }

    static func sunPosition(_ date: Date, _ loc: GeoLocation) -> HorizontalPosition {
        let d = days(date)
        return position(sunCoords(d), d, latitude: loc.latitude, longitude: loc.longitude)
    }

    static func moonPosition(_ date: Date, _ loc: GeoLocation) -> HorizontalPosition {
        let d = days(date)
        return position(moonCoords(d), d, latitude: loc.latitude, longitude: loc.longitude)
    }

    /// fraction 0…1 lit; phase 0 new, 0.25 first quarter, 0.5 full, 0.75 last quarter.
    static func moonIllumination(_ d: Double) -> (fraction: Double, phase: Double) {
        let s = sunCoords(d)
        let m = moonCoords(d)
        let sunDist = 149_598_000.0
        let phi = acos(sin(s.dec) * sin(m.dec) + cos(s.dec) * cos(m.dec) * cos(s.ra - m.ra))
        let inc = atan2(sunDist * sin(phi), m.dist - sunDist * cos(phi))
        let angle = atan2(
            cos(s.dec) * sin(s.ra - m.ra),
            sin(s.dec) * cos(m.dec) - cos(s.dec) * sin(m.dec) * cos(s.ra - m.ra))
        return ((1 + cos(inc)) / 2, 0.5 + (0.5 * inc * (angle < 0 ? -1 : 1)) / Double.pi)
    }

    static func phaseName(phase: Double, fraction: Double) -> String {
        let waxing = phase < 0.5
        if fraction < 0.03 { return "New moon" }
        if fraction > 0.97 { return "Full moon" }
        if abs(fraction - 0.5) < 0.04 { return waxing ? "First quarter" : "Last quarter" }
        if fraction < 0.5 { return waxing ? "Waxing crescent" : "Waning crescent" }
        return waxing ? "Waxing gibbous" : "Waning gibbous"
    }

    /// The site's names by sun altitude; `rising` means the sun is in the east.
    static func skyName(sunAltitudeDegrees alt: Double, rising: Bool) -> String {
        if alt < -12 { return "Night" }
        if alt < -0.8 { return rising ? "Dawn" : "Dusk" }
        if alt < 8 { return rising ? "Sunrise" : "Sunset" }
        if alt < 20 { return rising ? "Morning" : "Evening" }
        return "Day"
    }

    // MARK: Eclipses and special moons

    static func utc(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        Date(timeIntervalSince1970: Double(daysFromCivil(y, mo, d)) * 86400 + Double(h) * 3600 + Double(mi) * 60)
    }

    /// Total lunar eclipses (greatest eclipse, UTC), as listed on the site.
    static let totalEclipses: [Date] = [
        utc(2026, 3, 3, 11, 33), utc(2028, 12, 31, 16, 52), utc(2029, 6, 26, 3, 22), utc(2029, 12, 20, 22, 42),
        utc(2032, 4, 25, 15, 13), utc(2032, 10, 18, 19, 2), utc(2033, 4, 14, 19, 13), utc(2033, 10, 8, 10, 55),
    ]
    static let eclipseWindow: TimeInterval = 110 * 60

    /// 0 outside an eclipse, 1 at greatest eclipse.
    static func eclipseStrength(_ date: Date) -> Double {
        let gap = totalEclipses.map { abs(date.timeIntervalSince($0)) }.min() ?? .infinity
        return gap > eclipseWindow ? 0 : (1 + cos(Double.pi * gap / eclipseWindow)) / 2
    }

    /// Blue moon: the second full moon in the same calendar month, on local day
    /// ±1. `utcOffsetHours` is the local clock offset (the site uses IST, 5.5).
    static func isBlueMoon(_ date: Date, utcOffsetHours: Double) -> Bool {
        let local = date.timeIntervalSince1970 + utcOffsetHours * 3600
        let dayNumber = Int((local / 86400).rounded(.down))
        let (y, m, today) = civilFromDays(dayNumber)
        let first = daysFromCivil(y, m, 1)
        let length = daysFromCivil(m == 12 ? y + 1 : y, m == 12 ? 1 : m + 1, 1) - first
        func fraction(_ day: Int) -> Double {
            let t = Double(first + day - 1) * 86400 + 18.5 * 3600
            return moonIllumination(days(Date(timeIntervalSince1970: t))).fraction
        }
        var fullDays: [Int] = []
        for day in 1...length {
            let f = fraction(day)
            if f > 0.97 && f >= fraction(day - 1) && f >= fraction(day + 1) { fullDays.append(day) }
        }
        return fullDays.count >= 2 && today >= fullDays[1] - 1 && today <= fullDays[1] + 1
    }

    enum MoonEvent: Equatable {
        case blood(strength: Double), supermoon, blue

        var label: String {
            switch self {
            case .blood: "Blood moon"
            case .supermoon: "Supermoon"
            case .blue: "Blue moon"
            }
        }
    }

    /// The site's rules, in its order of precedence.
    static func moonEvent(date: Date, moonAltitudeDegrees: Double, fraction: Double, distanceKm: Double, utcOffsetHours: Double)
        -> MoonEvent?
    {
        let eclipse = eclipseStrength(date)
        if eclipse > 0 && moonAltitudeDegrees > 0 { return .blood(strength: eclipse) }
        if fraction > 0.97 && distanceKm < 367_500 { return .supermoon }
        if fraction > 0.97 && isBlueMoon(date, utcOffsetHours: utcOffsetHours) { return .blue }
        return nil
    }

    // MARK: Calendar arithmetic (proleptic Gregorian, days since 1970-01-01)

    static func daysFromCivil(_ year: Int, _ month: Int, _ day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    static func civilFromDays(_ z0: Int) -> (year: Int, month: Int, day: Int) {
        let z = z0 + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (m <= 2 ? y + 1 : y, m, d)
    }

    // MARK: Sunrise and sunset

    /// Sun altitude (degrees) at which the upper limb touches the horizon, with refraction.
    static let horizonAltitude = -0.833

    struct SunCrossing: Equatable {
        var date: Date
        var rising: Bool
    }

    /// Every moment in [from, to) when the sun crosses −0.833°: sampled every
    /// 10 minutes, then bisected to about a second.
    static func sunCrossings(from: Date, to: Date, location: GeoLocation) -> [SunCrossing] {
        func alt(_ t: Double) -> Double {
            sunPosition(Date(timeIntervalSince1970: t), location).altitudeDegrees - horizonAltitude
        }
        var result: [SunCrossing] = []
        let end = to.timeIntervalSince1970
        var t0 = from.timeIntervalSince1970
        var a0 = alt(t0)
        while t0 < end {
            let t1 = min(t0 + 600, end)
            let a1 = alt(t1)
            if (a0 < 0) != (a1 < 0) {
                var lo = t0, hi = t1
                var lowSide = a0
                for _ in 0..<12 {
                    let mid = (lo + hi) / 2
                    let am = alt(mid)
                    if (am < 0) == (lowSide < 0) { lo = mid; lowSide = am } else { hi = mid }
                }
                result.append(SunCrossing(date: Date(timeIntervalSince1970: (lo + hi) / 2), rising: a1 > a0))
            }
            t0 = t1
            a0 = a1
        }
        return result
    }
}
