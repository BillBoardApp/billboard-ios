import Darwin
import SwiftUI
import UIKit
import XCTest
@testable import Billboard

/// What VoiceOver can read in a SwiftUI view: every accessibility label, value and hint, found by hosting
/// the view in a window (a `UIHostingController`) and walking its accessibility elements. SwiftUI draws
/// `Text` itself, so the accessibility tree is where a view's words can be read in a unit test; an
/// element that hides its children (`.accessibilityElement(children: .ignore)`) is read by its own label.
///
/// SwiftUI builds that tree only while an assistive technology or UI automation is on, so the walk turns
/// automation on while it reads (`_AXSSetAutomationEnabled` in the simulator's libAccessibility, as
/// accessibility snapshot tools do) and off again after. `Host` keeps a view up for several reads and taps.
/// Test code only; the app never calls it.
@MainActor
enum AccessibilityTreeText {
    private typealias SetAutomationEnabled = @convention(c) (Int32) -> Void

    /// The switch for UI automation, or nil when it is not found.
    private static let setAutomationEnabled: SetAutomationEnabled? = {
        guard let handle = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW),
              let symbol = dlsym(handle, "_AXSSetAutomationEnabled") else { return nil }
        return unsafeBitCast(symbol, to: SetAutomationEnabled.self)
    }()

    /// The strings in `view`'s accessibility tree, in tree order, each once. `settle` is how long the
    /// hosted view runs before the walk (its `.task`s and appear handlers; a whole screen needs longer).
    static func strings<Content: View>(
        of view: Content,
        size: CGSize = CGSize(width: 390, height: 1600),
        settle: TimeInterval = 0.05
    ) -> [String] {
        let host = Host(view, size: size, settle: settle)
        defer { host.close() }
        return host.strings()
    }

    /// `strings(of:)` joined with " | ", for assertions and failure messages.
    static func text<Content: View>(
        of view: Content,
        size: CGSize = CGSize(width: 390, height: 1600),
        settle: TimeInterval = 0.05
    ) -> String {
        strings(of: view, size: size, settle: settle).joined(separator: " | ")
    }

    /// A view hosted in a window that stays up across several reads and taps, as a screen does between
    /// VoiceOver gestures: `activate(_:)` performs an element's default action (a button's tap), as a
    /// VoiceOver double tap does. Automation stays on until `close()`, which every test calls (`defer`).
    @MainActor
    final class Host {
        /// The window, for its appearance (`overrideUserInterfaceStyle`).
        let window: UIWindow
        private let controller: UIViewController

        /// `scene` puts the window on the test host's screen, for views that need a real window (a navigation
        /// stack's push and pop transitions); it then covers the app's own window.
        ///
        /// `safeAreaInsets` (with `scene`) models another phone's screen insets, such as an iPhone SE's 20 pt status
        /// bar and no home indicator, on the test host's iPhone 17 Pro, whose 62 pt top inset a window takes
        /// wherever it sits: once the window has its own insets, the hosted view gets the difference as
        /// additional safe area (negative where the host's are larger). `safeAreaInsets` (the property) reads
        /// the result back.
        init<Content: View>(
            _ view: Content,
            size: CGSize = CGSize(width: 390, height: 1600),
            settle: TimeInterval = 0.05,
            scene: UIWindowScene? = nil,
            safeAreaInsets modelled: UIEdgeInsets? = nil
        ) {
            XCTAssertNotNil(AccessibilityTreeText.setAutomationEnabled, "could not turn on the accessibility tree")
            AccessibilityTreeText.setAutomationEnabled?(1)
            controller = UIHostingController(rootView: view)
            if let scene {
                window = UIWindow(windowScene: scene)
                window.frame = CGRect(origin: .zero, size: size)
                window.windowLevel = .normal + 1
            } else {
                XCTAssertNil(modelled, "modelling a phone's insets needs the host's scene")
                // A window on no scene, so the view gets no safe area. UIKit makes windows from a scene
                // (`init(frame:)` is deprecated), so take the host's and leave it.
                guard let hostScene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
                    preconditionFailure("unit tests run in the app host, which has a window scene")
                }
                window = UIWindow(windowScene: hostScene)
                window.windowScene = nil
                window.frame = CGRect(origin: .zero, size: size)
            }
            window.rootViewController = controller
            window.makeKeyAndVisible()
            if let modelled {
                // The window takes the host screen's insets a run loop turn after it shows.
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                let own = window.safeAreaInsets
                controller.additionalSafeAreaInsets = UIEdgeInsets(
                    top: modelled.top - own.top,
                    left: modelled.left - own.left,
                    bottom: modelled.bottom - own.bottom,
                    right: modelled.right - own.right
                )
            }
            controller.view.frame = window.bounds
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
            // One run loop turn lets SwiftUI finish its first update.
            run(settle)
        }

        /// The hosted view's safe area: the window's own, plus what `safeAreaInsets` added.
        var safeAreaInsets: UIEdgeInsets {
            controller.view.safeAreaInsets
        }

        /// Lets the hosted view run for `interval` (its tasks, animations and updates), then lays it out.
        func run(_ interval: TimeInterval) {
            RunLoop.current.run(until: Date().addingTimeInterval(interval))
            controller.view.layoutIfNeeded()
        }

        /// Runs until `condition` holds, for at most `timeout` seconds, and returns whether it did. For a result
        /// that arrives after an animation or a refresh, which take longer on a busy machine (Xcode Cloud's
        /// virtual Mac, 2026-11-02). A check that something does *not* happen keeps a fixed `run(_:)`.
        @discardableResult
        func run(until condition: () -> Bool, timeout: TimeInterval = 6) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while !condition() {
                guard Date() < deadline else { return false }
                run(0.1)
            }
            return true
        }

        /// Whether a push or a pop is still animating in a navigation stack in the hosted view.
        var isNavigating: Bool {
            AccessibilityTreeText.navigationControllers(in: controller).contains { $0.transitionCoordinator != nil }
        }

        /// `run(until:)` that also waits for every push and pop to finish. Mid-animation the old page can still
        /// answer, and a path change made then can be dropped (Xcode Cloud, 2026-11-02).
        @discardableResult
        func run(untilSettled condition: () -> Bool = { true }, timeout: TimeInterval = 8) -> Bool {
            run(until: { !isNavigating && condition() }, timeout: timeout)
        }

        /// The strings in the hosted view's accessibility tree now, in tree order, each once.
        func strings() -> [String] {
            strings(under: controller.view)
        }

        /// The strings in the accessibility tree under `object`, a part of the hosted view (a navigation bar,
        /// say), in tree order, each once.
        func strings(under object: NSObject) -> [String] {
            var found: [String] = []
            var seenObjects = Set<ObjectIdentifier>()
            AccessibilityTreeText.collect(object, into: &found, seen: &seenObjects, depth: 0)
            var seenStrings = Set<String>()
            return found.filter { seenStrings.insert($0).inserted }
        }

        /// `strings()` joined with " | ".
        func text() -> String {
            strings().joined(separator: " | ")
        }

        /// The accessibility elements in the window, in tree order: what VoiceOver stops on, with its frame.
        func elements() -> [Element] {
            AccessibilityTreeText.elements(under: window)
        }

        /// Every accessibility identifier in the window, on elements and on containers.
        func identifiers() -> Set<String> {
            AccessibilityTreeText.identifiers(under: window)
        }

        /// Performs the default action of the first element labelled exactly `label` (`accessibilityActivate`),
        /// then runs the view for `settle`. False when no such element is found or it did not activate.
        @discardableResult
        func activate(_ label: String, settle: TimeInterval = 0.2) -> Bool {
            var seen = Set<ObjectIdentifier>()
            guard let element = AccessibilityTreeText.element(labelled: label, in: controller.view, seen: &seen, depth: 0) else {
                return false
            }
            let activated = element.accessibilityActivate()
            run(settle)
            return activated
        }

        /// The accessibility traits of the first element labelled exactly `label`, or nil when there is none
        /// (for the header and selected traits).
        func traits(of label: String) -> UIAccessibilityTraits? {
            var seen = Set<ObjectIdentifier>()
            return AccessibilityTreeText.element(labelled: label, in: controller.view, seen: &seen, depth: 0)?.accessibilityTraits
        }

        /// The accessibility hint of the first element labelled exactly `label`: nil when there is no such element
        /// or it has no hint (an empty hint counts as none).
        func hint(of label: String) -> String? {
            var seen = Set<ObjectIdentifier>()
            guard let hint = AccessibilityTreeText.element(labelled: label, in: controller.view, seen: &seen, depth: 0)?
                .accessibilityHint, !hint.isEmpty else { return nil }
            return hint
        }

        /// The Voice Control names (`accessibilityUserInputLabels`) of the first element labelled exactly `label`:
        /// nil when there is no such element, else what the element offers (iOS may fall back to the label).
        func inputLabels(of label: String) -> [String]? {
            var seen = Set<ObjectIdentifier>()
            guard let element = AccessibilityTreeText.element(labelled: label, in: controller.view, seen: &seen, depth: 0) else {
                return nil
            }
            return element.accessibilityUserInputLabels ?? []
        }

        /// The accessibility frame (screen coordinates) of the first element labelled exactly `label`, or nil when
        /// there is none: where VoiceOver draws its cursor, the button's own frame for a button.
        func frame(of label: String) -> CGRect? {
            var seen = Set<ObjectIdentifier>()
            return AccessibilityTreeText.element(labelled: label, in: controller.view, seen: &seen, depth: 0)?.accessibilityFrame
        }

        /// The accessibility frame (screen coordinates) of the first element whose identifier is exactly
        /// `identifier`, or nil when there is none.
        func frame(ofIdentifier identifier: String) -> CGRect? {
            var seen = Set<ObjectIdentifier>()
            return AccessibilityTreeText.element(identified: identifier, in: controller.view, seen: &seen, depth: 0)?.accessibilityFrame
        }

        /// The first navigation controller in the hosted view (a `NavigationStack`'s), for its bar, its back item
        /// and the pages pushed on it; nil when there is none.
        var navigationController: UINavigationController? {
            AccessibilityTreeText.navigationController(in: controller)
        }

        /// The accessibility identifier of the first element labelled exactly `label`, or nil.
        func identifier(of label: String) -> String? {
            var seen = Set<ObjectIdentifier>()
            guard let element = AccessibilityTreeText.element(labelled: label, in: controller.view, seen: &seen, depth: 0),
                  element.responds(to: NSSelectorFromString("accessibilityIdentifier")) else { return nil }
            return element.value(forKey: "accessibilityIdentifier") as? String
        }

        /// The accessibility label of the first element whose identifier is exactly `identifier`, or nil when
        /// there is none (the smoke UI tests find elements by these ids).
        func label(ofIdentifier identifier: String) -> String? {
            var seen = Set<ObjectIdentifier>()
            return AccessibilityTreeText.element(identified: identifier, in: controller.view, seen: &seen, depth: 0)?.accessibilityLabel
        }

        /// The accessibility value of the first element whose identifier is exactly `identifier`, or nil when
        /// there is none or it has no value.
        func value(ofIdentifier identifier: String) -> String? {
            var seen = Set<ObjectIdentifier>()
            return AccessibilityTreeText.element(identified: identifier, in: controller.view, seen: &seen, depth: 0)?.accessibilityValue
        }

        /// The names of the custom actions (VoiceOver's Actions rotor) of the first element whose identifier is
        /// exactly `identifier`; empty when there is none.
        func actionNames(ofIdentifier identifier: String) -> [String] {
            var seen = Set<ObjectIdentifier>()
            let element = AccessibilityTreeText.element(identified: identifier, in: controller.view, seen: &seen, depth: 0)
            return element?.accessibilityCustomActions?.map(\.name) ?? []
        }

        /// Performs the custom action `name` of the first element whose identifier is exactly `identifier`, as
        /// VoiceOver's Actions rotor does, then runs the view for `settle`. False when there is no such action.
        @discardableResult
        func performAction(named name: String, ofIdentifier identifier: String, settle: TimeInterval = 0.2) -> Bool {
            var seen = Set<ObjectIdentifier>()
            guard let element = AccessibilityTreeText.element(identified: identifier, in: controller.view, seen: &seen, depth: 0),
                  let action = element.accessibilityCustomActions?.first(where: { $0.name == name }) else { return false }
            var performed = false
            if let handler = action.actionHandler {
                performed = handler(action)
            } else if let target = action.target as? NSObject {
                _ = target.perform(action.selector, with: action)
                performed = true
            }
            run(settle)
            return performed
        }

        /// Takes the window down and turns automation off.
        func close() {
            window.isHidden = true
            window.rootViewController = nil
            AccessibilityTreeText.setAutomationEnabled?(0)
        }
    }

    /// An accessibility element of a hosted view: its label (empty when it has none), its identifier (empty
    /// when it has none) and its frame on the screen.
    struct Element {
        let label: String
        let identifier: String
        let frame: CGRect
    }

    /// The accessibility elements under `root`, in tree order.
    static func elements(under root: NSObject) -> [Element] {
        var found: [Element] = []
        walk(root) { object in
            guard object.isAccessibilityElement else { return }
            found.append(Element(label: object.accessibilityLabel ?? "", identifier: identifier(of: object), frame: object.accessibilityFrame))
        }
        return found
    }

    /// Every accessibility identifier under `root`, on elements and on containers.
    static func identifiers(under root: NSObject) -> Set<String> {
        var found = Set<String>()
        walk(root) { object in
            let id = identifier(of: object)
            if !id.isEmpty { found.insert(id) }
        }
        return found
    }

    private static func identifier(of object: NSObject) -> String {
        guard object.responds(to: NSSelectorFromString("accessibilityIdentifier")) else { return "" }
        return (object.value(forKey: "accessibilityIdentifier") as? String) ?? ""
    }

    /// Visits `root` and everything under it once, in tree order, to 80 levels (a whole window, with its
    /// navigation stack and a list, goes deeper than a hosted view).
    private static func walk(_ root: NSObject, visit: (NSObject) -> Void) {
        var seen = Set<ObjectIdentifier>()
        func step(_ object: NSObject, depth: Int) {
            guard depth < 80, seen.insert(ObjectIdentifier(object)).inserted else { return }
            visit(object)
            for child in children(of: object) {
                step(child, depth: depth + 1)
            }
        }
        step(root, depth: 0)
    }

    /// The accessibility element under `object` (itself included) labelled exactly `label`, in tree order.
    private static func element(labelled label: String, in object: NSObject, seen: inout Set<ObjectIdentifier>, depth: Int) -> NSObject? {
        guard depth < 60, seen.insert(ObjectIdentifier(object)).inserted else { return nil }
        if object.accessibilityLabel == label { return object }
        for child in children(of: object) {
            if let found = element(labelled: label, in: child, seen: &seen, depth: depth + 1) { return found }
        }
        return nil
    }

    /// The accessibility element under `object` (itself included) whose identifier is exactly `identifier`.
    private static func element(identified identifier: String, in object: NSObject, seen: inout Set<ObjectIdentifier>, depth: Int) -> NSObject? {
        guard depth < 60, seen.insert(ObjectIdentifier(object)).inserted else { return nil }
        if object.responds(to: NSSelectorFromString("accessibilityIdentifier")),
           object.value(forKey: "accessibilityIdentifier") as? String == identifier {
            return object
        }
        for child in children(of: object) {
            if let found = element(identified: identifier, in: child, seen: &seen, depth: depth + 1) { return found }
        }
        return nil
    }

    /// The first navigation controller at or under `controller`.
    private static func navigationController(in controller: UIViewController) -> UINavigationController? {
        if let navigation = controller as? UINavigationController { return navigation }
        for child in controller.children {
            if let navigation = navigationController(in: child) { return navigation }
        }
        return nil
    }

    /// Every navigation controller at or under `controller`.
    private static func navigationControllers(in controller: UIViewController) -> [UINavigationController] {
        [controller as? UINavigationController].compactMap { $0 } + controller.children.flatMap { navigationControllers(in: $0) }
    }

    /// `object`'s accessibility elements, then its subviews.
    private static func children(of object: NSObject) -> [NSObject] {
        var out: [NSObject] = []
        if let elements = object.accessibilityElements {
            out += elements.compactMap { $0 as? NSObject }
        } else {
            let count = object.accessibilityElementCount()
            if count != NSNotFound, count > 0 {
                out += (0..<count).compactMap { object.accessibilityElement(at: $0) as? NSObject }
            }
        }
        if let view = object as? UIView {
            out += view.subviews
        }
        return out
    }

    private static func collect(_ object: NSObject, into found: inout [String], seen: inout Set<ObjectIdentifier>, depth: Int) {
        guard depth < 60, seen.insert(ObjectIdentifier(object)).inserted else { return }
        for value in [object.accessibilityLabel, object.accessibilityValue, object.accessibilityHint] {
            if let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                found.append(value)
            }
        }
        for child in children(of: object) {
            collect(child, into: &found, seen: &seen, depth: depth + 1)
        }
    }
}
