import Foundation
import Testing

@testable import ApnumSky

// Reference values come from running the site's JavaScript (see Reference.swift).

func date(_ iso: String) -> Date { try! Date(iso, strategy: .iso8601) }

let locations: [String: GeoLocation] = [
    "pune": .pune,
    "london": GeoLocation(name: "London", latitude: 51.5074, longitude: -0.1278),
]

@Suite struct AstronomyMatchesSite {
    let engine = SkyEngine()

    @Test func sunAndMoonPositionsMatchJavaScript() {
        for c in refCases {
            let loc = locations[c.loc]!
            let scene = engine.scene(at: date(c.iso), location: loc, weather: .calm)
            #expect(abs(scene.sun.altitude - c.sunAlt) < 1e-9, "sun alt \(c.loc) \(c.iso)")
            #expect(abs(scene.sun.azimuth - c.sunAz) < 1e-9, "sun az \(c.loc) \(c.iso)")
            #expect(abs(scene.moon.altitude - c.moonAlt) < 1e-9, "moon alt \(c.loc) \(c.iso)")
            #expect(abs(scene.moon.azimuth - c.moonAz) < 1e-9, "moon az \(c.loc) \(c.iso)")
            #expect(abs(scene.moonFraction - c.fraction) < 1e-12)
            #expect(abs(scene.moonPhase - c.phase) < 1e-12)
        }
    }

    @Test func summaryNamesMatchJavaScript() {
        for c in refCases {
            let s = engine.summary(at: date(c.iso), location: locations[c.loc]!, weather: .calm)
            #expect(s.skyName == c.skyName, "\(c.loc) \(c.iso)")
            #expect(s.moonPhaseName == c.phaseName, "\(c.loc) \(c.iso)")
            #expect(s.moonPercentLit == Int((c.fraction * 100).rounded()))
            #expect(s.moonIsUp == (c.moonAlt > 0))
        }
    }

    @Test func starTransformMatchesJavaScript() {
        let points: [(Double, Double)] = [(101.29, -16.72), (279.23, 38.78), (37.95, 89.26), (213.92, 19.18)]
        for c in refCases {
            let frame = SkyFrame(date: date(c.iso), location: locations[c.loc]!)
            for (i, p) in points.enumerated() {
                let pos = frame.position(ra: p.0, dec: p.1)
                #expect(abs(pos.altitude - c.stars[i].alt) < 1e-9)
                #expect(abs(pos.azimuth - c.stars[i].az) < 1e-9)
            }
        }
    }

    @Test func planetsMatchJavaScript() {
        for c in refCases {
            let planets = Planets.positions(at: date(c.iso))
            #expect(planets.map(\.name) == ["Mercury", "Venus", "Mars", "Jupiter", "Saturn"])
            for (p, r) in zip(planets, c.planets) {
                #expect(p.name == r.name)
                #expect(abs(p.ra - r.ra) < 1e-7, "\(r.name) ra")
                #expect(abs(p.dec - r.dec) < 1e-7, "\(r.name) dec")
                #expect(abs(p.magnitude - r.mag) < 1e-9, "\(r.name) mag")
            }
        }
    }

    @Test func scenePlanetsAreTheOnesAboveTheHorizon() {
        let c = refCases[0]
        let scene = engine.scene(at: date(c.iso), location: .pune, weather: .calm)
        let frame = SkyFrame(date: date(c.iso), location: .pune)
        let expected = Planets.positions(at: date(c.iso)).filter { frame.position(ra: $0.ra, dec: $0.dec).altitude > 0 }.map(\.name)
        #expect(scene.planets.map(\.name) == expected)
        #expect(!expected.isEmpty)
        #expect(scene.planets.allSatisfy { $0.position.altitude > 0 })
    }

    @Test func meteorShowersMatchJavaScript() {
        for c in refCases where c.loc == "pune" {
            let shower = Meteors.active(at: date(c.iso), utcOffsetHours: 5.5)
            #expect(shower?.name == c.shower)
            #expect(abs((shower?.strength ?? 0) - c.showerStrength) < 1e-12)
            #expect(abs(Meteors.perMinute(shower) - c.mpm) < 1e-12)
        }
        #expect(Meteors.active(at: date("2026-08-12T12:00:00Z"), utcOffsetHours: 5.5)?.name == "Perseids")
        #expect(Meteors.active(at: date("2026-01-03T12:00:00Z"), utcOffsetHours: 5.5)?.name == "Quadrantids")
        #expect(Meteors.active(at: date("2026-12-14T12:00:00Z"), utcOffsetHours: 5.5)?.name == "Geminids")
        #expect(Meteors.active(at: date("2026-02-20T12:00:00Z"), utcOffsetHours: 5.5) == nil)
        #expect(Meteors.perMinute(nil) == 0.3)
        #expect(Meteors.perMinute(Meteors.active(at: date("2026-08-12T12:00:00Z"), utcOffsetHours: 5.5)) == 8)
    }

    @Test func engineReportsPerseidsInSummaryAndScene() {
        let t = date("2026-08-12T20:00:00Z")
        let s = engine.summary(at: t, location: .pune, weather: .calm)
        #expect(s.meteorShower == "Perseids")
        let scene = engine.scene(at: t, location: .pune, weather: .calm)
        #expect(scene.meteorsPerMinute > 6 && scene.meteorsPerMinute <= 8)
        #expect(scene.meteorRadiant != nil)
        // Quiet date: no shower named, no radiant.
        let quiet = engine.scene(at: date("2026-02-20T20:00:00Z"), location: .pune, weather: .calm)
        #expect(quiet.meteorRadiant == nil)
        #expect(engine.summary(at: date("2026-02-20T20:00:00Z"), location: .pune, weather: .calm).meteorShower == nil)
    }

    @Test func skyNamesBySunAltitude() {
        #expect(Astronomy.skyName(sunAltitudeDegrees: -30, rising: true) == "Night")
        #expect(Astronomy.skyName(sunAltitudeDegrees: -12.1, rising: false) == "Night")
        #expect(Astronomy.skyName(sunAltitudeDegrees: -5, rising: true) == "Dawn")
        #expect(Astronomy.skyName(sunAltitudeDegrees: -5, rising: false) == "Dusk")
        #expect(Astronomy.skyName(sunAltitudeDegrees: 3, rising: true) == "Sunrise")
        #expect(Astronomy.skyName(sunAltitudeDegrees: 3, rising: false) == "Sunset")
        #expect(Astronomy.skyName(sunAltitudeDegrees: 12, rising: true) == "Morning")
        #expect(Astronomy.skyName(sunAltitudeDegrees: 12, rising: false) == "Evening")
        #expect(Astronomy.skyName(sunAltitudeDegrees: 45, rising: false) == "Day")
    }

    @Test func moonPhaseNames() {
        #expect(Astronomy.phaseName(phase: 0.0, fraction: 0.0) == "New moon")
        #expect(Astronomy.phaseName(phase: 0.5, fraction: 1.0) == "Full moon")
        #expect(Astronomy.phaseName(phase: 0.25, fraction: 0.5) == "First quarter")
        #expect(Astronomy.phaseName(phase: 0.75, fraction: 0.5) == "Last quarter")
        #expect(Astronomy.phaseName(phase: 0.1, fraction: 0.2) == "Waxing crescent")
        #expect(Astronomy.phaseName(phase: 0.9, fraction: 0.2) == "Waning crescent")
        #expect(Astronomy.phaseName(phase: 0.4, fraction: 0.8) == "Waxing gibbous")
        #expect(Astronomy.phaseName(phase: 0.6, fraction: 0.8) == "Waning gibbous")
    }

    @Test func specialMoonsFollowTheSitesRules() {
        // Blue moon: second full moon of May 2026 (IST), the day before and of.
        #expect(Astronomy.isBlueMoon(date("2026-05-30T12:00:00Z"), utcOffsetHours: 5.5))
        #expect(Astronomy.isBlueMoon(date("2026-05-31T12:00:00Z"), utcOffsetHours: 5.5))
        #expect(!Astronomy.isBlueMoon(date("2026-05-20T12:00:00Z"), utcOffsetHours: 5.5))
        let blue = engine(date("2026-05-31T12:00:00Z"))
        #expect(blue.specialEvents == ["Blue moon"])
        // Supermoon on 2026-12-24.
        #expect(engine(date("2026-12-24T12:00:00Z")).specialEvents == ["Supermoon"])
        let scene = SkyEngine().scene(at: date("2026-12-24T12:00:00Z"), location: .pune, weather: .calm)
        #expect(scene.supermoon)
        // Ordinary night.
        #expect(engine(date("2026-11-12T12:00:00Z")).specialEvents.isEmpty)
    }

    @Test func bloodMoonOnlyWhileTheMoonIsUp() {
        #expect(Astronomy.eclipseStrength(date("2026-03-03T11:33:00Z")) == 1)
        #expect(Astronomy.eclipseStrength(date("2026-03-03T12:33:00Z")) > 0)
        #expect(Astronomy.eclipseStrength(date("2026-03-03T14:00:00Z")) == 0)
        let tokyo = GeoLocation(name: "Tokyo", latitude: 35.6762, longitude: 139.6503)
        let t = date("2026-03-03T11:33:00Z")
        let scene = SkyEngine().scene(at: t, location: tokyo, weather: .calm)
        #expect(scene.moon.altitude > 0)
        #expect(scene.bloodMoon == 1)
        #expect(SkyEngine().summary(at: t, location: tokyo, weather: .calm).specialEvents == ["Blood moon"])
        // Moon below the horizon in Pune: nothing.
        #expect(SkyEngine().scene(at: t, location: .pune, weather: .calm).bloodMoon == 0)
        // Blood tint reddens the palette.
        let plain = SkyEngine().scene(at: date("2026-03-03T14:00:00Z"), location: tokyo, weather: .calm)
        #expect(scene.palette != plain.palette)
    }

    private func engine(_ d: Date) -> SkySummary {
        // The site's blue-moon calendar is IST, so use a location at IST's meridian.
        SkyEngine().summary(at: d, location: GeoLocation(name: "IST", latitude: 18.5, longitude: 82.5), weather: .calm)
    }

    @Test func paletteTintsApplyInTheSitesOrder() {
        let t = date("2026-11-12T20:00:00Z")
        let wet = SkyWeather(kind: .rain, cloudCover: 1, temperatureC: 20, windKmh: 10, isLive: true)
        let scene = SkyEngine().scene(at: t, location: .pune, weather: wet)
        let expected = SkyPalette.forSunAltitude(scene.sunAltitudeDegrees).bloodTinted(0).weatherTinted(overcast: 1, wet: 0.7)
        #expect(scene.palette == expected)
    }

    @Test func milkyWayGeneratorMatchesJavaScript() {
        let pts = MilkyWay.points
        #expect(pts.count == 5000)
        for (p, r) in zip(pts, refMilkyWayFirst) {
            #expect(abs(p.ra - r.ra) < 1e-9)
            #expect(abs(p.dec - r.dec) < 1e-9)
            #expect(abs(p.core - r.core) < 1e-12)
        }
        #expect(abs(pts.last!.ra - refMilkyWayLast.ra) < 1e-9)
        #expect(abs(pts.reduce(0) { $0 + $1.ra } - refMilkyWaySumRA) < 1e-5)
        #expect(abs(pts.reduce(0) { $0 + $1.dec } - refMilkyWaySumDec) < 1e-5)
    }

    @Test func sceneContentIsSane() {
        let t = date("2026-11-12T20:00:00Z")
        let scene = SkyEngine().scene(at: t, location: .pune, weather: .calm)
        #expect(scene.stars.count > 400 && scene.stars.count < SkyCatalog.shared.stars.count)
        #expect(scene.stars.allSatisfy { $0.position.altitude > 0 })
        let names = Set(scene.stars.compactMap(\.name))
        #expect(names.isSuperset(of: ["Sirius", "Capella"]))
        #expect(SkyCatalog.shared.stars.compactMap(\.name).count == 17)
        #expect(scene.milkyWay.count > 1000)
        #expect(scene.milkyWay.allSatisfy { $0.position.altitude > 0 && $0.weight >= 0 && $0.weight <= 1 })
        #expect(!scene.constellations.isEmpty)
        #expect(scene.constellations.flatMap(\.lines).allSatisfy { $0.count > 1 && $0.allSatisfy { $0.altitude > 0 } })
        #expect(scene.night > 0.9)
    }

    @Test func sceneIsFast() {
        let engine = SkyEngine()
        _ = engine.scene(at: .now, location: .pune, weather: .calm)  // decode the catalogue once
        let start = ContinuousClock.now
        for i in 0..<10 { _ = engine.scene(at: Date(timeIntervalSince1970: 1_800_000_000 + Double(i) * 3600), location: .pune, weather: .calm) }
        let each = (ContinuousClock.now - start) / 10
        // Debug build; release is several times faster than this bound.
        #expect(each < .milliseconds(25), "scene took \(each)")
    }
}

@Suite struct SunriseSunset {
    @Test func puneMatchesBruteForceFromTheJavaScript() {
        let s = SkyEngine().summary(at: date("2026-11-12T12:00:00Z"), location: .pune, weather: .calm)
        #expect(abs(s.sunrise!.timeIntervalSince1970 - refPuneSunrise) < 120)
        #expect(abs(s.sunset!.timeIntervalSince1970 - refPuneSunset) < 120)
        #expect(s.sunrise! < s.sunset!)
    }

    @Test func londonMatchesBruteForceFromTheJavaScript() {
        let s = SkyEngine().summary(at: date("2026-11-12T12:00:00Z"), location: locations["london"]!, weather: .calm)
        #expect(abs(s.sunrise!.timeIntervalSince1970 - refLondonSunrise) < 120)
        #expect(abs(s.sunset!.timeIntervalSince1970 - refLondonSunset) < 120)
    }

    @Test func nextSunEventAdvancesThroughTheDay() {
        let engine = SkyEngine()
        let noon = engine.summary(at: date("2026-11-12T08:00:00Z"), location: .pune, weather: .calm)
        #expect(noon.nextSunEvent?.name == "Sunset")
        #expect(noon.nextSunEvent?.date == noon.sunset)
        let night = engine.summary(at: date("2026-11-12T16:00:00Z"), location: .pune, weather: .calm)
        #expect(night.nextSunEvent?.name == "Sunrise")
        #expect(night.nextSunEvent!.date > date("2026-11-12T16:00:00Z"))
        let early = engine.summary(at: date("2026-11-12T00:00:00Z"), location: .pune, weather: .calm)
        #expect(early.nextSunEvent?.name == "Sunrise")
        #expect(early.nextSunEvent?.date == early.sunrise)
    }

    @Test func polarDayAndNightHaveNoEvents() {
        let tromso = GeoLocation(name: "Tromso", latitude: 69.65, longitude: 18.96)
        let midnightSun = SkyEngine().summary(at: date("2026-06-21T12:00:00Z"), location: tromso, weather: .calm)
        #expect(midnightSun.sunrise == nil && midnightSun.sunset == nil && midnightSun.nextSunEvent == nil)
        let polarNight = SkyEngine().summary(at: date("2026-12-21T12:00:00Z"), location: tromso, weather: .calm)
        #expect(polarNight.sunrise == nil && polarNight.sunset == nil)
    }
}

@Suite struct PaletteAndWeather {
    @Test func paletteAtKeyframesAndBetween() {
        #expect(SkyPalette.forSunAltitude(-18).skyTop == RGB(hex: "#0d0b1f"))
        #expect(SkyPalette.forSunAltitude(-6).skyTop == RGB(hex: "#2b2150"))
        #expect(SkyPalette.forSunAltitude(0).sky == RGB(hex: "#7b5a7e"))
        #expect(SkyPalette.forSunAltitude(7).haze == RGB(hex: "#ffd39b"))
        #expect(SkyPalette.forSunAltitude(25).cloudLight == RGB(hex: "#ffffff"))
        #expect(SkyPalette.forSunAltitude(90) == SkyPalette.forSunAltitude(25))
        // Midpoints against the site's own output (rounded to 8-bit hex).
        func near(_ a: RGB, _ hex: String) -> Bool {
            let b = RGB(hex: hex)
            return abs(a.r - b.r) < 1.0 / 255 && abs(a.g - b.g) < 1.0 / 255 && abs(a.b - b.b) < 1.0 / 255
        }
        let m3 = SkyPalette.forSunAltitude(-3)
        #expect(near(m3.skyTop, "#45335b") && near(m3.sky, "#634872") && near(m3.rim, "#ecd7d6") && near(m3.ground, "#23172a"))
        let p12 = SkyPalette.forSunAltitude(12)
        #expect(near(p12.skyTop, "#6386c4") && near(p12.haze, "#efd7b3") && near(p12.mid, "#645360"))
    }

    @Test func weatherCodesMapAsOnTheSite() {
        let expected: [(Int, WeatherKind)] = [
            (0, .clear), (1, .clear), (2, .clear), (3, .cloudy), (45, .fog), (48, .fog), (51, .drizzle), (55, .drizzle),
            (57, .drizzle), (61, .rain), (63, .rain), (65, .rain), (67, .rain), (71, .cloudy), (75, .cloudy), (77, .cloudy),
            (80, .rain), (82, .rain), (85, .cloudy), (95, .storm), (99, .storm), (58, .cloudy),
        ]
        for (code, kind) in expected { #expect(WMO.kind(forCode: code) == kind, "code \(code)") }
    }

    @Test func openMeteoResponseParsesAndSendsOnlyCoordinates() throws {
        let json = """
            {"latitude":18.5,"longitude":73.8,"current":{"time":"2026-11-12T12:00","temperature_2m":24.6,"weather_code":63,\
            "cloud_cover":85,"precipitation":1.2,"wind_speed_10m":14.2}}
            """
        let w = try OpenMeteoWeather.parse(Data(json.utf8))
        #expect(w.kind == .rain && w.cloudCover == 0.85 && w.temperatureC == 25 && w.windKmh == 14.2 && w.isLive)
        #expect(throws: WeatherError.self) { try OpenMeteoWeather.parse(Data("{}".utf8)) }

        let url = OpenMeteoWeather.url(for: GeoLocation(name: "Private Name", latitude: 18.5204, longitude: 73.8567))
        #expect(url.host == "api.open-meteo.com" && url.scheme == "https")
        let items = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
        #expect(Set(items.keys) == ["latitude", "longitude", "current"])
        #expect(items["latitude"] == "18.52" && items["longitude"] == "73.86")
        #expect(!url.absoluteString.contains("Private"))
    }

    @Test func locationGuessAndPresets() {
        #expect(GeoLocation.guess(for: TimeZone(identifier: "Asia/Kolkata")!).name == "Pune")
        #expect(GeoLocation.guess(for: TimeZone(identifier: "Europe/London")!).name == "London")
        #expect(GeoLocation.guess(for: TimeZone(identifier: "America/Los_Angeles")!).name == "Los Angeles")
        let fallback = GeoLocation.guess(for: TimeZone(identifier: "Africa/Addis_Ababa")!)
        #expect(fallback.name == "Addis Ababa" && fallback.latitude == 30 && fallback.longitude == 45)
        #expect(GeoLocation.presets.count >= 30)
        #expect(GeoLocation.presets.allSatisfy { abs($0.latitude) <= 90 && abs($0.longitude) <= 180 })
        #expect(GeoLocation.preset(named: " sao paulo ")?.name == "Sao Paulo")
        #expect(GeoLocation.pune == GeoLocation(name: "Pune", latitude: 18.5204, longitude: 73.8567))
    }
}
