import CryptoKit
import XCTest
@testable import Billboard

/// The age is asked once, at sign-up (spec D 2.5.2). The answer waits on the device under a hash of
/// the email until the server records it; a failed send is retried on later launches (three attempts,
/// 1 s, 3 s and 9 s apart) instead of showing the age gate. Each test uses its own `UserDefaults`
/// suite; the retry runs with a recorded, instant sleep.
final class AdultAnswerStoreTests: XCTestCase {
    private func makeStore() throws -> (AdultAnswerStore, UserDefaults, String) {
        let suiteName = "AdultAnswerStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        return (AdultAnswerStore(defaults: defaults), defaults, suiteName)
    }

    // MARK: - Store

    func testAnswerIsStoredUnderAHashOfTheEmailAndNeverTheEmail() throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        store.saveAdultAnswer(email: " Voter@Example.com ")

        let digest = SHA256.hash(data: Data("voter@example.com".utf8)).map { String(format: "%02x", $0) }.joined()
        let key = "BillBoard.pendingAdultAnswer.v1.\(digest)"
        XCTAssertEqual(defaults.object(forKey: key) as? Bool, true)
        let stored = defaults.persistentDomain(forName: suite) ?? [:]
        XCTAssertEqual(Array(stored.keys), [key], "one key, and nothing else written")
        for (storedKey, value) in stored {
            XCTAssertFalse(storedKey.lowercased().contains("voter"), storedKey)
            XCTAssertFalse("\(value)".lowercased().contains("example"))
        }
    }

    func testLookupIgnoresCaseAndSpacesAndIsPerEmail() throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertFalse(store.hasPendingAnswer(email: "voter@example.com"))
        store.saveAdultAnswer(email: "voter@example.com")
        XCTAssertTrue(store.hasPendingAnswer(email: "VOTER@example.com "))
        XCTAssertFalse(store.hasPendingAnswer(email: "other@example.com"))
        XCTAssertFalse(store.hasPendingAnswer(email: nil))
        XCTAssertFalse(store.hasPendingAnswer(email: "  "))
    }

    func testClearDeletesOnlyThatEmailsAnswer() throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        store.saveAdultAnswer(email: "a@example.com")
        store.saveAdultAnswer(email: "b@example.com")
        store.clear(email: "A@example.com")

        XCTAssertFalse(store.hasPendingAnswer(email: "a@example.com"))
        XCTAssertTrue(store.hasPendingAnswer(email: "b@example.com"))
        XCTAssertNil(defaults.object(forKey: FirstRunStorage.pendingAdultAnswerKey(email: "a@example.com")), "removed, not set to false")
    }

    func testBlankEmailIsIgnored() throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        store.saveAdultAnswer(email: "   ")
        XCTAssertTrue((defaults.persistentDomain(forName: suite) ?? [:]).isEmpty)
    }

    // MARK: - Retry

    func testScheduleIsThreeAttemptsOneThreeAndNineSecondsApart() {
        XCTAssertEqual(AdultAnswerRetry.delays, [1, 3, 9])
    }

    func testFirstSuccessfulAttemptConfirms() async {
        let recorder = RetryRecorder(failures: 1)
        let outcome = await AdultAnswerRetry.run(
            sleep: { recorder.sleeps.append($0) },
            isStillNeeded: { true },
            attempt: { try recorder.attempt() }
        )
        XCTAssertEqual(outcome, .confirmed(attempts: 2))
        XCTAssertEqual(recorder.sleeps, [1, 3], "waits before each attempt, and stops after the success")
        XCTAssertEqual(recorder.attempts, 2)
    }

    func testEveryAttemptFailingKeepsTheAnswerForNextLaunch() async {
        let recorder = RetryRecorder(failures: .max)
        let outcome = await AdultAnswerRetry.run(
            sleep: { recorder.sleeps.append($0) },
            isStillNeeded: { true },
            attempt: { try recorder.attempt() }
        )
        XCTAssertEqual(outcome, .failed(attempts: 3))
        XCTAssertEqual(recorder.sleeps, [1, 3, 9])
        XCTAssertEqual(recorder.attempts, 3, "at most three attempts per launch")
    }

    func testStopsWhenTheAccountGotAnAnswerElsewhere() async {
        // The sign-up screen's own submission lands during the first wait.
        let recorder = RetryRecorder(failures: .max)
        let outcome = await AdultAnswerRetry.run(
            sleep: { recorder.sleeps.append($0) },
            isStillNeeded: { recorder.sleeps.count < 2 },
            attempt: { try recorder.attempt() }
        )
        XCTAssertEqual(outcome, .noLongerNeeded(attempts: 1))
        XCTAssertEqual(recorder.attempts, 1)

        let untouched = RetryRecorder(failures: 0)
        let none = await AdultAnswerRetry.run(
            sleep: { untouched.sleeps.append($0) },
            isStillNeeded: { false },
            attempt: { try untouched.attempt() }
        )
        XCTAssertEqual(none, .noLongerNeeded(attempts: 0))
        XCTAssertEqual(untouched.attempts, 0, "nothing is sent when the server already has an answer")
    }

    func testCancellationStopsWithoutAnotherAttempt() async {
        let recorder = RetryRecorder(failures: .max)
        let outcome = await AdultAnswerRetry.run(
            sleep: { delay in
                recorder.sleeps.append(delay)
                if recorder.sleeps.count == 2 { throw CancellationError() }
            },
            isStillNeeded: { true },
            attempt: { try recorder.attempt() }
        )
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(recorder.attempts, 1)

        let cancelledAttempt = await AdultAnswerRetry.run(
            sleep: { _ in },
            isStillNeeded: { true },
            attempt: { throw CancellationError() }
        )
        XCTAssertEqual(cancelledAttempt, .cancelled)
    }
}

/// Records the retry's waits and attempts; the first `failures` attempts throw.
private final class RetryRecorder: @unchecked Sendable {
    var sleeps: [TimeInterval] = []
    private(set) var attempts = 0
    private let failures: Int

    struct Failure: Error {}

    init(failures: Int) {
        self.failures = failures
    }

    func attempt() throws {
        attempts += 1
        if attempts <= failures { throw Failure() }
    }
}
