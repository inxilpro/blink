import Foundation

@MainActor
protocol SchedulerToken: AnyObject {
    func cancel()
}

/// Abstraction over wall-clock time and one-shot/repeating timers so the
/// break lifecycle can be driven deterministically in tests.
@MainActor
protocol SchedulerClock: AnyObject {
    var now: Date { get }

    @discardableResult
    func after(_ delay: TimeInterval, tolerance: TimeInterval, _ body: @escaping @MainActor () -> Void) -> SchedulerToken

    @discardableResult
    func repeating(every interval: TimeInterval, tolerance: TimeInterval, _ body: @escaping @MainActor () -> Void) -> SchedulerToken
}

@MainActor
final class SystemClock: SchedulerClock {
    private final class Token: SchedulerToken {
        private let timer: Timer
        init(_ timer: Timer) { self.timer = timer }
        func cancel() { timer.invalidate() }
    }

    var now: Date { Date() }

    @discardableResult
    func after(_ delay: TimeInterval, tolerance: TimeInterval, _ body: @escaping @MainActor () -> Void) -> SchedulerToken {
        makeToken(interval: delay, repeats: false, tolerance: tolerance, body)
    }

    @discardableResult
    func repeating(every interval: TimeInterval, tolerance: TimeInterval, _ body: @escaping @MainActor () -> Void) -> SchedulerToken {
        makeToken(interval: interval, repeats: true, tolerance: tolerance, body)
    }

    private func makeToken(interval: TimeInterval, repeats: Bool, tolerance: TimeInterval, _ body: @escaping @MainActor () -> Void) -> SchedulerToken {
        let timer = Timer(timeInterval: max(interval, 0.001), repeats: repeats) { _ in
            MainActor.assumeIsolated(body)
        }
        timer.tolerance = tolerance
        RunLoop.main.add(timer, forMode: .common)
        return Token(timer)
    }
}
