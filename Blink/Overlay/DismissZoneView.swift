import SwiftUI

/// The one region of the break overlay that accepts clicks.
struct DismissZoneView: View {
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "xmark.circle.fill")
                Text("Dismiss Break")
            }
            .font(.headline)
            .foregroundStyle(.white.opacity(isHovering ? 1 : 0.85))
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .background(Capsule().fill(.black.opacity(isHovering ? 0.85 : 0.6)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    DismissZoneView(action: {})
        .frame(width: 260, height: 64)
        .background(.gray)
}
