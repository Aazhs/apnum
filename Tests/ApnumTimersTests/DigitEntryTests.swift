import Testing
@testable import ApnumTimers

@Suite struct DigitEntryTests {
    func timer() -> DigitEntry { DigitEntry(values: [0, 0, 0], ranges: [0...23, 0...59, 0...59]) }

    @Test func twoDigitsFillASegmentAndAdvance() {
        var e = timer()
        e.type(1); e.type(2)
        #expect(e.values == [12, 0, 0])
        #expect(e.active == 1)
        e.type(3); e.type(0)
        #expect(e.values == [12, 30, 0])
        #expect(e.active == 2)
    }

    @Test func aDigitThatCannotStartATwoDigitValueAdvancesAtOnce() {
        var e = timer()
        e.focus(1)
        e.type(7)  // 70+ is over 59, so 7 is final
        #expect(e.values == [0, 7, 0])
        #expect(e.active == 2)
    }

    @Test func overflowStartsOver() {
        var e = DigitEntry(values: [0, 0], ranges: [0...23, 0...59])
        e.type(2); e.type(9)  // 29 > 23: keep 9 and advance (9 can't start a two-digit hour)
        #expect(e.values[0] == 9)
        #expect(e.active == 1)
    }

    @Test func arrowsWrap() {
        var e = DigitEntry(values: [0, 59], ranges: [1...12, 0...59], active: 1)
        e.step(1)
        #expect(e.values[1] == 0)
        e.step(-1)
        #expect(e.values[1] == 59)
        e.focus(0)
        #expect(e.values[0] == 1)  // clamped into 1...12 on init
        e.step(-1)
        #expect(e.values[0] == 12)
    }

    @Test func backspaceAndSet() {
        var e = timer()
        e.type(1)  // could still become 10-19, so it stays on hours
        #expect(e.active == 0)
        e.backspace()
        #expect(e.values[0] == 0)
        e.set([1, 2, 3])
        #expect(e.values == [1, 2, 3])
        e.set([99, 99, 99])
        #expect(e.values == [23, 59, 59])
    }
}
