import ApnumCore
import Foundation

public extension ChangeTopic {
    static let sky: ChangeTopic = "sky"
}

/// What is persisted in sky.json.
public struct SkySettings: Codable, Sendable, Equatable {
    public var location: GeoLocation
    public var liveWeather: Bool

    public init(location: GeoLocation, liveWeather: Bool = true) {
        self.location = location
        self.liveWeather = liveWeather
    }
}

/// Owns the sky settings (location, live weather) and the cached weather, and
/// computes scenes and summaries from them.
public actor SkyService {
    private let store: JSONFileStore<SkySettings>
    private let changes: ChangeFeed
    private let provider: (any WeatherProviding)?
    private let engine: SkyEngine
    private let now: @Sendable () -> Date

    private var current: SkySettings
    private var weather: SkyWeather?
    private var weatherFetchedAt: Date?
    private var refreshing = false

    static let weatherTTL: TimeInterval = 15 * 60

    public init(
        paths: AppPaths, changes: ChangeFeed, weather: (any WeatherProviding)?, engine: SkyEngine = .init(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        store = JSONFileStore(url: paths.file("sky.json"))
        self.changes = changes
        provider = weather
        self.engine = engine
        self.now = now
        current = SkySettings(location: .guess(for: .current))
    }

    /// Reads sky.json if it exists.
    public func load() async {
        if let saved = try? await store.load() { current = saved }
    }

    public func settings() -> SkySettings { current }

    public func setLocation(_ location: GeoLocation) async {
        guard location != current.location else { return }
        current.location = location
        weather = nil
        weatherFetchedAt = nil
        await persistAndPublish()
    }

    public func setLiveWeather(_ on: Bool) async {
        guard on != current.liveWeather else { return }
        current.liveWeather = on
        if !on {
            weather = nil
            weatherFetchedAt = nil
        }
        await persistAndPublish()
    }

    /// The cached live weather, or `.calm` when there is none.
    public func currentWeather() -> SkyWeather { weather ?? .calm }

    /// Fetches live weather unless it is off, unavailable, or was fetched less than 15 minutes ago
    /// (`force` ignores the age). Failures keep the last value. Returns whether a new value arrived.
    @discardableResult
    public func refreshWeather(force: Bool = false) async -> Bool {
        guard current.liveWeather, let provider, !refreshing else { return false }
        if !force, let at = weatherFetchedAt, now().timeIntervalSince(at) < Self.weatherTTL { return false }
        refreshing = true
        defer { refreshing = false }
        let location = current.location
        guard let fresh = try? await provider.current(at: location) else { return false }
        // The place or the setting may have changed while the request was in flight.
        guard current.liveWeather, current.location == location else { return false }
        let changed = fresh != weather
        weather = fresh
        weatherFetchedAt = now()
        if changed { changes.publish(.sky) }
        return true
    }

    public func scene(at date: Date) -> SkyScene {
        Perf.measure("scene") { engine.scene(at: date, location: current.location, weather: currentWeather()) }
    }

    /// A scene and its summary for one instant, in one actor hop (used while scrubbing time).
    public func snapshot(at date: Date) -> (scene: SkyScene, summary: SkySummary) {
        (scene(at: date), summary(at: date))
    }

    /// The real sky colour through the day at the current location (see `SkyEngine.dayColors`).
    public func dayColors(for date: Date) -> [RGB] {
        Perf.measure("dayColors") { engine.dayColors(for: date, location: current.location) }
    }

    public func summary(at date: Date) -> SkySummary {
        Perf.measure("summary") { engine.summary(at: date, location: current.location, weather: currentWeather()) }
    }

    /// The service's notion of now (injectable for tests).
    public nonisolated var currentDate: Date { now() }

    private func persistAndPublish() async {
        try? await store.save(current)
        changes.publish(.sky)
    }

    public nonisolated func makeTools() -> [AnyTool] {
        [
            AnyTool(SkyNowTool(service: self)),
            AnyTool(SkyLocationSetTool(service: self)),
            AnyTool(SkyWeatherRefreshTool(service: self)),
        ]
    }
}
