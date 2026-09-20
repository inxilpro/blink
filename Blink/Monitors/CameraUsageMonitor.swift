import CoreMediaIO
import Foundation
import os

/// Watches whether any camera is capturing system-wide, via CoreMediaIO's
/// `DeviceIsRunningSomewhere` property. This observes device *state* only —
/// no frames are touched, so no camera permission prompt is ever triggered.
/// Fully event-driven: property listeners fire on device start/stop and on
/// cameras appearing/disappearing.
@MainActor
final class CameraUsageMonitor {
    struct DeviceState {
        let name: String
        let isRunning: Bool
    }

    private(set) var isCameraActive = false
    private(set) var activeDeviceNames: [String] = []
    var onChange: ((_ isActive: Bool) -> Void)?

    /// Devices we have a listener installed on, by ID. Listeners on unplugged
    /// devices are left registered; their IDs simply go stale, harmlessly.
    private var knownDevices: [CMIOObjectID: String] = [:]

    private nonisolated static let systemObject = CMIOObjectID(kCMIOObjectSystemObject)

    private nonisolated static let devicesAddress = CMIOObjectPropertyAddress(
        mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
        mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
        mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
    )

    private nonisolated static let nameAddress = CMIOObjectPropertyAddress(
        mSelector: CMIOObjectPropertySelector(kCMIOObjectPropertyName),
        mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
        mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
    )

    private nonisolated static let runningSomewhereAddress = CMIOObjectPropertyAddress(
        mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
        mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeWildcard),
        mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementWildcard)
    )

    func start() {
        var devicesAddress = Self.devicesAddress
        let status = CMIOObjectAddPropertyListenerBlock(Self.systemObject, &devicesAddress, .main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        if status != kCMIOHardwareNoError {
            BlinkLog.capture.error("Failed to observe camera device list (status \(status, privacy: .public))")
        }
        refresh()
    }

    func snapshot() -> [DeviceState] {
        Self.currentDeviceIDs().map { id in
            DeviceState(
                name: knownDevices[id] ?? Self.deviceName(id),
                isRunning: Self.isRunningSomewhere(id)
            )
        }
    }

    private func refresh() {
        let devices = Self.currentDeviceIDs()
        for id in devices where knownDevices[id] == nil {
            let name = Self.deviceName(id)
            knownDevices[id] = name
            var address = Self.runningSomewhereAddress
            let status = CMIOObjectAddPropertyListenerBlock(id, &address, .main) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.recompute() }
            }
            BlinkLog.capture.notice("Watching camera '\(name, privacy: .public)' (listener status \(status, privacy: .public))")
        }
        let staleIDs = knownDevices.keys.filter { !devices.contains($0) }
        for id in staleIDs {
            BlinkLog.capture.notice("Camera '\(self.knownDevices[id] ?? "?", privacy: .public)' disappeared")
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
        guard isActive != isCameraActive else { return }
        isCameraActive = isActive
        BlinkLog.capture.notice("Camera state → \(isActive ? "ACTIVE (\(active.joined(separator: ", ")))" : "idle", privacy: .public)")
        onChange?(isActive)
    }

    // MARK: - CMIO plumbing

    private nonisolated static func currentDeviceIDs() -> [CMIOObjectID] {
        var address = devicesAddress
        var dataSize: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(systemObject, &address, 0, nil, &dataSize) == kCMIOHardwareNoError,
              dataSize > 0
        else { return [] }

        var deviceIDs = [CMIOObjectID](repeating: 0, count: Int(dataSize) / MemoryLayout<CMIOObjectID>.size)
        var dataUsed: UInt32 = 0
        guard CMIOObjectGetPropertyData(systemObject, &address, 0, nil, dataSize, &dataUsed, &deviceIDs) == kCMIOHardwareNoError
        else { return [] }
        return deviceIDs
    }

    private nonisolated static func deviceName(_ device: CMIOObjectID) -> String {
        var address = nameAddress
        var dataSize: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(device, &address, 0, nil, &dataSize) == kCMIOHardwareNoError,
              dataSize > 0
        else { return "Camera \(device)" }
        var value: CFString = "" as CFString
        var dataUsed: UInt32 = 0
        let status = withUnsafeMutablePointer(to: &value) {
            CMIOObjectGetPropertyData(device, &address, 0, nil, dataSize, &dataUsed, $0)
        }
        return status == kCMIOHardwareNoError ? (value as String) : "Camera \(device)"
    }

    private nonisolated static func isRunningSomewhere(_ device: CMIOObjectID) -> Bool {
        var address = runningSomewhereAddress
        var value: UInt32 = 0
        var dataUsed: UInt32 = 0
        let status = CMIOObjectGetPropertyData(
            device, &address, 0, nil,
            UInt32(MemoryLayout<UInt32>.size), &dataUsed, &value
        )
        return status == kCMIOHardwareNoError && value != 0
    }
}
