import Foundation
import Testing

@testable import ApnumSky

@Suite struct DaylightTests {
    @Test func puneEquinoxDayIsAboutTwelveHours() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        let day = cal.date(from: DateComponents(year: 2026, month: 3, day: 20, hour: 12))!
        let d = SkyEngine().daylight(for: day, location: .pune, calendar: cal)
        let rise = try #require(d.sunrise), set = try #require(d.sunset)
        #expect(rise < set)
        let hours = set.timeIntervalSince(rise) / 3600
        #expect(hours > 11.5 && hours < 12.7)
        #expect(cal.component(.hour, from: rise) == 6)
    }
}
