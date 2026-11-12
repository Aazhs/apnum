import Foundation

/// Computes the real sky for a place and time. PLACEHOLDER: returns sample
/// scenes until the astronomy port lands; the public API is final.
public struct SkyEngine: Sendable {
    public init() {}

    public func scene(at date: Date, location: GeoLocation, weather: SkyWeather) -> SkyScene {
        let hour = Double(Calendar.current.component(.hour, from: date))
        return .sample(sunAltitudeDegrees: 60 * sin((hour - 6) / 24 * 2 * .pi) - 10, weather: weather, date: date)
    }

    public func summary(at date: Date, location: GeoLocation, weather: SkyWeather) -> SkySummary {
        SkySummary(
            skyName: "Day", placeName: location.name, weather: weather, moonPhaseName: "Waxing crescent", moonPercentLit: 30,
            moonIsUp: false, sunrise: nil, sunset: nil, nextSunEvent: nil, meteorShower: nil, specialEvents: [])
    }
}
