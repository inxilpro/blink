import CoreAudio
import Foundation
import os

/// Watches whether any audio *input* device is capturing system-wide, via
/// CoreAudio's `DeviceIsRunningSomewhere` property — the audio twin of
/// `CameraUsageMonitor`. An open microphone is the most reliable public signal
/// that a call is in progress (it covers screen-share pairing sessions where
/// the camera stays off, and conferencing apps keep the input stream open even
/// while muted). State only — no audio is captured, no permission prompt.
@MainActor
final class MicrophoneUsageMonitor {
    struct DeviceState {
        let name: String
        let isRunning: Bool
    }

    private(set) var isMicrophoneActive = false
    private(set) var activeDeviceNames: [String] = []
    var onChange: ((_ isActive: Bool) -> Void)?

    /// Input devices we have a listener installed on, by ID. Listeners on
    /// unplugged devices are left registered; their IDs go stale harmlessly.
    private var knownDevices: [AudioObjectID: String] = [:]

    private nonisolated static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    private nonisolated static let devicesAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private nonisolated static let runningSomewhereAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    func start() {
        var devicesAddress = Self.devicesAddress
        let status = AudioObjectAddPropertyListenerBlock(Self.systemObject, &devicesAddress, .main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        if status != noErr {
            BlinkLog.capture.error("Failed to observe audio device list (status \(status, privacy: .public))")
        }
        refresh()
    }

    func snapshot() -> [DeviceState] {
        Self.currentInputDeviceIDs().map { id in
            DeviceState(
                name: knownDevices[id] ?? Self.deviceName(id),
                isRunning: Self.isRunningSomewhere(id)
            )
        }
    }

    private func refresh() {
        let devices = Self.currentInputDeviceIDs()
        for id in devices where knownDevices[id] == nil {
            let name = Self.deviceName(id)
            knownDevices[id] = name
            var address = Self.runningSomewhereAddress
            let status = AudioObjectAddPropertyListenerBlock(id, &address, .main) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.recompute() }
            }
            BlinkLog.capture.notice("Watching audio input '\(name, privacy: .public)' (listener status \(status, privacy: .public))")
        }
        let staleIDs = knownDevices.keys.filter { !devices.contains($0) }
        for id in staleIDs {
            BlinkLog.capture.notice("Audio input '\(self.knownDevices[id] ?? "?", privacy: .public)' disappeared")
            knownDevices.removeValue(forKey: id)
        }
        recompute()
    }

    private func recompute() {
        let active = knownDevices
            .filter { Self.isRunningSomewhere($0.key) }
            .map(\.value)
            .sorted()
        activeDeviceNames = active
        let isActive = !active.isEmpty
        guard isActive != isMicrophoneActive else { return }
        isMicrophoneActive = isActive
        BlinkLog.capture.notice("Microphone state → \(isActive ? "ACTIVE (\(active.joined(separator: ", ")))" : "idle", privacy: .public)")
        onChange?(isActive)
    }

    // MARK: - CoreAudio plumbing

    private nonisolated static func currentInputDeviceIDs() -> [AudioObjectID] {
        var address = devicesAddress
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &dataSize) == noErr,
              dataSize > 0
        else { return [] }

        var deviceIDs = [AudioObjectID](repeating: 0, count: Int(dataSize) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(systemObject, &address, 0, nil, &dataSize, &deviceIDs) == noErr
        else { return [] }
        return deviceIDs.filter(hasInputStreams)
    }

    private nonisolated static func hasInputStreams(_ device: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &dataSize) == noErr && dataSize > 0
    }

    private nonisolated static func deviceName(_ device: AudioObjectID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString = "" as CFString
        var dataSize = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(device, &address, 0, nil, &dataSize, $0)
        }
        return status == noErr ? (value as String) : "Audio input \(device)"
    }

    private nonisolated static func isRunningSomewhere(_ device: AudioObjectID) -> Bool {
        var address = runningSomewhereAddress
        var value: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &dataSize, &value)
        return status == noErr && value != 0
    }
}
