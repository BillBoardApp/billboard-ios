import Amplify
import Combine
import AWSCognitoAuthPlugin
import Foundation
import os

@MainActor
final class AuthManager: ObservableObject {
    enum Status: Equatable {
        case loading
        case signedOut
        case signedIn
        case newPasswordRequired(username: String)
        case error(String)

        /// Signed in or out (or mid sign-in): the session state is known. `.loading` and `.error` are not.
        var isKnownAuthState: Bool {
            switch self {
            case .signedIn, .signedOut, .newPasswordRequired:
                return true
            case .loading, .error:
                return false
            }
        }
    }

    @Published private(set) var status: Status = .loading {
        didSet { prepareAppAttestOnFirstKnownState() }
    }
    @Published private(set) var username: String?
    @Published var isBusy: Bool = false

    /// App Attest for sign-up metadata and the first-launch attestation; nil uses `AppAttestManager.current`.
    private let appAttestOverride: (any AppAttestManaging)?
    /// Posts the blocking update alert when a sign-up is refused with `APP_UPDATE_REQUIRED`.
    private let updateSignal: AppUpdateRequiredSignal
    private var didStartAppAttestPrepare = false
    /// The first-launch attestation started when the auth state was first known (C3 3.10). Tests await it.
    private(set) var appAttestPrepareTask: Task<Void, Never>?

    init(appAttest: (any AppAttestManaging)? = nil, updateSignal: AppUpdateRequiredSignal? = nil) {
        appAttestOverride = appAttest
        self.updateSignal = updateSignal ?? .shared
    }

    private var appAttest: any AppAttestManaging {
        appAttestOverride ?? AppAttestManager.current
    }

    /// Attests this install's key in the background once the auth state is first known (signed in or out),
    /// so the first vote or sign-up does not wait for it (spec D 2.8.1). Never blocks and never fails; the
    /// manager backs off on its own. Sign-up asks again through `signUpMetadata(email:)`.
    private func prepareAppAttestOnFirstKnownState() {
        guard !didStartAppAttestPrepare, status.isKnownAuthState else { return }
        didStartAppAttestPrepare = true
        let manager = appAttest
        appAttestPrepareTask = Task(priority: .utility) {
            await manager.prepareIfNeeded()
        }
    }

    func refresh() async {
        isBusy = true
        defer { isBusy = false }

        do {
            let session = try await Amplify.Auth.fetchAuthSession()
            status = session.isSignedIn ? .signedIn : .signedOut
        } catch {
            logFailure(error, operation: "fetchAuthSession")
            status = .error(AuthErrorMessages.message(for: error, context: .session))
        }
    }

    /// How a sign-in ended, for the screen that started it. The status says the rest.
    enum SignInOutcome: Equatable {
        case signedIn
        case newPasswordRequired
        /// The account's email was never confirmed (the sign-up left the code step, UX-39): the screen opens
        /// the code step for the email, and the status is `.signedOut` with no message.
        case needsEmailConfirmation
        /// `status` is `.error` with the message to show.
        case failed
    }

    @discardableResult
    func signIn(username: String, password: String) async -> SignInOutcome {
        isBusy = true
        defer { isBusy = false }

        do {
            let result = try await Amplify.Auth.signIn(username: username, password: password)
            if result.isSignedIn {
                self.username = username
                status = .signedIn
                return .signedIn
            }
            switch result.nextStep {
            case .confirmSignInWithNewPassword:
                self.username = username
                status = .newPasswordRequired(username: username)
                return .newPasswordRequired
            case let step where Self.needsEmailConfirmation(step):
                return markNeedsEmailConfirmation()
            default:
                status = .error(Self.message(forUnsupportedStep: result.nextStep))
                return .failed
            }
        } catch {
            logFailure(error, operation: "signIn")
            if AuthErrorMessages.isUserNotConfirmed(error) {
                return markNeedsEmailConfirmation()
            }
            let message = AuthErrorMessages.message(for: error, context: .signIn)
            status = .error(AuthErrorMessages.signInFailureMessage(
                message,
                hasUnfinishedSignUp: AdultAnswerStore().hasPendingAnswer(email: username)
            ))
            return .failed
        }
    }

    /// True for the sign-in step Amplify reports for an account whose email was never confirmed.
    nonisolated static func needsEmailConfirmation(_ step: AuthSignInStep) -> Bool {
        if case .confirmSignUp = step { return true }
        return false
    }

    private func markNeedsEmailConfirmation() -> SignInOutcome {
        AppLog.auth.info("Sign-in: the account's email is not confirmed; opening the code step")
        username = nil
        status = .signedOut
        return .needsEmailConfirmation
    }

    func confirmNewPassword(_ newPassword: String) async {
        isBusy = true
        defer { isBusy = false }

        do {
            let result = try await Amplify.Auth.confirmSignIn(challengeResponse: newPassword)
            if result.isSignedIn {
                status = .signedIn
            } else {
                switch result.nextStep {
                case .confirmSignInWithNewPassword:
                    status = .newPasswordRequired(username: username ?? "")
                default:
                    status = .error(Self.message(forUnsupportedStep: result.nextStep))
                }
            }
        } catch {
            logFailure(error, operation: "confirmSignIn")
            status = .error(AuthErrorMessages.message(for: error, context: .newPassword))
        }
    }

    func cancelSignIn() {
        username = nil
        status = .signedOut
    }

    /// Creates the Cognito account. The request carries the App Attest `ClientMetadata` (spec C3 3.5, 3.10):
    /// an assertion over the email (attesting this install's key first when needed), the DeviceCheck token
    /// and the app version. Building it takes at most 6 s and never fails; on any problem it holds a marker
    /// instead of an assertion, so the sign-up always goes ahead.
    func signUp(username: String, password: String) async throws -> AuthSignUpResult {
        let metadata = await appAttest.signUpMetadata(email: username)
        let options = Self.signUpOptions(email: username, metadata: metadata)
        do {
            return try await Amplify.Auth.signUp(username: username, password: password, options: options)
        } catch {
            noteSignUpFailure(error)
            throw error
        }
    }

    /// The sign-up options: the email attribute (the username is the email; set explicitly so the Cognito
    /// profile has it) and the `ClientMetadata` (`AWSAuthSignUpOptions.metadata`, never `validationData`).
    static func signUpOptions(email: String, metadata: [String: String]) -> AuthSignUpRequest.Options {
        AuthSignUpRequest.Options(
            userAttributes: [AuthUserAttribute(.email, value: email)],
            pluginOptions: AWSAuthSignUpOptions(metadata: metadata.isEmpty ? nil : metadata)
        )
    }

    /// A sign-up refused with `APP_UPDATE_REQUIRED` (enforce mode) shows the blocking update alert; the screen
    /// shows `AuthErrorMessages` copy for every refusal.
    func noteSignUpFailure(_ error: Error) {
        if AuthErrorMessages.signUpRejection(from: error) == .code(AppAttestServerCode.appUpdateRequired.rawValue) {
            updateSignal.post()
        }
    }

    func confirmSignUp(username: String, code: String) async throws -> AuthSignUpResult {
        try await Amplify.Auth.confirmSignUp(for: username, confirmationCode: code)
    }

    func resendSignUpCode(username: String) async throws -> AuthCodeDeliveryDetails {
        try await Amplify.Auth.resendSignUpCode(for: username)
    }

    func resetPassword(username: String) async throws -> AuthResetPasswordResult {
        try await Amplify.Auth.resetPassword(for: username)
    }

    func confirmResetPassword(username: String, newPassword: String, code: String) async throws {
        try await Amplify.Auth.confirmResetPassword(for: username, with: newPassword, confirmationCode: code)
    }

    func signOut() async {
        isBusy = true
        defer { isBusy = false }

        let userId = await currentUserIdForLocalPurge()
        let result = await Amplify.Auth.signOut()
        purgeLocalDataForSignOut(userId: userId)

        // The Auth category returns an abstract result. With Cognito, it is AWSCognitoSignOutResult.
        if let cognitoResult = result as? AWSCognitoSignOutResult {
            switch cognitoResult {
            case .complete:
                markSignedOut()
            case .partial(let revokeTokenError, let globalSignOutError, let hostedUIError):
                // Local credentials are gone; only server-side revocation failed.
                let parts: [String] = [
                    revokeTokenError.map { "revokeToken: \($0.error.errorDescription)" },
                    globalSignOutError.map { "globalSignOut: \($0.error.errorDescription)" },
                    hostedUIError.map { "hostedUI: \($0.error.errorDescription)" }
                ].compactMap { $0 }
                AppLog.auth.error("Sign-out completed locally; server-side steps failed: \(parts.joined(separator: "; "), privacy: .private)")
                markSignedOut()
            case .failed(let error):
                logFailure(error, operation: "signOut")
                status = .error(AuthErrorMessages.message(for: error, context: .signOut))
            }
        } else {
            // Fallback: treat as signed out.
            markSignedOut()
        }
    }

    /// Deletes the Cognito user after the backend has deleted the account's data.
    ///
    /// The backend deletes the Cognito user itself as the last step of account
    /// deletion, so by the time this runs Cognito usually answers "user not found"
    /// or "not authorized". Both mean the account is already gone: clear the local
    /// session and treat it as success. Any other failure is rethrown.
    func deleteCurrentAccount() async throws {
        do {
            try await Amplify.Auth.deleteUser()
        } catch let error as AuthError where Self.indicatesAccountAlreadyDeleted(error) {
            AppLog.auth.info("deleteUser: account already removed by the backend; clearing the local session")
            _ = await Amplify.Auth.signOut()
        }
    }

    private static func indicatesAccountAlreadyDeleted(_ error: AuthError) -> Bool {
        if AuthErrorMessages.isUserNotFound(error) {
            return true
        }
        switch error {
        case .notAuthorized, .sessionExpired, .signedOut:
            return true
        default:
            return false
        }
    }

    func setSignedOutLocally(userId: String? = nil) {
        purgeLocalDataForSignOut(userId: userId)
        markSignedOut()
    }

    private func markSignedOut() {
        username = nil
        status = .signedOut
    }

    func recoverFromInvalidSession(message: String) async {
        let userId = await currentUserIdForLocalPurge()
        _ = await Amplify.Auth.signOut()
        purgeLocalDataForSignOut(userId: userId)
        username = nil
        status = .error(message)
    }

    private static func message(forUnsupportedStep step: AuthSignInStep) -> String {
        AppLog.auth.error("Unsupported sign-in step: \(String(describing: step), privacy: .private)")
        switch step {
        case .confirmSignUp:
            return AuthErrorMessages.emailNotConfirmed
        case .resetPassword:
            return AuthErrorMessages.passwordResetRequired
        default:
            return AuthErrorMessages.unsupportedSignInStep
        }
    }

    private func logFailure(_ error: Error, operation: String) {
        AppLog.auth.error("\(operation, privacy: .public) failed: \(String(describing: error), privacy: .private)")
    }

    private func purgeLocalDataForSignOut(userId: String?) {
        PushRegistrationService.clearCachedRegistrations()
        PushPresentationSettings.clear()
        VerificationAddressStore.clearAll()
        UserLocalDataPurge.purge(userId: userId)
    }

    private func currentUserIdForLocalPurge() async -> String? {
        do {
            let currentUser = try await Amplify.Auth.getCurrentUser()
            if let userId = currentUser.userId.trimmedNonEmpty {
                return userId
            }
        } catch {
            // Fall back to the username captured during sign-in/new-password flows.
        }

        return username.trimmedNonEmpty
    }
}
