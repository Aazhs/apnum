import Foundation
import Synchronization

/// Results that depend only on the calendar day and the place, not on the minute: the sun's horizon
/// crossings (sunrise and sunset) and the colour ribbon of the day. Scrubbing the sky through a day asks
/// for the same answers hundreds of times, so they are computed once per (day, location).
final class SkyCache: Sendable {
    struct DayKey: Hashable {
        var day: Double  // start of the day, seconds since 1970
        var latitude: Double
        var longitude: Double
        var samples = 0
    }

    private let crossingStore = Mutex<[DayKey: [Astronomy.SunCrossing]]>([:])
    private let colorStore = Mutex<(key: DayKey, colors: [RGB])?>(nil)

    /// Number of times a value had to be computed (for tests).
    let misses = Mutex(0)

    func crossings(key: DayKey, compute: () -> [Astronomy.SunCrossing]) -> [Astronomy.SunCrossing] {
        if let hit = crossingStore.withLock({ $0[key] }) { return hit }
        let value = compute()
        misses.withLock { $0 += 1 }
        crossingStore.withLock { store in
            if store.count >= 8 { store.removeAll(keepingCapacity: true) }
            store[key] = value
        }
        return value
    }

    func colors(key: DayKey, compute: () -> [RGB]) -> [RGB] {
        if let hit = colorStore.withLock({ $0 }), hit.key == key { return hit.colors }
        let value = compute()
        misses.withLock { $0 += 1 }
        colorStore.withLock { $0 = (key, value) }
        return value
    }
}
