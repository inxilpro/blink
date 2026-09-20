import SwiftUI

/// Full-screen dim with a centered countdown, shown for the duration of a break.
struct BreakOverlayView: View {
    let settings: AppSettings
    let endDate: Date

    var body: some View {
        ZStack {
            Color.black.opacity(settings.dimLevel)
            VStack(spacing: 16) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(countdownString(at: context.date))
                        .font(.system(size: 300, weight: .black, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.95))
                }
                Text("Look at something 20 feet away")
                    .font(.system(size: 24, weight: .semibold, design: .default))
                    .foregroundStyle(.white.opacity(0.65))
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private func countdownString(at date: Date) -> String {
        let remaining = max(0, Int(endDate.timeIntervalSince(date).rounded(.up)))
        return String(format: "%d:%02d", remaining / 60, remaining % 60)
    }
}
