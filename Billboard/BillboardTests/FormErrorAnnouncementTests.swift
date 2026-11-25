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

    /// Under a pushed screen, Sign in's line still follows the shared sign-in state: Create account's own sign-in into
    /// the new account toggles it, and that screen says its own error. The hidden line stays quiet, and is not said
    /// again when Sign in shows again.
    func testSignInStaysQuietUnderAPushedScreen() throws {
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
        // A sign-in started from the pushed screen ends with the same error.
        auth.isBusy = true
        host.run(0.2)
        auth.isBusy = false
        host.run(0.3)
        XCTAssertEqual(spoken.lines, [AuthErrorMessages.wrongCredentials], "the hidden line says nothing")

        navigation.popViewController(animated: false)
        XCTAssertTrue(host.run(untilSettled: { navigation.viewControllers.count == 1 }), "back on Sign in")
        host.run(0.3)
        XCTAssertEqual(spoken.lines, [AuthErrorMessages.wrongCredentials], "nor once Sign in shows again")

        // Sign in's own next try is said again.
        auth.isBusy = true
        host.run(0.1)
        auth.isBusy = false
        host.run(0.1)
        XCTAssertEqual(spoken.lines, [AuthErrorMessages.wrongCredentials, AuthErrorMessages.wrongCredentials])
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

    // MARK: - Where do you vote? (UX-45a)

    // These tests are not async: a hosted screen needs the main run loop, which an async test holds.

    /// Find my district with an address the geocoder can't place: the line under the button is said once, queued
    /// after the button's label changes back, and said again when the next try fails the same way.
    func testWhereDoYouVoteSaysAnAddressNotFound() {
        let spoken = SpokenLines()
        let transport = RecordingTransport()
        let notFound = Data(#"{"verified":false}"#.utf8)
        transport.responses = [notFound, notFound]
        APIClient.$current.withValue(transport.client) {
            let host = Self.host(Self.signedOut(Self.whereDoYouVote()), spoken: spoken)
            defer { host.close() }
            XCTAssertEqual(spoken.lines, [], "nothing to say yet")

            XCTAssertTrue(host.activate("Find my district"), host.text())
            XCTAssertTrue(host.run(until: { host.label(ofIdentifier: "location.error") != nil }), host.text())
            host.run(0.3)
            XCTAssertEqual(host.label(ofIdentifier: "location.error"), LocationEditorView.addressNotFoundMessage)
            XCTAssertEqual(spoken.lines, [LocationEditorView.addressNotFoundMessage], "said once")

            XCTAssertTrue(host.activate("Find my district"), host.text())
            XCTAssertTrue(host.run(until: { transport.requests.count == 2 && host.label(ofIdentifier: "location.error") != nil }), host.text())
            host.run(0.3)
            XCTAssertEqual(spoken.lines, [LocationEditorView.addressNotFoundMessage, LocationEditorView.addressNotFoundMessage], "and again after the next try")
        }
    }

    /// A find that fails on the way (offline) says its line once.
    func testWhereDoYouVoteSaysAFailedSave() {
        let spoken = SpokenLines()
        let transport = RecordingTransport()
        transport.failure = { _ in URLError(.notConnectedToInternet) }
        APIClient.$current.withValue(transport.client) {
            let host = Self.host(Self.signedOut(Self.whereDoYouVote()), spoken: spoken)
            defer { host.close() }

            XCTAssertTrue(host.activate("Find my district"), host.text())
            XCTAssertTrue(host.run(until: { host.label(ofIdentifier: "location.error") != nil }), host.text())
            host.run(0.3)
            XCTAssertEqual(transport.requests.count, 1, "the find was sent")
            XCTAssertEqual(host.label(ofIdentifier: "location.error"), AuthErrorMessages.network)
            XCTAssertEqual(spoken.lines, [AuthErrorMessages.network], "said once")
        }
    }

    /// Choose your district, then Continue, with a save that fails at once: the line under Continue is said once,
    /// and said again when the next Continue fails the same way before the screen redraws (the line is cleared and
    /// shown again in one update, so only a new view says it again).
    func testWhereDoYouVoteSaysAFailedChosenDistrictEveryTime() {
        let spoken = SpokenLines()
        let saves = SaveCounter()
        let host = Self.host(Self.signedOut(Self.chooseYourDistrict(saves: saves)), spoken: spoken)
        defer { host.close() }

        XCTAssertTrue(host.activate(identifier: "location.chooseDistrict"), host.text())
        XCTAssertTrue(host.run(until: { host.label(ofIdentifier: "location.chooseDistrict.continue") != nil }), host.text())
        XCTAssertEqual(spoken.lines, [], "nothing to say yet")

        XCTAssertTrue(host.activate(identifier: "location.chooseDistrict.continue"), host.text())
        XCTAssertTrue(host.run(until: { host.label(ofIdentifier: "location.error") != nil }), host.text())
        host.run(0.3)
        XCTAssertEqual(saves.count, 1, "the save was tried")
        XCTAssertEqual(host.label(ofIdentifier: "location.error"), AuthErrorMessages.network)
        XCTAssertEqual(spoken.lines, [AuthErrorMessages.network], "said once")

        XCTAssertTrue(host.activate(identifier: "location.chooseDistrict.continue"), host.text())
        XCTAssertTrue(host.run(until: { saves.count == 2 }), host.text())
        host.run(0.3)
        XCTAssertEqual(spoken.lines, [AuthErrorMessages.network, AuthErrorMessages.network], "and again after the next Continue")
    }

    /// Setup's Continue follows the representatives; when that fails, the line under Try again is said once, and
    /// said again when Try again fails too.
    func testSetupSaysAFailedFollow() {
        let spoken = SpokenLines()
        let preferences = FailingPreferences()
        let host = Self.host(Self.whereDoYouVote(.setup, saved: Self.savedDistrict, preferences: preferences), spoken: spoken)
        defer { host.close() }
        let headline = LocationSavedPanel.spokenHeadline(state: "VA", district: "11")
        XCTAssertEqual(spoken.lines, [headline])

        XCTAssertTrue(host.activate("Continue"), host.text())
        XCTAssertTrue(host.run(until: { host.strings().contains(LocationSavedPanel.setupFollowFailedMessage) }), host.text())
        host.run(0.3)
        XCTAssertEqual(preferences.putCount, 1, "the follow was sent")
        XCTAssertEqual(spoken.lines, [headline, LocationSavedPanel.setupFollowFailedMessage], "said once")

        XCTAssertTrue(host.activate("Try again"), host.text())
        XCTAssertTrue(host.run(until: { preferences.putCount == 2 && host.strings().contains(LocationSavedPanel.setupFollowFailedMessage) }), host.text())
        host.run(0.3)
        XCTAssertEqual(
            spoken.lines,
            [headline, LocationSavedPanel.setupFollowFailedMessage, LocationSavedPanel.setupFollowFailedMessage],
            "and again after Try again"
        )
    }

    /// Profile's Follow your representatives says a failed follow once. While the follow runs the button says
    /// "Following…": the profile marks the members followed at once, but "You follow your representatives." waits
    /// for the save.
    func testProfileSaysAFailedFollow() {
        let spoken = SpokenLines()
        let preferences = FailingPreferences(delay: .milliseconds(800))
        let host = Self.host(Self.whereDoYouVote(.profile, saved: Self.savedDistrict, preferences: preferences), spoken: spoken)
        defer { host.close() }
        let headline = LocationSavedPanel.spokenHeadline(state: "VA", district: "11")

        XCTAssertTrue(host.activate("Follow your representatives", settle: 0.05), host.text())
        XCTAssertTrue(host.run(until: { host.strings().contains("Following…") }), host.text())
        XCTAssertFalse(host.strings().contains("You follow your representatives."), "no success before the save: \(host.text())")
        XCTAssertTrue(host.run(until: { host.strings().contains(LocationSavedPanel.profileFollowFailedMessage) }), host.text())
        host.run(0.3)
        XCTAssertEqual(preferences.putCount, 1, "the follow was sent")
        XCTAssertEqual(spoken.lines, [headline, LocationSavedPanel.profileFollowFailedMessage], "said once")
        XCTAssertTrue(host.strings().contains("Follow your representatives"), "the button is back: \(host.text())")
        XCTAssertFalse(host.strings().contains("You follow your representatives."), host.text())
    }

    /// A follow that fails at once, before the screen redraws, is said each time: in setup after Continue and Try
    /// again, in Profile after each Follow your representatives.
    func testAFollowThatFailsAtOnceIsSaidEveryTime() {
        let headline = LocationSavedPanel.spokenHeadline(state: "VA", district: "11")
        let flows: [(LocationEditorView.Context, first: String, again: String, line: String)] = [
            (.setup, "Continue", "Try again", LocationSavedPanel.setupFollowFailedMessage),
            (.profile, "Follow your representatives", "Follow your representatives", LocationSavedPanel.profileFollowFailedMessage)
        ]
        for flow in flows {
            let spoken = SpokenLines()
            let preferences = FailingPreferences(delay: nil)
            let host = Self.host(Self.whereDoYouVote(flow.0, saved: Self.savedDistrict, preferences: preferences), spoken: spoken)
            XCTAssertTrue(host.activate(flow.first), "\(flow.0): \(host.text())")
            XCTAssertTrue(host.run(until: { host.strings().contains(flow.line) }), "\(flow.0): \(host.text())")
            XCTAssertTrue(host.activate(flow.again), "\(flow.0): \(host.text())")
            XCTAssertTrue(host.run(until: { preferences.putCount == 2 }), "\(flow.0): \(host.text())")
            host.run(0.3)
            XCTAssertEqual(spoken.lines, [headline, flow.line, flow.line], "\(flow.0)")
            host.close()
        }
    }

    /// "You're in VA-11." is said once as the panel shows, in the words VoiceOver reads on the headline, through the
    /// form's sayer (`\.announceToVoiceOver`, which posts it queued, so the button's label change is not cut off).
    func testTheSuccessHeadlineIsSaidOnce() {
        let spoken = SpokenLines()
        let host = Self.host(Self.whereDoYouVote(.profile, saved: Self.savedDistrict, preferences: FailingPreferences()), spoken: spoken)
        defer { host.close() }
        XCTAssertEqual(spoken.lines, ["You're in Virginia's 11th district."])
        host.run(0.3)
        XCTAssertEqual(spoken.lines, ["You're in Virginia's 11th district."], "not again")
    }

    /// Where do you vote? with an address ready for Find my district.
    private static func whereDoYouVote() -> some View {
        var form = LocationForm()
        form.line1 = "10 Main St"
        form.city = "Fairfax"
        form.state = "VA"
        form.zip = "22030"
        return NavigationStack {
            LocationEditorView(context: .profile, congressService: FakeCongressService(), form: form) { _ in }
        }
    }

    /// Choose your district for VA-11, whose save to the account fails at once (offline), counted in `saves`.
    private static func chooseYourDistrict(saves: SaveCounter) -> some View {
        var form = LocationForm()
        form.state = "VA"
        form.district = "11"
        return NavigationStack {
            LocationEditorView(
                context: .profile,
                congressService: FakeCongressService(),
                form: form,
                saveChosenLocation: { _, _ in
                    saves.count += 1
                    throw URLError(.notConnectedToInternet)
                }
            ) { _ in }
        }
    }

    /// Where do you vote? open on the success panel for `saved`, its follows saved to `preferences`.
    private static func whereDoYouVote(
        _ context: LocationEditorView.Context,
        saved: LocationEditorResult,
        preferences: FailingPreferences
    ) -> some View {
        let auth = AuthManager()
        auth.cancelSignIn()
        return NavigationStack {
            LocationEditorView(context: context, congressService: FakeCongressService(), savedResult: saved) { _ in }
        }
        .environmentObject(auth)
        .environmentObject(UserStore(preferencesService: preferences, congressService: FakeCongressService()))
    }

    /// VA-11 found from an address, with its two senators and its House member, none followed yet.
    private static var savedDistrict: LocationEditorResult {
        func member(_ id: String, name: String, chamber: String, district: String?) -> CongressMemberManifestItem {
            CongressMemberManifestItem(dto: UserAPIContractsV1.CongressMemberManifestItem(
                bioguideId: id,
                name: name,
                chamber: chamber,
                state: "VA",
                party: "Democratic",
                district: district,
                depictionImageUrl: nil,
                updatedAt: nil,
                currentCongressBillsSupportedCount: nil,
                trackedSponsoredCount: nil,
                trackedSupportedCount: nil,
                currentCongressCounts: nil
            ))
        }
        return LocationEditorResult(
            state: "VA",
            district: "11",
            method: .address,
            verification: DistrictVerificationStatus(
                verified: true,
                status: "verified",
                method: DistrictVerificationStatus.methodAddressGeocode,
                verifiedAt: nil,
                resolved: DistrictVerificationResolved(state: "VA", districtId: "11"),
                signals: nil,
                repsSignalEligible: nil,
                nextStep: nil
            ),
            representatives: [
                member("S1", name: "Tim Kaine", chamber: "Senate", district: nil),
                member("S2", name: "Mark Warner", chamber: "Senate", district: nil),
                member("H11", name: "Jane Doe", chamber: "House", district: "11")
            ],
            followedRepresentatives: false
        )
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

/// How many times a save was tried.
@MainActor
private final class SaveCounter {
    var count = 0
}

/// Preferences whose saves fail as offline after a short wait, as a real request does: the follow is "Following…" for
/// a moment before the failure shows. With no wait, a save fails before the screen redraws.
@MainActor
private final class FailingPreferences: PreferencesServicing {
    private(set) var putCount = 0
    private let delay: Duration?

    init(delay: Duration? = .milliseconds(100)) {
        self.delay = delay
    }

    func getPreferences() async throws -> [PreferencesItem] { [] }

    func putPreferences(_ items: [PreferencesItem]) async throws {
        putCount += 1
        if let delay {
            try await Task.sleep(for: delay)
        }
        throw URLError(.notConnectedToInternet)
    }

    func deletePreferences(_ items: [PreferencesItem]) async throws {
        throw URLError(.notConnectedToInternet)
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
