import Foundation
import Testing
@testable import ApnumSky

@Test func paletteEndsMatchKeyframes() {
    #expect(SkyPalette.forSunAltitude(-40) == SkyPalette.forSunAltitude(-18))
    #expect(SkyPalette.forSunAltitude(0).rim == RGB(hex: "#fff6e3"))
}

@Test func dayColorsAreDarkAtMidnightAndBrightAtNoonInPune() {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Asia/Kolkata")!
    let date = cal.date(from: DateComponents(year: 2026, month: 11, day: 13, hour: 12))!
    let colors = SkyEngine().dayColors(for: date, location: .pune, samples: 25, calendar: cal)
    #expect(colors.count == 25)
    #expect(colors[0].luminance < 0.15)   // midnight
    #expect(colors[12].luminance > 0.45)  // noon
}

@Test func sunAltitudeIsHighAtNoonAndNegativeAtMidnightInPune() {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Asia/Kolkata")!
    let noon = cal.date(from: DateComponents(year: 2026, month: 11, day: 13, hour: 12))!
    let midnight = cal.date(from: DateComponents(year: 2026, month: 11, day: 13, hour: 0))!
    #expect(SkyEngine().sunAltitudeDegrees(at: noon, location: .pune) > 40)
    #expect(SkyEngine().sunAltitudeDegrees(at: midnight, location: .pune) < -20)
}

@Test func dawnAndDuskColoursLinger() {
    // The horizon and both extremes are unchanged.
    #expect(SkyPalette.lingering(0) == 0)
    #expect(SkyPalette.lingering(-40) == -18)
    #expect(SkyPalette.lingering(80) == 25)
    // Stretched in between: golden hour (palette 7) is reached at a real 13, full day (25) at 34.
    #expect(abs(SkyPalette.lingering(13) - 7) < 1e-9)
    #expect(abs(SkyPalette.lingering(34) - 25) < 1e-9)
    #expect(abs(SkyPalette.lingering(-9.5) - -6) < 1e-9)
    // A sun at 20 degrees still shows some warmth: the palette is not yet the full-day one.
    #expect(SkyPalette.forSky(sunAltitude: 20) != SkyPalette.forSunAltitude(25))
    #expect(SkyPalette.forSky(sunAltitude: 34) == SkyPalette.forSunAltitude(25))
    // Monotonic.
    var last = -100.0
    for a in stride(from: -30.0, through: 50, by: 0.5) {
        let v = SkyPalette.lingering(a)
        #expect(v >= last)
        last = v
    }
}
