import Foundation

public extension GeoLocation {
    static let pune = GeoLocation(name: "Pune", latitude: 18.5204, longitude: 73.8567)

    /// A best guess of where the user is from the Mac's time zone: the city the
    /// identifier names, or a mid-latitude point on the time zone's meridian.
    static func guess(for timeZone: TimeZone) -> GeoLocation {
        if let city = timeZoneCities[timeZone.identifier] { return city }
        let last = timeZone.identifier.split(separator: "/").last.map(String.init) ?? timeZone.identifier
        let name = last.replacingOccurrences(of: "_", with: " ")
        let longitude = Double(timeZone.secondsFromGMT()) / 3600 * 15
        return GeoLocation(name: name.isEmpty ? "Home" : name, latitude: 30, longitude: min(180, max(-180, longitude)))
    }

    /// A short list of world cities for a picker.
    static let presets: [GeoLocation] = [
        pune,
        GeoLocation(name: "Mumbai", latitude: 19.0760, longitude: 72.8777),
        GeoLocation(name: "New Delhi", latitude: 28.6139, longitude: 77.2090),
        GeoLocation(name: "Bengaluru", latitude: 12.9716, longitude: 77.5946),
        GeoLocation(name: "Kolkata", latitude: 22.5726, longitude: 88.3639),
        GeoLocation(name: "Dhaka", latitude: 23.8103, longitude: 90.4125),
        GeoLocation(name: "Dubai", latitude: 25.2048, longitude: 55.2708),
        GeoLocation(name: "Singapore", latitude: 1.3521, longitude: 103.8198),
        GeoLocation(name: "Bangkok", latitude: 13.7563, longitude: 100.5018),
        GeoLocation(name: "Hong Kong", latitude: 22.3193, longitude: 114.1694),
        GeoLocation(name: "Shanghai", latitude: 31.2304, longitude: 121.4737),
        GeoLocation(name: "Tokyo", latitude: 35.6762, longitude: 139.6503),
        GeoLocation(name: "Seoul", latitude: 37.5665, longitude: 126.9780),
        GeoLocation(name: "Sydney", latitude: -33.8688, longitude: 151.2093),
        GeoLocation(name: "Auckland", latitude: -36.8509, longitude: 174.7645),
        GeoLocation(name: "London", latitude: 51.5074, longitude: -0.1278),
        GeoLocation(name: "Paris", latitude: 48.8566, longitude: 2.3522),
        GeoLocation(name: "Berlin", latitude: 52.5200, longitude: 13.4050),
        GeoLocation(name: "Madrid", latitude: 40.4168, longitude: -3.7038),
        GeoLocation(name: "Istanbul", latitude: 41.0082, longitude: 28.9784),
        GeoLocation(name: "Moscow", latitude: 55.7558, longitude: 37.6173),
        GeoLocation(name: "Reykjavik", latitude: 64.1466, longitude: -21.9426),
        GeoLocation(name: "Cairo", latitude: 30.0444, longitude: 31.2357),
        GeoLocation(name: "Nairobi", latitude: -1.2921, longitude: 36.8219),
        GeoLocation(name: "Lagos", latitude: 6.5244, longitude: 3.3792),
        GeoLocation(name: "Johannesburg", latitude: -26.2041, longitude: 28.0473),
        GeoLocation(name: "New York", latitude: 40.7128, longitude: -74.0060),
        GeoLocation(name: "Chicago", latitude: 41.8781, longitude: -87.6298),
        GeoLocation(name: "Denver", latitude: 39.7392, longitude: -104.9903),
        GeoLocation(name: "Los Angeles", latitude: 34.0522, longitude: -118.2437),
        GeoLocation(name: "San Francisco", latitude: 37.7749, longitude: -122.4194),
        GeoLocation(name: "Toronto", latitude: 43.6532, longitude: -79.3832),
        GeoLocation(name: "Mexico City", latitude: 19.4326, longitude: -99.1332),
        GeoLocation(name: "Sao Paulo", latitude: -23.5505, longitude: -46.6333),
        GeoLocation(name: "Buenos Aires", latitude: -34.6037, longitude: -58.3816),
    ]

    /// A preset by name, ignoring case and diacritics.
    static func preset(named name: String) -> GeoLocation? {
        let key = name.trimmingCharacters(in: .whitespaces).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return presets.first {
            $0.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) == key
        }
    }
}

/// Time zone identifier to the city it is named for (India maps to Pune).
private let timeZoneCities: [String: GeoLocation] = {
    let cities: [(ids: [String], city: GeoLocation)] = [
        (["Asia/Kolkata", "Asia/Calcutta"], .pune),
        (["Europe/London", "Europe/Belfast", "Europe/Jersey"], GeoLocation(name: "London", latitude: 51.5074, longitude: -0.1278)),
        (["Europe/Paris"], GeoLocation(name: "Paris", latitude: 48.8566, longitude: 2.3522)),
        (["Europe/Berlin"], GeoLocation(name: "Berlin", latitude: 52.52, longitude: 13.405)),
        (["Europe/Madrid"], GeoLocation(name: "Madrid", latitude: 40.4168, longitude: -3.7038)),
        (["Europe/Rome"], GeoLocation(name: "Rome", latitude: 41.9028, longitude: 12.4964)),
        (["Europe/Amsterdam"], GeoLocation(name: "Amsterdam", latitude: 52.3676, longitude: 4.9041)),
        (["Europe/Stockholm"], GeoLocation(name: "Stockholm", latitude: 59.3293, longitude: 18.0686)),
        (["Europe/Istanbul", "Asia/Istanbul"], GeoLocation(name: "Istanbul", latitude: 41.0082, longitude: 28.9784)),
        (["Europe/Moscow"], GeoLocation(name: "Moscow", latitude: 55.7558, longitude: 37.6173)),
        (["Atlantic/Reykjavik"], GeoLocation(name: "Reykjavik", latitude: 64.1466, longitude: -21.9426)),
        (["America/New_York", "US/Eastern"], GeoLocation(name: "New York", latitude: 40.7128, longitude: -74.006)),
        (["America/Chicago", "US/Central"], GeoLocation(name: "Chicago", latitude: 41.8781, longitude: -87.6298)),
        (["America/Denver", "US/Mountain"], GeoLocation(name: "Denver", latitude: 39.7392, longitude: -104.9903)),
        (["America/Los_Angeles", "US/Pacific"], GeoLocation(name: "Los Angeles", latitude: 34.0522, longitude: -118.2437)),
        (["America/Phoenix"], GeoLocation(name: "Phoenix", latitude: 33.4484, longitude: -112.074)),
        (["America/Anchorage"], GeoLocation(name: "Anchorage", latitude: 61.2181, longitude: -149.9003)),
        (["Pacific/Honolulu"], GeoLocation(name: "Honolulu", latitude: 21.3069, longitude: -157.8583)),
        (["America/Toronto"], GeoLocation(name: "Toronto", latitude: 43.6532, longitude: -79.3832)),
        (["America/Vancouver"], GeoLocation(name: "Vancouver", latitude: 49.2827, longitude: -123.1207)),
        (["America/Mexico_City"], GeoLocation(name: "Mexico City", latitude: 19.4326, longitude: -99.1332)),
        (["America/Sao_Paulo"], GeoLocation(name: "Sao Paulo", latitude: -23.5505, longitude: -46.6333)),
        (["America/Argentina/Buenos_Aires", "America/Buenos_Aires"], GeoLocation(name: "Buenos Aires", latitude: -34.6037, longitude: -58.3816)),
        (["America/Bogota"], GeoLocation(name: "Bogota", latitude: 4.711, longitude: -74.0721)),
        (["Africa/Cairo"], GeoLocation(name: "Cairo", latitude: 30.0444, longitude: 31.2357)),
        (["Africa/Lagos"], GeoLocation(name: "Lagos", latitude: 6.5244, longitude: 3.3792)),
        (["Africa/Nairobi"], GeoLocation(name: "Nairobi", latitude: -1.2921, longitude: 36.8219)),
        (["Africa/Johannesburg"], GeoLocation(name: "Johannesburg", latitude: -26.2041, longitude: 28.0473)),
        (["Asia/Dubai"], GeoLocation(name: "Dubai", latitude: 25.2048, longitude: 55.2708)),
        (["Asia/Karachi"], GeoLocation(name: "Karachi", latitude: 24.8607, longitude: 67.0011)),
        (["Asia/Dhaka"], GeoLocation(name: "Dhaka", latitude: 23.8103, longitude: 90.4125)),
        (["Asia/Bangkok"], GeoLocation(name: "Bangkok", latitude: 13.7563, longitude: 100.5018)),
        (["Asia/Jakarta"], GeoLocation(name: "Jakarta", latitude: -6.2088, longitude: 106.8456)),
        (["Asia/Singapore"], GeoLocation(name: "Singapore", latitude: 1.3521, longitude: 103.8198)),
        (["Asia/Hong_Kong"], GeoLocation(name: "Hong Kong", latitude: 22.3193, longitude: 114.1694)),
        (["Asia/Shanghai", "Asia/Chongqing"], GeoLocation(name: "Shanghai", latitude: 31.2304, longitude: 121.4737)),
        (["Asia/Tokyo"], GeoLocation(name: "Tokyo", latitude: 35.6762, longitude: 139.6503)),
        (["Asia/Seoul"], GeoLocation(name: "Seoul", latitude: 37.5665, longitude: 126.978)),
        (["Australia/Sydney", "Australia/Melbourne"], GeoLocation(name: "Sydney", latitude: -33.8688, longitude: 151.2093)),
        (["Australia/Perth"], GeoLocation(name: "Perth", latitude: -31.9505, longitude: 115.8605)),
        (["Pacific/Auckland"], GeoLocation(name: "Auckland", latitude: -36.8509, longitude: 174.7645)),
        (["UTC", "GMT", "Etc/UTC", "Etc/GMT"], GeoLocation(name: "Greenwich", latitude: 51.4769, longitude: 0)),
    ]
    var map: [String: GeoLocation] = [:]
    for entry in cities { for id in entry.ids { map[id] = entry.city } }
    return map
}()
