import AppKit

/// Tracks whether the user's screen is actually in front of them: reports
/// unavailable while the screen is locked, displays or system are asleep, or
/// another user's session is active. Multiple overlapping reasons are unioned
/// so out-of-order notifications (e.g. wake before unlock) resolve correctly.
@MainActor
final class SystemAvailabilityMonitor: NSObject {
    var onAvailabilityChange: ((_ isAvailable: Bool) -> Void)?

    private enum Reason: Hashable {
        case screenLocked
        case displaysAsleep
        case systemAsleep
        case sessionInactive
    }

    private var reasons: Set<Reason> = []

    func start() {
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(self, selector: #selector(screenLocked), name: .init("com.apple.screenIsLocked"), object: nil)
        distributed.addObserver(self, selector: #selector(screenUnlocked), name: .init("com.apple.screenIsUnlocked"), object: nil)

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(screensSlept), name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(screensWoke), name: NSWorkspace.screensDidWakeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(systemSlept), name: NSWorkspace.willSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(systemWoke), name: NSWorkspace.didWakeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(sessionResigned), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        workspace.addObserver(self, selector: #selector(sessionActivated), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
    }

    @objc private func screenLocked() { add(.screenLocked) }
    @objc private func screenUnlocked() { remove(.screenLocked) }
    @objc private func screensSlept() { add(.displaysAsleep) }
    @objc private func screensWoke() { remove(.displaysAsleep) }
    @objc private func systemSlept() { add(.systemAsleep) }
    @objc private func systemWoke() { remove(.systemAsleep) }
    @objc private func sessionResigned() { add(.sessionInactive) }
    @objc private func sessionActivated() { remove(.sessionInactive) }

    private func add(_ reason: Reason) {
        let wasAvailable = reasons.isEmpty
        reasons.insert(reason)
        if wasAvailable {
            onAvailabilityChange?(false)
        }
    }

    private func remove(_ reason: Reason) {
        let wasAvailable = reasons.isEmpty
        reasons.remove(reason)
        if !wasAvailable, reasons.isEmpty {
            onAvailabilityChange?(true)
        }
    }
}
