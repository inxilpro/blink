import Foundation

/// Combines camera and microphone detection into a single "the user is
/// probably on a call, pairing, or presenting" signal.
///
/// A process-name screen-share heuristic used to live here too; it was removed
/// after it proved false: Zoom's `caphost` helper runs for the lifetime of the
/// Zoom app, not just during shares. An open microphone is the reliable public
/// signal for calls and pairing sessions (including screen sharing with the
/// camera off), and Blink's own overlays are capture-excluded as the backstop.
@MainActor
final class CaptureActivityMonitor {
    private let camera = CameraUsageMonitor()
    private let microphone = MicrophoneUsageMonitor()

    var onChange: ((_ isActive: Bool) -> Void)?

    var isActive: Bool {
        camera.isCameraActive || microphone.isMicrophoneActive
    }

    /// Short human-readable reasons the signal is currently active,
    /// e.g. `["Camera: Cam Link 4K", "Microphone: EVO4"]`.
    var activeReasons: [String] {
        var reasons: [String] = []
        if camera.isCameraActive {
            reasons.append("Camera: \(camera.activeDeviceNames.joined(separator: ", "))")
        }
        if microphone.isMicrophoneActive {
            reasons.append("Microphone: \(microphone.activeDeviceNames.joined(separator: ", "))")
        }
        return reasons
    }

    /// Per-device state for the diagnostics UI.
    func diagnosticRows() -> [String] {
        camera.snapshot().map { "Camera — \($0.name): \($0.isRunning ? "in use" : "idle")" }
            + microphone.snapshot().map { "Mic — \($0.name): \($0.isRunning ? "in use" : "idle")" }
    }

    func start() {
        camera.onChange = { [weak self] _ in
            guard let self else { return }
            onChange?(isActive)
        }
        microphone.onChange = { [weak self] _ in
            guard let self else { return }
            onChange?(isActive)
        }
        camera.start()
        microphone.start()
    }
}
