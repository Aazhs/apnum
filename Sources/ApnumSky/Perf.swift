import Foundation
import os
import Synchronization

/// Debug timing. With `APNUM_PERF=1` every operation slower than `threshold` prints one line to stderr
/// (`perf <label> <ms> ms`) and also emits an os_signpost interval, so Instruments shows the same spans.
/// Costs one boolean check when off. Never records inputs or outputs.
public enum Perf {
    public static let enabled = ProcessInfo.processInfo.environment["APNUM_PERF"] == "1"
    private static let log = OSLog(subsystem: "me.aarshj.apnum", category: "perf")

    /// Runs `body`, reporting its duration when `APNUM_PERF=1` and it took at least `threshold` milliseconds.
    @inline(__always)
    public static func measure<T>(_ label: StaticString, threshold: Double = 2, _ body: () throws -> T) rethrows -> T {
        guard enabled else { return try body() }
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: label, signpostID: id)
        let start = ContinuousClock.now
        defer {
            os_signpost(.end, log: log, name: label, signpostID: id)
            let d = ContinuousClock.now - start
            let ms = Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
            if ms >= threshold { note("perf \(label) \(String(format: "%.2f", ms)) ms") }
        }
        return try body()
    }

    /// One line on stderr (only when enabled).
    public static func note(_ line: @autoclosure () -> String) {
        guard enabled else { return }
        FileHandle.standardError.write(Data((line() + "\n").utf8))
    }

    private static let counts = Mutex<[String: Int]>([:])
    private static let ticker: Void = {
        let t = Thread {
            while true {
                Thread.sleep(forTimeInterval: 1)
                let snapshot = counts.withLock { c -> [String: Int] in defer { c = [:] }; return c }
                if !snapshot.isEmpty {
                    note("perf per-second " + snapshot.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
                }
            }
        }
        t.start()
    }()

    /// Counts an event; with `APNUM_PERF=1` the totals print once per second (`perf per-second scrub-set=30 applied=12`).
    public static func count(_ name: String) {
        guard enabled else { return }
        _ = ticker
        counts.withLock { $0[name, default: 0] += 1 }
    }
}
