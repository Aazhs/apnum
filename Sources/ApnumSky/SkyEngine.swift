import Foundation

/// Computes the real sky for a place and time: sun, moon, stars, planets, Milky Way,
/// constellations, meteor showers and special moons. A port of the sky model on aarshj.me.
public struct SkyEngine: Sendable {
    public init() {}

    /// Approximate local clock offset: mean solar time at the longitude. The site
    /// uses IST for the calendar day of meteor showers and blue moons.
    static func utcOffsetHours(_ location: GeoLocation) -> Double { location.longitude / 15 }

    public func scene(at date: Date, location: GeoLocation, weather: SkyWeather) -> SkyScene {
        let d = Astronomy.days(date)
        let lat = location.latitude, lon = location.longitude
        let sun = Astronomy.position(Astronomy.sunCoords(d), d, latitude: lat, longitude: lon)
        let moonC = Astronomy.moonCoords(d)
        let moon = Astronomy.position(moonC, d, latitude: lat, longitude: lon)
        let illum = Astronomy.moonIllumination(d)

        let offset = Self.utcOffsetHours(location)
        let event = Astronomy.moonEvent(
            date: date, moonAltitudeDegrees: moon.altitudeDegrees, fraction: illum.fraction, distanceKm: moonC.dist,
            utcOffsetHours: offset)
        var blood = 0.0
        var supermoon = false
        switch event {
        case .blood(let strength): blood = strength
        case .supermoon: supermoon = true
        default: break
        }

        let palette = SkyPalette.forSunAltitude(sun.altitudeDegrees)
            .bloodTinted(blood)
            .weatherTinted(overcast: weather.overcast, wet: weather.kind.wetness)

        let frame = SkyFrame(date: date, location: location)
        let catalog = SkyCatalog.shared
        let shower = Meteors.active(at: date, utcOffsetHours: offset)

        return SkyScene(
            date: date, location: location, weather: weather, palette: palette, sun: sun, moon: moon,
            moonFraction: illum.fraction, moonPhase: illum.phase,
            stars: catalog.visibleStars(frame),
            planets: Planets.visible(at: date, frame: frame),
            milkyWay: MilkyWay.visible(frame),
            constellations: catalog.visibleFigures(frame),
            meteorsPerMinute: Meteors.perMinute(shower),
            meteorRadiant: shower.map { frame.position(ra: $0.ra, dec: $0.dec) },
            bloodMoon: blood, supermoon: supermoon)
    }

    public func summary(at date: Date, location: GeoLocation, weather: SkyWeather) -> SkySummary {
        let d = Astronomy.days(date)
        let lat = location.latitude, lon = location.longitude
        let sun = Astronomy.position(Astronomy.sunCoords(d), d, latitude: lat, longitude: lon)
        let moonC = Astronomy.moonCoords(d)
        let moon = Astronomy.position(moonC, d, latitude: lat, longitude: lon)
        let illum = Astronomy.moonIllumination(d)
        let offset = Self.utcOffsetHours(location)

        let event = Astronomy.moonEvent(
            date: date, moonAltitudeDegrees: moon.altitudeDegrees, fraction: illum.fraction, distanceKm: moonC.dist,
            utcOffsetHours: offset)
        let shower = Meteors.active(at: date, utcOffsetHours: offset)

        // Today in local solar time, plus the following day so the next event is always found.
        let local = date.timeIntervalSince1970 + offset * 3600
        let dayStart = Date(timeIntervalSince1970: (local / 86400).rounded(.down) * 86400 - offset * 3600)
        let crossings = Astronomy.sunCrossings(from: dayStart, to: dayStart.addingTimeInterval(3 * 86400), location: location)
        let today = crossings.filter { $0.date < dayStart.addingTimeInterval(86400) }
        let next = crossings.first { $0.date > date }

        return SkySummary(
            skyName: Astronomy.skyName(sunAltitudeDegrees: sun.altitudeDegrees, rising: sun.azimuth < 0),
            placeName: location.name,
            weather: weather,
            moonPhaseName: Astronomy.phaseName(phase: illum.phase, fraction: illum.fraction),
            moonPercentLit: Int((illum.fraction * 100).rounded()),
            moonIsUp: moon.altitude > 0,
            sunrise: today.first { $0.rising }?.date,
            sunset: today.first { !$0.rising }?.date,
            nextSunEvent: next.map { SkySummary.SunEvent(name: $0.rising ? "Sunrise" : "Sunset", date: $0.date) },
            meteorShower: (shower?.strength ?? 0) > 0.25 ? shower?.name : nil,
            specialEvents: event.map { [$0.label] } ?? [])
    }
}

public extension SkyEngine {
    /// The sky colour (mid-sky) through one local day at `location`, sampled `samples` times
    /// from midnight to midnight. Follows the real sun, so dawn and dusk sit where they really are.
    func dayColors(for date: Date, location: GeoLocation, samples: Int = 49, calendar: Calendar = .current) -> [RGB] {
        let start = calendar.startOfDay(for: date)
        return (0..<samples).map { i in
            let t = start.addingTimeInterval(Double(i) / Double(samples - 1) * 86_400)
            let altitude = Astronomy.sunPosition(t, location).altitudeDegrees
            return SkyPalette.forSunAltitude(altitude).sky
        }
    }
}
