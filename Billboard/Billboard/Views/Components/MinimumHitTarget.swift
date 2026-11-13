import SwiftUI

extension View {
    /// Makes the whole view tappable and extends the tappable area to at least `size` x `size`
    /// points, centred on the view, without changing its layout or appearance.
    ///
    /// Apply it inside a `Button` label so the extra area belongs to the button.
    func billboardMinimumHitTarget(_ size: CGFloat = 44) -> some View {
        self
            .contentShape(Rectangle())
            .background {
                Color.clear
                    .frame(width: size, height: size)
                    .contentShape(Rectangle())
                    .accessibilityHidden(true)
            }
    }
}
