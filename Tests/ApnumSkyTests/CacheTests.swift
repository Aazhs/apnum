import Foundation
import Testing

@testable import ApnumSky

@Suite struct SkyCacheTests {
    @Test func summaryReusesSunCrossingsWithinADay() {
        let engine = SkyEngine()
        let noon = Date(timeIntervalSince1970: 1_750_000_000)
        let first = engine.summary(at: noon, location: .pune, weather: .calm)
        #expect(engine.cacheMisses == 1)
        // Scrubbing through the same solar day never recomputes sunrise and sunset.
        var last = first
        for step in 1..<20 {
            last = engine.summary(at: noon.addingTimeInterval(Double(step) * 300), location: .pune, weather: .calm)
        }
        #expect(engine.cacheMisses == 1)
        #expect(last.sunrise == first.sunrise)
        #expect(last.sunset == first.sunset)
    }

    @Test func cachedSummaryMatchesAFreshEngine() {
        let engine = SkyEngine()
        let date = Date(timeIntervalSince1970: 1_750_000_000)
        _ = engine.summary(at: date.addingTimeInterval(-3600), location: .pune, weather: .calm)
        #expect(engine.summary(at: date, location: .pune, weather: .calm) == SkyEngine().summary(at: date, location: .pune, weather: .calm))
    }

    @Test func differentDayComputesAgain() {
        let engine = SkyEngine()
        let date = Date(timeIntervalSince1970: 1_750_000_000)
        _ = engine.summary(at: date, location: .pune, weather: .calm)
        _ = engine.summary(at: date.addingTimeInterval(2 * 86_400), location: .pune, weather: .calm)
        #expect(engine.cacheMisses == 2)
    }

    @Test func dayColorsAreComputedOncePerDay() {
        let engine = SkyEngine()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        let date = Date(timeIntervalSince1970: 1_750_000_000)
        let a = engine.dayColors(for: date, location: .pune, calendar: cal)
        let b = engine.dayColors(for: date.addingTimeInterval(1800), location: .pune, calendar: cal)
        #expect(a == b)
        #expect(engine.cacheMisses == 1)
    }
}
