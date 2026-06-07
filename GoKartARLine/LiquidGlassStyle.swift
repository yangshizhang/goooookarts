import SwiftUI

extension View {
    func liquidGlassControl(cornerRadius: CGFloat = 14) -> some View {
        padding(.vertical, 6)
            .padding(.horizontal, 10)
            .modifier(LiquidGlassPanelModifier(cornerRadius: cornerRadius, isProminent: false))
    }
}

extension ButtonStyle where Self == LiquidGlassButtonStyle {
    static var liquidGlass: LiquidGlassButtonStyle { LiquidGlassButtonStyle(isProminent: false) }
    static var liquidGlassProminent: LiquidGlassButtonStyle { LiquidGlassButtonStyle(isProminent: true) }
}

struct LiquidGlassButtonStyle: ButtonStyle {
    var isProminent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
            .modifier(LiquidGlassPanelModifier(cornerRadius: 18, isProminent: isProminent))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .brightness(configuration.isPressed ? -0.08 : 0)
            .animation(.spring(response: 0.22, dampingFraction: 0.78), value: configuration.isPressed)
    }
}

struct LiquidGlassPanelModifier: ViewModifier {
    var cornerRadius: CGFloat
    var isProminent = false

    func body(content: Content) -> some View {
        content
            .foregroundStyle(.white)
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(surfaceGradient)
                    .blendMode(.plusLighter)
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(edgeGradient, lineWidth: isProminent ? 1.25 : 1)
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .inset(by: 1.5)
                    .strokeBorder(innerHighlight, lineWidth: 0.75)
                GeometryReader { proxy in
                    let width = proxy.size.width
                    let height = proxy.size.height
                    Capsule()
                        .fill(.white.opacity(isProminent ? 0.42 : 0.30))
                        .frame(width: max(width * 0.45, 24), height: max(height * 0.16, 5))
                        .blur(radius: 5)
                        .offset(x: width * 0.11, y: height * 0.10)
                    Capsule()
                        .fill(.cyan.opacity(isProminent ? 0.24 : 0.12))
                        .frame(width: max(width * 0.28, 18), height: max(height * 0.12, 4))
                        .blur(radius: 7)
                        .offset(x: width * 0.58, y: height * 0.64)
                }
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .allowsHitTesting(false)
            }
            .shadow(color: .white.opacity(isProminent ? 0.16 : 0.10), radius: 1, x: 0, y: -1)
            .shadow(color: .cyan.opacity(isProminent ? 0.22 : 0.10), radius: 10, x: 0, y: 4)
            .shadow(color: .black.opacity(0.42), radius: 14, x: 0, y: 10)
            .compositingGroup()
    }

    private var surfaceGradient: LinearGradient {
        LinearGradient(
            colors: [
                .white.opacity(isProminent ? 0.42 : 0.28),
                .white.opacity(isProminent ? 0.16 : 0.10),
                .cyan.opacity(isProminent ? 0.16 : 0.08),
                .white.opacity(isProminent ? 0.22 : 0.12)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var edgeGradient: LinearGradient {
        LinearGradient(
            colors: [
                .white.opacity(isProminent ? 0.90 : 0.70),
                .white.opacity(isProminent ? 0.30 : 0.22),
                .cyan.opacity(isProminent ? 0.42 : 0.24),
                .white.opacity(isProminent ? 0.55 : 0.36)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var innerHighlight: LinearGradient {
        LinearGradient(
            colors: [
                .white.opacity(isProminent ? 0.54 : 0.38),
                .clear,
                .white.opacity(isProminent ? 0.24 : 0.14)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}
