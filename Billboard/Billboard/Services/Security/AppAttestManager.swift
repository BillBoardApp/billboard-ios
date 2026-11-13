import Foundation
import os

/// App Attest for the whole app (spec C3 3.10, spec D 2.8.1). Services and `AuthManager` call
/// `AppAttestManager.current`; tests swap it with `AppAttestManager.$current.withValue(fake) { ... }`.
///
/// The client never blocks a vote or a sign-up: every failure still sends, with a `v1.e.<code>` marker,
/// and the server records outcomes in watch mode and refuses in enforce mode.
nonisolated protocol AppAttestManaging: Sendable {
    /// Makes sure this install has an attested key. Called by `AuthManager` once the auth state is first known
    /// and again before sign-up. Never throws; waits at most 8 s (the attestation carries on in the background).
    func prepareIfNeeded() async

    /// Sends one protected request (`POST /feedback`) with an `X-Billboard-App-Attest` header.
    ///
    /// Protected requests run one at a time across the app, so assertion counters reach the server in order
    /// (the wait is capped at 10 s). The header is an assertion bound to `method`, `path` and the SHA-256 of
    /// `body`, or a marker when none can be made. `send` must send exactly `body` and add `headers` to the
    /// request; it is called once, or twice when the server answers `APP_ATTEST_UNKNOWN_KEY` (new key) or
    /// `APP_ATTEST_FAILED` (fresh challenge). Its error is rethrown. With `FeatureFlags.appAttestClient` off,
    /// `send` gets no header. The legacy `/setFeedback` fallback after a 404 is sent outside this call, without
    /// the header (C3 3.10).
    ///
    /// `send` is `@concurrent` (it runs off the actor) so that fakes in the unit-test target, which is built
    /// without `NonisolatedNonsendingByDefault`, can declare the same plain `@Sendable` closure type.
    ///
    /// - Parameters:
    ///   - method: The HTTP method, such as `"POST"`.
    ///   - path: The API resource, with or without the leading slash (`"feedback"` and `"/feedback"` agree).
    ///   - body: The exact bytes `send` sends.
    @discardableResult
    func performProtected<T: Sendable>(
        method: String,
        path: String,
        body: Data?,
        send: @concurrent @Sendable (_ headers: [String: String]) async throws -> T
    ) async throws -> T

    /// The Cognito `ClientMetadata` for `Amplify.Auth.signUp` (`AWSAuthSignUpOptions(metadata:)`):
    /// `billboardAppAttest` (an assertion over the trimmed, lower-cased email, or a marker),
    /// `billboardDeviceCheck` (when the device supports DeviceCheck) and `billboardAppVersion`.
    /// Takes at most 6 s and always returns a map; with `FeatureFlags.appAttestClient` off it holds only the version.
    func signUpMetadata(email: String) async -> [String: String]
}

/// The live client: one key per install in the Keychain, attested once, then one assertion per protected
/// request. An `actor`, so it runs off the main actor despite the module's default isolation.
actor AppAttestManager: AppAttestManaging {
    /// Budgets and back-offs (C3 3.10). Tests shorten them.
    nonisolated struct Configuration: Sendable {
        /// `FeatureFlags.appAttestClient`: off sends no header and no attestation metadata.
        var isEnabled = FeatureFlags.appAttestClient
        /// Debug builds on an unsupported device (the Simulator) send `v1.b`; Release builds send `v1.u`.
        var isDebugBuild = AppAttestManager.isDebugBuild
        /// `billboardAppVersion` at sign-up.
        var appVersion = AppAttestWire.currentAppVersion
        /// The longest a caller waits for a key to be generated and attested.
        var attestBudget: TimeInterval = 8
        /// The longest a caller waits for a challenge and an assertion once the key is ready.
        var assertBudget: TimeInterval = 3
        /// The longest a protected request waits for the one before it.
        var gateWaitCap: TimeInterval = 10
        /// The longest `signUpMetadata(email:)` takes.
        var signUpBudget: TimeInterval = 6
        /// The pause after a failed attestation (network, 503, rejection, Keychain).
        var backoffInterval: TimeInterval = 60 * 60
        /// The pause after the server answers `clientMode: "off"`.
        var disabledInterval: TimeInterval = 6 * 60 * 60

        init() {}
    }

    /// The seams the manager works through.
    nonisolated struct Dependencies: Sendable {
        var attest: any AppAttestProviding
        var deviceToken: any DeviceTokenProviding
        var backend: any AppAttestBackend
        var storage: any AppAttestStoring
        /// Wall-clock time, for the persisted back-off timers.
        var now: @Sendable () -> Date
        /// Sleeps for a number of seconds; throws when cancelled. Budgets use it.
        var sleep: @Sendable (TimeInterval) async throws -> Void

        static var live: Dependencies {
            Dependencies(
                attest: LiveAppAttestProvider(),
                deviceToken: LiveDeviceTokenProvider(),
                backend: LiveAppAttestBackend(),
                storage: LiveAppAttestStorage(),
                now: { Date() },
                sleep: { seconds in try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000)) }
            )
        }
    }

    nonisolated static let isDebugBuild: Bool = {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }()

    nonisolated static let shared = AppAttestManager()

    /// The manager services use. Tests replace it for one call tree.
    @TaskLocal static var current: any AppAttestManaging = AppAttestManager.shared

    private let configuration: Configuration
    private let dependencies: Dependencies

    // Key
    private var cachedRecord: AppAttestKeyRecord?
    private var didLoadRecord = false
    private var attestation: Task<KeyState, Never>?
    private var lastAttestFailure: AppAttestClientErrorCode = .attest

    // FIFO gate for protected requests
    private var gateBusy = false
    private var gateWaiters: [GateWaiter] = []
    private var nextWaiterID: UInt64 = 0

    init(configuration: Configuration = Configuration(), dependencies: Dependencies = .live) {
        self.configuration = configuration
        self.dependencies = dependencies
    }

    // MARK: - AppAttestManaging

    func prepareIfNeeded() async {
        guard configuration.isEnabled else { return }
        let state = await keyState(ignoringBackoff: false)
        if case .unavailable(let code) = state {
            AppLog.api.info("[AppAttest] prepare: no attested key (\(code.rawValue, privacy: .public))")
        }
    }

    @discardableResult
    func performProtected<T: Sendable>(
        method: String,
        path: String,
        body: Data?,
        send: @concurrent @Sendable (_ headers: [String: String]) async throws -> T
    ) async throws -> T {
        guard configuration.isEnabled else { return try await send([:]) }

        let holdsGate = await acquireGate(maxWait: configuration.gateWaitCap)
        defer { if holdsGate { releaseGate() } }

        let purpose = AssertionPurpose.request(
            method: AppAttestWire.normalizedMethod(method),
            path: AppAttestWire.normalizedPath(path),
            bodySha256: AppAttestWire.bodySha256(body)
        )
        let first = await marker(for: purpose, ignoringBackoff: false)
        do {
            return try await send(first.headers)
        } catch {
            // The server rejects only in enforce mode, and only an assertion (C3 3.10); in watch mode it records the outcome.
            guard case .assertion(let keyId, _, _) = first,
                  let code = await dependencies.backend.serverCode(of: error).flatMap(AppAttestServerCode.init(rawValue:)) else {
                throw error
            }
            let second: AppAttestMarker
            switch code {
            case .unknownKey:
                AppLog.api.info("[AppAttest] server does not know key \(Self.prefix(keyId), privacy: .public); attesting a new key and resending once")
                discardKey(keyId)
                second = await marker(for: purpose, ignoringBackoff: true)
            case .failed:
                AppLog.api.info("[AppAttest] assertion refused; resending once with a fresh challenge")
                second = await marker(for: purpose, ignoringBackoff: false)
            default:
                throw error
            }
            return try await send(second.headers)
        }
    }

    func signUpMetadata(email: String) async -> [String: String] {
        var metadata: [String: String] = [:]
        if let version = configuration.appVersion {
            metadata[AppAttestWire.MetadataKey.appVersion] = version
        }
        guard configuration.isEnabled else { return metadata }

        let budget = configuration.signUpBudget
        let clock = ContinuousClock()
        let start = clock.now
        let deviceToken = dependencies.deviceToken
        let sleep = dependencies.sleep
        let tokenTask = Task {
            await AppAttestDeadline.value(within: budget, sleep: sleep) {
                await Self.deviceCheckToken(deviceToken)
            } ?? nil
        }

        // Ordered after any vote in flight, so its counter reaches the server first.
        let holdsGate = await acquireGate(maxWait: min(configuration.gateWaitCap, budget))
        let remaining = budget - Self.seconds(clock.now - start)
        let purpose = AssertionPurpose.signUp(emailSha256: AppAttestWire.emailSha256(email))
        let marker = await AppAttestDeadline.value(within: remaining, sleep: sleep) {
            await self.marker(for: purpose, ignoringBackoff: false)
        } ?? .clientError(.timeout)
        if holdsGate { releaseGate() }

        metadata[AppAttestWire.MetadataKey.appAttest] = marker.value
        if let token = await tokenTask.value {
            metadata[AppAttestWire.MetadataKey.deviceCheck] = token
        }
        return metadata
    }

    // MARK: - Marker

    private nonisolated enum AssertionPurpose: Sendable {
        case request(method: String, path: String, bodySha256: String)
        case signUp(emailSha256: String)

        func clientData(challenge: String) -> Data {
            switch self {
            case let .request(method, path, bodySha256):
                return AppAttestWire.requestClientData(challenge: challenge, method: method, path: path, bodySha256: bodySha256)
            case let .signUp(emailSha256):
                return AppAttestWire.signUpClientData(challenge: challenge, emailSha256: emailSha256)
            }
        }
    }

    private nonisolated enum AssertionAttempt: Sendable {
        case marker(AppAttestMarker)
        /// `DCError.invalidKey`: the Secure Enclave no longer has the key (reinstall, restore).
        case invalidKey
    }

    /// An assertion for `purpose`, or the marker that says why there is none. Waits at most 8 s for the key
    /// and 3 s for the assertion; after `invalidKey`, one new key and one more assertion within 8 s.
    private func marker(for purpose: AssertionPurpose, ignoringBackoff: Bool) async -> AppAttestMarker {
        let record: AppAttestKeyRecord
        switch await keyState(ignoringBackoff: ignoringBackoff) {
        case .unsupported:
            return configuration.isDebugBuild ? .debugBypass : .unsupported
        case .unavailable(let code):
            return .clientError(code)
        case .ready(let ready):
            record = ready
        }

        let sleep = dependencies.sleep
        guard let attempt = await AppAttestDeadline.value(within: configuration.assertBudget, sleep: sleep, operation: {
            await self.makeAssertion(record: record, purpose: purpose)
        }) else {
            return .clientError(.timeout)
        }
        switch attempt {
        case .marker(let marker):
            return marker
        case .invalidKey:
            AppLog.api.info("[AppAttest] key \(Self.prefix(record.keyId), privacy: .public) is gone; attesting a new key")
            discardKey(record.keyId)
            return await AppAttestDeadline.value(within: configuration.attestBudget, sleep: sleep) {
                await self.markerWithNewKey(for: purpose)
            } ?? .clientError(.timeout)
        }
    }

    private func markerWithNewKey(for purpose: AssertionPurpose) async -> AppAttestMarker {
        switch await keyState(ignoringBackoff: true) {
        case .unsupported:
            return configuration.isDebugBuild ? .debugBypass : .unsupported
        case .unavailable(let code):
            return .clientError(code)
        case .ready(let record):
            switch await makeAssertion(record: record, purpose: purpose) {
            case .marker(let marker):
                return marker
            case .invalidKey:
                discardKey(record.keyId)
                return .clientError(.assert)
            }
        }
    }

    private func makeAssertion(record: AppAttestKeyRecord, purpose: AssertionPurpose) async -> AssertionAttempt {
        let challenge: String
        do {
            switch try await dependencies.backend.challenge(purpose: .assert) {
            case .off:
                disableAttestation()
                return .marker(.clientError(.disabled))
            case .on(let value, _):
                challenge = value
            }
        } catch {
            AppLog.api.info("[AppAttest] assert challenge failed: \(String(describing: error), privacy: .private)")
            return .marker(.clientError(.challenge))
        }

        guard let appleKeyId = AppAttestWire.appleKeyId(fromWireKeyId: record.keyId) else { return .invalidKey }
        let clientData = purpose.clientData(challenge: challenge)
        do {
            let assertion = try await dependencies.attest.generateAssertion(
                appleKeyId,
                clientDataHash: AppAttestWire.sha256(clientData)
            )
            return .marker(.validatedAssertion(keyId: record.keyId, clientData: clientData, assertion: assertion))
        } catch {
            if AppAttestProviderFailure(error) == .invalidKey { return .invalidKey }
            AppLog.api.error("[AppAttest] generateAssertion failed: \(String(describing: error), privacy: .private)")
            return .marker(.clientError(.assert))
        }
    }

    // MARK: - Key

    private nonisolated enum KeyState: Sendable, Equatable {
        case ready(AppAttestKeyRecord)
        case unsupported
        case unavailable(AppAttestClientErrorCode)
    }

    /// The attested key, attesting one first when needed (joining an attestation already running). Waits at
    /// most `attestBudget`; the attestation itself is never cancelled and finishes in the background.
    private func keyState(ignoringBackoff: Bool) async -> KeyState {
        guard dependencies.attest.isSupported else { return .unsupported }
        if isActive(.disabledUntil, maxInterval: configuration.disabledInterval) { return .unavailable(.disabled) }
        if let record = currentRecord(), record.attested { return .ready(record) }

        let task: Task<KeyState, Never>
        if let running = attestation {
            task = running
        } else {
            if !ignoringBackoff, isActive(.backoffUntil, maxInterval: configuration.backoffInterval) {
                return .unavailable(lastAttestFailure)
            }
            task = Task {
                let state = await self.runAttestation()
                self.attestation = nil
                return state
            }
            attestation = task
        }
        return await AppAttestDeadline.value(within: configuration.attestBudget, sleep: dependencies.sleep) {
            await task.value
        } ?? .unavailable(.timeout)
    }

    /// generateKey → challenge (attest) → attestKey → `POST /app-attest/attest` → save `attested: true`,
    /// with C3 3.10's failure handling.
    private func runAttestation() async -> KeyState {
        var record: AppAttestKeyRecord
        // A stored key may already have been passed to attestKey (an earlier attempt, or an earlier install of
        // the app), and so may a key retried after APP_ATTEST_CHALLENGE_INVALID; when Apple refuses such a key
        // it is replaced once with a fresh one in the same attempt.
        var keyWasUsed: Bool
        if let stored = currentRecord() {
            if stored.attested { return .ready(stored) }
            record = stored
            keyWasUsed = true
        } else {
            guard let fresh = await generateKey() else { return .unavailable(lastAttestFailure) }
            record = fresh
            keyWasUsed = false
        }
        var replacedUsedKey = false
        var retriedChallenge = false

        while true {
            guard let appleKeyId = AppAttestWire.appleKeyId(fromWireKeyId: record.keyId) else {
                discardKey(record.keyId)
                return backOff(.attest, reason: "stored key ID unreadable")
            }

            let challenge: String
            do {
                switch try await dependencies.backend.challenge(purpose: .attest) {
                case .off:
                    disableAttestation()
                    return .unavailable(.disabled)
                case .on(let value, _):
                    challenge = value
                }
            } catch {
                return backOff(.challenge, reason: "attest challenge failed")
            }

            let attestationObject: Data
            do {
                attestationObject = try await dependencies.attest.attestKey(
                    appleKeyId,
                    clientDataHash: AppAttestWire.attestationClientDataHash(challenge: challenge)
                )
            } catch {
                let failure = AppAttestProviderFailure(error)
                guard failure.discardsKey else {
                    // serverUnavailable (Apple) or not a DeviceCheck error: keep the key, try again later.
                    return backOff(.attest, reason: "attestKey failed, key kept: \(failure)")
                }
                discardKey(record.keyId)
                guard keyWasUsed, !replacedUsedKey else {
                    return backOff(.attest, reason: "attestKey failed, key discarded: \(failure)")
                }
                replacedUsedKey = true
                guard let fresh = await generateKey() else { return .unavailable(lastAttestFailure) }
                record = fresh
                keyWasUsed = false
                retriedChallenge = false
                continue
            }

            do {
                let registration = try await dependencies.backend.register(
                    keyId: record.keyId,
                    challenge: challenge,
                    attestation: attestationObject
                )
                return markAttested(record, environment: registration.environment)
            } catch AppAttestServiceError.challengeInvalid where !retriedChallenge {
                retriedChallenge = true
                keyWasUsed = true
                continue
            } catch AppAttestServiceError.rejected {
                discardKey(record.keyId)
                return backOff(.attest, reason: "attestation rejected; key discarded")
            } catch {
                return backOff(.attest, reason: "attestation not registered, key kept: \(error)")
            }
        }
    }

    private func generateKey() async -> AppAttestKeyRecord? {
        let appleKeyId: String
        do {
            appleKeyId = try await dependencies.attest.generateKey()
        } catch {
            _ = backOff(.attest, reason: "generateKey failed: \(AppAttestProviderFailure(error))")
            return nil
        }
        guard let keyId = AppAttestWire.wireKeyId(fromAppleKeyId: appleKeyId) else {
            _ = backOff(.attest, reason: "generateKey returned an unreadable key ID")
            return nil
        }
        let record = AppAttestKeyRecord(keyId: keyId, attested: false)
        guard dependencies.storage.saveKey(record) else {
            // An unsaved key would be lost at the next launch and attested again: stop instead.
            _ = backOff(.keychain, reason: "the new key could not be saved")
            return nil
        }
        cachedRecord = record
        didLoadRecord = true
        return record
    }

    private func markAttested(_ record: AppAttestKeyRecord, environment: String) -> KeyState {
        let attested = AppAttestKeyRecord(
            keyId: record.keyId,
            attested: true,
            environment: environment,
            attestedAt: ISO8601DateFormatter().string(from: dependencies.now())
        )
        if !dependencies.storage.saveKey(attested) {
            // The server knows the key; this launch keeps using it and the next one attests it again
            // (`already_attested`).
            AppLog.store.error("[AppAttest] attested key could not be saved")
        }
        cachedRecord = attested
        didLoadRecord = true
        dependencies.storage.setDate(nil, for: .backoffUntil)
        lastAttestFailure = .attest
        AppLog.api.info("[AppAttest] key \(Self.prefix(record.keyId), privacy: .public) attested (\(environment, privacy: .public))")
        return .ready(attested)
    }

    private func currentRecord() -> AppAttestKeyRecord? {
        if !didLoadRecord {
            didLoadRecord = true
            switch dependencies.storage.loadKey() {
            case .none:
                cachedRecord = nil
            case .record(let record) where AppAttestWire.appleKeyId(fromWireKeyId: record.keyId) != nil:
                cachedRecord = record
            case .record, .unreadable:
                AppLog.store.error("[AppAttest] stored key unreadable; deleting it")
                dependencies.storage.deleteKey()
                cachedRecord = nil
            }
        }
        return cachedRecord
    }

    /// Deletes the stored key when it is still `keyId` (another path may have replaced it meanwhile).
    private func discardKey(_ keyId: String) {
        guard currentRecord()?.keyId == keyId else { return }
        dependencies.storage.deleteKey()
        cachedRecord = nil
    }

    // MARK: - Timers

    private func backOff(_ code: AppAttestClientErrorCode, reason: String) -> KeyState {
        lastAttestFailure = code
        dependencies.storage.setDate(dependencies.now().addingTimeInterval(configuration.backoffInterval), for: .backoffUntil)
        AppLog.api.info("[AppAttest] backing off: \(reason, privacy: .public)")
        return .unavailable(code)
    }

    private func disableAttestation() {
        AppLog.api.info("[AppAttest] server client mode off; pausing attestation")
        dependencies.storage.setDate(dependencies.now().addingTimeInterval(configuration.disabledInterval), for: .disabledUntil)
    }

    /// True while `timer` is in the future. A time further ahead than `maxInterval` (the clock was moved back)
    /// counts as expired, so a changed clock cannot pause attestation for longer than designed.
    private func isActive(_ timer: AppAttestTimer, maxInterval: TimeInterval) -> Bool {
        guard let until = dependencies.storage.date(for: timer) else { return false }
        let remaining = until.timeIntervalSince(dependencies.now())
        return remaining > 0 && remaining <= maxInterval
    }

    // MARK: - FIFO gate

    private nonisolated struct GateWaiter {
        let id: UInt64
        let continuation: CheckedContinuation<Bool, Never>
    }

    /// Waits for the protected request ahead to finish, at most `maxWait`. True when this caller now holds the
    /// gate and must `releaseGate()`; false when it went ahead after the cap (C3: worst case one
    /// `counter_not_increasing`).
    private func acquireGate(maxWait: TimeInterval) async -> Bool {
        guard gateBusy else {
            gateBusy = true
            return true
        }
        guard maxWait > 0 else { return false }
        nextWaiterID &+= 1
        let id = nextWaiterID
        let sleep = dependencies.sleep
        let timer = Task { [weak self] in
            try? await sleep(maxWait)
            await self?.expireWaiter(id)
        }
        let granted = await withCheckedContinuation { continuation in
            gateWaiters.append(GateWaiter(id: id, continuation: continuation))
        }
        timer.cancel()
        if !granted {
            AppLog.api.info("[AppAttest] waited \(maxWait, privacy: .public)s for the previous protected request; sending anyway")
        }
        return granted
    }

    private func expireWaiter(_ id: UInt64) {
        guard let index = gateWaiters.firstIndex(where: { $0.id == id }) else { return }
        gateWaiters.remove(at: index).continuation.resume(returning: false)
    }

    private func releaseGate() {
        if gateWaiters.isEmpty {
            gateBusy = false
        } else {
            gateWaiters.removeFirst().continuation.resume(returning: true)
        }
    }

    // MARK: - Helpers

    private nonisolated static func deviceCheckToken(_ provider: any DeviceTokenProviding) async -> String? {
        guard provider.isSupported, let token = try? await provider.generateToken(), !token.isEmpty else { return nil }
        return token.base64EncodedString()
    }

    private nonisolated static func seconds(_ duration: Duration) -> TimeInterval {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    /// The first 8 characters of a key ID, enough to correlate with the server's `keyIdPrefix`.
    private nonisolated static func prefix(_ keyId: String) -> String {
        String(keyId.prefix(8))
    }
}

// MARK: - Deadline

/// Waits for `operation` at most `seconds`. Unlike a task group, it returns at the deadline even when the
/// operation ignores cancellation (DeviceCheck calls do): the operation is cancelled and left to finish.
nonisolated enum AppAttestDeadline {
    /// The operation's value, or nil when the deadline passed or the caller was cancelled first.
    static func value<T: Sendable>(
        within seconds: TimeInterval,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void,
        operation: @escaping @Sendable () async -> T
    ) async -> T? {
        guard seconds > 0 else { return nil }
        let first = FirstValue<T>()
        let work = Task { first.resolve(await operation()) }
        let timer = Task {
            try? await sleep(seconds)
            first.resolve(nil)
        }
        let value = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                first.install(continuation)
            }
        } onCancel: {
            first.resolve(nil)
        }
        timer.cancel()
        if value == nil { work.cancel() }
        return value
    }

    /// The first of the operation's value and the deadline's nil, delivered once.
    private nonisolated final class FirstValue<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T?, Never>?
        private var early: T??
        private var isResolved = false

        func install(_ continuation: CheckedContinuation<T?, Never>) {
            lock.lock()
            if let early {
                lock.unlock()
                continuation.resume(returning: early)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }

        func resolve(_ value: T?) {
            lock.lock()
            guard !isResolved else {
                lock.unlock()
                return
            }
            isResolved = true
            if let continuation {
                self.continuation = nil
                lock.unlock()
                continuation.resume(returning: value)
            } else {
                early = .some(value)
                lock.unlock()
            }
        }
    }
}
