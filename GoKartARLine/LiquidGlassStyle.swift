import SwiftUI

extension View {
    func liquidGlassControl(cornerRadius: CGFloat = 14) -> some View {
        modifier(AdaptiveLiquidGlassControlModifier(cornerRadius: cornerRadius))
    }
}

extension ButtonStyle where Self == LiquidGlassButtonStyle {
    static var liquidGlass: LiquidGlassButtonStyle { LiquidGlassButtonStyle(isProminent: false) }
    static var liquidGlassProminent: LiquidGlassButtonStyle { LiquidGlassButtonStyle(isProminent: true) }
}

struct LiquidGlassButtonStyle: ButtonStyle {
    var isProminent = false

    func makeBody(configuration: Configuration) -> some View {
        Group {
            #if compiler(>=6.2)
            if #available(iOS 26.0, *) {
                OfficialLiquidGlassButtonBody(configuration: configuration, isProminent: isProminent)
            } else {
                LegacyAppleButtonBody(configuration: configuration, isProminent: isProminent)
            }
            #else
            LegacyAppleButtonBody(configuration: configuration, isProminent: isProminent)
            #endif
        }
    }
}

struct LiquidGlassPanelModifier: ViewModifier {
    var cornerRadius: CGFloat
    var isProminent = false

    func body(content: Content) -> some View {
        Group {
            #if compiler(>=6.2)
            if #available(iOS 26.0, *) {
                content
                    .glassEffect(in: .rect(cornerRadius: cornerRadius))
            } else {
                legacyPanel(content)
            }
            #else
            legacyPanel(content)
            #endif
        }
    }

    private func legacyPanel(_ content: Content) -> some View {
        content
            .foregroundStyle(.primary)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(isProminent ? 0.22 : 0.12), lineWidth: 1)
            }
    }
}

private struct AdaptiveLiquidGlassControlModifier: ViewModifier {
    var cornerRadius: CGFloat

    func body(content: Content) -> some View {
        Group {
            #if compiler(>=6.2)
            if #available(iOS 26.0, *) {
                content
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                    .glassEffect(in: .rect(cornerRadius: cornerRadius))
            } else {
                content
            }
            #else
            content
            #endif
        }
    }
}

private struct LegacyAppleButtonBody: View {
    var configuration: ButtonStyle.Configuration
    var isProminent: Bool

    var body: some View {
        configuration.label
            .font(.headline)
            .padding(.vertical, 9)
            .padding(.horizontal, 14)
            .foregroundStyle(isProminent ? .white : .accentColor)
            .background {
                if isProminent {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.accentColor)
                } else {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.45), lineWidth: 1)
                }
            }
            .opacity(configuration.isPressed ? 0.65 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

#if compiler(>=6.2)
@available(iOS 26.0, *)
private struct OfficialLiquidGlassButtonBody: View {
    var configuration: ButtonStyle.Configuration
    var isProminent: Bool

    var body: some View {
        configuration.label
            .font(.headline)
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
            .foregroundStyle(.white)
            .glassEffect(isProminent ? .regular.tint(.white.opacity(0.20)).interactive() : .regular.interactive(), in: .rect(cornerRadius: 18))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.78), value: configuration.isPressed)
    }
}
#endif
