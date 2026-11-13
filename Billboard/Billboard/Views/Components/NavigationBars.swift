import SwiftUI

// The two navigation bars of Civic Record (spec 3.21): navy on the tab roots and the screens before the
// tabs, system glass on every pushed screen and sheet. UIKit's appearance proxy draws only the glass bar
// (`BillBoardApp.configureUIKitAppearance`, spec 2.4); the navy is set per screen here.

/// The navy bar of the tab roots (Bills, Updates, Congress, Profile) and of the screens before the tabs
/// (sign in, create account, forgot password, new password, age gate, ineligible, Where do you vote?):
/// navy behind the status bar and the navigation bar, white status-bar icons, and the bar's items in their
/// dark appearance (the wordmark, the masthead chips' glass, a light back chevron on its disc).
///
/// The screen draws the navy itself, as an overlay the height of the bar, and hides the bar's own
/// background. Spec 3.21's `toolbarBackground(navy)` with `.visible` does not cross-fade with a pushed
/// screen's glass bar: on a push the navy vanished in the first frame and left the white "BILL" of the
/// wordmark on a pale bar, and on a pop, and for the whole of a held half swipe, navy covered the pushed
/// screen's bar (slice 0 spike, `q2-frames-push-toolbar-navy`, `q2-frames-half-swipe-edge-cancelled`).
/// Drawn by the screen, the navy slides in and out with it and the pushed screen's bar stays clear
/// (`q2-frames-*-navy-as-content`). Pull to refresh opens a paper gap under the navy (spec 3.21: the
/// system spinner stays on paper).
private struct NavyNavigationBarModifier: ViewModifier {
    /// The bottom of the status bar and navigation bar, in the window.
    @State private var barBottom: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { proxy in
                // The screen starts under the bar; a screen that ignores the top safe area still has the
                // bar's height as its inset.
                max(proxy.frame(in: .global).minY, proxy.safeAreaInsets.top)
            } action: { bottom in
                barBottom = bottom
            }
            .overlay(alignment: .top) {
                GeometryReader { proxy in
                    BillboardColors.navy
                        .frame(height: barBottom)
                        .offset(y: -proxy.frame(in: .global).minY)
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            // Content scrolled up under the bar goes under the navy: no soft edge below it.
            .scrollEdgeEffectHidden(true, for: .top)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            // White status-bar icons, and the bar's items resolve their dark colours, in light mode too.
            .toolbarColorScheme(.dark, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
    }
}

/// The system glass bar of a pushed screen (spec 3.21, 4.6): the system back button, the inline title in
/// the `navTitle` face (set by the appearance proxy), toolbar items in `ink`, and content that fades and
/// blurs under the bar instead of being cut. The bar background is set to `.automatic` on every pushed
/// screen explicitly, so it never inherits the navy root's hidden background.
private struct GlassNavigationBarModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .toolbarBackgroundVisibility(.automatic, for: .navigationBar)
            .scrollEdgeEffectStyle(.soft, for: .top)
    }
}

extension View {
    /// The navy bar of a tab root or a screen before the tabs (spec 3.21). Put the `Wordmark` in the
    /// principal slot.
    func navyNavigationBar() -> some View {
        modifier(NavyNavigationBarModifier())
    }

    /// The bar of a screen before the tabs (spec 3.21, 4.10 to 4.16): navy with the 26 pt `Wordmark` in
    /// the middle and no chips. Where the screen is pushed (Create account, Forgot password) the system
    /// back button sits on the navy in its dark appearance.
    func preTabBar() -> some View {
        navyNavigationBar()
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Wordmark(size: .compact)
                }
                // Set on the navy itself, not in a glass capsule of its own.
                .sharedBackgroundVisibility(.hidden)
            }
    }

    /// The system glass bar of a pushed screen (spec 3.21, 4.6), with the system back button.
    func glassNavigationBar() -> some View {
        modifier(GlassNavigationBarModifier())
    }
}
