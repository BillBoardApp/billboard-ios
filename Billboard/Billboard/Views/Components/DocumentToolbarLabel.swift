import SwiftUI

/// The glyph colour of a toolbar control on a document page's glass bar: the bill page's Watch and Share,
/// the member page's Follow (spec 3.21: toolbar items in ink).
///
/// A swipe back to a navy tab root draws the whole bar in the root's dark appearance for as long as the
/// finger is held, even with the page's own scheme set on the bar. In light mode the system then drew the
/// glyphs white on pale glass (1.9:1 on the simulator's screen); ink fixed to the page's appearance
/// measured 9.2:1 in the same frame, and is ink on the light glass and white on the dark glass at rest.
/// With Reduce Transparency or Increase Contrast the group behind them turns dark during the swipe, where
/// the system's white glyphs read and ink would not, so they keep the system's colour (nil).
///
/// Read the inputs from the page's environment, not the bar's: the bar's is the root's during the swipe.
enum DocumentToolbarGlyph {
    static func color(dark: Bool, increaseContrast: Bool, reduceTransparency: Bool) -> Color? {
        guard !increaseContrast, !reduceTransparency else { return nil }
        return BillboardPalette.interactive.fixedColor(dark: dark)
    }
}

/// A word-and-symbol control in a document page's bar (Watch, Follow): the symbol and the word side by
/// side, not a `Label`, which the bar draws as its icon alone even with `.titleAndIcon`, so the state
/// would show only as a glyph (spec 1.4). Like system bar buttons it keeps the bar's fixed size (capped at
/// `.large`); the button it labels offers the Large Content Viewer instead
/// (`documentToolbarLargeContent(_:systemImage:)`).
struct DocumentToolbarLabel: View {
    let title: String
    let systemImage: String
    /// `DocumentToolbarGlyph.color(...)` for the page, or nil for the system's colour.
    let glyphColor: Color?

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .contentTransition(.symbolEffect(.replace))
            Text(title)
        }
        .dynamicTypeSize(...DynamicTypeSize.large)
        .foregroundStyleIfSet(glyphColor)
    }
}

extension View {
    /// `foregroundStyle(color)`, or the view unchanged when `color` is nil.
    @ViewBuilder
    func foregroundStyleIfSet(_ color: Color?) -> some View {
        if let color {
            foregroundStyle(color)
        } else {
            self
        }
    }

    /// The Large Content Viewer for a bar control that keeps its size at accessibility text sizes.
    func documentToolbarLargeContent(_ title: String, systemImage: String) -> some View {
        accessibilityShowsLargeContentViewer {
            Label(title, systemImage: systemImage)
        }
    }
}
