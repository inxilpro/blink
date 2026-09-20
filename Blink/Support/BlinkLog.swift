import Foundation
import os

/// Structured logging for detection and scheduling decisions, at `notice`
/// level so entries persist for after-the-fact inspection:
///
///     log show --last 1h --predicate 'subsystem == "com.cmorrell.Blink"'
///     log stream --predicate 'subsystem == "com.cmorrell.Blink"'
enum BlinkLog {
    nonisolated static let scheduler = Logger(subsystem: subsystem, category: "scheduler")
    nonisolated static let capture = Logger(subsystem: subsystem, category: "capture")

    private nonisolated static let subsystem = Bundle.main.bundleIdentifier ?? "com.cmorrell.Blink"
}
