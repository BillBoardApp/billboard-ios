//
//  BillBoardApp.swift
//  Billboard
//
//  Part of the Billboard project.
//

import SwiftUI
import Combine
import os

@main
struct BillBoardApp: App {
    @UIApplicationDelegateAdaptor(PushNotificationsAppDelegate.self) private var pushDelegate
    @StateObject private var auth = AuthManager()
    @StateObject private var userStore = UserStore()
    /// App Settings > Appearance. System by default; the app never forces an appearance.
    @AppStorage(AppearancePreference.storageKey) private var appearance: AppearancePreference = .system
    /// Set when Amplify could not be configured. Every auth and API call would fail, so the app shows the
    /// startup failure screen instead of the normal UI, for the rest of the launch: with amplify-swift 2.x a
    /// second configure in the same launch cannot succeed, so the screen has no Try again (project decision of
    /// 2026-10-29).
    private let startupFailed: Bool

    init() {
        MetricDiagnosticsSubscriber.shared.register()
        AppLaunchOptions.prepareAppForLaunch()
        // 1.2 reads its own manifest cache keys (INT-11), so the copy 1.1 left is never read. Delete it on a
        // utility task: the launch does not wait for the file system.
        BillsManifestCache().discardEarlierCachesInBackground()

        startupFailed = !StartupConfiguration.attempt { try AmplifyService.configureIfNeeded() }
        Self.configureUIKitAppearance()
    }

    /// Bar and control colours for UIKit-backed views (Civic Record spec 2.4). The navigation bar is the
    /// system's glass bar: pushed screens and sheets use it as it is, with an `ink` title and `ink` bar
    /// buttons, and the system back button. The tab roots and the screens before the tabs draw their navy
    /// bar themselves (`navyNavigationBar()`, spec 3.21), so nothing here forces navy or a dark style.
    private static func configureUIKitAppearance() {
        let nav = UINavigationBarAppearance()
        nav.configureWithDefaultBackground()
        nav.titleTextAttributes = [
            .foregroundColor: BillboardUIColors.primaryText,
            // The `navTitle` role: fixed 18 pt condensed bold, like the system's inline title. An inline
            // bar has a fixed height, so the title does not scale; long-pressing the bar shows it in the
            // Large Content Viewer.
            .font: UIFont.systemFont(ofSize: TextRole.navTitle.size, weight: .bold, width: .condensed)
        ]
        nav.largeTitleTextAttributes = [.foregroundColor: BillboardUIColors.primaryText]
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav
        // Links and buttons are navy ink (project decision): the back chevron and the bar buttons.
        UINavigationBar.appearance().tintColor = BillboardUIColors.interactive

        // Segmented pickers follow the page surfaces in both appearances: a `well` track, a `sheet`
        // selection, `ink2` labels and an `ink` selected label.
        let segmented = UISegmentedControl.appearance()
        segmented.backgroundColor = BillboardUIColors.secondaryBackground
        segmented.selectedSegmentTintColor = BillboardUIColors.cardBackground
        let segmentFont = UIFont.systemFont(ofSize: 14, weight: .semibold)
        segmented.setTitleTextAttributes([.foregroundColor: BillboardUIColors.secondaryText, .font: segmentFont], for: .normal)
        segmented.setTitleTextAttributes([.foregroundColor: BillboardUIColors.primaryText, .font: segmentFont], for: .selected)

        // Hide scroll indicators app-wide to avoid stray overlay rails from
        // SwiftUI/UIKit-backed scroll containers.
        UIScrollView.appearance().showsVerticalScrollIndicator = false
        UIScrollView.appearance().showsHorizontalScrollIndicator = false
    }

    var body: some Scene {
        WindowGroup {
            if startupFailed {
                StartupFailureView()
            } else {
                appRoot
            }
        }
    }

    private static func applyWindowAppearance(_ preference: AppearancePreference) {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.overrideUserInterfaceStyle = preference.userInterfaceStyle
            }
        }
    }

    private var appRoot: some View {
        RootView()
            .environmentObject(auth)
            .environmentObject(userStore)
            // System follows the iPhone; Light or Dark is the user's choice in App Settings, set on the
            // windows. Not with preferredColorScheme: it also sets the status bar from the root, so a
            // Light choice drew dark status-bar icons on the navy bars (spec 3.21 wants white there,
            // which the bars' dark toolbar scheme gives). The window style also takes effect at once
            // when switching back to System, which preferredColorScheme(nil) alone did not.
            .onChange(of: appearance, initial: true) { _, preference in
                Self.applyWindowAppearance(preference)
            }
            .onReceive(NotificationCenter.default.publisher(for: .billboardShouldPromptPushPermission)) { _ in
                pushDelegate.requestAuthorizationAndRegisterIfPossible()
            }
            .onReceive(NotificationCenter.default.publisher(for: .billboardShouldSyncPushRegistration)) { _ in
                pushDelegate.syncRemoteNotificationRegistrationIfAuthorized()
            }
            .onOpenURL { url in
                guard case .bill(let guid) = AppDeepLink(url: url) else {
                    AppLog.push.info("Ignored unsupported deep link")
                    return
                }
                PendingAppDeepLink.saveBillGuid(guid)
                NotificationCenter.default.post(
                    name: .billboardDidReceiveBillDeepLink,
                    object: nil,
                    userInfo: ["guid": guid]
                )
            }
    }
}

/// Configuring sign-in and the API clients at launch.
enum StartupConfiguration {
    /// Runs `configure`; false when it threw. The error is logged and never shown: the startup failure screen
    /// says what to do in plain words (feature review N10).
    static func attempt(_ configure: () throws -> Void) -> Bool {
        do {
            try configure()
            return true
        } catch {
            AppLog.auth.fault("Amplify configuration failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }
}

/// Blocking screen shown when the app cannot configure its sign-in and API
/// clients (for example a missing or corrupt `amplifyconfiguration.json`). Civic Record spec 4.3: the
/// wordmark on navy, the title in white and the explanation in white at 85%, ending on the contact address as
/// a mail link. No Try again (project decision of 2026-10-29): with amplify-swift 2.x a second configure in the
/// same launch cannot succeed, so the plain message (update, reinstall or email) is the whole screen. The error
/// itself goes to the log only, never on screen ("AmplifyError: …", feature review N10).
struct StartupFailureView: View {

    /// The explanation, ending on the one contact address (UX-39) in place of "contact support".
    static let message = "Something is wrong with this copy of the app. Update Billboard from the App Store or reinstall it. If that doesn't help, email \(ContactUs.address)."

    /// `message` with the address as an underlined mailto link.
    static var attributedMessage: AttributedString {
        var text = AttributedString(message)
        if let range = text.range(of: ContactUs.address) {
            text[range].link = ContactUs.mailURL
            text[range].underlineStyle = .single
        }
        return text
    }

    var body: some View {
        ZStack {
            BillboardColors.navy
                .ignoresSafeArea()

            // Centred as it always was; at the largest text sizes, where the words no longer fit on a small
            // phone, the screen scrolls instead of cutting off the address.
            ViewThatFits(in: .vertical) {
                content
                ScrollView {
                    content
                        .padding(.vertical, 24)
                }
            }
        }
    }

    private var content: some View {
        VStack(spacing: 16) {
            Wordmark(size: .compact)

            Text("Billboard can't start")
                .textRole(.title)
                .foregroundStyle(BillboardColors.textOnNavy)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)

            // The address is a link to a new email (UX-39), underlined in the text colour: ink would vanish on navy.
            Text(Self.attributedMessage)
                .textRole(.body)
                .foregroundStyle(BillboardColors.textOnNavy.opacity(0.85))
                .tint(BillboardColors.textOnNavy)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("startupFailure.message")
        }
        .padding(.horizontal, 32)
    }
}
