import AppKit

/// A borderless, non-activating panel used for all overlay chrome. It can never
/// become key or main, so keyboard focus stays with the frontmost app no matter
/// what. Mouse pass-through is controlled per-instance via `ignoresMouseEvents`.
final class OverlayPanel: NSPanel {
    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // Never visible to screen recording or sharing, even if capture
        // detection misses a session in progress.
        sharingType = .none
        isReleasedWhenClosed = false
        animationBehavior = .none
        hidesOnDeactivate = false
        isFloatingPanel = true
        worksWhenModal = true
        alphaValue = 0
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
