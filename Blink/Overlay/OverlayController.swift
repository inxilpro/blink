import AppKit
import SwiftUI

/// Owns the overlay windows on every connected display: the pre-break vignette,
/// the break dim + countdown, and the dismiss zone. All panels are click-through
/// except the dismiss zone, and none can take keyboard focus.
@MainActor
final class OverlayController {
    var onDismiss: (() -> Void)?

    private enum State {
        case hidden
        case vignette
        case onBreak(endDate: Date)
    }

    private let settings: AppSettings
    private var state: State = .hidden
    private var vignettePanels: [OverlayPanel] = []
    private var breakPanels: [OverlayPanel] = []
    private var dismissPanels: [OverlayPanel] = []
    private var screenObserver: NSObjectProtocol?

    private nonisolated static let breakFadeInDuration: TimeInterval = 2.5
    private nonisolated static let fadeOutDuration: TimeInterval = 0.8

    init(settings: AppSettings) {
        self.settings = settings
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { [weak self] in self?.screenConfigurationChanged() }
        }
    }

    // MARK: - Public API

    func showVignette(fadeDuration: TimeInterval) {
        removePanels(&vignettePanels)
        state = .vignette
        vignettePanels = NSScreen.screens.map { screen in
            let panel = OverlayPanel(frame: screen.frame)
            panel.contentView = NSHostingView(rootView: VignetteView())
            panel.orderFrontRegardless()
            return panel
        }
        animate(vignettePanels, toAlpha: 1, duration: fadeDuration, timing: .linear)
    }

    func showBreak(endDate: Date, duration: TimeInterval) {
        state = .onBreak(endDate: endDate)
        buildBreakPanels(endDate: endDate)
        let fadeIn = min(Self.breakFadeInDuration, duration / 3)
        animate(breakPanels + dismissPanels, toAlpha: 1, duration: fadeIn, timing: .easeInEaseOut)
        // Crossfade the vignette away underneath the dim.
        fadeOutAndRemove(vignettePanels, duration: fadeIn)
        vignettePanels = []
    }

    func hideAll(fadeDuration: TimeInterval = OverlayController.fadeOutDuration) {
        state = .hidden
        fadeOutAndRemove(vignettePanels + breakPanels + dismissPanels, duration: fadeDuration)
        vignettePanels = []
        breakPanels = []
        dismissPanels = []
    }

    // MARK: - Panel construction

    private func buildBreakPanels(endDate: Date) {
        removePanels(&breakPanels)
        removePanels(&dismissPanels)
        for screen in NSScreen.screens {
            let breakPanel = OverlayPanel(frame: screen.frame)
            breakPanel.contentView = NSHostingView(rootView: BreakOverlayView(settings: settings, endDate: endDate))
            breakPanel.orderFrontRegardless()
            breakPanels.append(breakPanel)

            let dismissPanel = OverlayPanel(frame: Self.dismissZoneFrame(on: screen))
            dismissPanel.ignoresMouseEvents = false
            dismissPanel.contentView = NSHostingView(rootView: DismissZoneView { [weak self] in
                self?.onDismiss?()
            })
            dismissPanel.orderFrontRegardless()
            dismissPanels.append(dismissPanel)
        }
    }

    /// Bottom-center of the screen: clearly visible but well away from where an
    /// in-progress click is likely to land.
    private static func dismissZoneFrame(on screen: NSScreen) -> NSRect {
        let size = NSSize(width: 240, height: 64)
        return NSRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.minY + floor(screen.frame.height * 0.14),
            width: size.width,
            height: size.height
        )
    }

    private func screenConfigurationChanged() {
        // Rebuild for the new display set; skip fade-in since the overlay is
        // already conceptually visible.
        switch state {
        case .hidden:
            break
        case .vignette:
            removePanels(&vignettePanels)
            showVignette(fadeDuration: 0.2)
        case .onBreak(let endDate):
            buildBreakPanels(endDate: endDate)
            (breakPanels + dismissPanels).forEach { $0.alphaValue = 1 }
        }
    }

    // MARK: - Animation helpers

    private func animate(
        _ panels: [NSWindow],
        toAlpha alpha: CGFloat,
        duration: TimeInterval,
        timing: CAMediaTimingFunctionName,
        completion: (@MainActor () -> Void)? = nil
    ) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = max(0.01, duration)
            context.timingFunction = CAMediaTimingFunction(name: timing)
            panels.forEach { $0.animator().alphaValue = alpha }
        }, completionHandler: completion.map { body in { @Sendable in MainActor.assumeIsolated(body) } })
    }

    private func fadeOutAndRemove(_ panels: [OverlayPanel], duration: TimeInterval) {
        guard !panels.isEmpty else { return }
        animate(panels, toAlpha: 0, duration: duration, timing: .easeInEaseOut) {
            panels.forEach { panel in
                panel.orderOut(nil)
                panel.close()
            }
        }
    }

    private func removePanels(_ panels: inout [OverlayPanel]) {
        panels.forEach { panel in
            panel.orderOut(nil)
            panel.close()
        }
        panels = []
    }
}
