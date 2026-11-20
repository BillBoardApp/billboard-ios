import SwiftUI
import UIKit
import XCTest
@testable import Billboard

/// A form's error or status line is said to VoiceOver when it appears and whenever it changes (UX-45). VoiceOver's
/// focus stays on the button that was tapped, so a line that appeared silently ("Incorrect email or password." above
/// Sign in) was never heard, and a VoiceOver user could think the app had hung. A field's own hint ("Passwords don't
/// match.") stays quiet: VoiceOver reads it with the field. Each form is hosted with a recorder in place of
/// VoiceOver (`\.announceToVoiceOver`).
@MainActor
final class FormErrorAnnouncementTests: XCTestCase {
    // MARK: - The helper

    /// The app says the line as a queued announcement, so a button changing its label ("Signing in…" back to "Sign
    /// in") is not cut off, as the bill page queues its own (spec 3.10.3).
    func testTheLineIsAQueuedAnnouncement() {
        let text = VoiceOverAnnouncement.queued(AuthErrorMessages.wrongCredentials)
        XCTAssertEqual(text.string, AuthErrorMessages.wrongCredentials)
        XCTAssertEqual(text.attribute(.accessibilitySpeechQueueAnnouncement, at: 0, effectiveRange: nil) as? Bool, true)
    }

    func testALineIsSaidWhenItAppearsAndWhenItsWordsChange() {
        let spoken = SpokenLines()
        let line = FormLine()
        let host = Self.host(FormLine.Screen(line: line), spoken: spoken)
        defer { host.close() }
        XCTAssertEqual(spoken.lines, [], "nothing to say yet")

        line.message = AuthErrorMessages.wrongCredentials
        host.run(0.1)
        XCTAssertEqual(spoken.lines, [AuthErrorMessages.wrongCredentials])

        line.message = AuthErrorMessages.network
        host.run(0.1)
        XCTAssertEqual(spoken.lines, [AuthErrorMessages.wrongCredentials, AuthErrorMessages.network])

        // A form clears its line when it tries again; the same error coming back is said again.
        line.message = nil
        host.run(0.1)
        line.message = AuthErrorMessages.network
        host.run(0.1)
        XCTAssertEqual(spoken.lines, [AuthErrorMessages.wrongCredentials, AuthErrorMessages.network, AuthErrorMessages.network])
    }

    /// Sign-in keeps its line up while the next try runs (the error is the auth state). Nothing is said during the
    /// try; when it ends the line is said again, even with the same words.
    func testALineKeptUpWhileTheFormTriesAgainIsSaidWhenTheTryEnds() {
        let spoken = SpokenLines()
        let line = FormLine()
        line.message = AuthErrorMessages.wrongCredentials
        let host = Self.host(FormLine.Screen(line: line), spoken: spoken)
        defer { host.close() }
        XCTAssertEqual(spoken.lines, [AuthErrorMessages.wrongCredentials])

        line.isBusy = true
        host.run(0.1)
        XCTAssertEqual(spoken.lines, [AuthErrorMessages.wrongCredentials], "nothing while the try runs")
        line.isBusy = false
        host.run(0.1)
        XCTAssertEqual(spoken.lines, [AuthErrorMessages.wrongCredentials, AuthErrorMessages.wrongCredentials])

        line.isBusy = true
        host.run(0.1)
        line.message = AuthErrorMessages.network
        line.isBusy = false
        host.run(0.1)
        XCTAssertEqual(
            spoken.lines,
            [AuthErrorMessages.wrongCredentials, AuthErrorMessages.wrongCredentials, AuthErrorMessages.network],
            "a new error once"
        )
    }

    // MARK: - Each form

    func testSignInSaysItsError() {
        let spoken = SpokenLines()
        let auth = AuthManager(status: .error(AuthErrorMessages.wrongCredentials))
        let host = Self.host(NavigationStack { LoginView() }.environmentObject(auth), spoken: spoken)
        defer { host.close() }
        XCTAssertEqual(spoken.lines, [AuthErrorMessages.wrongCredentials])

        // The next sign-in fails the same way: "Signing in…", then the same line, said again.
        auth.isBusy = true
        host.run(0.1)
        auth.isBusy = false
        host.run(0.1)
        XCTAssertEqual(spoken.lines, [AuthErrorMessages.wrongCredentials, AuthErrorMessages.wrongCredentials])
    }

    /// Back on Sign in from Forgot password, the line still there is not said again.
    func testSignInDoesNotRepeatItsErrorWhenShownAgain() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let spoken = SpokenLines()
        let auth = AuthManager(status: .error(AuthErrorMessages.wrongCredentials))
        let host = AccessibilityTreeText.Host(
            NavigationStack { LoginView() }
                .environmentObject(auth)
                .environment(\.announceToVoiceOver, spoken.announce),
            size: CGSize(width: 390, height: 844),
            settle: 0.3,
            scene: scene
        )
        defer { host.close() }
        let navigation = try XCTUnwrap(host.navigationController, "the stack's navigation controller")
        XCTAssertEqual(spoken.lines, [AuthErrorMessages.wrongCredentials])

        XCTAssertTrue(host.activate("Forgot password?"), host.text())
        XCTAssertTrue(host.run(untilSettled: { navigation.viewControllers.count == 2 }), "Forgot password pushed")
        navigation.popViewController(animated: false)
        XCTAssertTrue(host.run(untilSettled: { navigation.viewControllers.count == 1 }), "back on Sign in")
        host.run(0.3)
        XCTAssertEqual(spoken.lines, [AuthErrorMessages.wrongCredentials])
    }

    /// Create account says its error, not the field's "Passwords don't match.", which shows too.
    func testCreateAccountSaysItsErrorButNotTheFieldHint() {
        let spoken = SpokenLines()
        let view = NavigationStack {
            CreateAccountView(
                email: "voter@example.com",
                password: "Secret-123",
                confirmPassword: "Secret-124",
                isAdultConfirmed: true,
                errorMessage: AuthErrorMessages.signUpUnavailable
            )
        }
        let host = Self.host(Self.signedOut(view), spoken: spoken)
        defer { host.close() }
        XCTAssertTrue(host.strings().contains(PasswordMismatchHint.message), host.text())
        XCTAssertEqual(spoken.lines, [AuthErrorMessages.signUpUnavailable])
    }

    /// The code step says its error, and scrolls down to it: it sits under Resend code and Back to sign in, below the
    /// fold at large text sizes. Modelled on an iPhone SE (20 pt status bar) and a 402 x 874 phone.
    func testTheCodeStepSaysItsErrorAndScrollsItIntoView() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let phones: [(name: String, size: CGSize, insets: UIEdgeInsets)] = [
            ("iPhone SE", CGSize(width: 375, height: 667), UIEdgeInsets(top: 20, left: 0, bottom: 0, right: 0)),
            ("402 x 874", CGSize(width: 402, height: 874), UIEdgeInsets(top: 62, left: 0, bottom: 34, right: 0))
        ]
        for phone in phones {
            let spoken = SpokenLines()
            let view = NavigationStack {
                CreateAccountView(
                    step: .confirmCode(details: nil),
                    origin: .signIn,
                    email: "voter@example.com",
                    password: "Secret-123",
                    code: "123456",
                    errorMessage: AuthErrorMessages.codeMismatch
                )
            }
            .environment(\.dynamicTypeSize, .accessibility3)
            let host = AccessibilityTreeText.Host(
                Self.signedOut(view).environment(\.announceToVoiceOver, spoken.announce),
                size: phone.size,
                settle: 0.6,
                scene: scene,
                safeAreaInsets: phone.insets
            )
            defer { host.close() }
            XCTAssertEqual(spoken.lines, [AuthErrorMessages.codeMismatch], phone.name)

            let line = try XCTUnwrap(host.frame(ofIdentifier: "signup.error"), "\(phone.name): \(host.text())")
            XCTAssertGreaterThanOrEqual(line.minY, phone.insets.top, "\(phone.name): \(line)")
            XCTAssertLessThanOrEqual(line.maxY, phone.size.height - phone.insets.bottom + 0.5, "\(phone.name): \(line)")
        }
    }

    /// Reset password says its error, not the field's "Passwords don't match.".
    func testResetPasswordSaysItsError() {
        let spoken = SpokenLines()
        let view = NavigationStack {
            ForgotPasswordView(
                step: .confirm(details: nil),
                email: "voter@example.com",
                code: "123456",
                newPassword: "Secret-123",
                confirmNewPassword: "Secret-124",
                errorMessage: AuthErrorMessages.codeExpired
            )
        }
        let host = Self.host(Self.signedOut(view), spoken: spoken)
        defer { host.close() }
        XCTAssertTrue(host.strings().contains(PasswordMismatchHint.message), host.text())
        XCTAssertEqual(spoken.lines, [AuthErrorMessages.codeExpired])
    }

    func testSetANewPasswordSaysItsError() {
        let spoken = SpokenLines()
        let auth = AuthManager(status: .error(AuthErrorMessages.passwordPolicy))
        let host = Self.host(NavigationStack { NewPasswordRequiredView() }.environmentObject(auth), spoken: spoken)
        defer { host.close() }
        XCTAssertEqual(spoken.lines, [AuthErrorMessages.passwordPolicy])

        auth.isBusy = true
        host.run(0.1)
        auth.isBusy = false
        host.run(0.1)
        XCTAssertEqual(spoken.lines, [AuthErrorMessages.passwordPolicy, AuthErrorMessages.passwordPolicy], "said again after the next try")
    }

    func testTheAgeGateSaysItsError() {
        let spoken = SpokenLines()
        let host = Self.host(Self.signedOut(AdultAttestationGateView(errorMessage: AuthErrorMessages.network)), spoken: spoken)
        defer { host.close() }
        XCTAssertEqual(spoken.lines, [AuthErrorMessages.network])
    }

    func testTopicsSayTheirSaveError() {
        let spoken = SpokenLines()
        let message = "Couldn't save your topics. Try again."
        let view = NavigationStack {
            TopicPickerView(context: .profile, errorMessage: message) {}
        }
        let host = Self.host(Self.signedOut(view), spoken: spoken)
        defer { host.close() }
        XCTAssertEqual(spoken.lines, [message])
    }

    func testNotificationsSayTheirSaveError() {
        let spoken = SpokenLines()
        let view = NotificationsSectionContent(
            model: NotificationsSectionModel(permission: .authorized, settings: .allEnabled),
            isWeeklyBriefOn: true,
            errorMessage: NotificationSettingsStore.saveFailedMessage,
            onSetMaster: { _ in },
            onSetKind: { _, _ in },
            onSetWeeklyBrief: { _ in },
            onRequestPermission: {},
            onOpenSettings: {}
        )
        let host = Self.host(view, spoken: spoken)
        defer { host.close() }
        XCTAssertEqual(spoken.lines, [NotificationSettingsStore.saveFailedMessage])
    }

    /// Delete account says its progress lines and its error, from the list itself: a list makes its rows only as
    /// they scroll into view.
    func testDeleteAccountSaysItsProgressAndItsError() {
        for (status, error) in [("Finishing up…", nil), (nil, AuthErrorMessages.network)] as [(String?, String?)] {
            let spoken = SpokenLines()
            let view = NavigationStack {
                DeleteAccountDataView(statusMessage: status, errorMessage: error)
            }
            let host = Self.host(Self.signedOut(view), spoken: spoken)
            defer { host.close() }
            XCTAssertEqual(spoken.lines, [status ?? error].compactMap { $0 })
        }
    }

    // MARK: - Helpers

    private static func host<Content: View>(_ view: Content, spoken: SpokenLines) -> AccessibilityTreeText.Host {
        AccessibilityTreeText.Host(
            view.environment(\.announceToVoiceOver, spoken.announce),
            size: CGSize(width: 390, height: 1600),
            settle: 0.3
        )
    }

    /// `view` with a signed-out auth manager and an empty user store, so it makes no network call.
    private static func signedOut<Content: View>(_ view: Content) -> some View {
        let auth = AuthManager()
        auth.cancelSignIn()
        let userStore = UserStore(preferencesService: StaticPreferencesService(items: []), congressService: FakeCongressService())
        return view
            .environmentObject(auth)
            .environmentObject(userStore)
    }
}

/// What VoiceOver was told, in order.
@MainActor
private final class SpokenLines {
    private(set) var lines: [String] = []

    var announce: @MainActor @Sendable (String) -> Void {
        { [self] line in lines.append(line) }
    }
}

/// A form's error line, driven from the test: the words, and whether the form is trying again.
@MainActor
private final class FormLine: ObservableObject {
    @Published var message: String?
    @Published var isBusy = false

    struct Screen: View {
        @ObservedObject var line: FormLine

        var body: some View {
            VStack {
                Button("Sign in") {}
                if let message = line.message {
                    RecordErrorText(message, announces: !line.isBusy)
                }
            }
        }
    }
}
