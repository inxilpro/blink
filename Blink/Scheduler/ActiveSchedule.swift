import Foundation

/// The hours-of-day and days-of-week window during which Blink issues breaks.
/// Pure value semantics: all window arithmetic is testable without a clock.
struct ActiveSchedule: Equatable, Sendable {
    static let minuteRange = 0...(24 * 60 - 1)

    var limitHours: Bool
    /// Minutes from midnight. When `endMinute <= startMinute` the window runs
    /// past midnight, and `days` refers to the day the window *starts* on.
    var startMinute: Int
    var endMinute: Int
    var limitDays: Bool
    /// `Calendar` weekday numbers, 1 = Sunday.
    var days: Set<Int>

    static let unrestricted = ActiveSchedule(
        limitHours: false,
        startMinute: 9 * 60,
        endMinute: 17 * 60,
        limitDays: false,
        days: Set(2...6)
    )

    /// True when no filtering applies and the scheduler can ignore the window entirely.
    var isAlwaysActive: Bool {
        !limitHours && allowedDays.count == 7
    }

    /// An empty day selection would leave Blink permanently dormant, so it is
    /// read as "no day filter" rather than "never".
    private var allowedDays: Set<Int> {
        limitDays && !days.isEmpty ? days : Set(1...7)
    }

    func isActive(at date: Date, calendar: Calendar = .autoupdatingCurrent) -> Bool {
        guard !isAlwaysActive else { return true }
        return window(containing: date, calendar: calendar) != nil
    }

    /// The moment the current window closes, or `nil` if `date` is outside one.
    func currentWindowEnd(at date: Date, calendar: Calendar = .autoupdatingCurrent) -> Date? {
        guard !isAlwaysActive else { return nil }
        return window(containing: date, calendar: calendar)?.end
    }

    /// The next moment a window opens strictly after `date`.
    func nextActivation(after date: Date, calendar: Calendar = .autoupdatingCurrent) -> Date? {
        guard !isAlwaysActive else { return nil }
        // A week plus slack covers every reachable day, including DST shifts.
        for offset in 0...8 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: date),
                  let window = window(startingOnDayOf: day, calendar: calendar),
                  window.start > date
            else { continue }
            return window.start
        }
        return nil
    }

    // MARK: - Window arithmetic

    private func window(containing date: Date, calendar: Calendar) -> (start: Date, end: Date)? {
        // An overnight window covering `date` starts on the previous day.
        for offset in [0, -1] {
            guard let day = calendar.date(byAdding: .day, value: offset, to: date),
                  let window = window(startingOnDayOf: day, calendar: calendar),
                  window.start <= date, date < window.end
            else { continue }
            return window
        }
        return nil
    }

    /// The window that begins on the calendar day containing `date`, or `nil`
    /// when that weekday is excluded.
    private func window(startingOnDayOf date: Date, calendar: Calendar) -> (start: Date, end: Date)? {
        let day = calendar.startOfDay(for: date)
        guard allowedDays.contains(calendar.component(.weekday, from: day)) else { return nil }
        guard limitHours else {
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            return (day, next)
        }
        guard let start = time(startMinute, onDayOf: day, calendar: calendar) else { return nil }
        let endDay = endMinute > startMinute ? day : calendar.date(byAdding: .day, value: 1, to: day)
        guard let endDay, let end = time(endMinute, onDayOf: endDay, calendar: calendar) else { return nil }
        // Equal start/end means a full day; the guard also absorbs DST anomalies.
        guard end > start else { return (start, start.addingTimeInterval(24 * 3600)) }
        return (start, end)
    }

    private func time(_ minuteOfDay: Int, onDayOf date: Date, calendar: Calendar) -> Date? {
        calendar.date(
            bySettingHour: minuteOfDay / 60,
            minute: minuteOfDay % 60,
            second: 0,
            of: date,
            matchingPolicy: .nextTime,
            direction: .forward
        )
    }
}
