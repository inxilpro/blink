import SwiftUI

/// Subtle darkening around the screen edges that hints a break is approaching.
struct VignetteView: View {
    var body: some View {
        GeometryReader { geometry in
            let radius = hypot(geometry.size.width, geometry.size.height) / 2
            Rectangle()
                .fill(
                    RadialGradient(
                        gradient: Gradient(stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .clear, location: 0.6),
                            .init(color: .black.opacity(0.45), location: 1),
                        ]),
                        center: .center,
                        startRadius: 0,
                        endRadius: radius
                    )
                )
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

#Preview {
    VignetteView()
        .frame(width: 640, height: 400)
        .background(.white)
}
