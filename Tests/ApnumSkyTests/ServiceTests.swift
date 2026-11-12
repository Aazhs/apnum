import ApnumCore
import Foundation
import Synchronization
import Testing

@testable import ApnumSky

final class FakeWeather: WeatherProviding {
    private let state = Mutex<(calls: Int, result: Result<SkyWeather, Error>, seen: [GeoLocation])>(
        (0, .success(FakeWeather.rainy), []))
    static let rainy = SkyWeather(kind: .rain, cloudCover: 0.9, temperatureC: 22, windKmh: 12, isLive: true)

    var calls: Int { state.withLock { $0.calls } }
    var seen: [GeoLocation] { state.withLock { $0.seen } }
    func set(_ result: Result<SkyWeather, Error>) { state.withLock { $0.result = result } }

    func current(at location: GeoLocation) async throws -> SkyWeather {
        try state.withLock {
            $0.calls += 1
            $0.seen.append(location)
            return try $0.result.get()
        }
    }
}

final class Clock: Sendable {
    private let t = Mutex(Date(timeIntervalSince1970: 1_800_000_000))
    var date: Date { t.withLock { $0 } }
    func advance(_ s: TimeInterval) { t.withLock { $0 = $0.addingTimeInterval(s) } }
}

struct Harness {
    let paths = AppPaths.temporary()
    let feed = ChangeFeed()
    let fake = FakeWeather()
    let clock = Clock()
    let service: SkyService

    init(paths: AppPaths? = nil, provider: Bool = true) {
        let p = paths ?? self.paths
        let clock = self.clock
        service = SkyService(paths: p, changes: feed, weather: provider ? fake : nil, now: { clock.date })
    }
}

@Suite struct SkyServiceTests {
    @Test func settingsPersistAcrossInstances() async throws {
        let h = Harness()
        await h.service.load()
        #expect(await h.service.settings().liveWeather)
        let tokyo = GeoLocation(name: "Tokyo", latitude: 35.68, longitude: 139.65)
        await h.service.setLocation(tokyo)
        await h.service.setLiveWeather(false)

        let again = SkyService(paths: h.paths, changes: ChangeFeed(), weather: nil)
        await again.load()
        let s = await again.settings()
        #expect(s.location == tokyo && s.liveWeather == false)
        #expect(FileManager.default.fileExists(atPath: h.paths.file("sky.json").path))
    }

    @Test func publishesOnSettingChangesOnly() async throws {
        let h = Harness()
        let stream = h.feed.subscribe()
        await h.service.setLocation(.pune)
        await h.service.setLocation(GeoLocation(name: "Paris", latitude: 48.86, longitude: 2.35))
        await h.service.setLiveWeather(true)  // already true: no change
        await h.service.setLiveWeather(false)
        var topics: [ChangeTopic] = []
        for await t in stream {
            topics.append(t)
            if topics.count == 2 { break }
        }
        #expect(topics == [.sky, .sky])
    }

    @Test func weatherIsCachedForFifteenMinutes() async {
        let h = Harness()
        await h.service.load()
        #expect(await h.service.currentWeather() == .calm)
        #expect(await h.service.refreshWeather())
        #expect(await h.service.currentWeather() == FakeWeather.rainy)
        h.clock.advance(14 * 60)
        #expect(await h.service.refreshWeather() == false)
        #expect(h.fake.calls == 1)
        h.clock.advance(2 * 60)
        #expect(await h.service.refreshWeather())
        #expect(h.fake.calls == 2)
        #expect(await h.service.refreshWeather(force: true))
        #expect(h.fake.calls == 3)
    }

    @Test func failuresKeepTheLastValue() async {
        let h = Harness()
        await h.service.refreshWeather()
        h.fake.set(.failure(URLError(.notConnectedToInternet)))
        h.clock.advance(3600)
        #expect(await h.service.refreshWeather() == false)
        #expect(await h.service.currentWeather() == FakeWeather.rainy)
    }

    @Test func liveWeatherOffNeverFetchesAndLocationChangeDropsTheCache() async {
        let h = Harness()
        await h.service.refreshWeather()
        await h.service.setLocation(GeoLocation(name: "Oslo", latitude: 59.9, longitude: 10.7))
        #expect(await h.service.currentWeather() == .calm)
        #expect(await h.service.refreshWeather())
        #expect(h.fake.seen.last?.name == "Oslo")
        await h.service.setLiveWeather(false)
        #expect(await h.service.currentWeather() == .calm)
        #expect(await h.service.refreshWeather(force: true) == false)
        #expect(h.fake.calls == 2)
    }

    @Test func noProviderMeansCalm() async {
        let h = Harness(provider: false)
        #expect(await h.service.refreshWeather() == false)
        #expect(await h.service.currentWeather() == .calm)
    }

    @Test func sceneAndSummaryUseLocationAndWeather() async {
        let h = Harness()
        await h.service.setLocation(.pune)
        await h.service.refreshWeather()
        let t = date("2026-11-12T12:00:00Z")
        let scene = await h.service.scene(at: t)
        #expect(scene.location == .pune && scene.weather == FakeWeather.rainy)
        #expect(await h.service.summary(at: t).placeName == "Pune")
    }
}

@Suite struct SkyToolTests {
    func registry(_ h: Harness) -> ToolRegistry { ToolRegistry(tools: h.service.makeTools()) }

    @Test func toolsAreDescribed() {
        let r = registry(Harness())
        #expect(r.descriptors.map(\.name) == ["sky.location.set", "sky.now", "sky.weather.refresh"])
        #expect(r.descriptor(named: "sky.now")?.tier == .read)
        #expect(r.descriptor(named: "sky.location.set")?.tier == .write)
    }

    @Test func nowReportsTheSky() async throws {
        let h = Harness()
        await h.service.setLocation(.pune)
        let r = registry(h)
        let out = try await r.callJSON("sky.now", input: ["at": "2026-11-12T20:00:00Z"], caller: .agent("test"))
        let summary = try #require(out["summary"])
        #expect(summary["skyName"] == "Night")
        #expect(summary["placeName"] == "Pune")
        #expect(summary["moonPhaseName"] != nil)
        guard case .string(let sunrise)? = summary["sunrise"] else { Issue.record("no sunrise"); return }
        #expect(parseISODate(sunrise) != nil)
        guard case .number(let alt)? = out["sunAltitudeDegrees"] else { Issue.record("no altitude"); return }
        #expect(alt < -12)
        guard case .array(let planets)? = out["visiblePlanets"] else { Issue.record("no planets"); return }
        #expect(planets.allSatisfy { if case .string = $0 { true } else { false } })

        // Defaults to the service's clock when no date is given.
        _ = try await r.callJSON("sky.now", caller: .ui)
        await #expect(throws: ToolError.self) {
            try await r.callJSON("sky.now", input: ["at": "yesterday"], caller: .ui)
        }
    }

    @Test func locationSetByPresetOrCoordinates() async throws {
        let h = Harness()
        let r = registry(h)
        let tokyo = try await r.callJSON("sky.location.set", input: ["preset": "tokyo"], caller: .agent("test"))
        #expect(tokyo["name"] == "Tokyo")
        #expect(await h.service.settings().location.name == "Tokyo")

        let custom = try await r.callJSON(
            "sky.location.set", input: ["name": "Cabin", "latitude": 60.5, "longitude": -150.25], caller: .agent("test"))
        #expect(custom["name"] == "Cabin" && custom["latitude"] == 60.5)
        #expect(await h.service.settings().location == GeoLocation(name: "Cabin", latitude: 60.5, longitude: -150.25))

        for bad: JSONValue in [
            ["latitude": 91, "longitude": 0], ["latitude": 0, "longitude": 181], ["latitude": 5], ["preset": "Atlantis"], [:],
        ] {
            await #expect(throws: ToolError.self) { try await r.callJSON("sky.location.set", input: bad, caller: .ui) }
        }
        #expect(await h.service.settings().location.name == "Cabin")
    }

    @Test func weatherRefreshReturnsTheWeather() async throws {
        let h = Harness()
        let r = registry(h)
        let out = try await r.callJSON("sky.weather.refresh", caller: .agent("test"))
        #expect(out["kind"] == "rain" && out["isLive"] == true)
        #expect(h.fake.calls == 1)
        _ = try await r.callJSON("sky.weather.refresh", caller: .agent("test"))
        #expect(h.fake.calls == 2)  // explicit refresh ignores the cache

        h.fake.set(.failure(URLError(.timedOut)))
        await #expect(throws: ToolError.self) { try await r.callJSON("sky.weather.refresh", caller: .ui) }

        await h.service.setLiveWeather(false)
        await #expect(throws: ToolError.self) { try await r.callJSON("sky.weather.refresh", caller: .ui) }
    }
}
