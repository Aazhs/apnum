import Foundation
import Testing

@testable import ApnumSky

@Suite struct EasterEggTests {
    typealias Key = KonamiDetector.Key

    private func run(_ keys: [Key]) -> [Bool] {
        var d = KonamiDetector()
        return keys.map { d.feed($0) }
    }

    @Test func completesOnTheLastKey() {
        let r = run(KonamiDetector.sequence)
        #expect(r.last == true)
        #expect(r.dropLast().allSatisfy { !$0 })
    }

    @Test func wrongKeyRestarts() {
        #expect(!run([.up, .up, .down, .left, .right, .b, .a]).contains(true))
    }

    @Test func extraLeadingUpStillWorks() {
        #expect(run([.up] + KonamiDetector.sequence).last == true)
    }

    @Test func canRepeat() {
        let r = run(KonamiDetector.sequence + KonamiDetector.sequence)
        #expect(r.filter { $0 }.count == 2)
    }

    @Test func horrorWindowAndChance() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        func at(_ h: Int) -> Date { Date(timeIntervalSince1970: Double(h) * 3600 + 600) }
        #expect(HorrorMode.isActive(now: at(3), roll: 0.01, forced: false, calendar: cal))
        #expect(!HorrorMode.isActive(now: at(4), roll: 0.01, forced: false, calendar: cal))
        #expect(!HorrorMode.isActive(now: at(1), roll: 0.01, forced: false, calendar: cal))
        #expect(!HorrorMode.isActive(now: at(3), roll: 0.5, forced: false, calendar: cal))
        #expect(HorrorMode.isActive(now: at(12), roll: 0.9, forced: true, calendar: cal))
    }

    @Test func constellationFigureKeepsOldInitialiser() {
        let f = ConstellationFigure(id: "Ori", name: "Orion", lines: [])
        #expect(f.wiki == nil)
    }
}
