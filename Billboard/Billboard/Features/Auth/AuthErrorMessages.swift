import Amplify
import AWSCognitoAuthPlugin
import Foundation

/// An app error whose `errorDescription` is fixed copy written for users, so it
/// can be shown as is. SDK and backend errors never conform.
protocol UserFacingError: LocalizedError {}

/// Fixed, plain user copy for errors from Cognito (through Amplify) and the
/// account APIs.
///
/// Raw SDK and backend strings are never shown. They are written for developers,
/// and Cognito's own messages ("User does not exist", "User cannot be confirmed")
/// reveal whether an email has an account. Every sign-in and recovery failure
/// that could hint at that maps to the same neutral copy.
enum AuthErrorMessages {
    enum Context {
        case signIn
        case signUp
        case confirmSignUp
        case resendCode
        case resetPassword
        case confirmResetPassword
        case newPassword
        case session
        case signOut
        case ageAttestation
        case deleteAccount
        case general
    }

    static let wrongCredentials = "Incorrect email or password."
    static let codeExpired = "That code has expired. Request a new one and try again."
    static let codeMismatch = "That code isn't right. Check it and try again."
    static let tooManyAttempts = "Too many attempts. Wait a few minutes, then try again."
    static let network = "You appear to be offline. Check your connection and try again."
    static let generic = "Something went wrong. Please try again."
    static let sessionExpired = "Your session expired. Please sign in again."
    static let passwordPolicy = "Use at least 8 characters, with upper and lower case letters, a number and a symbol."
    static let signUpUnavailable = "We couldn't create an account with that email. If you already have one, sign in or reset your password."
    static let resetCodeSent = "If an account exists for that email, we sent it a reset code."
    static let emailNotConfirmed = "Confirm your email address first. Check your inbox for the code we sent."
    static let passwordResetRequired = "Reset your password to continue. Tap \u{201C}Forgot password?\u{201D} on the sign-in screen."
    static let codeDeliveryFailed = "We couldn't send a code to that email. Check the address and try again."
    static let serviceUnavailable = "Billboard is having trouble right now. Try again in a moment."
    /// Points at the one contact address (UX-39): signed out, About's Contact us row is out of reach.
    static let unsupportedSignInStep = "This account needs a sign-in step Billboard doesn't support yet. Email \(ContactUs.address) for help."
    /// Confirm or Resend on the code step found no account: an unconfirmed sign-up is deleted after a while
    /// (REL-53), so the email is free to sign up again. The form opens again with the email kept.
    static let signUpExpired = "This sign-up has expired. Create your account again with this email."
    /// `wrongCredentials` when this iPhone signed up with the email and never finished the first sign-in
    /// (`AdultAnswerStore` still holds its answer). Device-local, so it says nothing about the account.
    /// The password comes first: while the unconfirmed account exists, the right password opens the code step,
    /// and Create account fails for that email. Only once the server's cleanup has deleted the unconfirmed account
    /// (REL-53) does Cognito answer like a wrong password for any password, and creating the account again works.
    static let wrongCredentialsAfterSignUp = "Incorrect email or password. If you never entered the code we emailed when you signed up, sign in with the password you chose then, and you'll get to enter it. If that doesn't work, create your account again."

    // Limit and App Attest server codes (spec D 2.8.4, C3 4.5). Under watch the server returns none of these;
    // under enforce it returns them.

    /// `DEVICE_ACCOUNT_LIMIT`: a fourth account on this install or device.
    static let deviceAccountLimit = "This iPhone has reached the limit of 3 Billboard accounts."
    /// `APP_ATTEST_REQUIRED`, or `APP_ATTEST_FAILED` / `APP_ATTEST_UNKNOWN_KEY` after the client's one resend.
    static let appNotConfirmed = "We couldn't confirm this is the Billboard app on your iPhone. Update the app and try again."
    /// `POST /feedback` 429 `VOTE_DAILY_LIMIT` (INT-06). The vote was not stored.
    static let voteDailyLimit = "You've reached today's limit of 200 votes. This vote wasn't saved. You can vote again after midnight UTC."
    /// `VOTE_DAILY_LIMIT` on a reasons update: the vote was saved earlier, the reasons were not.
    static let reasonsDailyLimit = "You've reached today's limit of 200 votes, so your reasons weren't saved. You can add them after midnight UTC."
    /// Any other failed vote write: the optimistic vote stays on screen, and nothing retries it. Also
    /// `APP_ATTEST_UNAVAILABLE`, whose refused vote rolls back (`BillVoteStore.voteFailure(for:)`, APPF-27).
    static let voteNotSaved = "Your vote may not have saved. Check your connection and vote again."
    /// `POST /district-verification` 429 `VERIFICATION_RATE_LIMITED` (INT-03).
    static let verificationRateLimited = "You can verify a new address 3 times in 30 days. Try again later, or choose your district instead."
    /// `APP_UPDATE_REQUIRED` (426, or a refused sign-up): the same words as the blocking update alert.
    static var appUpdateRequired: String { AppUpdatePrompt.message }

    /// User copy for `error` in `context`.
    static func message(for error: Error, context: Context) -> String {
        if APIErrorResponse.isNetworkFailure(error) {
            return network
        }

        if let authError = error as? AuthError {
            return message(for: authError, context: context)
        }

        if let userFacingError = error as? UserFacingError,
           let description = userFacingError.errorDescription,
           !description.isEmpty {
            return description
        }

        if error is APIRequest.AuthResolutionError {
            return sessionExpired
        }

        // A backend code comes only from an HTTP error body; its copy wins over the status copy.
        if let code = APIErrorResponse.errorCode(from: error),
           let copy = message(forBackendCode: code) {
            return copy
        }

        if let status = APIErrorDebug.httpStatusCode(from: error) {
            return message(forHTTPStatus: status)
        }

        return generic
    }

    /// True when Cognito reported an account whose email was never confirmed (sign-in for a sign-up that left
    /// the code step). Amplify usually reports it as the sign-in step `.confirmSignUp` instead.
    static func isUserNotConfirmed(_ error: Error) -> Bool {
        guard let authError = error as? AuthError,
              case .service(_, _, let underlying) = authError else {
            return false
        }
        return (underlying as? AWSCognitoAuthError) == .userNotConfirmed
    }

    /// The sign-in failure line: `wrongCredentialsAfterSignUp` in place of `wrongCredentials` while this iPhone
    /// holds an unfinished sign-up for the email, else `message` as it is.
    static func signInFailureMessage(_ message: String, hasUnfinishedSignUp: Bool) -> String {
        message == wrongCredentials && hasUnfinishedSignUp ? wrongCredentialsAfterSignUp : message
    }

    /// True when Cognito reported that no such user exists. Callers use this to
    /// continue as if the request succeeded, so the UI never confirms whether an
    /// email is registered.
    static func isUserNotFound(_ error: Error) -> Bool {
        guard let authError = error as? AuthError,
              case .service(_, _, let underlying) = authError else {
            return false
        }
        return (underlying as? AWSCognitoAuthError) == .userNotFound
    }

    /// True when a password-reset request failed only because the email has no
    /// usable account (not found, or no verified email). The reset screen then
    /// carries on as if a code was sent.
    static func isUnknownAccountForPasswordReset(_ error: Error) -> Bool {
        if isUserNotFound(error) {
            return true
        }
        guard let authError = error as? AuthError,
              case .service(_, _, let underlying) = authError else {
            return false
        }
        return (underlying as? AWSCognitoAuthError) == .invalidParameter
    }

    /// User copy for a known backend error code (`{"error": "CODE"}`, or the code of a refused sign-up),
    /// or nil, so callers fall back to their status-based copy. `APP_ATTEST_UNAVAILABLE` has no copy of its
    /// own: a vote shows `voteNotSaved`, anything else its 503 copy.
    static func message(forBackendCode code: String) -> String? {
        switch code {
        case "ADULT_STATUS_LOCKED":
            return "This account is recorded as under 18, and that can't be changed in the app."
        case "ADULT_REQUIRED":
            return "Confirm your age before doing that."
        case "ACCOUNT_INELIGIBLE":
            return "This account isn't eligible to do that."
        case "ACCOUNT_DELETION_IN_PROGRESS":
            return "This account is being deleted."
        case "ACCOUNT_DELETED":
            return "This account has been deleted."
        case AppAttestServerCode.deviceAccountLimit.rawValue:
            return deviceAccountLimit
        case AppAttestServerCode.required.rawValue,
             AppAttestServerCode.failed.rawValue,
             AppAttestServerCode.unknownKey.rawValue:
            return appNotConfirmed
        case AppAttestServerCode.appUpdateRequired.rawValue:
            return appUpdateRequired
        case BackendCode.voteDailyLimit:
            return voteDailyLimit
        case BackendCode.verificationRateLimited:
            return verificationRateLimited
        default:
            return nil
        }
    }

    /// Limit codes (C2 3.2, 3.3.3). The App Attest codes are `AppAttestServerCode`.
    nonisolated enum BackendCode {
        static let voteDailyLimit = "VOTE_DAILY_LIMIT"
        static let verificationRateLimited = "VERIFICATION_RATE_LIMITED"
    }

    // MARK: - Pre-sign-up rejections

    /// Why the pre-sign-up trigger refused a sign-up. Cognito reports a rejection as
    /// "PreSignUp failed with error X." (it adds the period). X is an upper-snake code (C3's App Attest checks,
    /// returned under enforce) or a full sentence written for users (C2's INT-05 email checks), integration plan X11.
    nonisolated enum SignUpRejection: Equatable {
        case code(String)
        case sentence(String)
    }

    /// The rejection inside a Cognito `UserLambdaValidationException` (`AWSCognitoAuthError.lambda`), if any.
    static func signUpRejection(from error: Error) -> SignUpRejection? {
        guard let authError = error as? AuthError,
              case .service(let description, _, let underlying) = authError,
              (underlying as? AWSCognitoAuthError) == .lambda else {
            return nil
        }
        return signUpRejection(fromCognitoMessage: description)
    }

    /// Parses "PreSignUp failed with error X." with the trailing period removed. Nil when the message has
    /// another shape, or when X is neither a code nor a sentence fit to show (`displayableServerSentence`).
    nonisolated static func signUpRejection(fromCognitoMessage message: String) -> SignUpRejection? {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "PreSignUp failed with error"
        guard trimmed.count > prefix.count,
              trimmed.prefix(prefix.count).caseInsensitiveCompare(prefix) == .orderedSame else {
            return nil
        }
        var detail = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        if detail.hasSuffix(".") {
            detail.removeLast() // the period Cognito appends
        }
        detail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        if detail.range(of: #"^[A-Z][A-Z0-9_]{1,63}$"#, options: .regularExpression) != nil {
            return .code(detail)
        }
        return displayableServerSentence(detail).map(SignUpRejection.sentence)
    }

    /// A server sentence that may be shown as is (C2's INT-05 copy): trimmed, at most 300 characters, one line,
    /// starting with a capital letter and ending with a full stop (added when Cognito's was the only one).
    /// Nil for anything that looks like a developer message: an exception or error name, or a stack line.
    nonisolated static func displayableServerSentence(_ raw: String) -> String? {
        var sentence = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sentence.isEmpty,
              sentence.count <= 300,
              !sentence.contains(where: \.isNewline),
              let first = sentence.unicodeScalars.first,
              CharacterSet.uppercaseLetters.contains(first),
              sentence.contains(" ") else {
            return nil
        }
        let developerMarkers = [
            #"Exception"#,               // SomeException, "Exception:"
            #"\b[A-Za-z]*Error\b"#,      // Error, TypeError, ValidationError
            #"\bat\s+\S+\s+\(\S*:\d+"#,  // a stack frame: "at handler (/var/task/index.js:1:2)"
            #"\.(js|mjs|cjs|ts):\d+"#,   // a source location
            #"/var/task|node_modules"#,
            #"(?i)\btask timed out\b|\bundefined\b|\bnull\b"#
        ]
        for pattern in developerMarkers where sentence.range(of: pattern, options: .regularExpression) != nil {
            return nil
        }
        if let last = sentence.last, !".!?".contains(last) {
            sentence.append(".")
        }
        return sentence
    }

    /// User copy for a refused sign-up: the code's copy, the server's sentence, or the generic copy.
    static func message(for rejection: SignUpRejection) -> String {
        switch rejection {
        case .code(let code):
            return message(forBackendCode: code) ?? generic
        case .sentence(let sentence):
            return sentence
        }
    }

    static func message(forHTTPStatus status: Int) -> String {
        switch status {
        case 401:
            return sessionExpired
        case 403:
            return "You can't do that with this account."
        case 429:
            return tooManyAttempts
        case 500...599:
            return serviceUnavailable
        default:
            return generic
        }
    }

    // MARK: - Cognito

    private static func message(for error: AuthError, context: Context) -> String {
        if let cognitoError = error.underlyingError as? AWSCognitoAuthError {
            switch cognitoError {
            case .lambda:
                // A Lambda trigger refused the request. Only the pre-sign-up trigger's answer is meant for users.
                guard context == .signUp, let rejection = signUpRejection(from: error) else { return generic }
                return message(for: rejection)
            case .network:
                return network
            case .limitExceeded, .requestLimitExceeded, .failedAttemptsLimitExceeded:
                return tooManyAttempts
            case .codeExpired:
                return codeExpired
            case .codeMismatch:
                return codeMismatch
            case .invalidPassword:
                return passwordPolicy
            case .userNotFound:
                return messageForUnknownAccount(in: context)
            case .usernameExists, .aliasExists:
                return context == .signUp ? signUpUnavailable : generic
            case .userNotConfirmed:
                return context == .signIn ? emailNotConfirmed : generic
            case .passwordResetRequired:
                return passwordResetRequired
            case .codeDelivery:
                return codeDeliveryFailed
            case .invalidParameter:
                switch context {
                case .signUp:
                    return "Check your email address and password, then try again."
                case .resetPassword:
                    // Cognito uses this for accounts without a verified email.
                    return resetCodeSent
                default:
                    return generic
                }
            default:
                break
            }
        }

        switch error {
        case .notAuthorized(let description, _, _):
            // Cognito uses NotAuthorized both for a wrong password and for a
            // temporary lockout after repeated failures.
            if description.localizedCaseInsensitiveContains("attempts exceeded") {
                return tooManyAttempts
            }
            switch context {
            case .signIn:
                return wrongCredentials
            case .confirmSignUp, .confirmResetPassword:
                return codeMismatch
            case .newPassword, .session, .deleteAccount:
                return sessionExpired
            default:
                return generic
            }
        case .sessionExpired, .signedOut:
            return context == .signOut ? generic : sessionExpired
        case .validation:
            return context == .signIn ? wrongCredentials : generic
        default:
            return generic
        }
    }

    private static func messageForUnknownAccount(in context: Context) -> String {
        switch context {
        case .signIn:
            return wrongCredentials
        case .resetPassword:
            return resetCodeSent
        case .confirmSignUp, .confirmResetPassword:
            return codeMismatch
        case .newPassword, .session, .deleteAccount:
            return sessionExpired
        default:
            return generic
        }
    }
}
