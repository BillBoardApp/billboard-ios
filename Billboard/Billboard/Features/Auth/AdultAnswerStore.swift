import Foundation

/// The sign-up age answer, kept on this device until the server confirms it (spec D 2.5.2).
///
/// Create account asks "I'm 18 or older" once and stores the answer under
/// `FirstRunStorage.pendingAdultAnswerKey(email:)` (a SHA-256 of the email, so no email is stored in
/// clear). The first sign-in submits it (`POST /adult-attestation`); if that fails, the signed-in
/// bootstrap retries it (`AdultAnswerRetry`) instead of asking again. The answer is deleted once the
/// server reports an answer for the account.
nonisolated struct AdultAnswerStore {
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Records that the person signing up with `email` confirmed they are 18 or older.
    func saveAdultAnswer(email: String) {
        guard let key = key(for: email) else { return }
        defaults.set(true, forKey: key)
    }

    /// True while an answer given at sign-up with `email` waits for the server.
    func hasPendingAnswer(email: String?) -> Bool {
        guard let key = key(for: email) else { return false }
        return defaults.bool(forKey: key)
    }

    /// Deletes the stored answer for `email`, if any.
    func clear(email: String?) {
        guard let key = key(for: email) else { return }
        defaults.removeObject(forKey: key)
    }

    private func key(for email: String?) -> String? {
        guard let email = email.trimmedNonEmpty else { return nil }
        return FirstRunStorage.pendingAdultAnswerKey(email: email)
    }
}

/// Resubmits a stored sign-up age answer on a later launch (spec D 2.5.2): at most three attempts
/// per launch, 1 s, 3 s and 9 s apart, while the account still has no answer on the server.
nonisolated enum AdultAnswerRetry {
    /// Wait before each attempt, in seconds. The first wait also lets a submission still running from
    /// the sign-up screen land first, so the two rarely both post.
    static let delays: [TimeInterval] = [1, 3, 9]

    enum Outcome: Equatable {
        /// An attempt succeeded; the stored answer can be deleted.
        case confirmed(attempts: Int)
        /// The account got an answer some other way (for example the sign-up screen's own submission).
        case noLongerNeeded(attempts: Int)
        /// Every attempt failed; the stored answer stays for the next launch.
        case failed(attempts: Int)
        /// The task was cancelled (sign-out, or the bootstrap restarted).
        case cancelled
    }

    /// Runs the retries.
    /// - Parameters:
    ///   - sleep: Waits the given seconds; throws when cancelled.
    ///   - isStillNeeded: Checked before each attempt: false when the account already has an answer.
    ///   - attempt: Submits the answer and confirms it (`UserStore.submitAdultAttestation(isAdult: true)`).
    static func run(
        delays: [TimeInterval] = AdultAnswerRetry.delays,
        sleep: (TimeInterval) async throws -> Void,
        isStillNeeded: () async -> Bool,
        attempt: () async throws -> Void
    ) async -> Outcome {
        var attempts = 0
        for delay in delays {
            do {
                try await sleep(delay)
            } catch {
                return .cancelled
            }
            guard await isStillNeeded() else { return .noLongerNeeded(attempts: attempts) }

            attempts += 1
            do {
                try await attempt()
                return .confirmed(attempts: attempts)
            } catch is CancellationError {
                return .cancelled
            } catch {
                continue
            }
        }
        return .failed(attempts: attempts)
    }

    /// `Task.sleep` for `seconds`; throws `CancellationError` when the task is cancelled.
    static func taskSleep(_ seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
}
