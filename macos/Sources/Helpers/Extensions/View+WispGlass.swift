import SwiftUI

extension View {
    /// Wisp side-panel surface. On macOS 26+ this is real "Liquid Glass" (frosted,
    /// refractive) that pairs with the window's background blur for a premium translucent
    /// look; on earlier systems it falls back to a plain translucent material so the app
    /// still builds and reads correctly.
    ///
    /// Used for the file sidebar and the Markdown pane so their chrome floats over the
    /// terminal's blurred background instead of sitting on a flat opaque panel.
    @ViewBuilder
    func wispGlassPanel(cornerRadius: CGFloat = 0) -> some View {
        if #available(macOS 26.0, iOS 26.0, *) {
            glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            background(
                .regularMaterial,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
        }
    }
}
