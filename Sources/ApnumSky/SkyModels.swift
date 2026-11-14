import Foundation

// The shared vocabulary of the live sky. `SkyEngine` (astronomy) produces a
// `SkyScene`; the pixel renderer in the app draws one. Keeping the contract
// here lets both sides be built and tested independently.
//
// The model follows the author's site, aarshj.me: everything is driven by the
// real altitude of the sun, not by the clock hour, so dawn and dusk last as long
// as they really do at your latitude and time of year.

// MARK: - Colour

public struct RGB: Sendable, Equatable, Hashable, Codable {
    public var r: Double, g: Double, b: Double

    public init(_ r: Double, _ g: Double, _ b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    /// "#RRGGBB".
    public init(hex: String) {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        let v = UInt32(s, radix: 16) ?? 0
        self.init(Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
    }

    /// Linear blend towards `other` by `t` (0 = self, 1 = other).
    public func mix(_ other: RGB, _ t: Double) -> RGB {
        RGB(r + (other.r - r) * t, g + (other.g - g) * t, b + (other.b - b) * t)
    }

    public var luminance: Double { 0.3 * r + 0.59 * g + 0.11 * b }

    public func scaled(_ k: Double) -> RGB { RGB(r * k, g * k, b * k) }
}

// MARK: - Palette

/// Every colour in the scene, for one sun altitude. Roles match aarshj.me.
public struct SkyPalette: Sendable, Equatable, Codable {
    public var skyTop, sky, skyLow, haze: RGB
    public var cloud, cloudLight: RGB
    public var far, peak, peakShade, mid, near, ground: RGB
    /// The lit edge on the hero ridge.
    public var rim: RGB

    public init(
        skyTop: RGB, sky: RGB, skyLow: RGB, haze: RGB, cloud: RGB, cloudLight: RGB, far: RGB, peak: RGB,
        peakShade: RGB, mid: RGB, near: RGB, ground: RGB, rim: RGB
    ) {
        self.skyTop = skyTop; self.sky = sky; self.skyLow = skyLow; self.haze = haze
        self.cloud = cloud; self.cloudLight = cloudLight
        self.far = far; self.peak = peak; self.peakShade = peakShade; self.mid = mid; self.near = near; self.ground = ground
        self.rim = rim
    }

    fileprivate init(_ h: [String]) {
        self.init(
            skyTop: RGB(hex: h[0]), sky: RGB(hex: h[1]), skyLow: RGB(hex: h[2]), haze: RGB(hex: h[3]),
            cloud: RGB(hex: h[4]), cloudLight: RGB(hex: h[5]), far: RGB(hex: h[6]), peak: RGB(hex: h[7]),
            peakShade: RGB(hex: h[8]), mid: RGB(hex: h[9]), near: RGB(hex: h[10]), ground: RGB(hex: h[11]), rim: RGB(hex: h[12]))
    }

    fileprivate var all: [RGB] { [skyTop, sky, skyLow, haze, cloud, cloudLight, far, peak, peakShade, mid, near, ground, rim] }

    fileprivate init(all c: [RGB]) {
        self.init(
            skyTop: c[0], sky: c[1], skyLow: c[2], haze: c[3], cloud: c[4], cloudLight: c[5], far: c[6], peak: c[7],
            peakShade: c[8], mid: c[9], near: c[10], ground: c[11], rim: c[12])
    }

    /// Keyframes by sun altitude in degrees (aarshj.me `sky.js`).
    static let keyframes: [(altitude: Double, palette: SkyPalette)] = [
        (-18, SkyPalette(["#0d0b1f", "#161433", "#221e45", "#2e2852", "#24213f", "#322e55", "#25234a", "#353262", "#262449", "#1b1936", "#131128", "#0c0b19", "#8c88c4"])),
        (-6, SkyPalette(["#2b2150", "#4a3666", "#7a4f78", "#9a6585", "#4f3b66", "#6a4f78", "#5c4470", "#86607e", "#644a6c", "#3c2a4e", "#2a1c38", "#1c1226", "#d9b7c8"])),
        (0, SkyPalette(["#5f4466", "#7b5a7e", "#a06e8c", "#b98299", "#7e5f86", "#93708f", "#8e5e7e", "#d88a86", "#b46f78", "#5e3a57", "#3f2740", "#2a1b2e", "#fff6e3"])),
        (7, SkyPalette(["#6d86bf", "#c9938a", "#efae84", "#ffd39b", "#d08a80", "#f6b99c", "#b07d8c", "#e09a7c", "#b2706a", "#6e4a5c", "#4a3044", "#2e1f2c", "#ffe8b8"])),
        (25, SkyPalette(["#4a86d0", "#68a2dc", "#94c2e8", "#c4e0f0", "#e4eef8", "#ffffff", "#8ea7c6", "#7391b2", "#5a7493", "#4b6a6c", "#33504a", "#22362e", "#f4fbff"])),
    ]

    static let blood = SkyPalette(["#1a0608", "#2e0b0e", "#4a1414", "#6b1f1c", "#3a1012", "#52181a", "#3d1214", "#5a1c1a", "#401314", "#2a0b0d", "#1c0709", "#120405", "#ff8a6a"])

    /// The palette for a sun altitude, linearly interpolated between keyframes.
    public static func forSunAltitude(_ degrees: Double) -> SkyPalette {
        let frames = keyframes
        let alt = min(max(degrees, frames[0].altitude), frames[frames.count - 1].altitude)
        var i = 0
        while i < frames.count - 2 && alt > frames[i + 1].altitude { i += 1 }
        let a = frames[i], b = frames[i + 1]
        let t = (alt - a.altitude) / (b.altitude - a.altitude)
        return SkyPalette(all: zip(a.palette.all, b.palette.all).map { $0.mix($1, t) })
    }

    /// The palette apnum shows for a real sun altitude, with dawn and dusk stretched.
    ///
    /// Real twilight is brief (about half an hour in the tropics), so the best colours of the day would
    /// flash past. `lingering` maps the real altitude onto the keyframes so those colours last longer.
    public static func forSky(sunAltitude degrees: Double) -> SkyPalette {
        forSunAltitude(lingering(degrees))
    }

    /// Maps a real sun altitude to the altitude used for the palette lookup. The horizon stays at the
    /// horizon; everything around it is stretched: night colours end at −21° instead of −18°, deep
    /// twilight is reached at −9.5° instead of −6°, the golden hour lasts until 13° instead of 7°, and
    /// full daylight colours arrive at 34° instead of 25°.
    public static func lingering(_ degrees: Double) -> Double {
        let real: [Double] = [-21, -9.5, 0, 13, 34]
        let shown = keyframes.map(\.altitude)  // -18, -6, 0, 7, 25
        if degrees <= real[0] { return shown[0] }
        if degrees >= real[real.count - 1] { return shown[shown.count - 1] }
        var i = 0
        while i < real.count - 2 && degrees > real[i + 1] { i += 1 }
        let t = (degrees - real[i]) / (real[i + 1] - real[i])
        return shown[i] + (shown[i + 1] - shown[i]) * t
    }

    /// Greys and darkens the sky for cloud and rain (aarshj.me `weatherTint`).
    public func weatherTinted(overcast: Double, wet: Double) -> SkyPalette {
        guard overcast > 0 || wet > 0 else { return self }
        let airy: Set<Int> = [0, 1, 2, 3, 4, 5]  // sky*, haze, cloud*
        return SkyPalette(all: all.enumerated().map { index, c in
            guard index != 12 else { return c }  // rim stays bright
            let isAiry = airy.contains(index)
            let grey = overcast * (isAiry ? 0.55 : 0.3)
            let dark = 1 - wet * (isAiry ? 0.2 : 0.12)
            let lum = c.luminance
            return c.mix(RGB(lum, lum, lum), grey).scaled(dark)
        })
    }

    /// Reddens everything during a total lunar eclipse (strength 0…1).
    public func bloodTinted(_ strength: Double) -> SkyPalette {
        guard strength > 0 else { return self }
        return SkyPalette(all: zip(all, Self.blood.all).map { $0.mix($1, strength * 0.85) })
    }
}

// MARK: - Positions and bodies

/// A position in the local sky. Angles in radians; azimuth is measured from
/// south, positive towards the west (SunCalc convention).
public struct HorizontalPosition: Sendable, Equatable, Codable {
    public var altitude: Double
    public var azimuth: Double
    public init(altitude: Double, azimuth: Double) {
        self.altitude = altitude
        self.azimuth = azimuth
    }
    public var altitudeDegrees: Double { altitude * 180 / .pi }
}

public struct SkyStar: Sendable, Equatable {
    public var position: HorizontalPosition
    public var magnitude: Double
    /// B−V colour index; drives the star's tint.
    public var colorIndex: Double
    public var name: String?

    public init(position: HorizontalPosition, magnitude: Double, colorIndex: Double, name: String? = nil) {
        self.position = position
        self.magnitude = magnitude
        self.colorIndex = colorIndex
        self.name = name
    }

    /// aarshj.me `starColour`.
    public var color: RGB {
        switch colorIndex {
        case ..<0: RGB(hex: "#b8d0ff")
        case ..<0.3: RGB(hex: "#e2e9ff")
        case ..<0.6: RGB(hex: "#fff6e3")
        case ..<1.0: RGB(hex: "#ffe1b0")
        default: RGB(hex: "#ffc48e")
        }
    }
}

public struct SkyPlanet: Sendable, Equatable {
    public var name: String
    public var position: HorizontalPosition
    public var magnitude: Double
    public var color: RGB
    public init(name: String, position: HorizontalPosition, magnitude: Double, color: RGB) {
        self.name = name
        self.position = position
        self.magnitude = magnitude
        self.color = color
    }
}

/// A faint point of the Milky Way; `weight` 0…1 is how dense the band is there.
public struct MilkyWayPoint: Sendable, Equatable {
    public var position: HorizontalPosition
    public var weight: Double
    public init(position: HorizontalPosition, weight: Double) {
        self.position = position
        self.weight = weight
    }
}

public struct ConstellationFigure: Sendable, Equatable {
    public var id: String
    public var name: String
    /// Polylines of stick-figure vertices.
    public var lines: [[HorizontalPosition]]
    /// Wikipedia article title (the part after `/wiki/`), when known.
    public var wiki: String?
    public init(id: String, name: String, lines: [[HorizontalPosition]], wiki: String? = nil) {
        self.id = id
        self.name = name
        self.lines = lines
        self.wiki = wiki
    }
}

// MARK: - Weather

public enum WeatherKind: String, Sendable, Codable, CaseIterable {
    case clear, cloudy, fog, drizzle, rain, storm

    public var label: String {
        switch self {
        case .clear: "clear"
        case .cloudy: "cloudy"
        case .fog: "foggy"
        case .drizzle: "drizzle"
        case .rain: "rain"
        case .storm: "thunderstorm"
        }
    }

    /// How wet the scene looks (aarshj.me).
    public var wetness: Double {
        switch self {
        case .drizzle: 0.4
        case .rain: 0.7
        case .storm: 1
        default: 0
        }
    }
}

public struct SkyWeather: Sendable, Equatable, Codable {
    public var kind: WeatherKind
    /// 0…1.
    public var cloudCover: Double
    public var temperatureC: Double?
    public var windKmh: Double
    /// False when this is a default rather than a live reading.
    public var isLive: Bool

    public init(kind: WeatherKind, cloudCover: Double, temperatureC: Double?, windKmh: Double, isLive: Bool) {
        self.kind = kind
        self.cloudCover = cloudCover
        self.temperatureC = temperatureC
        self.windKmh = windKmh
        self.isLive = isLive
    }

    public static let calm = SkyWeather(kind: .clear, cloudCover: 0.2, temperatureC: nil, windKmh: 6, isLive: false)

    public var overcast: Double { min(1, cloudCover * (kind == .clear ? 0.6 : 1)) }
}

// MARK: - Location

public struct GeoLocation: Sendable, Equatable, Codable {
    public var name: String
    public var latitude: Double
    public var longitude: Double
    public init(name: String, latitude: Double, longitude: Double) {
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
    }
}

// MARK: - Scene and summary

/// Everything the renderer needs for one instant.
public struct SkyScene: Sendable {
    public var date: Date
    public var location: GeoLocation
    public var weather: SkyWeather
    /// Already weather- and eclipse-tinted.
    public var palette: SkyPalette
    public var sun: HorizontalPosition
    public var moon: HorizontalPosition
    /// 0…1 illuminated fraction.
    public var moonFraction: Double
    /// 0 new, 0.25 first quarter, 0.5 full, 0.75 last quarter.
    public var moonPhase: Double
    public var stars: [SkyStar]
    public var planets: [SkyPlanet]
    public var milkyWay: [MilkyWayPoint]
    public var constellations: [ConstellationFigure]
    /// Expected meteors per minute right now (0 when no shower and not night).
    public var meteorsPerMinute: Double
    /// Where active-shower meteors appear to come from.
    public var meteorRadiant: HorizontalPosition?
    /// 0…1 during a total lunar eclipse.
    public var bloodMoon: Double
    public var supermoon: Bool

    public init(
        date: Date, location: GeoLocation, weather: SkyWeather, palette: SkyPalette, sun: HorizontalPosition,
        moon: HorizontalPosition, moonFraction: Double, moonPhase: Double, stars: [SkyStar] = [], planets: [SkyPlanet] = [],
        milkyWay: [MilkyWayPoint] = [], constellations: [ConstellationFigure] = [], meteorsPerMinute: Double = 0,
        meteorRadiant: HorizontalPosition? = nil, bloodMoon: Double = 0, supermoon: Bool = false
    ) {
        self.date = date; self.location = location; self.weather = weather; self.palette = palette
        self.sun = sun; self.moon = moon; self.moonFraction = moonFraction; self.moonPhase = moonPhase
        self.stars = stars; self.planets = planets; self.milkyWay = milkyWay; self.constellations = constellations
        self.meteorsPerMinute = meteorsPerMinute; self.meteorRadiant = meteorRadiant
        self.bloodMoon = bloodMoon; self.supermoon = supermoon
    }

    public var sunAltitudeDegrees: Double { sun.altitudeDegrees }
    public var moonWaxing: Bool { moonPhase < 0.5 }
    public var overcast: Double { weather.overcast }
    public var wet: Double { weather.kind.wetness }
    public var wind: Double { weather.windKmh }

    /// 0 while the sun is above −2°, 1 below −12° (stars, fireflies, lamp).
    public var night: Double { min(max((-sunAltitudeDegrees - 2) / 10, 0), 1) }
    /// Peaks at a sun altitude of 3°, zero outside −5…11° (warm light on the land).
    public var golden: Double { max(0, 1 - abs(sunAltitudeDegrees - 3) / 8) * (1 - overcast * 0.7) }
    /// 0 above 8°, 1 below −12° (how much the land darkens).
    public var dim: Double { min(max((8 - sunAltitudeDegrees) / 20, 0), 1) }
    /// True when light text reads better on this sky.
    public var isDark: Bool { palette.sky.luminance < 0.5 }
}

/// Equality by the inputs and headline outputs of a scene (time, place, weather, palette, sun, moon and
/// how many stars, planets and Milky Way points are up). SwiftUI compares view values on every update;
/// without this it walks the ~3,000 star and Milky Way elements of both scenes each time.
extension SkyScene: Equatable {
    public static func == (a: SkyScene, b: SkyScene) -> Bool {
        a.date == b.date && a.location == b.location && a.weather == b.weather && a.palette == b.palette
            && a.sun == b.sun && a.moon == b.moon && a.moonPhase == b.moonPhase && a.bloodMoon == b.bloodMoon
            && a.stars.count == b.stars.count && a.planets.count == b.planets.count
            && a.milkyWay.count == b.milkyWay.count && a.constellations.count == b.constellations.count
    }
}

/// Words for the sky clock: "Dusk in Pune, light rain, 24°C".
public struct SkySummary: Sendable, Equatable, Codable {
    /// Night, Dawn, Sunrise, Morning, Day, Evening, Sunset, Dusk.
    public var skyName: String
    public var placeName: String
    public var weather: SkyWeather
    public var moonPhaseName: String
    public var moonPercentLit: Int
    public var moonIsUp: Bool
    public var sunrise: Date?
    public var sunset: Date?
    /// The next of sunrise/sunset after now.
    public var nextSunEvent: SunEvent?
    /// The active meteor shower, if it is near its peak.
    public var meteorShower: String?
    /// Rare events worth a gold line: "Blood moon", "Supermoon", "Blue moon".
    public var specialEvents: [String]

    public struct SunEvent: Sendable, Equatable, Codable {
        public var name: String  // "Sunrise" or "Sunset"
        public var date: Date
        public init(name: String, date: Date) {
            self.name = name
            self.date = date
        }
    }

    public init(
        skyName: String, placeName: String, weather: SkyWeather, moonPhaseName: String, moonPercentLit: Int,
        moonIsUp: Bool, sunrise: Date?, sunset: Date?, nextSunEvent: SunEvent?, meteorShower: String?, specialEvents: [String]
    ) {
        self.skyName = skyName; self.placeName = placeName; self.weather = weather
        self.moonPhaseName = moonPhaseName; self.moonPercentLit = moonPercentLit; self.moonIsUp = moonIsUp
        self.sunrise = sunrise; self.sunset = sunset; self.nextSunEvent = nextSunEvent
        self.meteorShower = meteorShower; self.specialEvents = specialEvents
    }
}

// MARK: - Samples (for the renderer while it is developed, and for previews)

public extension SkyScene {
    /// A plausible scene without astronomy: the sun on a simple arc for the given
    /// altitude, scattered stars. For renderer development and previews only.
    static func sample(
        sunAltitudeDegrees: Double, moonPhase: Double = 0.3, weather: SkyWeather = .calm, date: Date = .now
    ) -> SkyScene {
        let sunAlt = sunAltitudeDegrees * .pi / 180
        let sun = HorizontalPosition(altitude: sunAlt, azimuth: sunAltitudeDegrees >= 0 ? -0.6 : 0.9)
        let moon = HorizontalPosition(altitude: 0.7 - sunAlt * 0.6, azimuth: 0.5)
        var seeded = SplitMix(seed: 42)
        let stars = (0..<900).map { _ in
            SkyStar(
                position: HorizontalPosition(altitude: seeded.unit() * 1.4, azimuth: (seeded.unit() - 0.5) * 2 * .pi * 0.66),
                magnitude: -1 + seeded.unit() * 6.5, colorIndex: seeded.unit() * 1.6 - 0.2)
        }
        let base = SkyPalette.forSky(sunAltitude: sunAltitudeDegrees)
        return SkyScene(
            date: date, location: GeoLocation(name: "Sample", latitude: 18.52, longitude: 73.86), weather: weather,
            palette: base.weatherTinted(overcast: weather.overcast, wet: weather.kind.wetness),
            sun: sun, moon: moon, moonFraction: (1 - cos(2 * .pi * moonPhase)) / 2, moonPhase: moonPhase,
            stars: stars, meteorsPerMinute: sunAltitudeDegrees < -12 ? 2 : 0)
    }
}

/// A tiny deterministic generator for stable procedural content.
public struct SplitMix: Sendable {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    /// Uniform in [0, 1).
    public mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}
