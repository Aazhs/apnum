import ApnumCore
import Foundation

public struct SkyNowOutput: Codable, Sendable, Equatable {
    public var date: Date
    public var location: GeoLocation
    public var summary: SkySummary
    public var sunAltitudeDegrees: Double
    public var moonAltitudeDegrees: Double
    /// Planets above the horizon while the sky is dark enough to see them (sun below −3°).
    public var visiblePlanets: [String]
}

struct SkyNowTool: Tool {
    struct Input: Codable, Sendable {
        var at: String?
    }
    let service: SkyService
    static let name = "sky.now"
    static let summary =
        "Describe the sky at the user's location: sky name, weather, moon phase and whether it is up, sunrise, sunset, next sun event, meteor shower, visible planets."
    static let tier = PermissionTier.read
    static let inputSchema = Schema.object([
        "at": .string("ISO-8601 date and time to describe; defaults to now", format: "date-time")
    ])

    func run(_ input: Input, context: ToolContext) async throws -> SkyNowOutput {
        var date = service.currentDate
        if let text = input.at?.trimmingCharacters(in: .whitespaces), !text.isEmpty {
            guard let parsed = parseISODate(text) else {
                throw ToolError.invalidInput("at must be an ISO-8601 date and time such as 2026-11-12T18:30:00Z, got \"\(text)\".")
            }
            date = parsed
        }
        let scene = await service.scene(at: date)
        let summary = await service.summary(at: date)
        let dark = scene.sunAltitudeDegrees < -3
        return SkyNowOutput(
            date: date, location: scene.location, summary: summary, sunAltitudeDegrees: scene.sunAltitudeDegrees,
            moonAltitudeDegrees: scene.moon.altitudeDegrees, visiblePlanets: dark ? scene.planets.map(\.name) : [])
    }
}

func parseISODate(_ text: String) -> Date? {
    let plain = ISO8601DateFormatter()
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return plain.date(from: text) ?? fractional.date(from: text)
}

struct SkyLocationSetTool: Tool {
    struct Input: Codable, Sendable {
        var name: String?
        var latitude: Double?
        var longitude: Double?
        var preset: String?
    }
    let service: SkyService
    static let name = "sky.location.set"
    static let summary =
        "Set the place the sky is computed for: either a preset city name, or latitude and longitude in degrees with an optional name."
    static let tier = PermissionTier.write
    static let inputSchema = Schema.object([
        "preset": .string("A city from the built-in list, such as Pune, London or Tokyo"),
        "name": .string("Display name for a custom location"),
        "latitude": .number("Degrees north, -90 to 90"),
        "longitude": .number("Degrees east, -180 to 180"),
    ])

    func run(_ input: Input, context: ToolContext) async throws -> GeoLocation {
        let location: GeoLocation
        if let preset = input.preset?.trimmingCharacters(in: .whitespaces), !preset.isEmpty {
            guard let found = GeoLocation.preset(named: preset) else {
                let names = GeoLocation.presets.map(\.name).joined(separator: ", ")
                throw ToolError.invalidInput("Unknown preset \"\(preset)\". Presets: \(names). Or give latitude and longitude.")
            }
            location = found
        } else {
            guard let lat = input.latitude, let lon = input.longitude else {
                throw ToolError.invalidInput("Give a preset name, or both latitude and longitude.")
            }
            guard lat.isFinite, (-90...90).contains(lat) else {
                throw ToolError.invalidInput("latitude must be between -90 and 90, got \(lat).")
            }
            guard lon.isFinite, (-180...180).contains(lon) else {
                throw ToolError.invalidInput("longitude must be between -180 and 180, got \(lon).")
            }
            let name = input.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            location = GeoLocation(name: name.isEmpty ? "Custom location" : String(name.prefix(80)), latitude: lat, longitude: lon)
        }
        await service.setLocation(location)
        return location
    }
}

struct SkyWeatherRefreshTool: Tool {
    let service: SkyService
    static let name = "sky.weather.refresh"
    static let summary = "Fetch the live weather for the sky location now and return it (only the coordinates are sent to Open-Meteo)."
    static let tier = PermissionTier.write
    static let inputSchema = Schema.empty

    func run(_ input: Empty, context: ToolContext) async throws -> SkyWeather {
        guard await service.settings().liveWeather else {
            throw ToolError.unavailable("Live weather is turned off in the sky settings.")
        }
        guard await service.refreshWeather(force: true) else {
            throw ToolError.unavailable("Could not fetch live weather; the last known value was kept.")
        }
        return await service.currentWeather()
    }
}
