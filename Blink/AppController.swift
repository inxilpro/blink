import AppKit

/// Composition root: wires the scheduler, monitors, overlays, and menu bar
/// together and translates between them.
@MainActor
final class AppController: NSObject, NSApplicationDelegate {
    private let settings = AppSettings()
    private let clock = SystemClock()
    private let availability = SystemAvailabilityMonitor()
    private let capture = CaptureActivityMonitor()

    private lazy var scheduler = BreakScheduler(
        settings: settings,
        clock: clock,
        idleSeconds: { SystemIdle.seconds() },
        isCaptureActive: { [capture] in capture.isActive }
    )

    private lazy var overlay = OverlayController(settings: settings)
    private lazy var settingsWindow = SettingsWindowController(settings: settings)

    private lazy var statusItem = StatusItemController(
        settings: settings,
        scheduler: scheduler,
        capture: capture,
        actions: .init(
            startBreakNow: { [weak self] in self?.scheduler.startBreakNow() },
            skipNextBreak: { [weak self] in self?.scheduler.skipNextBreak() },
            pauseOneHour: { [weak self] in self?.scheduler.pause(for: 3600) },
            pauseUntilTomorrow: { [weak self] in self?.scheduler.pauseUntilTomorrow() },
            pauseUntilResumed: { [weak self] in self?.scheduler.pause(until: nil) },
            resume: { [weak self] in self?.scheduler.resume() },
            openSettings: { [weak self] in self?.settingsWindow.show() },
            copyDiagnostics: { [weak self] in self?.copyDiagnostics() },
            quit: { NSApp.terminate(nil) }
        )
    )

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        scheduler.delegate = self
        overlay.onDismiss = { [weak self] in self?.scheduler.dismissBreak() }
        capture.onChange = { [weak self] isActive in
            self?.scheduler.captureStateDidChange(isActive: isActive)
            self?.statusItem.refresh()
        }
        availability.onAvailabilityChange = { [weak self] isAvailable in
            if isAvailable {
                self?.scheduler.systemDidResume()
            } else {
                self?.scheduler.systemDidSuspend()
            }
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsChanged),
            name: .blinkSettingsDidChange,
            object: nil
        )

        capture.start()
        availability.start()
        statusItem.install()
        scheduler.start()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    // MARK: - Settings

    /// Keys whose changes affect the running timer (as opposed to purely
    /// visual settings, which the overlay picks up live).
    private static let scheduleAffectingKeys: Set<String> = [
        AppSettings.Keys.workInterval,
        AppSettings.Keys.preBreakLead,
        AppSettings.Keys.skipDuringCapture,
        AppSettings.Keys.limitToActiveHours,
        AppSettings.Keys.activeStart,
        AppSettings.Keys.activeEnd,
        AppSettings.Keys.limitToActiveDays,
        AppSettings.Keys.activeDays,
    ]

    @objc private func settingsChanged(_ notification: Notification) {
        if let key = notification.userInfo?["key"] as? String, Self.scheduleAffectingKeys.contains(key) {
            scheduler.settingsDidChange()
        }
        statusItem.refresh()
    }

    // MARK: - Diagnostics

    private func copyDiagnostics() {
        let formatter = ISO8601DateFormatter()
        var lines: [String] = []
        lines.append("Blink diagnostics — \(formatter.string(from: Date()))")
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        lines.append("Version: \(version)")
        lines.append("")
        lines.append("Phase: \(scheduler.phase)")
        if let next = scheduler.nextBreakDate {
            lines.append("Next break: \(formatter.string(from: next))")
        }
        lines.append("Deferring for capture: \(scheduler.isDeferringForCapture)")
        lines.append("Outside active schedule: \(scheduler.isOutsideActiveSchedule)")
        if let resume = scheduler.activeScheduleResumeDate {
            lines.append("Active schedule reopens: \(formatter.string(from: resume))")
        }
        if let deadline = scheduler.deferralDeadline {
            lines.append("Deferral deadline: \(formatter.string(from: deadline))")
        }
        lines.append("Capture active: \(capture.isActive) \(capture.activeReasons.joined(separator: "; "))")
        lines.append("Idle: \(Int(SystemIdle.seconds()))s")
        lines.append("")
        lines.append("Devices:")
        lines.append(contentsOf: capture.diagnosticRows().map { "  \($0)" })
        lines.append("")
        lines.append("Settings:")
        lines.append("  workInterval: \(Int(settings.workInterval))s")
        lines.append("  breakDuration: \(Int(settings.breakDuration))s")
        lines.append("  preBreakLead: \(Int(settings.preBreakLead))s")
        lines.append("  dimLevel: \(settings.dimLevel)")
        lines.append("  idleResetThreshold: \(Int(settings.idleResetThreshold))s")
        lines.append("  skipDuringCapture: \(settings.skipDuringCapture)")
        lines.append("  activeSchedule: \(settings.activeSchedule)")
        lines.append("")
        lines.append("Log history: log show --last 1h --predicate 'subsystem == \"\(Bundle.main.bundleIdentifier ?? "com.cmorrell.Blink")\"'")

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(lines.joined(separator: "\n"), forType: .string)
    }
}

// MARK: - BreakSchedulerDelegate

extension AppController: BreakSchedulerDelegate {
    func schedulerDidEnterPreBreak(_ scheduler: BreakScheduler, leadTime: TimeInterval) {
        overlay.showVignette(fadeDuration: leadTime)
        statusItem.refresh()
    }

    func schedulerDidStartBreak(_ scheduler: BreakScheduler, endDate: Date, duration: TimeInterval) {
        if settings.playSounds {
            BreakSound.playStart()
        }
        overlay.showBreak(endDate: endDate, duration: duration)
        statusItem.refresh()
    }

    func schedulerDidEndBreak(_ scheduler: BreakScheduler, completed: Bool) {
        if completed, settings.playSounds {
            BreakSound.playEnd()
        }
        overlay.hideAll()
        statusItem.refresh()
    }

    func schedulerStateDidChange(_ scheduler: BreakScheduler) {
        statusItem.refresh()
    }
}
