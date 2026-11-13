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
