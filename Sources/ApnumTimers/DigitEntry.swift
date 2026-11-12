/// Keyboard entry for segmented numbers such as `hr : min : sec` or `hour : minute`,
/// behaving like the macOS Clock app's time fields:
///
/// - Click or Tab to a segment, then type digits. Two digits fill a segment and
///   move on to the next one; one digit followed by another key keeps the digit.
/// - Up and Down arrows step the active segment and wrap around its range.
/// - Left and Right arrows move between segments.
/// - Delete removes the last typed digit.
public struct DigitEntry: Equatable, Sendable {
    public private(set) var values: [Int]
    public let ranges: [ClosedRange<Int>]
    public private(set) var active: Int
    /// Digits typed into the active segment since it was focused.
    public private(set) var buffer: String = ""

    public init(values: [Int], ranges: [ClosedRange<Int>], active: Int = 0) {
        precondition(values.count == ranges.count && !values.isEmpty)
        self.ranges = ranges
        self.values = zip(values, ranges).map { min(max($0, $1.lowerBound), $1.upperBound) }
        self.active = min(max(active, 0), values.count - 1)
    }

    public mutating func focus(_ index: Int) {
        active = min(max(index, 0), values.count - 1)
        buffer = ""
    }

    public mutating func type(_ digit: Int) {
        guard (0...9).contains(digit) else { return }
        let range = ranges[active]
        buffer += String(digit)
        var value = Int(buffer) ?? 0
        if value > range.upperBound {
            // Too big for two digits: start over with this digit.
            buffer = String(digit)
            value = digit
        }
        values[active] = min(max(value, range.lowerBound), range.upperBound)
        if buffer.count >= 2 || value * 10 > range.upperBound {
            advance()
        }
    }

    public mutating func step(_ delta: Int) {
        let range = ranges[active]
        let span = range.upperBound - range.lowerBound + 1
        let offset = (values[active] - range.lowerBound + delta) % span
        values[active] = range.lowerBound + (offset + span) % span
        buffer = ""
    }

    public mutating func backspace() {
        guard !buffer.isEmpty else {
            values[active] = ranges[active].lowerBound
            return
        }
        buffer.removeLast()
        values[active] = max(Int(buffer) ?? ranges[active].lowerBound, ranges[active].lowerBound)
    }

    /// Moves to the next segment; stays on the last one.
    public mutating func advance() {
        buffer = ""
        if active < values.count - 1 { active += 1 }
    }

    public mutating func retreat() {
        buffer = ""
        if active > 0 { active -= 1 }
    }

    /// Replaces all values (for example when a preset is chosen).
    public mutating func set(_ newValues: [Int]) {
        guard newValues.count == values.count else { return }
        values = zip(newValues, ranges).map { min(max($0, $1.lowerBound), $1.upperBound) }
        buffer = ""
    }
}
