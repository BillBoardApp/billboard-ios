import SwiftUI

/// The inline title in a document page's bar (Civic Record spec 4.28 for the bill page, 4.58 and 4.59 for the
/// party, chamber and member pages): out of the bar while the page's own title is on screen, in it once the
/// front matter has scrolled under the bar, so the page never shows its title twice.
///
/// The screen's title stays set all along and only the bar's view of it comes and goes
/// (`.toolbar(removing: .title)`). An empty `.navigationTitle` at rest also emptied the navigation item, so a
/// page pushed from the page at rest got a back button reading "Back" and a blank entry in the back menu.
///
/// Put it on the page's scroll view; `titleBottom` is where the page's title ends in the scroll content's
/// coordinates (0 until measured, when the bar shows no title).
struct DocumentInlineTitle: ViewModifier {
    let title: String
    let titleBottom: CGFloat

    @State private var isPastTitle = false

    /// True once the content has scrolled further than the title's bottom (never before it is measured).
    static func isPastTitle(contentOffsetY: CGFloat, topInset: CGFloat, titleBottom: CGFloat) -> Bool {
        titleBottom > 0 && contentOffsetY + topInset > titleBottom
    }

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: Bool.self) { geometry in
                Self.isPastTitle(contentOffsetY: geometry.contentOffset.y, topInset: geometry.contentInsets.top, titleBottom: titleBottom)
            } action: { _, isPast in
                isPastTitle = isPast
            }
            .navigationTitle(title)
            .toolbar(removing: isPastTitle ? nil : .title)
    }
}
