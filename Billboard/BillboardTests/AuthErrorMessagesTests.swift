import Amplify
import AWSCognitoAuthPlugin
import XCTest
@testable import Billboard

/// The copy for every server code and message shape of spec D 2.8.4 (and integration plan X11: the
/// pre-sign-up message "PreSignUp failed with error X." read with its trailing period removed).
final class AuthErrorMessagesTests: XCTestCase {
    private let appNotConfirmed = "We couldn't confirm this is the Billboard app on your iPhone. Update the app and try again."
    private let deviceLimit = "This iPhone has reached the limit of 3 Billboard accounts."
    private let updateRequired = "This version of Billboard can't vote or create accounts any more. Update to continue."
    private let generic = "Something went wrong. Please try again."

    /// The error Amplify raises for a Cognito `UserLambdaValidationException`.
    private func lambdaError(_ message: String) -> AuthError {
        .service(message, "Check the Lambda trigger.", AWSCognitoAuthError.lambda)
    }

    // MARK: - Pre-sign-up codes (C3 3.5, enforce mode)

    @MainActor
    func testAPreSignUpCodeShowsItsCopy() {
        let cases = [
            ("DEVICE_ACCOUNT_LIMIT", deviceLimit),
            ("APP_ATTEST_REQUIRED", appNotConfirmed),
            ("APP_ATTEST_FAILED", appNotConfirmed),
            ("APP_ATTEST_UNKNOWN_KEY", appNotConfirmed),
            ("APP_UPDATE_REQUIRED", updateRequired)
        ]
        for (code, copy) in cases {
            let error = lambdaError("PreSignUp failed with error \(code).")
            XCTAssertEqual(AuthErrorMessages.message(for: error, context: .signUp), copy, code)
        }
    }

    @MainActor
    func testAnUnknownPreSignUpCodeIsGeneric() {
        let error = lambdaError("PreSignUp failed with error SOMETHING_NEW.")

        XCTAssertEqual(AuthErrorMessages.message(for: error, context: .signUp), generic)
    }

    func testTheCodeIsReadWithOrWithoutCognitosPeriod() {
        XCTAssertEqual(
            AuthErrorMessages.signUpRejection(fromCognitoMessage: "PreSignUp failed with error DEVICE_ACCOUNT_LIMIT."),
            .code("DEVICE_ACCOUNT_LIMIT")
        )
        XCTAssertEqual(
            AuthErrorMessages.signUpRejection(fromCognitoMessage: " PreSignUp failed with error DEVICE_ACCOUNT_LIMIT "),
            .code("DEVICE_ACCOUNT_LIMIT")
        )
        XCTAssertEqual(
            AuthErrorMessages.signUpRejection(fromCognitoMessage: "presignup failed with error APP_UPDATE_REQUIRED."),
            .code("APP_UPDATE_REQUIRED")
        )
        XCTAssertNil(AuthErrorMessages.signUpRejection(fromCognitoMessage: "PostConfirmation failed with error DEVICE_ACCOUNT_LIMIT."))
        XCTAssertNil(AuthErrorMessages.signUpRejection(fromCognitoMessage: "PreSignUp failed with error"))
        XCTAssertNil(AuthErrorMessages.signUpRejection(fromCognitoMessage: "User lambda validation error."))
    }

    // MARK: - Pre-sign-up sentences (C2 INT-05)

    @MainActor
    func testAServerSentenceIsShownWithoutCognitosPeriod() {
        let disposable = "Use a permanent email address. Temporary email services can't be used for Billboard accounts."
        let variant = "An account already uses this email address (addresses that differ only by a +tag or dots count as the same). "
            + "Sign in or reset your password."

        for sentence in [disposable, variant] {
            let error = lambdaError("PreSignUp failed with error \(sentence).")
            XCTAssertEqual(AuthErrorMessages.message(for: error, context: .signUp), sentence)
        }
    }

    func testASentenceWhoseOnlyFullStopWasCognitosKeepsOne() {
        XCTAssertEqual(
            AuthErrorMessages.signUpRejection(fromCognitoMessage: "PreSignUp failed with error Sign-ups are paused right now."),
            .sentence("Sign-ups are paused right now.")
        )
        XCTAssertEqual(
            AuthErrorMessages.signUpRejection(fromCognitoMessage: "PreSignUp failed with error Is this your email?."),
            .sentence("Is this your email?")
        )
    }

    @MainActor
    func testDeveloperMessagesAreNeverShown() {
        let messages = [
            "ResourceNotFoundException: Requested resource not found",
            "TypeError: Cannot read properties of undefined (reading 'email')",
            "Unexpected Error while checking the email",
            "Task timed out after 5.01 seconds",
            "Failed at checkEmail (/var/task/index.js:12:3)",
            "Failed in index.mjs:40 while checking",
            "Cannot find module in node_modules/foo",
            "The value was null when checking",
            "lower-case text from a developer",
            "Nope",
            "Use a permanent email address.\nTemporary email services can't be used.",
            "Use a permanent email address. " + String(repeating: "Really. ", count: 40)
        ]
        for message in messages {
            let error = lambdaError("PreSignUp failed with error \(message).")
            XCTAssertEqual(AuthErrorMessages.message(for: error, context: .signUp), generic, message)
        }
    }

    func testTheSentenceLimitIs300Characters() {
        let longest = "A" + String(repeating: "b", count: 297) + " c" // 300 characters, ends without a stop
        XCTAssertEqual(longest.count, 300)
        XCTAssertEqual(AuthErrorMessages.displayableServerSentence(longest), longest + ".")
        XCTAssertNil(AuthErrorMessages.displayableServerSentence(longest + "d"))
    }

    // MARK: - Lambda errors elsewhere

    @MainActor
    func testALambdaRefusalOutsideSignUpIsGeneric() {
        let error = lambdaError("PreSignUp failed with error Use a permanent email address.")

        for context: AuthErrorMessages.Context in [.signIn, .confirmSignUp, .resendCode, .general] {
            XCTAssertEqual(AuthErrorMessages.message(for: error, context: context), generic, "\(context)")
        }
    }

    @MainActor
    func testOnlyLambdaErrorsAreReadAsSignUpRejections() {
        let invalidParameter = AuthError.service(
            "PreSignUp failed with error DEVICE_ACCOUNT_LIMIT.",
            "",
            AWSCognitoAuthError.invalidParameter
        )

        XCTAssertNil(AuthErrorMessages.signUpRejection(from: invalidParameter))
        XCTAssertNil(AuthErrorMessages.signUpRejection(from: FakeServiceError()))
        XCTAssertEqual(
            AuthErrorMessages.signUpRejection(from: lambdaError("PreSignUp failed with error DEVICE_ACCOUNT_LIMIT.")),
            .code("DEVICE_ACCOUNT_LIMIT")
        )
    }

    @MainActor
    func testOtherSignUpErrorsKeepTheirCopy() {
        XCTAssertEqual(
            AuthErrorMessages.message(for: AuthError.service("", "", AWSCognitoAuthError.usernameExists), context: .signUp),
            "We couldn't create an account with that email. If you already have one, sign in or reset your password."
        )
        XCTAssertEqual(
            AuthErrorMessages.message(for: AuthError.service("", "", AWSCognitoAuthError.invalidPassword), context: .signUp),
            "Use at least 8 characters, with upper and lower case letters, a number and a symbol."
        )
    }

    // MARK: - API codes (spec D 2.8.4)

    @MainActor
    func testEveryBackendErrorCodeHasItsCopy() {
        let cases: [(String, String?)] = [
            ("DEVICE_ACCOUNT_LIMIT", deviceLimit),
            ("APP_ATTEST_REQUIRED", appNotConfirmed),
            ("APP_ATTEST_FAILED", appNotConfirmed),
            ("APP_ATTEST_UNKNOWN_KEY", appNotConfirmed),
            ("APP_UPDATE_REQUIRED", updateRequired),
            ("VOTE_DAILY_LIMIT", "You've reached today's limit of 200 votes. This vote wasn't saved. You can vote again after midnight UTC."),
            ("VERIFICATION_RATE_LIMITED", "You can verify a new address 3 times in 30 days. Try again later, or choose your district instead."),
            // No copy of its own: a vote says it may not have saved, anything else shows its 503 copy.
            ("APP_ATTEST_UNAVAILABLE", nil),
            ("SOMETHING_NEW", nil),
            // Unchanged.
            ("ADULT_REQUIRED", "Confirm your age before doing that."),
            ("ACCOUNT_DELETED", "This account has been deleted.")
        ]
        for (code, copy) in cases {
            XCTAssertEqual(AuthErrorMessages.message(forBackendCode: code), copy, code)
        }
    }

    @MainActor
    func testACodedErrorBodyShowsItsCopy() {
        XCTAssertEqual(AuthErrorMessages.message(for: backendError("APP_ATTEST_REQUIRED"), context: .general), appNotConfirmed)
        XCTAssertEqual(AuthErrorMessages.message(for: backendError("DEVICE_ACCOUNT_LIMIT"), context: .general), deviceLimit)
    }

    @MainActor
    func testUnknownCodesFallBackToTheStatusCopy() {
        XCTAssertEqual(AuthErrorMessages.message(for: backendError("SOMETHING_NEW"), context: .general), generic)
        XCTAssertEqual(
            AuthErrorMessages.message(for: httpStatusError(403), context: .general),
            "You can't do that with this account."
        )
        XCTAssertEqual(
            AuthErrorMessages.message(for: httpStatusError(503), context: .general),
            "Billboard is having trouble right now. Try again in a moment."
        )
        XCTAssertEqual(
            AuthErrorMessages.message(for: httpStatusError(429), context: .general),
            "Too many attempts. Wait a few minutes, then try again."
        )
    }

    // MARK: - Copy (spec D 2.4.2)

    @MainActor
    func testCopyNamesBillboardAndDropsPlease() {
        XCTAssertEqual(AuthErrorMessages.serviceUnavailable, "Billboard is having trouble right now. Try again in a moment.")
        XCTAssertEqual(
            AuthErrorMessages.unsupportedSignInStep,
            // UX-39 (project decision, 2026-10-28): every "Contact support" names the contact address instead.
            "This account needs a sign-in step Billboard doesn't support yet. Email contact@billboard-project.com for help."
        )
        XCTAssertEqual(AuthErrorMessages.appUpdateRequired, AppUpdatePrompt.message, "the same words as the update alert")

        let newCopy = [
            AuthErrorMessages.serviceUnavailable,
            AuthErrorMessages.unsupportedSignInStep,
            AuthErrorMessages.deviceAccountLimit,
            AuthErrorMessages.appNotConfirmed,
            AuthErrorMessages.voteDailyLimit,
            AuthErrorMessages.reasonsDailyLimit,
            AuthErrorMessages.voteNotSaved,
            AuthErrorMessages.verificationRateLimited
        ]
        for copy in newCopy {
            XCTAssertFalse(copy.contains("BillBoard"), copy)
            XCTAssertFalse(copy.contains("Please"), copy)
        }
    }
}

/// `AuthManager`'s App Attest work (spec C3 3.5 and 3.10, spec D 2.8.1): the sign-up `ClientMetadata`, the
/// first-launch attestation and the update alert after a refused sign-up. Nothing here calls Amplify.
final class AuthManagerAppAttestTests: XCTestCase {
    @MainActor
    func testSignUpOptionsCarryTheEmailAndTheClientMetadata() throws {
        let metadata = [
            "billboardAppAttest": "v1.a.key.data.sig",
            "billboardDeviceCheck": "dG9rZW4=",
            "billboardAppVersion": "1.2"
        ]

        let options = AuthManager.signUpOptions(email: "voter@example.com", metadata: metadata)

        let attributes = try XCTUnwrap(options.userAttributes)
        XCTAssertEqual(attributes.map(\.key), [.email])
        XCTAssertEqual(attributes.map(\.value), ["voter@example.com"])
        let plugin = try XCTUnwrap(options.pluginOptions as? AWSAuthSignUpOptions)
        XCTAssertEqual(plugin.metadata, metadata)
        XCTAssertNil(plugin.validationData, "ClientMetadata, never validationData (C3 3.10)")
    }

    @MainActor
    func testEmptyMetadataIsLeftOut() throws {
        let options = AuthManager.signUpOptions(email: "voter@example.com", metadata: [:])

        let plugin = try XCTUnwrap(options.pluginOptions as? AWSAuthSignUpOptions)
        XCTAssertNil(plugin.metadata)
    }

    @MainActor
    func testTheFirstKnownAuthStateStartsTheAttestationOnce() async {
        let appAttest = FakeAppAttestManager()
        let auth = AuthManager(appAttest: appAttest, updateSignal: AppUpdateRequiredSignal(center: NotificationCenter()))
        XCTAssertNil(auth.appAttestPrepareTask, "nothing while the auth state is loading")

        auth.cancelSignIn() // signed out: the login screen, where a sign-up may follow
        await auth.appAttestPrepareTask?.value
        auth.cancelSignIn()
        await auth.appAttestPrepareTask?.value

        XCTAssertEqual(appAttest.prepareCount, 1)
        XCTAssertTrue(appAttest.signUpEmails.isEmpty)
    }

    @MainActor
    func testOnlySignedInOrOutCountsAsKnown() {
        XCTAssertTrue(AuthManager.Status.signedIn.isKnownAuthState)
        XCTAssertTrue(AuthManager.Status.signedOut.isKnownAuthState)
        XCTAssertTrue(AuthManager.Status.newPasswordRequired(username: "voter@example.com").isKnownAuthState)
        XCTAssertFalse(AuthManager.Status.loading.isKnownAuthState)
        XCTAssertFalse(AuthManager.Status.error("Offline").isKnownAuthState)
    }

    @MainActor
    func testASignUpRefusedForAnOldBuildShowsTheUpdateAlert() {
        let center = NotificationCenter()
        var posted = 0
        let observer = center.addObserver(forName: .billboardAppUpdateRequired, object: nil, queue: nil) { _ in
            posted += 1
        }
        defer { center.removeObserver(observer) }
        let auth = AuthManager(appAttest: FakeAppAttestManager(), updateSignal: AppUpdateRequiredSignal(center: center))

        auth.noteSignUpFailure(AuthError.service("PreSignUp failed with error DEVICE_ACCOUNT_LIMIT.", "", AWSCognitoAuthError.lambda))
        auth.noteSignUpFailure(AuthError.service("", "", AWSCognitoAuthError.usernameExists))
        XCTAssertEqual(posted, 0)

        auth.noteSignUpFailure(AuthError.service("PreSignUp failed with error APP_UPDATE_REQUIRED.", "", AWSCognitoAuthError.lambda))
        auth.noteSignUpFailure(AuthError.service("PreSignUp failed with error APP_UPDATE_REQUIRED.", "", AWSCognitoAuthError.lambda))
        XCTAssertEqual(posted, 1, "once per launch")
    }
}
