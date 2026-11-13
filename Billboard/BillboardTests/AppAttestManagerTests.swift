import DeviceCheck
import Foundation
import XCTest
@testable import Billboard

/// `AppAttestManager` with fake App Attest, DeviceCheck, server, storage and clock (spec C3 7.3, spec D 2.8.1,
/// integration plan X12: five quick votes reach the server one at a time with increasing counters).
final class AppAttestManagerTests: XCTestCase {
    private var device: FakeAppAttestDevice!
    private var tokens: FakeDeviceTokens!
    private var server: FakeAppAttestServer!
    private var storage: InMemoryAppAttestStorage!
    private var clock: TestClock!
    private var holds: [AsyncHold] = []

    private let body = Data(#"{"billId":"BILLS-119hr1ih","feedback":"Yea"}"#.utf8)

    override func setUp() {
        super.setUp()
        device = FakeAppAttestDevice()
        tokens = FakeDeviceTokens()
        server = FakeAppAttestServer()
        storage = InMemoryAppAttestStorage()
        clock = TestClock()
        holds = []
    }

    override func tearDown() {
        // Release anything a test left suspended, so no continuation leaks into the next test.
        holds.forEach { $0.open() }
        super.tearDown()
    }

    private func hold() -> AsyncHold {
        let hold = AsyncHold()
        holds.append(hold)
        return hold
    }

    private func makeManager(
        storage customStorage: InMemoryAppAttestStorage? = nil,
        _ configure: (inout AppAttestManager.Configuration) -> Void = { _ in }
    ) -> AppAttestManager {
        var configuration = AppAttestManager.Configuration()
        configuration.isEnabled = true
        configuration.isDebugBuild = false
        configuration.appVersion = "1.2"
        configuration.attestBudget = 2
        configuration.assertBudget = 2
        configuration.gateWaitCap = 2
        configuration.signUpBudget = 2
        configure(&configuration)
        let clock = self.clock!
        return AppAttestManager(
            configuration: configuration,
            dependencies: AppAttestManager.Dependencies(
                attest: device,
                deviceToken: tokens,
                backend: server,
                storage: customStorage ?? storage,
                now: { clock.now },
                sleep: { seconds in try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000)) }
            )
        )
    }

    /// Sends one protected vote and returns the header it carried.
    @discardableResult
    private func vote(
        _ manager: AppAttestManager,
        body: Data? = nil,
        recorder: SendRecorder = SendRecorder()
    ) async throws -> [String: String] {
        try await manager.performProtected(method: "POST", path: "feedback", body: body ?? self.body) { headers in
            try recorder.record(headers)
        }
        return recorder.headers.last ?? [:]
    }

    private func marker(_ headers: [String: String]) -> String? {
        headers[AppAttestWire.attestHeader]
    }

    // MARK: - First run

    func testFirstRunGeneratesAttestsAndAssertsWithTheExactHeader() async throws {
        let manager = makeManager()

        let headers = try await vote(manager)

        // generateKey → challenge(attest) → attestKey → POST /app-attest/attest → challenge(assert) → assertion
        XCTAssertEqual(device.generatedKeys.count, 1)
        let appleKeyId = try XCTUnwrap(device.generatedKeys.first)
        let wireKeyId = try XCTUnwrap(AppAttestWire.wireKeyId(fromAppleKeyId: appleKeyId))
        XCTAssertEqual(server.challengePurposes, [.attest, .assert])
        let attestChallenge = server.issuedChallenges[0]
        let assertChallenge = server.issuedChallenges[1]

        let attestCall = try XCTUnwrap(device.attestCalls.first)
        XCTAssertEqual(attestCall.keyId, appleKeyId, "Apple gets its own standard base64 key ID back")
        XCTAssertEqual(attestCall.clientDataHash, AppAttestWire.sha256(Data(attestChallenge.utf8)))

        let registration = try XCTUnwrap(server.registrations.first)
        XCTAssertEqual(registration.keyId, wireKeyId)
        XCTAssertEqual(registration.challenge, attestChallenge)
        XCTAssertEqual(registration.attestation, FakeAppAttestDevice.attestationObject(for: appleKeyId))

        let expectedClientData = Data(
            (#"{"v":1,"purpose":"request","challenge":""# + assertChallenge
                + #"","method":"POST","path":"/feedback","bodySha256":""# + AppAttestWire.bodySha256(body) + #""}"#).utf8
        )
        let assertionCall = try XCTUnwrap(device.assertionCalls.first)
        XCTAssertEqual(assertionCall.keyId, appleKeyId)
        XCTAssertEqual(assertionCall.clientDataHash, AppAttestWire.sha256(expectedClientData))
        let assertion = FakeAppAttestDevice.assertion(counter: 1, clientDataHash: assertionCall.clientDataHash)
        XCTAssertEqual(
            headers,
            ["X-Billboard-App-Attest": "v1.a.\(wireKeyId).\(AppAttestWire.base64URL(expectedClientData)).\(AppAttestWire.base64URL(assertion))"]
        )

        guard case .record(let record) = storage.loadKey() else { return XCTFail("the key is stored") }
        XCTAssertEqual(record.keyId, wireKeyId)
        XCTAssertTrue(record.attested)
        XCTAssertEqual(record.environment, "production")
        XCTAssertNotNil(record.attestedAt)
        XCTAssertNil(storage.date(for: .backoffUntil))
    }

    func testLaterVotesReuseTheAttestedKeyWithAFreshChallengeEach() async throws {
        let manager = makeManager()
        await manager.prepareIfNeeded()
        XCTAssertEqual(server.challengePurposes, [.attest])

        let first = try await vote(manager)
        let second = try await vote(manager)

        XCTAssertEqual(device.generatedKeys.count, 1)
        XCTAssertEqual(device.attestCalls.count, 1)
        XCTAssertEqual(server.challengePurposes, [.attest, .assert, .assert])
        let firstParts = try XCTUnwrap(ParsedAssertion(marker(first)))
        let secondParts = try XCTUnwrap(ParsedAssertion(marker(second)))
        XCTAssertEqual(firstParts.keyId, secondParts.keyId)
        XCTAssertNotEqual(firstParts.challenge, secondParts.challenge)
        XCTAssertEqual(firstParts.counter + 1, secondParts.counter)
    }

    func testClientDataBindsTheBodyActuallySent() async throws {
        let manager = makeManager()
        let otherBody = Data(#"{"billId":"BILLS-119s5is","feedback":"Abstain"}"#.utf8)

        let first = try await vote(manager, body: body)
        let second = try await vote(manager, body: otherBody)
        let empty = try await manager.performProtected(method: "post", path: "/feedback", body: nil) { headers in headers }

        XCTAssertEqual(try XCTUnwrap(ParsedAssertion(marker(first))).json["bodySha256"] as? String, AppAttestWire.bodySha256(body))
        XCTAssertEqual(try XCTUnwrap(ParsedAssertion(marker(second))).json["bodySha256"] as? String, AppAttestWire.bodySha256(otherBody))
        let emptyParts = try XCTUnwrap(ParsedAssertion(marker(empty)))
        XCTAssertEqual(emptyParts.json["bodySha256"] as? String, "47DEQpj8HBSa-_TImW-5JCeuQeRkm5NMpJWZG3hSuFU")
        XCTAssertEqual(emptyParts.json["method"] as? String, "POST")
        XCTAssertEqual(emptyParts.json["path"] as? String, "/feedback")
        XCTAssertEqual(emptyParts.json["purpose"] as? String, "request")
        XCTAssertEqual(emptyParts.json["v"] as? Int, 1)
    }

    // MARK: - Attestation failures (C3 3.10)

    func testAppleServerUnavailableKeepsTheKeyAndBacksOffForAnHour() async throws {
        device.attestErrors = [DCError(.serverUnavailable)]
        let manager = makeManager()

        let headers = try await vote(manager)

        XCTAssertEqual(marker(headers), "v1.e.attest")
        guard case .record(let kept) = storage.loadKey() else { return XCTFail("the key is kept") }
        XCTAssertFalse(kept.attested)
        XCTAssertEqual(storage.date(for: .backoffUntil), clock.now.addingTimeInterval(3600))

        // Within the hour: nothing is tried again.
        clock.advance(by: 59 * 60)
        await manager.prepareIfNeeded()
        let sent = try await vote(manager)
        XCTAssertEqual(marker(sent), "v1.e.attest")
        XCTAssertEqual(device.attestCalls.count, 1)
        XCTAssertEqual(server.challengePurposes, [.attest])

        // After it: the same key is attested.
        clock.advance(by: 2 * 60)
        let later = try await vote(manager)
        XCTAssertEqual(device.generatedKeys.count, 1, "no new key")
        XCTAssertEqual(device.attestCalls.map(\.keyId), [device.generatedKeys[0], device.generatedKeys[0]])
        XCTAssertEqual(try XCTUnwrap(ParsedAssertion(marker(later))).keyId, kept.keyId)
        XCTAssertNil(storage.date(for: .backoffUntil), "success clears the back-off")
    }

    func testAnyOtherDeviceCheckErrorDiscardsAFreshKey() async throws {
        device.attestErrors = [DCError(.invalidInput)]
        let manager = makeManager()

        let sent = try await vote(manager)
        XCTAssertEqual(marker(sent), "v1.e.attest")

        XCTAssertEqual(storage.loadKey(), .none, "the key is discarded")
        XCTAssertEqual(device.generatedKeys.count, 1, "a fresh key is not replaced in the same attempt")
        XCTAssertNotNil(storage.date(for: .backoffUntil))

        clock.advance(by: 3601)
        let later = try await vote(manager)
        XCTAssertEqual(device.generatedKeys.count, 2, "the next attempt generates a new key")
        XCTAssertEqual(
            try XCTUnwrap(ParsedAssertion(marker(later))).keyId,
            AppAttestWire.wireKeyId(fromAppleKeyId: device.generatedKeys[1])
        )
    }

    func testAStoredKeyAppleRefusesIsReplacedOnceInTheSameAttempt() async throws {
        // An unattested key left by an earlier install: the Secure Enclave no longer has it.
        let staleAppleKeyId = Data(repeating: 0xEE, count: 32).base64EncodedString()
        let staleWireKeyId = try XCTUnwrap(AppAttestWire.wireKeyId(fromAppleKeyId: staleAppleKeyId))
        XCTAssertTrue(storage.saveKey(AppAttestKeyRecord(keyId: staleWireKeyId, attested: false)))
        device.unknownKeys = [staleAppleKeyId]
        let manager = makeManager()

        let headers = try await vote(manager)

        XCTAssertEqual(device.attestCalls.map(\.keyId), [staleAppleKeyId, device.generatedKeys[0]])
        let parts = try XCTUnwrap(ParsedAssertion(marker(headers)))
        XCTAssertEqual(parts.keyId, AppAttestWire.wireKeyId(fromAppleKeyId: device.generatedKeys[0]))
        XCTAssertNil(storage.date(for: .backoffUntil))
    }

    func testRejectedAttestationDiscardsTheKey() async throws {
        server.registerResults = [.failure(AppAttestServiceError.rejected)]
        let manager = makeManager()

        let sent = try await vote(manager)
        XCTAssertEqual(marker(sent), "v1.e.attest")

        XCTAssertEqual(storage.loadKey(), .none)
        XCTAssertNotNil(storage.date(for: .backoffUntil))
    }

    func testServerUnavailableKeepsTheKeyAndBacksOff() async throws {
        server.registerResults = [.failure(AppAttestServiceError.unavailable)]
        let manager = makeManager()

        let sent = try await vote(manager)
        XCTAssertEqual(marker(sent), "v1.e.attest")

        guard case .record(let kept) = storage.loadKey() else { return XCTFail("the key is kept") }
        XCTAssertFalse(kept.attested)
        XCTAssertEqual(storage.date(for: .backoffUntil), clock.now.addingTimeInterval(3600))
    }

    func testChallengeInvalidRetriesOnceWithANewChallengeAndTheSameKey() async throws {
        server.registerResults = [.failure(AppAttestServiceError.challengeInvalid)]
        let manager = makeManager()

        let headers = try await vote(manager)

        XCTAssertEqual(device.generatedKeys.count, 1)
        XCTAssertEqual(server.registrations.count, 2)
        XCTAssertEqual(server.registrations[0].keyId, server.registrations[1].keyId)
        XCTAssertNotEqual(server.registrations[0].challenge, server.registrations[1].challenge)
        XCTAssertTrue(marker(headers)?.hasPrefix("v1.a.") == true)
    }

    func testChallengeInvalidTwiceKeepsTheKeyAndBacksOff() async throws {
        server.registerResults = [
            .failure(AppAttestServiceError.challengeInvalid),
            .failure(AppAttestServiceError.challengeInvalid)
        ]
        let manager = makeManager()

        let sent = try await vote(manager)
        XCTAssertEqual(marker(sent), "v1.e.attest")

        XCTAssertEqual(server.registrations.count, 2)
        guard case .record(let kept) = storage.loadKey() else { return XCTFail("the key is kept") }
        XCTAssertFalse(kept.attested)
        XCTAssertNotNil(storage.date(for: .backoffUntil))
    }

    func testAppleRefusingASecondAttestationOfTheSameKeyGetsOneFreshKey() async throws {
        server.registerResults = [.failure(AppAttestServiceError.challengeInvalid)]
        device.attestErrors = [nil, DCError(.invalidKey)] // the retry with the same key is refused by Apple
        let manager = makeManager()

        let headers = try await vote(manager)

        XCTAssertEqual(device.generatedKeys.count, 2)
        XCTAssertEqual(
            try XCTUnwrap(ParsedAssertion(marker(headers))).keyId,
            AppAttestWire.wireKeyId(fromAppleKeyId: device.generatedKeys[1])
        )
    }

    func testNetworkFailureOnTheAttestChallengeBacksOff() async throws {
        server.challengeResults = [.failure(AppAttestServiceError.unavailable)]
        let manager = makeManager()

        let sent = try await vote(manager)
        XCTAssertEqual(marker(sent), "v1.e.challenge")
        XCTAssertEqual(storage.date(for: .backoffUntil), clock.now.addingTimeInterval(3600))
        let sentAgain = try await vote(manager)
        XCTAssertEqual(marker(sentAgain), "v1.e.challenge", "the reason holds through the back-off")
        XCTAssertEqual(server.challengePurposes, [.attest])
    }

    func testKeychainFailureSendsTheKeychainMarker() async throws {
        storage.failSaves = true
        let manager = makeManager()

        let sent = try await vote(manager)
        XCTAssertEqual(marker(sent), "v1.e.keychain")

        XCTAssertTrue(device.attestCalls.isEmpty, "an unsaved key is never attested")
        XCTAssertEqual(server.challengePurposes, [])
    }

    func testUnreadableStoredKeyIsDeletedAndReplaced() async throws {
        storage.stored = .unreadable
        let manager = makeManager()

        let headers = try await vote(manager)

        XCTAssertEqual(device.generatedKeys.count, 1)
        XCTAssertTrue(marker(headers)?.hasPrefix("v1.a.") == true)
    }

    func testConcurrentPreparesShareOneAttestation() async throws {
        let attestHold = hold()
        device.attestHold = attestHold
        let manager = makeManager()

        async let first: Void = manager.prepareIfNeeded()
        async let second: Void = manager.prepareIfNeeded()
        try await waitUntil { self.device.attestArrivals == 1 }
        attestHold.open()
        _ = await (first, second)

        XCTAssertEqual(device.generatedKeys.count, 1)
        XCTAssertEqual(device.attestCalls.count, 1)
        XCTAssertEqual(server.registrations.count, 1)
    }

    // MARK: - Assertion failures

    func testInvalidKeyDuringAnAssertionAttestsANewKeyAndRetriesOnce() async throws {
        let manager = makeManager()
        await manager.prepareIfNeeded()
        let oldAppleKeyId = device.generatedKeys[0]
        device.unknownKeys = [oldAppleKeyId] // reinstall or restore: the keychain entry survived, the key did not

        let headers = try await vote(manager)

        XCTAssertEqual(device.generatedKeys.count, 2)
        XCTAssertEqual(device.assertionCalls.map(\.keyId), [oldAppleKeyId, device.generatedKeys[1]])
        let parts = try XCTUnwrap(ParsedAssertion(marker(headers)))
        XCTAssertEqual(parts.keyId, AppAttestWire.wireKeyId(fromAppleKeyId: device.generatedKeys[1]))
        guard case .record(let record) = storage.loadKey() else { return XCTFail("the new key is stored") }
        XCTAssertEqual(record.keyId, parts.keyId)
        XCTAssertTrue(record.attested)
    }

    func testInvalidKeyIgnoresTheAttestationBackoff() async throws {
        let manager = makeManager()
        await manager.prepareIfNeeded()
        storage.setDate(clock.now.addingTimeInterval(1800), for: .backoffUntil)
        device.unknownKeys = [device.generatedKeys[0]]

        let headers = try await vote(manager)

        XCTAssertTrue(marker(headers)?.hasPrefix("v1.a.") == true)
        XCTAssertEqual(device.generatedKeys.count, 2)
    }

    func testOtherAssertionErrorsSendTheAssertMarker() async throws {
        let manager = makeManager()
        await manager.prepareIfNeeded()
        device.assertionErrors = [DCError(.unknownSystemFailure)]

        let sent = try await vote(manager)
        XCTAssertEqual(marker(sent), "v1.e.assert")
        XCTAssertEqual(device.generatedKeys.count, 1, "the key is kept")
        let sentAgain = try await vote(manager)
        XCTAssertTrue(marker(sentAgain)?.hasPrefix("v1.a.") == true)
    }

    func testAssertChallengeFailureSendsTheChallengeMarkerWithoutBackoff() async throws {
        let manager = makeManager()
        await manager.prepareIfNeeded()
        server.challengeResults = [.failure(URLError(.notConnectedToInternet))]

        let sent = try await vote(manager)
        XCTAssertEqual(marker(sent), "v1.e.challenge")
        XCTAssertNil(storage.date(for: .backoffUntil))
        let sentAgain = try await vote(manager)
        XCTAssertTrue(marker(sentAgain)?.hasPrefix("v1.a.") == true, "the next vote tries again")
    }

    // MARK: - Server rejections (enforce mode)

    func testUnknownKeyFromTheServerReattestsAndResendsOnce() async throws {
        let manager = makeManager()
        let recorder = SendRecorder()
        recorder.failures = [FakeServerRejection(code: "APP_ATTEST_UNKNOWN_KEY")]

        try await vote(manager, recorder: recorder)

        XCTAssertEqual(recorder.headers.count, 2)
        let first = try XCTUnwrap(ParsedAssertion(marker(recorder.headers[0])))
        let second = try XCTUnwrap(ParsedAssertion(marker(recorder.headers[1])))
        XCTAssertNotEqual(first.keyId, second.keyId, "a new key")
        XCTAssertEqual(device.generatedKeys.count, 2)
        XCTAssertEqual(server.registrations.count, 2)
    }

    func testUnknownKeyIsResentOnlyOnce() async throws {
        let manager = makeManager()
        let recorder = SendRecorder()
        let rejection = FakeServerRejection(code: "APP_ATTEST_UNKNOWN_KEY")
        recorder.failures = [rejection, rejection, rejection]

        do {
            try await vote(manager, recorder: recorder)
            XCTFail("the second rejection is the caller's")
        } catch {
            XCTAssertEqual(error as? FakeServerRejection, rejection)
        }
        XCTAssertEqual(recorder.headers.count, 2)
    }

    func testAttestFailedFromTheServerResendsOnceWithAFreshChallenge() async throws {
        let manager = makeManager()
        let recorder = SendRecorder()
        recorder.failures = [FakeServerRejection(code: "APP_ATTEST_FAILED")]

        try await vote(manager, recorder: recorder)

        XCTAssertEqual(recorder.headers.count, 2)
        let first = try XCTUnwrap(ParsedAssertion(marker(recorder.headers[0])))
        let second = try XCTUnwrap(ParsedAssertion(marker(recorder.headers[1])))
        XCTAssertEqual(first.keyId, second.keyId, "same key")
        XCTAssertNotEqual(first.challenge, second.challenge, "fresh challenge")
        XCTAssertEqual(device.generatedKeys.count, 1)
    }

    func testOtherServerCodesAndPlainErrorsAreNotRetried() async throws {
        let failures: [Error] = [
            FakeServerRejection(code: "APP_ATTEST_REQUIRED"),
            FakeServerRejection(code: "DEVICE_ACCOUNT_LIMIT"),
            FakeServerRejection(code: "APP_UPDATE_REQUIRED"),
            FakeServerRejection(code: "VOTE_DAILY_LIMIT"),
            URLError(.notConnectedToInternet)
        ]
        let manager = makeManager()
        for failure in failures {
            let recorder = SendRecorder()
            recorder.failures = [failure]
            do {
                try await vote(manager, recorder: recorder)
                XCTFail("\(failure) is rethrown")
            } catch {
                XCTAssertEqual(String(describing: error), String(describing: failure))
            }
            XCTAssertEqual(recorder.headers.count, 1, "\(failure)")
        }
    }

    func testAMarkerIsNeverResent() async throws {
        device.supported = false
        let manager = makeManager()
        let recorder = SendRecorder()
        recorder.failures = [FakeServerRejection(code: "APP_ATTEST_UNKNOWN_KEY")]

        do {
            try await vote(manager, recorder: recorder)
            XCTFail("rethrown")
        } catch {}
        XCTAssertEqual(recorder.headers.count, 1)
    }

    // MARK: - Unsupported, disabled, flag off

    func testUnsupportedDeviceSendsUInReleaseAndBInDebug() async throws {
        device.supported = false

        let release = makeManager { $0.isDebugBuild = false }
        let sent = try await vote(release)
        XCTAssertEqual(sent, ["X-Billboard-App-Attest": "v1.u"])
        let debug = makeManager { $0.isDebugBuild = true }
        let sentAgain = try await vote(debug)
        XCTAssertEqual(sentAgain, ["X-Billboard-App-Attest": "v1.b"])

        await release.prepareIfNeeded()
        XCTAssertTrue(device.generatedKeys.isEmpty)
        XCTAssertEqual(server.challengePurposes, [], "no network call on an unsupported device")
    }

    func testClientModeOffDisablesAttestationForSixHours() async throws {
        server.challengeResults = [.success(.off)]
        let manager = makeManager()

        let sent = try await vote(manager)
        XCTAssertEqual(marker(sent), "v1.e.disabled")
        XCTAssertEqual(storage.date(for: .disabledUntil), clock.now.addingTimeInterval(6 * 3600))

        clock.advance(by: 5 * 3600)
        let sentAgain = try await vote(manager)
        XCTAssertEqual(marker(sentAgain), "v1.e.disabled")
        await manager.prepareIfNeeded()
        XCTAssertEqual(server.challengePurposes, [.attest], "nothing is asked while disabled")

        clock.advance(by: 3600 + 1)
        let sentLater = try await vote(manager)
        XCTAssertTrue(marker(sentLater)?.hasPrefix("v1.a.") == true)
        XCTAssertEqual(server.challengePurposes, [.attest, .attest, .assert])
    }

    func testClientModeOffOnAnAssertChallengeDisablesToo() async throws {
        let manager = makeManager()
        await manager.prepareIfNeeded()
        server.challengeResults = [.success(.off)]

        let sent = try await vote(manager)
        XCTAssertEqual(marker(sent), "v1.e.disabled")
        let sentAgain = try await vote(manager)
        XCTAssertEqual(marker(sentAgain), "v1.e.disabled")
        XCTAssertEqual(server.challengePurposes, [.attest, .assert])
    }

    func testTimersSurviveARelaunchButNotAClockMovedBack() async throws {
        storage.setDate(clock.now.addingTimeInterval(1800), for: .backoffUntil)
        let relaunched = makeManager()
        let sent = try await vote(relaunched)
        XCTAssertEqual(marker(sent), "v1.e.attest", "a back-off from the last launch holds")
        XCTAssertTrue(device.generatedKeys.isEmpty)

        // A timer further ahead than its interval (the clock was moved back) is ignored.
        storage.setDate(clock.now.addingTimeInterval(30 * 24 * 3600), for: .backoffUntil)
        storage.setDate(clock.now.addingTimeInterval(30 * 24 * 3600), for: .disabledUntil)
        let sentAgain = try await vote(makeManager())
        XCTAssertTrue(marker(sentAgain)?.hasPrefix("v1.a.") == true)
    }

    func testFeatureFlagOffSendsNoHeaderAndNoAttestationMetadata() async throws {
        let manager = makeManager { $0.isEnabled = false }

        let headers = try await vote(manager)
        await manager.prepareIfNeeded()
        let metadata = await manager.signUpMetadata(email: "voter@example.com")

        XCTAssertEqual(headers, [:])
        XCTAssertEqual(metadata, ["billboardAppVersion": "1.2"])
        XCTAssertTrue(device.generatedKeys.isEmpty)
        XCTAssertEqual(server.challengePurposes, [])
        XCTAssertEqual(tokens.calls, 0)
    }

    // MARK: - Serialization (FIFO gate)

    func testFiveQuickVotesReachTheServerOneAtATimeWithIncreasingCounters() async throws {
        let manager = makeManager()
        let recorder = SendRecorder(delay: 0.03)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<5 {
                let voteBody = Data(#"{"billId":"BILLS-119hr\#(index)","feedback":"Yea"}"#.utf8)
                group.addTask {
                    try await manager.performProtected(method: "POST", path: "feedback", body: voteBody) { headers in
                        try await recorder.recordSlowly(headers)
                    }
                }
            }
            try await group.waitForAll()
        }

        XCTAssertEqual(recorder.headers.count, 5)
        XCTAssertEqual(recorder.maxInFlight, 1, "never two protected requests on the wire at once")
        let counters = try recorder.headers.map { try XCTUnwrap(ParsedAssertion(marker($0))).counter }
        XCTAssertEqual(counters, counters.sorted())
        XCTAssertEqual(Set(counters).count, 5, "strictly increasing: \(counters)")
        XCTAssertEqual(device.generatedKeys.count, 1)
        XCTAssertEqual(server.challengePurposes.filter { $0 == .attest }.count, 1)
        XCTAssertEqual(server.challengePurposes.filter { $0 == .assert }.count, 5)
    }

    func testTheWaitForTheRequestAheadIsCapped() async throws {
        let manager = makeManager { $0.gateWaitCap = 0.3 }
        await manager.prepareIfNeeded()
        let stuck = hold()
        let recorder = SendRecorder()

        let first = Task {
            try await manager.performProtected(method: "POST", path: "feedback", body: self.body) { headers in
                try recorder.record(headers)
                await stuck.wait()
            }
        }
        try await waitUntil { recorder.headers.count == 1 }

        let started = Date()
        let second = try await vote(manager, recorder: recorder)
        let waited = Date().timeIntervalSince(started)

        XCTAssertTrue(marker(second)?.hasPrefix("v1.a.") == true)
        XCTAssertGreaterThanOrEqual(waited, 0.25, "it waited for the request ahead")
        XCTAssertLessThan(waited, 1.5, "but no longer than the cap")
        stuck.open()
        try await first.value
    }

    func testAVoteWaitsForTheOneAheadWhenItFinishesInTime() async throws {
        let manager = makeManager { $0.gateWaitCap = 5 }
        await manager.prepareIfNeeded()
        let slow = hold()
        let recorder = SendRecorder()

        let first = Task {
            try await manager.performProtected(method: "POST", path: "feedback", body: self.body) { headers in
                try recorder.record(headers)
                await slow.wait()
                recorder.finish()
            }
        }
        try await waitUntil { recorder.headers.count == 1 }
        let second = Task { try await self.vote(manager, recorder: recorder) }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(recorder.headers.count, 1, "the second vote waits")

        slow.open()
        try await first.value
        _ = try await second.value
        XCTAssertEqual(recorder.headers.count, 2)
        XCTAssertEqual(recorder.finishedBeforeSecondSend, true)
    }

    // MARK: - Budgets

    func testAssertionBudgetSendsTheTimeoutMarker() async throws {
        let manager = makeManager { $0.assertBudget = 0.3 }
        await manager.prepareIfNeeded()
        device.assertionHold = hold()

        let started = Date()
        let headers = try await vote(manager)

        XCTAssertEqual(marker(headers), "v1.e.timeout")
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
    }

    func testAttestationBudgetSendsTheTimeoutMarkerAndTheKeyIsReadyLater() async throws {
        let manager = makeManager { $0.attestBudget = 0.3 }
        let attestHold = hold()
        device.attestHold = attestHold

        let started = Date()
        let sent = try await vote(manager)
        XCTAssertEqual(marker(sent), "v1.e.timeout")
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)

        // The attestation carries on and finishes in the background.
        attestHold.open()
        try await waitUntil {
            if case .record(let record) = self.storage.loadKey() { return record.attested }
            return false
        }
        let sentAgain = try await vote(manager)
        XCTAssertTrue(marker(sentAgain)?.hasPrefix("v1.a.") == true)
        XCTAssertEqual(device.attestCalls.count, 1)
    }

    func testPrepareNeverWaitsLongerThanTheBudget() async throws {
        let manager = makeManager { $0.attestBudget = 0.3 }
        device.attestHold = hold()

        let started = Date()
        await manager.prepareIfNeeded()

        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
    }

    // MARK: - Keychain

    func testTheKeySurvivesANewManagerInstance() async throws {
        let first = makeManager()
        await first.prepareIfNeeded()

        // A new launch (or a sign-out and another account): the manager has no reset, and the stored key is used.
        let second = makeManager()
        let headers = try await vote(second)

        XCTAssertEqual(device.generatedKeys.count, 1)
        XCTAssertEqual(device.attestCalls.count, 1)
        XCTAssertEqual(
            try XCTUnwrap(ParsedAssertion(marker(headers))).keyId,
            AppAttestWire.wireKeyId(fromAppleKeyId: device.generatedKeys[0])
        )
    }

    func testLiveStorageKeepsTheRecordInTheKeychainAndTheTimersInDefaults() throws {
        let suffix = UUID().uuidString
        let suiteName = "BillboardTests.appAttest.\(suffix)"
        let storage = LiveAppAttestStorage(keychainService: "BillboardTests.appAttest.\(suffix)", defaultsSuiteName: suiteName)
        defer {
            storage.deleteKey()
            UserDefaults().removePersistentDomain(forName: suiteName)
        }
        let record = AppAttestKeyRecord(keyId: "iInD91fLmBNJf1uM35LYM2FQ9DOE3FNDPD-tKlX7pkw", attested: true, environment: "production", attestedAt: "2026-10-08T12:00:00Z")

        XCTAssertEqual(LiveAppAttestStorage.keychainAccount, "appattest.v1")
        XCTAssertEqual(storage.loadKey(), .none)
        try XCTSkipUnless(storage.saveKey(record), "Keychain unavailable in this test host")
        XCTAssertEqual(storage.loadKey(), .record(record))

        // Other stores' sign-out cleanup (`deleteAll(accountPrefix:)`) cannot reach the key's account.
        KeychainStore(service: "BillboardTests.appAttest.\(suffix)", accessibility: .systemDefault)
            .deleteAll(accountPrefix: "verification_address_draft")
        XCTAssertEqual(storage.loadKey(), .record(record))

        storage.deleteKey()
        XCTAssertEqual(storage.loadKey(), .none)

        let until = Date(timeIntervalSince1970: 1_800_000_000)
        storage.setDate(until, for: .backoffUntil)
        XCTAssertEqual(storage.date(for: .backoffUntil), until)
        XCTAssertNil(storage.date(for: .disabledUntil))
        storage.setDate(nil, for: .backoffUntil)
        XCTAssertNil(storage.date(for: .backoffUntil))
    }

    func testKeyRecordJSONUsesTheDocumentedFields() throws {
        let record = AppAttestKeyRecord(keyId: "k", attested: true, environment: "development", attestedAt: "2026-10-08T12:00:00Z")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? NSDictionary)
        XCTAssertEqual(object, ["keyId": "k", "attested": true, "environment": "development", "attestedAt": "2026-10-08T12:00:00Z"])
        let unattested = try JSONDecoder().decode(AppAttestKeyRecord.self, from: Data(#"{"keyId":"k","attested":false}"#.utf8))
        XCTAssertEqual(unattested, AppAttestKeyRecord(keyId: "k", attested: false))
    }

    // MARK: - Sign-up metadata

    func testSignUpMetadataAssertsOverTheTrimmedLowerCasedEmail() async throws {
        tokens.token = Data([0xFB, 0xFF, 0xBF, 0x01])
        let manager = makeManager()

        let metadata = await manager.signUpMetadata(email: "  Voter@Example.COM ")

        XCTAssertEqual(Set(metadata.keys), ["billboardAppAttest", "billboardDeviceCheck", "billboardAppVersion"])
        XCTAssertEqual(metadata["billboardAppVersion"], "1.2")
        XCTAssertEqual(metadata["billboardDeviceCheck"], "+/+/AQ==", "standard base64")
        let parts = try XCTUnwrap(ParsedAssertion(metadata["billboardAppAttest"]))
        XCTAssertEqual(
            parts.clientData,
            Data((#"{"v":1,"purpose":"signup","challenge":""# + parts.challenge
                + #"","emailSha256":"0puTyx6EEEzOhT_C-BWU9wy3q4X5XbflbSR5XC8N4wg"}"#).utf8)
        )
        XCTAssertEqual(server.challengePurposes, [.attest, .assert], "one attestation, one assertion")
        XCTAssertEqual(device.assertionCalls.last?.clientDataHash, AppAttestWire.sha256(parts.clientData))
    }

    func testSignUpMetadataWithoutDeviceCheckOrAppAttestSupport() async throws {
        device.supported = false
        tokens.supported = false
        let manager = makeManager { $0.isDebugBuild = true }

        let metadata = await manager.signUpMetadata(email: "voter@example.com")

        XCTAssertEqual(metadata, ["billboardAppAttest": "v1.b", "billboardAppVersion": "1.2"])
        XCTAssertEqual(tokens.calls, 0)
    }

    func testSignUpMetadataLeavesOutAnInvalidVersionAndAFailedToken() async throws {
        tokens.error = DCError(.unknownSystemFailure)
        let manager = makeManager { $0.appVersion = nil }

        let metadata = await manager.signUpMetadata(email: "voter@example.com")

        XCTAssertEqual(Set(metadata.keys), ["billboardAppAttest"])
    }

    func testSignUpMetadataReturnsWithinItsBudget() async throws {
        device.attestHold = hold()
        tokens.hold = hold()
        let manager = makeManager {
            $0.signUpBudget = 0.4
            $0.attestBudget = 5
        }

        let started = Date()
        let metadata = await manager.signUpMetadata(email: "voter@example.com")

        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
        XCTAssertEqual(metadata, ["billboardAppAttest": "v1.e.timeout", "billboardAppVersion": "1.2"])
    }

    // MARK: - Helpers

    func testProviderFailureClassification() {
        XCTAssertEqual(AppAttestProviderFailure(DCError(.serverUnavailable)), .serverUnavailable)
        XCTAssertEqual(AppAttestProviderFailure(DCError(.invalidKey)), .invalidKey)
        XCTAssertEqual(AppAttestProviderFailure(NSError(domain: DCError.errorDomain, code: DCError.Code.invalidKey.rawValue)), .invalidKey)
        XCTAssertEqual(AppAttestProviderFailure(DCError(.invalidInput)), .otherDeviceCheck(DCError.Code.invalidInput.rawValue))
        XCTAssertEqual(AppAttestProviderFailure(URLError(.timedOut)), .other)
        XCTAssertFalse(AppAttestProviderFailure(DCError(.serverUnavailable)).discardsKey)
        XCTAssertTrue(AppAttestProviderFailure(DCError(.invalidKey)).discardsKey)
        XCTAssertTrue(AppAttestProviderFailure(DCError(.featureUnsupported)).discardsKey)
        XCTAssertFalse(AppAttestProviderFailure(URLError(.timedOut)).discardsKey)
    }

    func testDeadlineReturnsEvenWhenTheOperationIgnoresCancellation() async {
        let stuck = hold()
        let sleep: @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }

        let started = Date()
        let value = await AppAttestDeadline.value(within: 0.2, sleep: sleep) { () -> Int in
            await stuck.wait() // never checks cancellation
            return 1
        }
        XCTAssertNil(value)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)

        let quick = await AppAttestDeadline.value(within: 2, sleep: sleep) { 42 }
        XCTAssertEqual(quick, 42)
        let none = await AppAttestDeadline.value(within: 0, sleep: sleep) { 42 }
        XCTAssertNil(none, "no budget, no wait")
    }

    func testTheSharedManagerIsTheDefaultAndCanBeSwapped() {
        XCTAssertTrue(AppAttestManager.current as AnyObject === AppAttestManager.shared)
        let swapped = makeManager { $0.isEnabled = false }
        AppAttestManager.$current.withValue(swapped) {
            XCTAssertTrue(AppAttestManager.current as AnyObject === swapped)
        }
    }

    private func waitUntil(
        timeout: TimeInterval = 3,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("condition not met in \(timeout)s", file: file, line: line)
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

// MARK: - Fakes

/// A parsed `v1.a` marker. Fake assertions are a 4-byte big-endian counter followed by the clientData hash.
private struct ParsedAssertion {
    let keyId: String
    let clientData: Data
    let assertion: Data
    let json: [String: Any]

    init?(_ marker: String?) {
        guard let marker, marker.hasPrefix("v1.a.") else { return nil }
        let segments = marker.dropFirst("v1.a.".count).split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard segments.count == 3,
              let clientData = AppAttestWire.data(base64URL: segments[1]),
              let assertion = AppAttestWire.data(base64URL: segments[2]),
              assertion.count == 36,
              let json = try? JSONSerialization.jsonObject(with: clientData) as? [String: Any] else {
            return nil
        }
        keyId = segments[0]
        self.clientData = clientData
        self.assertion = assertion
        self.json = json
    }

    var challenge: String { json["challenge"] as? String ?? "" }
    var counter: UInt32 { assertion.prefix(4).reduce(0) { $0 << 8 | UInt32($1) } }
}

private struct FakeServerRejection: Error, Equatable {
    let code: String
}

/// Suspends callers of `wait()` until `open()`; safe from any thread.
private final class AsyncHold: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if isOpen {
                lock.unlock()
                continuation.resume()
                return
            }
            waiters.append(continuation)
            lock.unlock()
        }
    }

    func open() {
        lock.lock()
        isOpen = true
        let pending = waiters
        waiters = []
        lock.unlock()
        pending.forEach { $0.resume() }
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_791_460_800) // 2026-10-08

    var now: Date { lock.withLock { current } }

    func advance(by seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }
}

/// Records each send's headers; throws the queued failures in order.
private final class SendRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let delay: TimeInterval
    private var recorded: [[String: String]] = []
    private var inFlight = 0
    private var maxConcurrent = 0
    private var finishedCount = 0
    private var finishedBeforeSecond: Bool?
    var failures: [Error] = []

    init(delay: TimeInterval = 0) {
        self.delay = delay
    }

    var headers: [[String: String]] { lock.withLock { recorded } }
    var maxInFlight: Int { lock.withLock { maxConcurrent } }
    var finishedBeforeSecondSend: Bool? { lock.withLock { finishedBeforeSecond } }

    func record(_ headers: [String: String]) throws {
        let failure: Error? = lock.withLock {
            recorded.append(headers)
            if recorded.count == 2 { finishedBeforeSecond = finishedCount >= 1 }
            return failures.isEmpty ? nil : failures.removeFirst()
        }
        if let failure { throw failure }
    }

    func finish() {
        lock.withLock { finishedCount += 1 }
    }

    func recordSlowly(_ headers: [String: String]) async throws {
        lock.withLock {
            inFlight += 1
            maxConcurrent = max(maxConcurrent, inFlight)
        }
        try record(headers)
        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        lock.withLock { inFlight -= 1 }
    }
}

/// App Attest on a fake device: keys are 32 bytes of their sequence number; the attestation object names the
/// key; each assertion is the key's next counter (4 bytes) followed by the clientData hash.
private final class FakeAppAttestDevice: AppAttestProviding, @unchecked Sendable {
    struct Call {
        let keyId: String
        let clientDataHash: Data
    }

    private let lock = NSLock()
    private var supportedValue = true
    private var keys: [String] = []
    private var attests: [Call] = []
    private var assertions: [Call] = []
    private var counters: [String: UInt32] = [:]
    private var arrivals = 0
    private var queuedAttestErrors: [Error?] = []
    private var queuedAssertionErrors: [Error] = []
    private var unknown: Set<String> = []
    private var attestHoldValue: AsyncHold?
    private var assertionHoldValue: AsyncHold?

    var supported: Bool {
        get { lock.withLock { supportedValue } }
        set { lock.withLock { supportedValue = newValue } }
    }
    /// attestKey outcomes in order (nil succeeds); later calls succeed.
    var attestErrors: [Error?] {
        get { lock.withLock { queuedAttestErrors } }
        set { lock.withLock { queuedAttestErrors = newValue } }
    }
    var assertionErrors: [Error] {
        get { lock.withLock { queuedAssertionErrors } }
        set { lock.withLock { queuedAssertionErrors = newValue } }
    }
    /// Apple key IDs the Secure Enclave no longer has (`invalidKey`).
    var unknownKeys: Set<String> {
        get { lock.withLock { unknown } }
        set { lock.withLock { unknown = newValue } }
    }
    var attestHold: AsyncHold? {
        get { lock.withLock { attestHoldValue } }
        set { lock.withLock { attestHoldValue = newValue } }
    }
    var assertionHold: AsyncHold? {
        get { lock.withLock { assertionHoldValue } }
        set { lock.withLock { assertionHoldValue = newValue } }
    }
    var generatedKeys: [String] { lock.withLock { keys } }
    var attestCalls: [Call] { lock.withLock { attests } }
    var assertionCalls: [Call] { lock.withLock { assertions } }
    var attestArrivals: Int { lock.withLock { arrivals } }

    var isSupported: Bool { supported }

    static func attestationObject(for keyId: String) -> Data {
        Data("attestation:\(keyId)".utf8)
    }

    static func assertion(counter: UInt32, clientDataHash: Data) -> Data {
        withUnsafeBytes(of: counter.bigEndian) { Data($0) } + clientDataHash
    }

    func generateKey() async throws -> String {
        lock.withLock {
            let keyId = Data(repeating: UInt8(keys.count + 1), count: 32).base64EncodedString()
            keys.append(keyId)
            return keyId
        }
    }

    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data {
        let (hold, failure): (AsyncHold?, Error?) = lock.withLock {
            arrivals += 1
            attests.append(Call(keyId: keyId, clientDataHash: clientDataHash))
            if unknown.contains(keyId) { return (attestHoldValue, DCError(.invalidKey)) }
            let queued = queuedAttestErrors.isEmpty ? nil : queuedAttestErrors.removeFirst()
            return (attestHoldValue, queued)
        }
        await hold?.wait()
        if let failure { throw failure }
        return Self.attestationObject(for: keyId)
    }

    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data {
        let hold = lock.withLock { assertionHoldValue }
        await hold?.wait()
        return try lock.withLock {
            assertions.append(Call(keyId: keyId, clientDataHash: clientDataHash))
            if unknown.contains(keyId) { throw DCError(.invalidKey) }
            if !queuedAssertionErrors.isEmpty { throw queuedAssertionErrors.removeFirst() }
            let counter = (counters[keyId] ?? 0) + 1
            counters[keyId] = counter
            return Self.assertion(counter: counter, clientDataHash: clientDataHash)
        }
    }
}

private final class FakeDeviceTokens: DeviceTokenProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var supportedValue = true
    private var tokenValue = Data([1, 2, 3])
    private var errorValue: Error?
    private var holdValue: AsyncHold?
    private var callCount = 0

    var supported: Bool {
        get { lock.withLock { supportedValue } }
        set { lock.withLock { supportedValue = newValue } }
    }
    var token: Data {
        get { lock.withLock { tokenValue } }
        set { lock.withLock { tokenValue = newValue } }
    }
    var error: Error? {
        get { lock.withLock { errorValue } }
        set { lock.withLock { errorValue = newValue } }
    }
    var hold: AsyncHold? {
        get { lock.withLock { holdValue } }
        set { lock.withLock { holdValue = newValue } }
    }
    var calls: Int { lock.withLock { callCount } }

    var isSupported: Bool { supported }

    func generateToken() async throws -> Data {
        let (hold, error, token): (AsyncHold?, Error?, Data) = lock.withLock {
            callCount += 1
            return (holdValue, errorValue, tokenValue)
        }
        await hold?.wait()
        if let error { throw error }
        return token
    }
}

/// The App Attest routes: unique valid challenges and successful registrations unless results are queued.
private final class FakeAppAttestServer: AppAttestBackend, @unchecked Sendable {
    struct Registration {
        let keyId: String
        let challenge: String
        let attestation: Data
    }

    private let lock = NSLock()
    private var purposes: [AppAttestChallengePurpose] = []
    private var issued: [String] = []
    private var registered: [Registration] = []
    private var queuedChallengeResults: [Result<AppAttestChallengeResult, Error>] = []
    private var queuedRegisterResults: [Result<AppAttestRegistration, Error>] = []

    /// Answers for the next challenge requests; later ones issue a fresh challenge.
    var challengeResults: [Result<AppAttestChallengeResult, Error>] {
        get { lock.withLock { queuedChallengeResults } }
        set { lock.withLock { queuedChallengeResults = newValue } }
    }
    /// Answers for the next registrations; later ones succeed (`attested`, production).
    var registerResults: [Result<AppAttestRegistration, Error>] {
        get { lock.withLock { queuedRegisterResults } }
        set { lock.withLock { queuedRegisterResults = newValue } }
    }
    var challengePurposes: [AppAttestChallengePurpose] { lock.withLock { purposes } }
    var issuedChallenges: [String] { lock.withLock { issued } }
    var registrations: [Registration] { lock.withLock { registered } }

    func challenge(purpose: AppAttestChallengePurpose) async throws -> AppAttestChallengeResult {
        let result: Result<AppAttestChallengeResult, Error> = lock.withLock {
            purposes.append(purpose)
            if !queuedChallengeResults.isEmpty { return queuedChallengeResults.removeFirst() }
            let challenge = AppAttestWire.base64URL(Data(repeating: UInt8(100 + issued.count), count: 32))
            issued.append(challenge)
            return .success(.on(challenge: challenge, expiresAt: "2026-10-08T12:05:00.000Z"))
        }
        return try result.get()
    }

    func register(keyId: String, challenge: String, attestation: Data) async throws -> AppAttestRegistration {
        let result: Result<AppAttestRegistration, Error> = lock.withLock {
            registered.append(Registration(keyId: keyId, challenge: challenge, attestation: attestation))
            if !queuedRegisterResults.isEmpty { return queuedRegisterResults.removeFirst() }
            return .success(AppAttestRegistration(status: .attested, environment: "production"))
        }
        return try result.get()
    }

    func serverCode(of error: any Error) async -> String? {
        (error as? FakeServerRejection)?.code
    }
}

private final class InMemoryAppAttestStorage: AppAttestStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: AppAttestStoredKey = .none
    private var dates: [AppAttestTimer: Date] = [:]
    private var failSavesValue = false

    var stored: AppAttestStoredKey {
        get { lock.withLock { storedValue } }
        set { lock.withLock { storedValue = newValue } }
    }
    var failSaves: Bool {
        get { lock.withLock { failSavesValue } }
        set { lock.withLock { failSavesValue = newValue } }
    }

    func loadKey() -> AppAttestStoredKey { stored }

    func saveKey(_ record: AppAttestKeyRecord) -> Bool {
        lock.withLock {
            guard !failSavesValue else { return false }
            storedValue = .record(record)
            return true
        }
    }

    func deleteKey() { stored = .none }

    func date(for timer: AppAttestTimer) -> Date? {
        lock.withLock { dates[timer] }
    }

    func setDate(_ date: Date?, for timer: AppAttestTimer) {
        lock.withLock { dates[timer] = date }
    }
}
