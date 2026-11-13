import UIKit

/// The page's scroll view under `view` (itself included): of the scroll views whose content is taller than
/// they are, the one with the tallest content, so a control's own scroll view (a row of tags, a text view) is
/// never taken for the page. Nil when nothing under `view` scrolls. Test code only.
@MainActor
func pageScrollView(in view: UIView) -> UIScrollView? {
    var best: UIScrollView?
    func visit(_ view: UIView) {
        if let scroll = view as? UIScrollView, scroll.contentSize.height > scroll.bounds.height + 1,
           scroll.contentSize.height > (best?.contentSize.height ?? 0) {
            best = scroll
        }
        view.subviews.forEach(visit)
    }
    visit(view)
    return best
}
