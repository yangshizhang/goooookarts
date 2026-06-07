import SwiftUI

extension View {
    func liquidGlassControl(cornerRadius: CGFloat = 14) -> some View {
        padding(.vertical, 6)
            .padding(.horizontal, 10)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}
