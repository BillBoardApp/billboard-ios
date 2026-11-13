import SwiftUI
import UIKit
import XCTest

/// Draws a view the way the app shows it: in a `UIHostingController` on a window of the test host's scene.
///
/// Use it for screens with text fields or a search field. `ImageRenderer` has no focus system, so a view that
/// uses `@FocusState` (`LoginView`, `CreateAccountView`, `LocationEditorView`, the Congress search) makes
/// SwiftUI report "Accessing FocusState's value outside of the body of a View" there.
@MainActor
enum HostedRender {
    /// `view` at `width`, `height` tall (nil: the view's own height at that width), drawn at `scale` after
    /// `settle` seconds. The window ignores the host's safe area, as `ImageRenderer` does.
    static func image<Content: View>(
        _ view: Content,
        width: CGFloat,
        height: CGFloat?,
        style: UIUserInterfaceStyle,
        scale: CGFloat = 1,
        settle: TimeInterval = 0.05
    ) throws -> CGImage {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "the hosted test app has a window scene"
        )
        let host = UIHostingController(rootView: view)
        host.safeAreaRegions = []
        host.overrideUserInterfaceStyle = style
        let fittedHeight = height ?? host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let size = CGSize(width: width, height: ceil(fittedHeight))

        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.overrideUserInterfaceStyle = style
        window.rootViewController = host
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(settle))
        host.view.layoutIfNeeded()

        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        return try XCTUnwrap(image.cgImage, "drawing failed")
    }
}
