import Foundation
import Observation

extension Notification.Name {
    static let blinkSettingsDidChange = Notification.Name("BlinkSettingsDidChange")
}

/// User-configurable settings, persisted to `UserDefaults`. All durations are in seconds.
@MainActor
@Observable
final class AppSettings {
    static let workIntervalRange: ClosedRange<TimeInterval> = (5 * 60)...(120 * 60)
    static let breakDurationRange: ClosedRange<TimeInterval> = 10...120
    static let preBreakLeadRange: ClosedRange<TimeInterval> = 0...60
    static let dimLevelRange: ClosedRange<Double> = 0.2...0.9
    static let idleResetRange: ClosedRange<TimeInterval> = 60...(30 * 60)

    var workInterval: TimeInterval { didSet { persist(workInterval, forKey: Keys.workInterval, oldValue: oldValue) } }
    var breakDuration: TimeInterval { didSet { persist(breakDuration, forKey: Keys.breakDuration, oldValue: oldValue) } }
    var preBreakLead: TimeInterval { didSet { persist(preBreakLead, forKey: Keys.preBreakLead, oldValue: oldValue) } }
    var dimLevel: Double { didSet { persist(dimLevel, forKey: Keys.dimLevel, oldValue: oldValue) } }
    var idleResetThreshold: TimeInterval { didSet { persist(idleResetThreshold, forKey: Keys.idleReset, oldValue: oldValue) } }
    var skipDuringCapture: Bool { didSet { persist(skipDuringCapture, forKey: Keys.skipDuringCapture, oldValue: oldValue) } }
    var playSounds: Bool { didSet { persist(playSounds, forKey: Keys.playSounds, oldValue: oldValue) } }
    var showTimeRemainingInMenuBar: Bool { didSet { persist(showTimeRemainingInMenuBar, forKey: Keys.showTimeRemaining, oldValue: oldValue) } }

    var limitToActiveHours: Bool { didSet { persist(limitToActiveHours, forKey: Keys.limitToActiveHours, oldValue: oldValue) } }
    /// Minutes from midnight; an end at or before the start means the window runs overnight.
    var activeStartMinute: Int {
        didSet {
            let clamped = ActiveSchedule.minuteRange.clamping(activeStartMinute)
            guard clamped == activeStartMinute else {
                activeStartMinute = clamped
                return
            }
            persist(activeStartMinute, forKey: Keys.activeStart, oldValue: oldValue)
        }
    }
    var activeEndMinute: Int {
        didSet {
            let clamped = ActiveSchedule.minuteRange.clamping(activeEndMinute)
            guard clamped == activeEndMinute else {
                activeEndMinute = clamped
                return
            }
            persist(activeEndMinute, forKey: Keys.activeEnd, oldValue: oldValue)
        }
    }
    var limitToActiveDays: Bool { didSet { persist(limitToActiveDays, forKey: Keys.limitToActiveDays, oldValue: oldValue) } }
    /// `Calendar` weekday numbers, 1 = Sunday.
    var activeDays: Set<Int> {
        didSet {
            guard activeDays != oldValue else { return }
            defaults.set(Self.mask(from: activeDays), forKey: Keys.activeDays)
            notifyChange(key: Keys.activeDays)
        }
    }

    /// The window the scheduler enforces, derived from the toggles above.
    var activeSchedule: ActiveSchedule {
        ActiveSchedule(
            limitHours: limitToActiveHours,
            startMinute: activeStartMinute,
            endMinute: activeEndMinute,
            limitDays: limitToActiveDays,
            days: activeDays
        )
    }

    enum Keys {
        static let workInterval = "workIntervalSeconds"
        static let breakDuration = "breakDurationSeconds"
        static let preBreakLead = "preBreakLeadSeconds"
        static let dimLevel = "dimLevel"
        static let idleReset = "idleResetSeconds"
        static let skipDuringCapture = "skipDuringCapture"
        static let playSounds = "playSounds"
        static let showTimeRemaining = "showTimeRemainingInMenuBar"
        static let limitToActiveHours = "limitToActiveHours"
        static let activeStart = "activeStartMinute"
        static let activeEnd = "activeEndMinute"
        static let limitToActiveDays = "limitToActiveDays"
        static let activeDays = "activeDaysMask"
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Keys.workInterval: 20.0 * 60,
            Keys.breakDuration: 20.0,
            Keys.preBreakLead: 15.0,
            Keys.dimLevel: 0.5,
            Keys.idleReset: 3.0 * 60,
            Keys.skipDuringCapture: true,
            Keys.playSounds: false,
            Keys.showTimeRemaining: false,
            Keys.limitToActiveHours: false,
            Keys.activeStart: 9 * 60,
            Keys.activeEnd: 17 * 60,
            Keys.limitToActiveDays: false,
            Keys.activeDays: Self.mask(from: Set(2...6)),
        ])
        workInterval = Self.workIntervalRange.clamping(defaults.double(forKey: Keys.workInterval))
        breakDuration = Self.breakDurationRange.clamping(defaults.double(forKey: Keys.breakDuration))
        preBreakLead = Self.preBreakLeadRange.clamping(defaults.double(forKey: Keys.preBreakLead))
        dimLevel = Self.dimLevelRange.clamping(defaults.double(forKey: Keys.dimLevel))
        idleResetThreshold = Self.idleResetRange.clamping(defaults.double(forKey: Keys.idleReset))
        skipDuringCapture = defaults.bool(forKey: Keys.skipDuringCapture)
        playSounds = defaults.bool(forKey: Keys.playSounds)
        showTimeRemainingInMenuBar = defaults.bool(forKey: Keys.showTimeRemaining)
        limitToActiveHours = defaults.bool(forKey: Keys.limitToActiveHours)
        activeStartMinute = ActiveSchedule.minuteRange.clamping(defaults.integer(forKey: Keys.activeStart))
        activeEndMinute = ActiveSchedule.minuteRange.clamping(defaults.integer(forKey: Keys.activeEnd))
        limitToActiveDays = defaults.bool(forKey: Keys.limitToActiveDays)
        activeDays = Self.days(fromMask: defaults.integer(forKey: Keys.activeDays))
    }

    private func persist(_ value: Double, forKey key: String, oldValue: Double) {
        guard value != oldValue else { return }
        defaults.set(value, forKey: key)
        notifyChange(key: key)
    }

    private func persist(_ value: Int, forKey key: String, oldValue: Int) {
        guard value != oldValue else { return }
        defaults.set(value, forKey: key)
        notifyChange(key: key)
    }

    private func persist(_ value: Bool, forKey key: String, oldValue: Bool) {
        guard value != oldValue else { return }
        defaults.set(value, forKey: key)
        notifyChange(key: key)
    }

    private func notifyChange(key: String) {
        NotificationCenter.default.post(name: .blinkSettingsDidChange, object: self, userInfo: ["key": key])
    }

    // MARK: - Weekday bitmask

    private static func mask(from days: Set<Int>) -> Int {
        days.filter { (1...7).contains($0) }.reduce(0) { $0 | (1 << $1) }
    }

    private static func days(fromMask mask: Int) -> Set<Int> {
        Set((1...7).filter { mask & (1 << $0) != 0 })
    }
}

extension ClosedRange {
    func clamping(_ value: Bound) -> Bound {
        Swift.min(Swift.max(value, lowerBound), upperBound)
    }
}
