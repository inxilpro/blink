import CoreGraphics
import Foundation

enum SystemIdle {
    /// Seconds since the last user input event. `CGEventSource` exposes idle
    /// time per event type; the minimum across input types is the effective
    /// system idle time. This reads timestamps only — no event tap, no
    /// Input Monitoring permission.
    nonisolated static func seconds() -> TimeInterval {
        let eventTypes: [CGEventType] = [
            .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .scrollWheel, .keyDown, .flagsChanged,
        ]
        return eventTypes.reduce(.greatestFiniteMagnitude) { shortest, type in
            min(shortest, CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: type))
        }
    }
}
