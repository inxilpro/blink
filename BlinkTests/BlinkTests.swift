import Foundation
import Testing
@testable import Blink

// MARK: - Virtual time

/// A `SchedulerClock` driven by `advance(by:)`, firing due timers in order.
@MainActor
final class TestClock: SchedulerClock {
    final class Token: SchedulerToken {
        fileprivate var isCancelled = false
        func cancel() { isCancelled = true }
    }

    private final class Entry {
        var due: Date
        let interval: TimeInterval?
        let body: @MainActor () -> Void
        let token: Token

        init(due: Date, interval: TimeInterval?, body: @escaping @MainActor () -> Void, token: Token) {
            self.due = due
            self.interval = interval
            self.body = body
            self.token = token
        }
    }

    var now = Date(timeIntervalSinceReferenceDate: 0)
    private var entries: [Entry] = []

    @discardableResult
    func after(_ delay: TimeInterval, tolerance: TimeInterval, _ body: @escaping @MainActor () -> Void) -> SchedulerToken {
        let token = Token()
        entries.append(Entry(due: now.addingTimeInterval(delay), interval: nil, body: body, token: token))
        return token
    }

    @discardableResult
    func repeating(every interval: TimeInterval, tolerance: TimeInterval, _ body: @escaping @MainActor () -> Void) -> SchedulerToken {
        let token = Token()
        entries.append(Entry(due: now.addingTimeInterval(interval), interval: interval, body: body, token: token))
        return token
    }

    func advance(by seconds: TimeInterval) {
        let target = now.addingTimeInterval(seconds)
        while true {
            entries.removeAll { $0.token.isCancelled }
            guard let next = entries.filter({ $0.due <= target }).min(by: { $0.due < $1.due }) else { break }
            now = next.due
            if let interval = next.interval {
                next.due = next.due.addingTimeInterval(interval)
            } else {
                entries.removeAll { $0 === next }
            }
            next.body()
        }
        now = target
    }
}

// MARK: - Delegate recording

@MainActor
final class DelegateRecorder: BreakSchedulerDelegate {
    var preBreakLeads: [TimeInterval] = []
    var breakStarts: [(endDate: Date, duration: TimeInterval)] = []
    var breakEnds: [Bool] = []

    func schedulerDidEnterPreBreak(_ scheduler: BreakScheduler, leadTime: TimeInterval) {
        preBreakLeads.append(leadTime)
    }

    func schedulerDidStartBreak(_ scheduler: BreakScheduler, endDate: Date, duration: TimeInterval) {
        breakStarts.append((endDate, duration))
    }

    func schedulerDidEndBreak(_ scheduler: BreakScheduler, completed: Bool) {
        breakEnds.append(completed)
    }

    func schedulerStateDidChange(_ scheduler: BreakScheduler) {}
}

// MARK: - Test environment

@MainActor
final class TestEnvironment {
    /// Mutable world state the scheduler reads through its injected closures.
    @MainActor
    final class World {
        var idleSeconds: TimeInterval = 0
        var captureActive = false
    }

    let clock = TestClock()
    let settings: AppSettings
    let recorder = DelegateRecorder()
    let scheduler: BreakScheduler
    private let world: World
    private let suiteName: String

    var idleSeconds: TimeInterval {
        get { world.idleSeconds }
        set { world.idleSeconds = newValue }
    }

    var captureActive: Bool {
        get { world.captureActive }
        set { world.captureActive = newValue }
    }

    init(calendar: Calendar = .current, startingAt start: Date? = nil) {
        let suiteName = "BlinkTests-\(UUID().uuidString)"
        let world = World()
        let settings = AppSettings(defaults: UserDefaults(suiteName: suiteName)!)
        self.suiteName = suiteName
        self.world = world
        self.settings = settings
        if let start {
            clock.now = start
        }
        scheduler = BreakScheduler(
            settings: settings,
            clock: clock,
            calendar: calendar,
            idleSeconds: { world.idleSeconds },
            isCaptureActive: { world.captureActive }
        )
        scheduler.delegate = recorder
    }

    deinit {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }
}

// MARK: - Tests

@Suite("Break scheduler")
@MainActor
struct BreakSchedulerTests {
    @Test("Default cycle: work → pre-break → break → work")
    func fullCycle() {
        let env = TestEnvironment()
        env.scheduler.start()
        #expect(env.scheduler.phase == .working)
        #expect(env.scheduler.nextBreakDate == env.clock.now.addingTimeInterval(20 * 60))

        // Pre-break fires 15 s before the 20-minute mark.
        env.clock.advance(by: 20 * 60 - 15)
        #expect(env.scheduler.phase == .preBreak)
        #expect(env.recorder.preBreakLeads == [15])

        env.clock.advance(by: 15)
        #expect(env.scheduler.phase == .onBreak)
        #expect(env.recorder.breakStarts.count == 1)
        #expect(env.recorder.breakStarts[0].duration == 20)

        env.clock.advance(by: 20)
        #expect(env.scheduler.phase == .working)
        #expect(env.recorder.breakEnds == [true])
        #expect(env.scheduler.nextBreakDate == env.clock.now.addingTimeInterval(20 * 60))
    }

    @Test("Idle past threshold at pre-break time silently resets the timer")
    func idleAtPreBreakResets() {
        let env = TestEnvironment()
        env.scheduler.start()
        env.idleSeconds = 4 * 60

        env.clock.advance(by: 20 * 60)
        #expect(env.scheduler.phase == .working)
        #expect(env.recorder.preBreakLeads.isEmpty)
        #expect(env.recorder.breakStarts.isEmpty)
    }

    @Test("Going idle mid-interval keeps pushing the timer out (rolling reset)")
    func idleDuringWorkRolls() {
        let env = TestEnvironment()
        env.scheduler.start()

        env.clock.advance(by: 10 * 60)
        let beforeIdle = env.scheduler.nextBreakDate

        // User walks away; the 30 s housekeeping check notices after the threshold.
        env.idleSeconds = 3 * 60
        env.clock.advance(by: 60)
        #expect(env.scheduler.nextBreakDate != beforeIdle)
        #expect(env.scheduler.nextBreakDate == env.clock.now.addingTimeInterval(20 * 60))

        // Returning grants a full interval — no imminent break.
        env.idleSeconds = 0
        env.clock.advance(by: 5 * 60)
        #expect(env.recorder.preBreakLeads.isEmpty)
    }

    @Test("Capture at break time defers, then fires when capture ends")
    func captureDefersUntilEnd() {
        let env = TestEnvironment()
        env.scheduler.start()
        env.captureActive = true

        env.clock.advance(by: 20 * 60)
        #expect(env.scheduler.isDeferringForCapture)
        #expect(env.recorder.preBreakLeads.isEmpty)

        // Sharing ends well within the deferral cap.
        env.captureActive = false
        env.scheduler.captureStateDidChange(isActive: false)
        #expect(env.scheduler.phase == .preBreak)
        #expect(!env.scheduler.isDeferringForCapture)

        env.clock.advance(by: 15)
        #expect(env.scheduler.phase == .onBreak)
    }

    @Test("A deferred break is skipped after the deferral cap")
    func deferralCapSkips() {
        let env = TestEnvironment()
        env.scheduler.start()
        env.captureActive = true

        env.clock.advance(by: 20 * 60)
        #expect(env.scheduler.isDeferringForCapture)

        env.clock.advance(by: BreakScheduler.deferralCap + 30)
        #expect(!env.scheduler.isDeferringForCapture)
        #expect(env.scheduler.phase == .working)
        #expect(env.recorder.breakStarts.isEmpty)
        #expect(env.scheduler.nextBreakDate != nil)
    }

    @Test("Capture starting during the pre-break vignette cancels it")
    func captureDuringPreBreakCancels() {
        let env = TestEnvironment()
        env.scheduler.start()

        env.clock.advance(by: 20 * 60 - 15)
        #expect(env.scheduler.phase == .preBreak)

        env.captureActive = true
        env.scheduler.captureStateDidChange(isActive: true)
        #expect(env.scheduler.phase == .working)
        #expect(env.scheduler.isDeferringForCapture)
        #expect(env.recorder.breakEnds == [false])
    }

    @Test("Dismissing a break restarts the work timer")
    func dismissRestartsTimer() {
        let env = TestEnvironment()
        env.scheduler.start()

        env.clock.advance(by: 20 * 60)
        #expect(env.scheduler.phase == .onBreak)

        env.scheduler.dismissBreak()
        #expect(env.scheduler.phase == .working)
        #expect(env.recorder.breakEnds == [false])
        #expect(env.scheduler.nextBreakDate == env.clock.now.addingTimeInterval(20 * 60))
    }

    @Test("Skip next break pushes the next break a full interval out")
    func skipNextBreak() {
        let env = TestEnvironment()
        env.scheduler.start()

        env.clock.advance(by: 15 * 60)
        env.scheduler.skipNextBreak()
        #expect(env.scheduler.nextBreakDate == env.clock.now.addingTimeInterval(20 * 60))

        env.clock.advance(by: 10 * 60)
        #expect(env.recorder.breakStarts.isEmpty)
    }

    @Test("Pause for a duration auto-resumes")
    func pauseAutoResumes() {
        let env = TestEnvironment()
        env.scheduler.start()

        env.scheduler.pause(for: 3600)
        #expect(env.scheduler.phase == .paused(until: env.clock.now.addingTimeInterval(3600)))
        #expect(env.scheduler.nextBreakDate == nil)

        // Nothing fires while paused.
        env.clock.advance(by: 30 * 60)
        #expect(env.recorder.breakStarts.isEmpty)

        env.clock.advance(by: 30 * 60)
        #expect(env.scheduler.phase == .working)
        #expect(env.scheduler.nextBreakDate != nil)
    }

    @Test("Indefinite pause holds until manually resumed")
    func indefinitePause() {
        let env = TestEnvironment()
        env.scheduler.start()

        env.scheduler.pause(until: nil)
        env.clock.advance(by: 8 * 3600)
        #expect(env.scheduler.phase == .paused(until: nil))
        #expect(env.recorder.breakStarts.isEmpty)

        env.scheduler.resume()
        #expect(env.scheduler.phase == .working)
    }

    @Test("Pausing during a break tears the overlay down")
    func pauseDuringBreak() {
        let env = TestEnvironment()
        env.scheduler.start()

        env.clock.advance(by: 20 * 60)
        #expect(env.scheduler.phase == .onBreak)

        env.scheduler.pause(for: 3600)
        #expect(env.recorder.breakEnds == [false])
        if case .paused = env.scheduler.phase {} else {
            Issue.record("Expected paused phase")
        }
    }

    @Test("System suspend cancels overlays; resume restarts the cycle")
    func suspendAndResume() {
        let env = TestEnvironment()
        env.scheduler.start()

        env.clock.advance(by: 20 * 60 - 15)
        #expect(env.scheduler.phase == .preBreak)

        env.scheduler.systemDidSuspend()
        #expect(env.recorder.breakEnds == [false])
        #expect(env.scheduler.nextBreakDate == nil)

        // Nothing fires while locked/asleep.
        env.clock.advance(by: 2 * 3600)
        #expect(env.recorder.breakStarts.isEmpty)

        env.scheduler.systemDidResume()
        #expect(env.scheduler.phase == .working)
        #expect(env.scheduler.nextBreakDate == env.clock.now.addingTimeInterval(20 * 60))
    }

    @Test("Zero lead time goes straight to the break overlay")
    func zeroLeadSkipsVignette() {
        let env = TestEnvironment()
        env.settings.preBreakLead = 0
        env.scheduler.start()

        env.clock.advance(by: 20 * 60)
        #expect(env.scheduler.phase == .onBreak)
        #expect(env.recorder.preBreakLeads.isEmpty)
    }

    @Test("Take Break Now works from paused state")
    func breakNowFromPaused() {
        let env = TestEnvironment()
        env.scheduler.start()
        env.scheduler.pause(until: nil)

        env.scheduler.startBreakNow()
        #expect(env.scheduler.phase == .onBreak)

        env.clock.advance(by: 20)
        #expect(env.scheduler.phase == .working)
        #expect(env.scheduler.nextBreakDate != nil)
    }
}

@Suite("App settings")
@MainActor
struct AppSettingsTests {
    private func freshSettings() -> (AppSettings, String) {
        let suite = "BlinkTests-\(UUID().uuidString)"
        return (AppSettings(defaults: UserDefaults(suiteName: suite)!), suite)
    }

    @Test("Spec defaults")
    func defaults() {
        let (settings, suite) = freshSettings()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        #expect(settings.workInterval == 20 * 60)
        #expect(settings.breakDuration == 20)
        #expect(settings.preBreakLead == 15)
        #expect(settings.dimLevel == 0.5)
        #expect(settings.idleResetThreshold == 3 * 60)
        #expect(settings.skipDuringCapture)
        #expect(!settings.playSounds)
        #expect(!settings.showTimeRemainingInMenuBar)
        #expect(!settings.showDebugMenu)
    }

    @Test("Show debug menu persists")
    func debugMenuPersists() {
        let suite = "BlinkTests-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let first = AppSettings(defaults: UserDefaults(suiteName: suite)!)
        first.showDebugMenu = true

        #expect(AppSettings(defaults: UserDefaults(suiteName: suite)!).showDebugMenu)
    }

    @Test("Values persist across instances")
    func persistence() {
        let suite = "BlinkTests-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let first = AppSettings(defaults: UserDefaults(suiteName: suite)!)
        first.workInterval = 25 * 60
        first.dimLevel = 0.7
        first.playSounds = true

        let second = AppSettings(defaults: UserDefaults(suiteName: suite)!)
        #expect(second.workInterval == 25 * 60)
        #expect(second.dimLevel == 0.7)
        #expect(second.playSounds)
    }
}

// MARK: - Active hours / days

/// A fixed-zone calendar and date builder so window arithmetic is independent
/// of wherever the tests happen to run.
@MainActor
private enum Fixture {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }()

    /// January 2025: the 8th is a Wednesday, the 11th a Saturday.
    static func date(day: Int, hour: Int, minute: Int = 0, second: Int = 0) -> Date {
        let components = DateComponents(year: 2025, month: 1, day: day, hour: hour, minute: minute, second: second)
        return calendar.date(from: components)!
    }

    static let weekdays = Set(2...6)
}

@Suite("Active schedule window")
@MainActor
struct ActiveScheduleTests {
    private func nineToFiveWeekdays() -> ActiveSchedule {
        ActiveSchedule(
            limitHours: true,
            startMinute: 9 * 60,
            endMinute: 17 * 60,
            limitDays: true,
            days: Fixture.weekdays
        )
    }

    @Test("Inside the window on a weekday, outside it after hours")
    func weekdayHours() {
        let schedule = nineToFiveWeekdays()
        #expect(schedule.isActive(at: Fixture.date(day: 8, hour: 10), calendar: Fixture.calendar))
        #expect(schedule.isActive(at: Fixture.date(day: 8, hour: 9), calendar: Fixture.calendar))
        #expect(!schedule.isActive(at: Fixture.date(day: 8, hour: 8, minute: 59), calendar: Fixture.calendar))
        // The end is exclusive: 17:00 is already outside.
        #expect(!schedule.isActive(at: Fixture.date(day: 8, hour: 17), calendar: Fixture.calendar))
    }

    @Test("Weekends are excluded when days are limited")
    func weekendExcluded() {
        let schedule = nineToFiveWeekdays()
        #expect(!schedule.isActive(at: Fixture.date(day: 11, hour: 10), calendar: Fixture.calendar))
        #expect(!schedule.isActive(at: Fixture.date(day: 12, hour: 10), calendar: Fixture.calendar))
    }

    @Test("Next activation skips the rest of the day and the weekend")
    func nextActivation() {
        let schedule = nineToFiveWeekdays()
        #expect(
            schedule.nextActivation(after: Fixture.date(day: 8, hour: 18), calendar: Fixture.calendar)
                == Fixture.date(day: 9, hour: 9)
        )
        // Friday evening rolls all the way to Monday morning.
        #expect(
            schedule.nextActivation(after: Fixture.date(day: 10, hour: 18), calendar: Fixture.calendar)
                == Fixture.date(day: 13, hour: 9)
        )
    }

    @Test("The current window end is the day's closing time")
    func windowEnd() {
        let schedule = nineToFiveWeekdays()
        #expect(
            schedule.currentWindowEnd(at: Fixture.date(day: 8, hour: 10), calendar: Fixture.calendar)
                == Fixture.date(day: 8, hour: 17)
        )
        #expect(schedule.currentWindowEnd(at: Fixture.date(day: 8, hour: 18), calendar: Fixture.calendar) == nil)
    }

    @Test("An end before the start runs the window overnight")
    func overnightWindow() {
        let schedule = ActiveSchedule(
            limitHours: true,
            startMinute: 22 * 60,
            endMinute: 6 * 60,
            limitDays: false,
            days: Fixture.weekdays
        )
        #expect(schedule.isActive(at: Fixture.date(day: 8, hour: 23), calendar: Fixture.calendar))
        #expect(schedule.isActive(at: Fixture.date(day: 9, hour: 2), calendar: Fixture.calendar))
        #expect(!schedule.isActive(at: Fixture.date(day: 9, hour: 7), calendar: Fixture.calendar))
        #expect(
            schedule.nextActivation(after: Fixture.date(day: 9, hour: 7), calendar: Fixture.calendar)
                == Fixture.date(day: 9, hour: 22)
        )
    }

    @Test("Limiting days alone keeps those days whole")
    func daysOnly() {
        let schedule = ActiveSchedule(
            limitHours: false,
            startMinute: 9 * 60,
            endMinute: 17 * 60,
            limitDays: true,
            days: Fixture.weekdays
        )
        #expect(schedule.isActive(at: Fixture.date(day: 8, hour: 3), calendar: Fixture.calendar))
        #expect(schedule.isActive(at: Fixture.date(day: 8, hour: 23), calendar: Fixture.calendar))
        #expect(!schedule.isActive(at: Fixture.date(day: 11, hour: 12), calendar: Fixture.calendar))
    }

    @Test("An empty day selection is read as no day filter, never as silence")
    func emptyDaysFallBack() {
        let schedule = ActiveSchedule(
            limitHours: false,
            startMinute: 0,
            endMinute: 0,
            limitDays: true,
            days: []
        )
        #expect(schedule.isAlwaysActive)
        #expect(schedule.isActive(at: Fixture.date(day: 11, hour: 12), calendar: Fixture.calendar))
    }

    @Test("With no limits the schedule never constrains anything")
    func unrestricted() {
        #expect(ActiveSchedule.unrestricted.isAlwaysActive)
        #expect(ActiveSchedule.unrestricted.isActive(at: Fixture.date(day: 11, hour: 3), calendar: Fixture.calendar))
        #expect(ActiveSchedule.unrestricted.nextActivation(after: Fixture.date(day: 11, hour: 3), calendar: Fixture.calendar) == nil)
    }
}

@Suite("Scheduler within active hours")
@MainActor
struct SchedulerActiveScheduleTests {
    private func makeEnvironment(day: Int, hour: Int, minute: Int = 0, second: Int = 0) -> TestEnvironment {
        let env = TestEnvironment(calendar: Fixture.calendar, startingAt: Fixture.date(day: day, hour: hour, minute: minute, second: second))
        env.settings.limitToActiveHours = true
        env.settings.activeStartMinute = 9 * 60
        env.settings.activeEndMinute = 17 * 60
        env.settings.limitToActiveDays = true
        env.settings.activeDays = Fixture.weekdays
        return env
    }

    @Test("Closing time parks the cycle until the window reopens")
    func parksAtEndOfDay() {
        // Wednesday 16:50 — the next break would land past 17:00.
        let env = makeEnvironment(day: 8, hour: 16, minute: 50)
        env.scheduler.start()
        #expect(!env.scheduler.isOutsideActiveSchedule)

        env.clock.advance(by: 20 * 60)
        #expect(env.scheduler.isOutsideActiveSchedule)
        #expect(env.scheduler.nextBreakDate == nil)
        #expect(env.recorder.breakStarts.isEmpty)
        #expect(env.scheduler.activeScheduleResumeDate == Fixture.date(day: 9, hour: 9))

        // Nothing fires overnight.
        env.clock.advance(by: 15 * 3600)
        #expect(env.recorder.breakStarts.isEmpty)
    }

    @Test("The cycle restarts on its own when the window reopens")
    func resumesAtWindowStart() {
        let env = makeEnvironment(day: 8, hour: 16, minute: 50)
        env.scheduler.start()

        // Wednesday 16:50 → Thursday 09:00:01.
        env.clock.advance(by: (16 * 3600 + 10 * 60) + 1)
        #expect(!env.scheduler.isOutsideActiveSchedule)
        #expect(env.scheduler.nextBreakDate == Fixture.date(day: 9, hour: 9).addingTimeInterval(20 * 60))

        env.clock.advance(by: 20 * 60)
        #expect(env.scheduler.phase == .onBreak)
        #expect(env.recorder.breakStarts.count == 1)
    }

    @Test("Friday evening waits out the whole weekend")
    func skipsWeekend() {
        let env = makeEnvironment(day: 10, hour: 16, minute: 50)
        env.scheduler.start()

        env.clock.advance(by: 20 * 60)
        #expect(env.scheduler.isOutsideActiveSchedule)
        #expect(env.scheduler.activeScheduleResumeDate == Fixture.date(day: 13, hour: 9))

        // All weekend long, nothing.
        env.clock.advance(by: 2 * 24 * 3600)
        #expect(env.recorder.breakStarts.isEmpty)
        #expect(env.scheduler.isOutsideActiveSchedule)
    }

    @Test("Turning the limit on outside the window parks the cycle immediately")
    func settingsChangeParksImmediately() {
        let env = TestEnvironment(calendar: Fixture.calendar, startingAt: Fixture.date(day: 8, hour: 20))
        env.scheduler.start()
        #expect(!env.scheduler.isOutsideActiveSchedule)
        #expect(env.scheduler.nextBreakDate != nil)

        env.settings.limitToActiveHours = true
        env.settings.activeStartMinute = 9 * 60
        env.settings.activeEndMinute = 17 * 60
        env.scheduler.settingsDidChange()

        #expect(env.scheduler.isOutsideActiveSchedule)
        #expect(env.scheduler.nextBreakDate == nil)
        #expect(env.scheduler.activeScheduleResumeDate == Fixture.date(day: 9, hour: 9))
    }

    @Test("A break already on screen at closing time is allowed to finish")
    func breakInFlightSurvivesClosingTime() {
        // Start so the break begins at 16:59:50 and runs 20 s past 17:00.
        let env = makeEnvironment(day: 8, hour: 16, minute: 39, second: 50)
        env.scheduler.start()

        env.clock.advance(by: 20 * 60)
        #expect(env.scheduler.phase == .onBreak)

        env.clock.advance(by: 20)
        #expect(env.recorder.breakEnds == [true])
        #expect(env.scheduler.isOutsideActiveSchedule)
        #expect(env.scheduler.nextBreakDate == nil)
    }

    @Test("Take Break Now still works outside the window")
    func manualBreakOutsideWindow() {
        let env = makeEnvironment(day: 11, hour: 12)
        env.scheduler.start()
        #expect(env.scheduler.isOutsideActiveSchedule)

        env.scheduler.startBreakNow()
        #expect(env.scheduler.phase == .onBreak)

        env.clock.advance(by: 20)
        #expect(env.recorder.breakEnds == [true])
        #expect(env.scheduler.isOutsideActiveSchedule)
    }
}

@Suite("Active schedule settings")
@MainActor
struct ActiveScheduleSettingsTests {
    @Test("Defaults leave the schedule unrestricted")
    func defaults() {
        let suite = "BlinkTests-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: UserDefaults(suiteName: suite)!)

        #expect(!settings.limitToActiveHours)
        #expect(!settings.limitToActiveDays)
        #expect(settings.activeStartMinute == 9 * 60)
        #expect(settings.activeEndMinute == 17 * 60)
        #expect(settings.activeDays == Set(2...6))
        #expect(settings.activeSchedule.isAlwaysActive)
    }

    @Test("Hours and days persist across instances")
    func persistence() {
        let suite = "BlinkTests-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let first = AppSettings(defaults: UserDefaults(suiteName: suite)!)
        first.limitToActiveHours = true
        first.activeStartMinute = 8 * 60 + 30
        first.activeEndMinute = 18 * 60
        first.limitToActiveDays = true
        first.activeDays = [2, 4, 6]

        let second = AppSettings(defaults: UserDefaults(suiteName: suite)!)
        #expect(second.limitToActiveHours)
        #expect(second.activeStartMinute == 8 * 60 + 30)
        #expect(second.activeEndMinute == 18 * 60)
        #expect(second.limitToActiveDays)
        #expect(second.activeDays == [2, 4, 6])
    }

    @Test("Out-of-range minutes are clamped")
    func clamping() {
        let suite = "BlinkTests-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: UserDefaults(suiteName: suite)!)

        settings.activeStartMinute = -30
        #expect(settings.activeStartMinute == 0)
        settings.activeEndMinute = 5_000
        #expect(settings.activeEndMinute == 24 * 60 - 1)
    }
}
