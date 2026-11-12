import Foundation

/// Where live weather comes from. Implementations must send nothing but the coordinates.
public protocol WeatherProviding: Sendable {
    func current(at: GeoLocation) async throws -> SkyWeather
}

public enum WeatherError: Error, Sendable, Equatable {
    case badResponse(Int)
    case malformed
}

/// Open-Meteo (https://open-meteo.com): free, keyless. Only the (rounded) coordinates leave the Mac.
public struct OpenMeteoWeather: WeatherProviding {
    private let session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    public static func url(for location: GeoLocation) -> URL {
        var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        c.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.2f", location.latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.2f", location.longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code,cloud_cover,precipitation,wind_speed_10m"),
        ]
        return c.url!
    }

    public func current(at location: GeoLocation) async throws -> SkyWeather {
        var request = URLRequest(url: Self.url(for: location), timeoutInterval: 10)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw WeatherError.badResponse(http.statusCode)
        }
        return try Self.parse(data)
    }

    struct Response: Decodable {
        struct Current: Decodable {
            var temperature_2m: Double?
            var weather_code: Int
            var cloud_cover: Double?
            var wind_speed_10m: Double?
        }
        var current: Current
    }

    static func parse(_ data: Data) throws -> SkyWeather {
        guard let c = try? JSONDecoder().decode(Response.self, from: data).current else { throw WeatherError.malformed }
        return WMO.weather(
            code: c.weather_code, cloudPercent: c.cloud_cover ?? 0, temperatureC: c.temperature_2m, windKmh: c.wind_speed_10m ?? 0)
    }
}

/// WMO weather codes grouped into what the scene can draw (as on aarshj.me).
public enum WMO {
    public static func kind(forCode code: Int) -> WeatherKind {
        if code <= 2 { return .clear }
        if code == 3 { return .cloudy }
        if code == 45 || code == 48 { return .fog }
        if (51...57).contains(code) { return .drizzle }
        if (61...67).contains(code) || (80...82).contains(code) { return .rain }
        if (71...77).contains(code) { return .cloudy }
        if code >= 95 { return .storm }
        return .cloudy
    }

    public static func weather(code: Int, cloudPercent: Double, temperatureC: Double?, windKmh: Double) -> SkyWeather {
        SkyWeather(
            kind: kind(forCode: code), cloudCover: min(1, max(0, cloudPercent / 100)),
            temperatureC: temperatureC.map { $0.rounded() }, windKmh: windKmh, isLive: true)
    }
}
