import Amplify
import AWSCognitoAuthPlugin
import SwiftUI
import UIKit
import XCTest
@testable import Billboard

/// Sign-in recovery and contact (UX-39, feature review N7): a sign-in that finds the account's email never
/// confirmed opens the code step for that email instead of ending on "confirm your email"; Resend says where the
/// code went; a sign-up deleted while unconfirmed (REL-53) leads back to Create account; and every message that
/// sent people to "support" names the one contact address, which About's Contact us row opens.
@MainActor
final class SignInRecoveryTests: XCTestCase {
    // MARK: - Unconfirmed sign-in

    func testTheUnconfirmedSignInStepOpensTheCodeStep() {
        XCTAssertTrue(AuthManager.needsEmailConfirmation(.confirmSignUp(nil)))
        XCTAssertFalse(AuthManager.needsEmailConfirmation(.done))
        XCTAssertFalse(AuthManager.needsEmailConfirmation(.confirmSignInWithNewPassword(nil)))
        XCTAssertFalse(AuthManager.needsEmailConfirmation(.resetPassword(nil)))
    }

    func testAThrownUnconfirmedErrorIsRecognised() {
        XCTAssertTrue(AuthErrorMessages.isUserNotConfirmed(AuthError.service("User is not confirmed.", "", AWSCognitoAuthError.userNotConfirmed)))
        XCTAssertFalse(AuthErrorMessages.isUserNotConfirmed(AuthError.service("", "", AWSCognitoAuthError.userNotFound)))
        XCTAssertFalse(AuthErrorMessages.isUserNotConfirmed(AuthError.notAuthorized("Incorrect username or password.", "", nil)))
        XCTAssertFalse(AuthErrorMessages.isUserNotConfirmed(FakeServiceError()))
    }

    /// Sign-in that reports an unconfirmed email still reads "confirm your email" outside sign-in, and nothing
    /// changes what other contexts show.
    func testOtherContextsKeepTheirCopy() {
        let unconfirmed = AuthError.service("", "", AWSCognitoAuthError.userNotConfirmed)
        XCTAssertEqual(AuthErrorMessages.message(for: unconfirmed, context: .signIn), AuthErrorMessages.emailNotConfirmed)
        XCTAssertEqual(AuthErrorMessages.message(for: unconfirmed, context: .general), AuthErrorMessages.generic)
    }

    func testTheCodeStepOpenedBySignInHasTheEmailAndPassword() {
        let pending = PendingSignUpConfirmation(email: "voter@example.com", password: "Secret-123")
        XCTAssertEqual(pending.id, "voter@example.com")
        XCTAssertEqual(
            CreateAccountView.unconfirmedSignInMessage(email: pending.email),
            "Your email isn't confirmed yet. Enter the code we emailed to voter@example.com when you signed up. If you can't find it, or it has expired, tap Resend code."
        )
    }

    /// The code step a sign-in opens (frame 17's code step): the title, the line naming the email, the code field,
    /// Confirm with its hint, Resend code and Back to sign in.
    func testTheCodeStepFromSignInReadsInFull() throws {
        let auth = AuthManager()
        auth.cancelSignIn()
        let userStore = UserStore(preferencesService: StaticPreferencesService(items: []), congressService: FakeCongressService())
        let view = NavigationStack {
            CreateAccountView(confirming: PendingSignUpConfirmation(email: "voter@example.com", password: "Secret-123"))
        }
        .environmentObject(auth)
        .environmentObject(userStore)
        let host = AccessibilityTreeText.Host(view, size: CGSize(width: 390, height: 1200), settle: 0.3)
        defer { host.close() }
        let text = host.text()

        XCTAssertTrue(text.contains("Confirm your account"), text)
        XCTAssertTrue(text.contains(CreateAccountView.unconfirmedSignInMessage(email: "voter@example.com")), text)
        XCTAssertTrue(text.contains("Resend code"), text)
        XCTAssertTrue(text.contains("Back to sign in"), text)
        XCTAssertTrue(text.contains("Confirm"), text)
        XCTAssertTrue(host.identifiers().contains("signup.code"), "the code field")
        XCTAssertTrue(host.identifiers().contains("signup.code.unconfirmed"))
        XCTAssertFalse(text.contains("Create your account"), "opens on the code step, not the form")
    }

    /// Opened from Create account, the code step keeps its own line (only "A code was sent to …" once sent).
    func testTheCodeStepFromSignUpHasNoSignInLine() {
        let auth = AuthManager()
        auth.cancelSignIn()
        let userStore = UserStore(preferencesService: StaticPreferencesService(items: []), congressService: FakeCongressService())
        let view = NavigationStack {
            CreateAccountView(step: .confirmCode(details: nil), email: "voter@example.com", password: "Secret-123")
        }
        .environmentObject(auth)
        .environmentObject(userStore)
        let host = AccessibilityTreeText.Host(view, size: CGSize(width: 390, height: 1200), settle: 0.3)
        defer { host.close() }
        XCTAssertFalse(host.identifiers().contains("signup.code.unconfirmed"), host.text())
    }

    // MARK: - After the cleanup (REL-53)

    func testASignUpDeletedWhileUnconfirmedLeadsBackToCreateAccount() {
        XCTAssertEqual(AuthErrorMessages.signUpExpired, "This sign-up has expired. Create your account again with this email.")
        // Cognito's user-not-found, as Confirm and Resend report it without user-existence protection.
        XCTAssertTrue(AuthErrorMessages.isUserNotFound(AuthError.service("", "", AWSCognitoAuthError.userNotFound)))
    }

    /// When Confirm or Resend finds the sign-up gone, the long Create account form opens again with the expired
    /// line under Create account. The form scrolls down to that line, so it is on screen where the person lands; it
    /// used to open at the top with the line below the fold on every phone (iPhone SE: Create account ended at
    /// 775 pt of 667). Modelled with each phone's insets: the SE's 20 pt status bar, and a 402 x 874 phone's. As in
    /// the app, the code step shows first and the form replaces it once the screen is laid out (the test window takes
    /// its modelled insets a moment after it shows).
    func testTheExpiredLineIsOnScreenWhereTheFormOpensAgain() throws {
        let auth = AuthManager()
        auth.cancelSignIn()
        let userStore = UserStore(preferencesService: StaticPreferencesService(items: []), congressService: FakeCongressService())
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let phones: [(name: String, size: CGSize, insets: UIEdgeInsets)] = [
            ("iPhone SE", CGSize(width: 375, height: 667), UIEdgeInsets(top: 20, left: 0, bottom: 0, right: 0)),
            ("402 x 874", CGSize(width: 402, height: 874), UIEdgeInsets(top: 62, left: 0, bottom: 34, right: 0))
        ]
        for phone in phones {
            let restart = ExpiredSignUpRestart()
            let view = ExpiredSignUpRestart.Screen(restart: restart)
                .environmentObject(auth)
                .environmentObject(userStore)
            let host = AccessibilityTreeText.Host(view, size: phone.size, settle: 0.3, scene: scene, safeAreaInsets: phone.insets)
            defer { host.close() }
            XCTAssertTrue(host.identifiers().contains("signup.code"), "\(phone.name): the code step first")
            restart.hasExpired = true
            host.run(0.6)

            XCTAssertTrue(host.strings().contains(AuthErrorMessages.signUpExpired), "\(phone.name): \(host.text())")
            let line = try XCTUnwrap(host.frame(ofIdentifier: "signup.error"), phone.name)
            XCTAssertGreaterThanOrEqual(line.minY, phone.insets.top, "\(phone.name): \(line)")
            XCTAssertLessThanOrEqual(line.maxY, phone.size.height - phone.insets.bottom + 0.5, "\(phone.name): \(line)")
            let button = try XCTUnwrap(host.frame(ofIdentifier: "signup.submit"), phone.name)
            XCTAssertLessThanOrEqual(button.maxY, line.minY, "\(phone.name): Create account just above the line")
        }
    }

    /// With user-existence protection on, a deleted sign-up answers like a wrong password. Only an iPhone that
    /// signed up with the email (and never finished the first sign-in) adds the way back; the line never depends on
    /// what the server said about the account. It sends people to their password first: until the server's cleanup
    /// has deleted the account (REL-53), that opens the code step, and Create account fails for the email.
    func testAWrongPasswordAfterAnUnfinishedSignUpOnThisIPhoneSaysToTryThePasswordThenSignUpAgain() {
        XCTAssertEqual(
            AuthErrorMessages.signInFailureMessage(AuthErrorMessages.wrongCredentials, hasUnfinishedSignUp: true),
            "Incorrect email or password. If you never entered the code we emailed when you signed up, sign in with the password you chose then, and you'll get to enter it. If that doesn't work, create your account again."
        )
        XCTAssertEqual(
            AuthErrorMessages.signInFailureMessage(AuthErrorMessages.wrongCredentials, hasUnfinishedSignUp: false),
            AuthErrorMessages.wrongCredentials
        )
        XCTAssertEqual(
            AuthErrorMessages.signInFailureMessage(AuthErrorMessages.network, hasUnfinishedSignUp: true),
            AuthErrorMessages.network,
            "only the wrong-password line changes"
        )
    }

    func testAnUnfinishedSignUpIsTheStoredAgeAnswer() throws {
        let suite = "sign-in-recovery-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let answers = AdultAnswerStore(defaults: defaults)

        XCTAssertFalse(answers.hasPendingAnswer(email: "voter@example.com"))
        answers.saveAdultAnswer(email: "voter@example.com")
        XCTAssertTrue(answers.hasPendingAnswer(email: "voter@example.com"))
        answers.clear(email: "voter@example.com")
        XCTAssertFalse(answers.hasPendingAnswer(email: "voter@example.com"))
    }

    // MARK: - Contact us

    func testTheContactAddressAndItsMailLink() {
        XCTAssertEqual(ContactUs.address, "contact@billboard-project.com")
        XCTAssertEqual(ContactUs.mailURL.absoluteString, "mailto:contact@billboard-project.com")
        XCTAssertEqual(ContactUs.title, "Contact us")
        XCTAssertTrue(ContactUs.footer.contains(ContactUs.address), "the footer shows the address for anyone without Mail")
    }

    /// Mail set up: a new email. Not set up: the address, with Copy and "Open email app" for another default
    /// app. Nothing opened: the address with Copy.
    func testMailNotSetUpShowsTheAddress() {
        XCTAssertNil(ContactUs.firstFallback(canSendMail: true))
        XCTAssertEqual(ContactUs.firstFallback(canSendMail: false), .mailNotSetUp)
        XCTAssertEqual(
            ContactUs.Fallback.mailNotSetUp.message,
            "Mail isn't set up on this iPhone. Write to contact@billboard-project.com from any email app."
        )
        XCTAssertEqual(ContactUs.Fallback.couldNotOpen.message, "Billboard couldn't open an email app. Write to contact@billboard-project.com.")
        XCTAssertTrue(ContactUs.Fallback.mailNotSetUp.offersEmailApp)
        XCTAssertFalse(ContactUs.Fallback.couldNotOpen.offersEmailApp)
    }

    /// No message says "Contact support" any more: each names the address (signed out, About is out of reach).
    func testEveryContactMessageNamesTheAddress() {
        XCTAssertEqual(
            AuthErrorMessages.unsupportedSignInStep,
            "This account needs a sign-in step Billboard doesn't support yet. Email contact@billboard-project.com for help."
        )
        XCTAssertEqual(
            StartupFailureView.message,
            "Something is wrong with this copy of the app. Update Billboard from the App Store or reinstall it. If that doesn't help, email contact@billboard-project.com."
        )
        for message in [AuthErrorMessages.unsupportedSignInStep, StartupFailureView.message] {
            XCTAssertFalse(message.localizedCaseInsensitiveContains("support."), message)
        }
        XCTAssertTrue(SignInForm.offersContact(for: AuthErrorMessages.unsupportedSignInStep), "Sign in offers Contact us under it")
        XCTAssertFalse(SignInForm.offersContact(for: AuthErrorMessages.wrongCredentials))
    }

    func testTheStartupAddressIsAMailLink() throws {
        let message = StartupFailureView.attributedMessage
        XCTAssertEqual(String(message.characters), StartupFailureView.message)
        let range = try XCTUnwrap(message.range(of: ContactUs.address))
        XCTAssertEqual(message[range].link, ContactUs.mailURL)
        XCTAssertEqual(message[range].underlineStyle, .single)
    }

    /// About's Contact us row: in ink with the leave-the-app arrow, its footer naming the address, the hint
    /// saying where it goes, and an id for the UI tests. The disclaimer stays word for word.
    func testAboutHasContactUs() throws {
        let info = AboutInfo(infoDictionary: [
            "CFBundleShortVersionString": "1.2",
            "CFBundleVersion": "45",
            AboutInfo.websiteBaseURLKey: "https://billboard-project.com"
        ])
        let host = AccessibilityTreeText.Host(NavigationStack { AboutView(info: info) }, size: CGSize(width: 390, height: 1200), settle: 0.3)
        defer { host.close() }
        let text = host.text()
        XCTAssertTrue(text.contains("Contact us"), text)
        XCTAssertTrue(text.contains(ContactUs.footer), text)
        XCTAssertTrue(text.contains(AboutInfo.disclaimer), text)
        XCTAssertEqual(host.identifier(of: "Contact us"), "about.contactUs")
        XCTAssertEqual(host.hint(of: "Contact us"), ContactUs.accessibilityHint)
    }
}

/// The code step, then the form as `restartSignUp` leaves it once `hasExpired` is set: the switch the app makes when
/// Confirm or Resend finds the sign-up gone.
@MainActor
private final class ExpiredSignUpRestart: ObservableObject {
    @Published var hasExpired = false

    struct Screen: View {
        @ObservedObject var restart: ExpiredSignUpRestart

        var body: some View {
            NavigationStack {
                if restart.hasExpired {
                    CreateAccountView(step: .enterDetails, origin: .signIn, email: "voter@example.com", password: "Secret-123", signUpExpired: true)
                } else {
                    CreateAccountView(confirming: PendingSignUpConfirmation(email: "voter@example.com", password: "Secret-123"))
                }
            }
        }
    }
}
