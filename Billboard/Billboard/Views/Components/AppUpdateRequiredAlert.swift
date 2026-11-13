import Combine
import SwiftUI

// The blocking update prompt (spec D 2.8.1 and 2.8.4, C3 3.8). The server asks for it only under
// enforce: a 426 `APP_UPDATE_REQUIRED` on any request (posted by `APIServiceSupport`) or a sign-up refused
// with `APP_UPDATE_REQUIRED` (posted by the auth error mapping). `RootView` applies `.appUpdateRequiredAlert()` once.

extension Notification.Name {
    /// Posted at most once per launch, through `AppUpdateRequiredSignal`, when the server refuses this build.
    nonisolated static let billboardAppUpdateRequired = Notification.Name("BillBoard.appUpdateRequired")
}

/// The prompt's copy and link.
nonisolated enum AppUpdatePrompt {
    static let title = "Update Billboard"
    static let message = "This version of Billboard can't vote or create accounts any more. Update to continue."
    static let openAppStoreTitle = "Open App Store"
    /// Billboard on the App Store (App Store ID 6757132060).
    static let appStoreURL = URL(string: "https://apps.apple.com/app/id6757132060")
}

/// Posts `.billboardAppUpdateRequired` once per launch, however many requests are refused.
final class AppUpdateRequiredSignal {
    static let shared = AppUpdateRequiredSignal()

    private let center: NotificationCenter
    private(set) var hasPosted = false

    init(center: NotificationCenter = .default) {
        self.center = center
    }

    /// Posts the notification the first time; returns false (and posts nothing) after that.
    @discardableResult
    func post() -> Bool {
        guard !hasPosted else { return false }
        hasPosted = true
        center.post(name: .billboardAppUpdateRequired, object: nil)
        return true
    }
}

/// When the alert shows. Once required, it stays required for the launch: it comes back after it is closed and
/// whenever the app becomes active again, so the app cannot be used past it.
nonisolated struct AppUpdateRequiredAlertState: Equatable {
    private(set) var isRequired = false
    var isPresented = false

    /// The server refused this build.
    mutating func require() {
        isRequired = true
        isPresented = true
    }

    /// The app became active (for example back from the App Store without updating).
    mutating func sceneBecameActive() {
        if isRequired { isPresented = true }
    }

    /// True once the alert has closed while still required: show it again.
    var needsReshow: Bool {
        isRequired && !isPresented
    }
}

/// Shows the blocking "Update Billboard" alert once `.billboardAppUpdateRequired` is posted.
struct AppUpdateRequiredAlertModifier: ViewModifier {
    var center: NotificationCenter = .default

    @State private var state = AppUpdateRequiredAlertState()
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .onReceive(center.publisher(for: .billboardAppUpdateRequired).receive(on: DispatchQueue.main)) { _ in
                state.require()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { state.sceneBecameActive() }
            }
            .task(id: state.needsReshow) {
                // An alert closes on any button; bring it back while the update is still required.
                guard state.needsReshow else { return }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if state.needsReshow { state.isPresented = true }
            }
            .alert(AppUpdatePrompt.title, isPresented: $state.isPresented) {
                Button(AppUpdatePrompt.openAppStoreTitle) {
                    if let url = AppUpdatePrompt.appStoreURL { openURL(url) }
                }
            } message: {
                Text(AppUpdatePrompt.message)
            }
    }
}

extension View {
    /// The blocking update alert. Apply once, at the root of the app (`RootView`).
    func appUpdateRequiredAlert() -> some View {
        modifier(AppUpdateRequiredAlertModifier())
    }
}
