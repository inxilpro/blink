import AppKit

/// The menu bar presence: a state-reflecting icon and the pause/skip menu.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    struct Actions {
        let startBreakNow: () -> Void
        let skipNextBreak: () -> Void
        let pauseOneHour: () -> Void
        let pauseUntilTomorrow: () -> Void
        let pauseUntilResumed: () -> Void
        let resume: () -> Void
        let openSettings: () -> Void
        let canCheckForUpdates: () -> Bool
        let checkForUpdates: () -> Void
        let copyDiagnostics: () -> Void
        let quit: () -> Void
    }

    private let settings: AppSettings
    private let scheduler: BreakScheduler
    private let capture: CaptureActivityMonitor
    private let actions: Actions
    private var statusItem: NSStatusItem?
    private var refreshTimer: Timer?

    private static let pausedUntilFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    /// Resume times for the active window can be days out, so they carry a day.
    private static let resumeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEE j:mm")
        return formatter
    }()

    init(settings: AppSettings, scheduler: BreakScheduler, capture: CaptureActivityMonitor, actions: Actions) {
        self.settings = settings
        self.scheduler = scheduler
        self.capture = capture
        self.actions = actions
        super.init()
    }

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.imagePosition = .imageLeading
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        statusItem = item

        // Keeps the optional time-remaining text fresh; a no-op otherwise.
        let timer = Timer(timeInterval: 20, repeats: true) { _ in
            MainActor.assumeIsolated { [weak self] in self?.refresh() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer

        refresh()
    }

    /// True when breaks are being (or will be) held back for a call/share.
    private var isSuppressedByCapture: Bool {
        scheduler.isDeferringForCapture || (settings.skipDuringCapture && capture.isActive)
    }

    func refresh() {
        guard let button = statusItem?.button else { return }

        let symbolName: String
        switch scheduler.phase {
        case .paused:
            symbolName = "eye.slash"
        case .preBreak, .onBreak:
            symbolName = "eye.fill"
        case .working:
            if scheduler.isOutsideActiveSchedule {
                symbolName = "eye.slash"
            } else {
                symbolName = isSuppressedByCapture ? "hourglass" : "eye"
            }
        }
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Blink")

        if settings.showTimeRemainingInMenuBar,
           case .working = scheduler.phase,
           !isSuppressedByCapture,
           !scheduler.isOutsideActiveSchedule,
           let next = scheduler.nextBreakDate {
            let minutes = max(0, Int((next.timeIntervalSinceNow / 60).rounded(.up)))
            button.title = " \(minutes)m"
        } else {
            button.title = ""
        }
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        for line in statusLines() {
            let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())

        let isPaused: Bool
        if case .paused = scheduler.phase { isPaused = true } else { isPaused = false }

        if isPaused {
            menu.addItem(ClosureMenuItem("Resume", handler: actions.resume))
        } else {
            menu.addItem(ClosureMenuItem("Take Break Now", handler: actions.startBreakNow))
            menu.addItem(ClosureMenuItem("Skip Next Break", handler: actions.skipNextBreak))
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Pause for 1 Hour", handler: actions.pauseOneHour))
            menu.addItem(ClosureMenuItem("Pause Until Tomorrow", handler: actions.pauseUntilTomorrow))
            menu.addItem(ClosureMenuItem("Pause Until Resumed", handler: actions.pauseUntilResumed))
        }

        if settings.showDebugMenu {
            menu.addItem(.separator())
            menu.addItem(debugSubmenuItem())
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Settings…", keyEquivalent: ",", handler: actions.openSettings))
        if actions.canCheckForUpdates() {
            menu.addItem(ClosureMenuItem("Check for Updates…", handler: actions.checkForUpdates))
        }
        menu.addItem(ClosureMenuItem("Quit Blink", keyEquivalent: "q", handler: actions.quit))
    }

    /// One or two disabled info lines explaining exactly what Blink is doing.
    private func statusLines() -> [String] {
        switch scheduler.phase {
        case .paused(let until):
            if let until {
                return ["Paused until \(Self.pausedUntilFormatter.string(from: until))"]
            }
            return ["Paused"]
        case .onBreak:
            return ["Break in progress"]
        case .preBreak:
            return ["Break starting…"]
        case .working:
            if scheduler.isOutsideActiveSchedule {
                guard let resume = scheduler.activeScheduleResumeDate else { return ["Outside your active hours"] }
                return ["Outside your active hours", "Resumes \(Self.resumeFormatter.string(from: resume))"]
            }
            if scheduler.isDeferringForCapture {
                return ["Break waiting until your call ends"] + capture.activeReasons.map { "  \($0)" }
            }
            var lines: [String] = []
            if let next = scheduler.nextBreakDate {
                let minutes = Int((next.timeIntervalSinceNow / 60).rounded(.up))
                lines.append(minutes <= 1 ? "Next break in under a minute" : "Next break in \(minutes) min")
            } else {
                lines.append("Waiting…")
            }
            if settings.skipDuringCapture, capture.isActive {
                lines.append("On a call — breaks will wait")
                lines.append(contentsOf: capture.activeReasons.map { "  \($0)" })
            }
            return lines
        }
    }

    /// Live per-device detection state, so "why does Blink think I'm on a
    /// call?" is answerable from the menu bar. Off by default; the
    /// "Show debug menu" setting reveals it.
    private func debugSubmenuItem() -> NSMenuItem {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for row in capture.diagnosticRows() {
            let item = NSMenuItem(title: row, action: nil, keyEquivalent: "")
            item.isEnabled = false
            submenu.addItem(item)
        }
        submenu.addItem(.separator())
        submenu.addItem(ClosureMenuItem("Copy Diagnostics", handler: actions.copyDiagnostics))

        let item = NSMenuItem(title: "Debug", action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }
}

/// `NSMenuItem` that invokes a closure, avoiding target/action plumbing.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, keyEquivalent: String = "", handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(invoke), keyEquivalent: keyEquivalent)
        target = self
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func invoke() {
        handler()
    }
}
