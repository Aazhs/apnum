import Foundation

public extension SkyEngine {
    /// The sun's altitude in degrees (negative below the horizon) at `date` for `location`.
    func sunAltitudeDegrees(at date: Date, location: GeoLocation) -> Double {
        Astronomy.sunPosition(date, location).altitudeDegrees
    }
}
