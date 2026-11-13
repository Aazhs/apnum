import Foundation

public extension SkyEngine {
    /// Sunrise and sunset on the local calendar day containing `date`, at `location`.
    /// Either is nil when the sun does not cross the horizon that day (polar day or night).
    func daylight(for date: Date, location: GeoLocation, calendar: Calendar = .current) -> (sunrise: Date?, sunset: Date?) {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        let crossings = Astronomy.sunCrossings(from: start, to: end, location: location)
        return (crossings.first { $0.rising }?.date, crossings.first { !$0.rising }?.date)
    }
}
