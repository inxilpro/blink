import Foundation
import os

@MainActor
protocol BreakSchedulerDelegate: AnyObject {
    func schedulerDidEnterPreBreak(_ scheduler: BreakScheduler, leadTime: TimeInterval)
    func schedulerDidStartBreak(_ scheduler: BreakScheduler, endDate: Date, duration: TimeInterval)
    /// Fired when overlays should come down — either the break ran to completion
    /// (`completed == true`) or it was dismissed/cancelled/suppressed.
    func schedulerDidEndBreak(_ scheduler: BreakScheduler, completed: Bool)
    func schedulerStateDidChange(_ scheduler: BreakScheduler)
}

/// The break lifecycle state machine. Owns no UI: it reports transitions through
/// its delegate and reads the outside world (idle time, capture activity) through
/// injected closures so it can be tested with a virtual clock.
@MainActor
final class BreakScheduler {
    enum Phase: Equatable {
        case working
        case preBreak
        case onBreak
        case paused(until: Date?)
    }

    /// How long a due break may wait for screen sharing / camera use to end
    /// before it is skipped outright.
    static let deferralCap: TimeInterval = 10 * 60
    static let deferralCheckInterval: TimeInterval = 20
    static let idleCheckInterval: TimeInterval = 30

    weak var delegate: BreakSchedulerDelegate?

    private(set) var phase: Phase = .working
    /// When the next break overlay is expected to begin. `nil` while paused,
    /// deferring, suspended, or on break.
    private(set) var nextBreakDate: Date?
    private(set) var isDeferringForCapture = false
    /// True when the current time falls outside the user's active hours/days.
    private(set) var isOutsideActiveSchedule = false
    /// When the active window next opens, while `isOutsideActiveSchedule`.
    private(set) var activeScheduleResumeDate: Date?

    private let settings: AppSettings
    private let clock: SchedulerClock
    private let calendar: Calendar
    private let idleSeconds: () -> TimeInterval
    private let isCaptureActive: () -> Bool

    private(set) var deferralDeadline: Date?

    private var phaseToken: SchedulerToken?
    private var deferralToken: SchedulerToken?
    private var resumeToken: SchedulerToken?
    private var housekeepingToken: SchedulerToken?
    private var scheduleBoundaryToken: SchedulerToken?
    private var isSystemSuspended = false

    init(
        settings: AppSettings,
        clock: SchedulerClock,
        calendar: Calendar = .autoupdatingCurrent,
        idleSeconds: @escaping () -> TimeInterval,
        isCaptureActive: @escaping () -> Bool
    ) {
        self.settings = settings
        self.clock = clock
        self.calendar = calendar
        self.idleSeconds = idleSeconds
        self.isCaptureActive = isCaptureActive
    }

    // MARK: - Lifecycle

    func start() {
        housekeepingToken = clock.repeating(every: Self.idleCheckInterval, tolerance: 5) { [weak self] in
            self?.idleCheckTick()
        }
        restartWork()
    }

    /// Begins a fresh work interval, cancelling any in-flight phase.
    private func restartWork() {
        cancelPhaseTimer()
        endDeferral()
        phase = .working
        guard !isSystemSuspended else {
            nextBreakDate = nil
            notifyStateChange()
            return
        }
        armScheduleBoundary()
        guard !isOutsideActiveSchedule else {
            nextBreakDate = nil
            notifyStateChange()
            return
        }
        let interval = settings.workInterval
        let lead = effectiveLead
        nextBreakDate = clock.now.addingTimeInterval(interval)
        phaseToken = clock.after(max(1, interval - lead), tolerance: 1) { [weak self] in
            self?.preBreakDue()
        }
        notifyStateChange()
    }

    // MARK: - Phase transitions

    private func preBreakDue() {
        guard phase == .working, !isSystemSuspended, !isDeferringForCapture else { return }
        guard settings.activeSchedule.isActive(at: clock.now, calendar: calendar) else {
            BlinkLog.scheduler.notice("Break due outside active hours — parking until the window reopens")
            restartWork()
            return
        }
        let idle = idleSeconds()
        guard idle < settings.idleResetThreshold else {
            // The user is away — treat it as a break already taken.
            BlinkLog.scheduler.notice("Break due, but user idle \(Int(idle), privacy: .public)s — resetting silently")
            restartWork()
            return
        }
        if settings.skipDuringCapture, isCaptureActive() {
            BlinkLog.scheduler.notice("Break due during camera/microphone use — deferring")
            beginDeferral()
            return
        }
        enterPreBreak()
    }

    private func enterPreBreak() {
        endDeferral()
        let lead = effectiveLead
        guard lead >= 1 else {
            beginBreak()
            return
        }
        cancelPhaseTimer()
        phase = .preBreak
        nextBreakDate = clock.now.addingTimeInterval(lead)
        delegate?.schedulerDidEnterPreBreak(self, leadTime: lead)
        phaseToken = clock.after(lead, tolerance: 0.5) { [weak self] in
            self?.breakDue()
        }
        notifyStateChange()
    }

    private func breakDue() {
        guard phase == .preBreak else { return }
        // Conditions may have changed during the lead time; re-check before dimming.
        if idleSeconds() >= settings.idleResetThreshold {
            BlinkLog.scheduler.notice("User went idle during pre-break — resetting")
            delegate?.schedulerDidEndBreak(self, completed: false)
            restartWork()
            return
        }
        if settings.skipDuringCapture, isCaptureActive() {
            BlinkLog.scheduler.notice("Camera/microphone became active during pre-break — deferring")
            delegate?.schedulerDidEndBreak(self, completed: false)
            beginDeferral()
            return
        }
        beginBreak()
    }

    private func beginBreak() {
        cancelPhaseTimer()
        endDeferral()
        phase = .onBreak
        nextBreakDate = nil
        let duration = settings.breakDuration
        let endDate = clock.now.addingTimeInterval(duration)
        delegate?.schedulerDidStartBreak(self, endDate: endDate, duration: duration)
        phaseToken = clock.after(duration, tolerance: 0.25) { [weak self] in
            self?.finishBreak()
        }
        notifyStateChange()
    }

    private func finishBreak() {
        guard phase == .onBreak else { return }
        delegate?.schedulerDidEndBreak(self, completed: true)
        restartWork()
    }

    // MARK: - User actions

    func dismissBreak() {
        guard phase == .preBreak || phase == .onBreak else { return }
        delegate?.schedulerDidEndBreak(self, completed: false)
        restartWork()
    }

    func startBreakNow() {
        guard phase != .onBreak, !isSystemSuspended else { return }
        if case .paused = phase {
            resumeToken?.cancel()
            resumeToken = nil
        }
        beginBreak()
    }

    func skipNextBreak() {
        switch phase {
        case .preBreak, .onBreak:
            delegate?.schedulerDidEndBreak(self, completed: false)
            restartWork()
        case .working:
            restartWork()
        case .paused:
            break
        }
    }

    /// Pauses reminders; `until: nil` pauses until manually resumed.
    func pause(until: Date?) {
        if phase == .preBreak || phase == .onBreak {
            delegate?.schedulerDidEndBreak(self, completed: false)
        }
        cancelPhaseTimer()
        endDeferral()
        resumeToken?.cancel()
        resumeToken = nil
        phase = .paused(until: until)
        nextBreakDate = nil
        if let until {
            resumeToken = clock.after(max(1, until.timeIntervalSince(clock.now)), tolerance: 30) { [weak self] in
                self?.resume()
            }
        }
        notifyStateChange()
    }

    func pause(for duration: TimeInterval) {
        pause(until: clock.now.addingTimeInterval(duration))
    }

    func pauseUntilTomorrow() {
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: clock.now) ?? clock.now.addingTimeInterval(24 * 3600)
        pause(until: calendar.startOfDay(for: tomorrow))
    }

    func resume() {
        guard case .paused = phase else { return }
        resumeToken?.cancel()
        resumeToken = nil
        restartWork()
    }

    // MARK: - External conditions

    /// Screen locked, displays or system asleep, or session switched away.
    func systemDidSuspend() {
        guard !isSystemSuspended else { return }
        isSystemSuspended = true
        BlinkLog.scheduler.notice("System unavailable (lock/sleep/session switch) — suspending")
        if phase == .preBreak || phase == .onBreak {
            delegate?.schedulerDidEndBreak(self, completed: false)
        }
        cancelPhaseTimer()
        endDeferral()
        if case .paused = phase {
            notifyStateChange()
        } else {
            phase = .working
            nextBreakDate = nil
            notifyStateChange()
        }
    }

    func systemDidResume() {
        guard isSystemSuspended else { return }
        isSystemSuspended = false
        BlinkLog.scheduler.notice("System available again — resuming")
        switch phase {
        case .paused(let until):
            if let until, clock.now >= until {
                resume()
            } else {
                notifyStateChange()
            }
        default:
            restartWork()
        }
    }

    func captureStateDidChange(isActive: Bool) {
        guard settings.skipDuringCapture else { return }
        if isActive {
            switch phase {
            case .preBreak:
                delegate?.schedulerDidEndBreak(self, completed: false)
                beginDeferral()
            case .onBreak:
                delegate?.schedulerDidEndBreak(self, completed: false)
                restartWork()
            default:
                break
            }
        } else if isDeferringForCapture {
            deferralTick()
        }
    }

    func settingsDidChange() {
        armScheduleBoundary()
        if isDeferringForCapture, !settings.skipDuringCapture {
            if isOutsideActiveSchedule {
                restartWork()
            } else {
                enterPreBreak()
            }
            return
        }
        if phase == .working, !isDeferringForCapture, !isSystemSuspended {
            restartWork()
        } else {
            notifyStateChange()
        }
    }

    // MARK: - Deferral (break due while sharing/on camera)

    private func beginDeferral() {
        cancelPhaseTimer()
        phase = .working
        nextBreakDate = nil
        if !isDeferringForCapture {
            isDeferringForCapture = true
            deferralDeadline = clock.now.addingTimeInterval(Self.deferralCap)
            BlinkLog.scheduler.notice("Deferring break for up to \(Int(Self.deferralCap / 60), privacy: .public) min")
        }
        deferralToken?.cancel()
        deferralToken = clock.repeating(every: Self.deferralCheckInterval, tolerance: 5) { [weak self] in
            self?.deferralTick()
        }
        notifyStateChange()
    }

    private func deferralTick() {
        guard isDeferringForCapture, !isSystemSuspended else { return }
        guard settings.activeSchedule.isActive(at: clock.now, calendar: calendar) else {
            BlinkLog.scheduler.notice("Active window closed while deferring — dropping the pending break")
            restartWork()
            return
        }
        if !isCaptureActive() {
            if idleSeconds() >= settings.idleResetThreshold {
                BlinkLog.scheduler.notice("Capture ended but user idle — resetting instead of showing deferred break")
                restartWork()
            } else {
                BlinkLog.scheduler.notice("Capture ended — showing the deferred break")
                enterPreBreak()
            }
        } else if let deadline = deferralDeadline, clock.now >= deadline {
            // The call has gone on too long to keep the break pending — skip it.
            BlinkLog.scheduler.notice("Deferral cap reached — skipping this break and restarting the cycle")
            restartWork()
        }
    }

    private func endDeferral() {
        isDeferringForCapture = false
        deferralDeadline = nil
        deferralToken?.cancel()
        deferralToken = nil
    }

    // MARK: - Active hours / days

    /// Recomputes whether we are inside the user's window and arms a one-shot
    /// timer for the next boundary, so nothing polls between transitions.
    private func armScheduleBoundary() {
        scheduleBoundaryToken?.cancel()
        scheduleBoundaryToken = nil

        let schedule = settings.activeSchedule
        let now = clock.now
        let isActive = schedule.isActive(at: now, calendar: calendar)
        isOutsideActiveSchedule = !isActive
        activeScheduleResumeDate = isActive ? nil : schedule.nextActivation(after: now, calendar: calendar)

        let boundary = isActive
            ? schedule.currentWindowEnd(at: now, calendar: calendar)
            : activeScheduleResumeDate
        guard let boundary else { return }
        scheduleBoundaryToken = clock.after(max(1, boundary.timeIntervalSince(now)), tolerance: 5) { [weak self] in
            self?.scheduleBoundaryReached()
        }
    }

    private func scheduleBoundaryReached() {
        scheduleBoundaryToken = nil
        switch phase {
        case .working:
            restartWork()
        case .preBreak, .onBreak:
            // Let the break in flight finish; `restartWork` re-arms afterwards.
            armScheduleBoundary()
        case .paused:
            armScheduleBoundary()
            notifyStateChange()
        }
    }

    // MARK: - Idle housekeeping

    private func idleCheckTick() {
        guard phase == .working, !isSystemSuspended, !isDeferringForCapture, !isOutsideActiveSchedule else { return }
        // Rolling reset: while the user is away the work timer keeps getting
        // pushed out, so returning always grants a full interval.
        if idleSeconds() >= settings.idleResetThreshold {
            restartWork()
        }
    }

    // MARK: - Helpers

    private var effectiveLead: TimeInterval {
        min(settings.preBreakLead, max(0, settings.workInterval - 1))
    }

    private func cancelPhaseTimer() {
        phaseToken?.cancel()
        phaseToken = nil
    }

    private func notifyStateChange() {
        delegate?.schedulerStateDidChange(self)
    }
}
