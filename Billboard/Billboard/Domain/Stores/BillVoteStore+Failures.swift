import Foundation

extension BillVoteStore {
    // MARK: - Failure copy (spec D 2.8.4)

    static let loadVotesFailedMessage = "Couldn't check your votes. Pull down to try again."
    static let checkVoteFailedMessage = "Couldn't check your vote on this bill."
    static let reasonsNotSavedMessage = "Your reasons could not be saved. Try again in a moment."

    /// What a failed vote write shows, and whether the vote is rolled back (APPF-27). `POST /feedback`
    /// answers every coded refusal before it stores the row (account eligibility, then App Attest, then the
    /// daily limit), so a vote refused with a code the app knows was not stored and rolls back:
    /// `VOTE_DAILY_LIMIT`, the App Attest codes (`APP_ATTEST_UNAVAILABLE` included: 503, fail closed),
    /// `APP_UPDATE_REQUIRED`, `DEVICE_ACCOUNT_LIMIT` and the account codes. A failure without a code
    /// (offline, a timeout, a status without a body) or with a code the app does not know may have been
    /// stored, so it keeps the optimistic vote. Known codes get their copy
    /// (`AuthErrorMessages.message(forBackendCode:)`); every other failure gets `voteNotSaved`, which bill detail
    /// shows over the vote it keeps. `APP_ATTEST_UNAVAILABLE` gets the refusal strip's "This vote wasn't saved. Try
    /// again." (`BillVoteBarModel.refusalFallbackText`): its vote is gone and the buttons are back, so a new tap
    /// sends it, and nothing is waiting to be saved (UX-49).
    static func voteFailure(for error: Error) -> (message: String, rollsBack: Bool) {
        guard let code = APIErrorResponse.errorCode(from: error) else {
            return (AuthErrorMessages.voteNotSaved, false)
        }
        switch code {
        case AuthErrorMessages.BackendCode.voteDailyLimit:
            return (AuthErrorMessages.voteDailyLimit, true)
        case AppAttestServerCode.unavailable.rawValue:
            return (BillVoteBarModel.refusalFallbackText, true)
        default:
            guard let copy = AuthErrorMessages.message(forBackendCode: code) else {
                return (AuthErrorMessages.voteNotSaved, false)
            }
            return (copy, true)
        }
    }

    /// What a failed reasons update shows. The vote itself was stored earlier and stays.
    static func reasonsFailureMessage(for error: Error) -> String {
        guard let code = APIErrorResponse.errorCode(from: error) else { return reasonsNotSavedMessage }
        switch code {
        case AuthErrorMessages.BackendCode.voteDailyLimit:
            return AuthErrorMessages.reasonsDailyLimit
        case AppAttestServerCode.unavailable.rawValue:
            return reasonsNotSavedMessage
        default:
            return AuthErrorMessages.message(forBackendCode: code) ?? reasonsNotSavedMessage
        }
    }
}
