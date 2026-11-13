import CryptoKit
import Foundation

/// The App Attest wire formats (spec C3 4.3-4.4, spec D 2.8.1), typed by hand because the contract
/// generator emits only `ApiError`. Source of truth: the platform's `contracts/README.md`
/// "App Attest (INT-04)" and the OpenAPI components `AppAttestMarker`, `AppAttestRequestClientData`,
/// `AppAttestSignUpClientData`, `PreSignUpClientMetadata` and `AppVersion`.
///
/// Pure functions with no state, `nonisolated` so the `AppAttestManager` actor and the main actor both
/// call them. Every segment on the wire is base64url without padding; Apple's key IDs and the attestation
/// object travel as standard base64 only where the contract says so.
nonisolated enum AppAttestWire {
    // MARK: - Names

    /// The assertion or marker header, sent on `POST /feedback` only.
    static let attestHeader = "X-Billboard-App-Attest"
    /// The app version header (`CFBundleShortVersionString`), sent on the user API requests the app builds
    /// through `APIServiceSupport` (integration plan X16; set there, not here).
    static let appVersionHeader = "X-Billboard-App-Version"

    /// Cognito sign-up `ClientMetadata` keys (`PreSignUpClientMetadata`).
    enum MetadataKey {
        static let appAttest = "billboardAppAttest"
        static let deviceCheck = "billboardDeviceCheck"
        static let appVersion = "billboardAppVersion"
    }

    // MARK: - Limits (AppAttestMarker, AppVersion)

    static let keyIdByteCount = 32
    static let challengeLength = 43
    static let maxClientDataBytes = 1024
    static let maxAssertionBytes = 512
    static let maxMarkerLength = 2048
    static let maxAppVersionLength = 32

    // MARK: - base64url

    /// base64url without padding (RFC 4648 section 5).
    static func base64URL(_ data: Data) -> String {
        var encoded = data.base64EncodedString()
        encoded = encoded.replacingOccurrences(of: "+", with: "-")
        encoded = encoded.replacingOccurrences(of: "/", with: "_")
        while encoded.hasSuffix("=") { encoded.removeLast() }
        return encoded
    }

    /// Strict base64url without padding; nil for any other character or an impossible length (4n + 1).
    static func data(base64URL value: String) -> Data? {
        guard value.utf8.allSatisfy(isBase64URLByte), value.utf8.count % 4 != 1 else { return nil }
        var standard = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while standard.utf8.count % 4 != 0 { standard.append("=") }
        return Data(base64Encoded: standard)
    }

    /// The wire key ID (base64url of 32 bytes) for the standard base64 key ID `DCAppAttestService` returns,
    /// or nil when it is not a 32-byte value.
    static func wireKeyId(fromAppleKeyId appleKeyId: String) -> String? {
        guard let bytes = Data(base64Encoded: appleKeyId), bytes.count == keyIdByteCount else { return nil }
        return base64URL(bytes)
    }

    /// The standard base64 key ID `DCAppAttestService` expects back, from a stored wire key ID.
    static func appleKeyId(fromWireKeyId wireKeyId: String) -> String? {
        guard let bytes = data(base64URL: wireKeyId), bytes.count == keyIdByteCount else { return nil }
        return bytes.base64EncodedString()
    }

    /// True for a challenge as `POST /app-attest/challenge` issues it: base64url of 32 bytes (43 characters).
    static func isValidChallenge(_ challenge: String) -> Bool {
        challenge.utf8.count == challengeLength && challenge.utf8.allSatisfy(isBase64URLByte)
    }

    private static func isBase64URLByte(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
             UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "_"):
            return true
        default:
            return false
        }
    }

    // MARK: - Hashes

    static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    /// `clientDataHash` for `attestKey`: SHA-256 of the challenge's UTF-8 bytes (C3 3.3 step 4).
    static func attestationClientDataHash(challenge: String) -> Data {
        sha256(Data(challenge.utf8))
    }

    /// `bodySha256`: base64url of the SHA-256 of the exact body bytes sent (of no bytes when there is no body).
    static func bodySha256(_ body: Data?) -> String {
        base64URL(sha256(body ?? Data()))
    }

    /// The address the sign-up assertion binds: trimmed and lower-cased, as the pre-sign-up trigger
    /// compares it (`emailSha256` in the platform's `wire.ts`).
    static func normalizedEmail(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// `emailSha256`: base64url of the SHA-256 of the trimmed, lower-cased email address.
    static func emailSha256(_ email: String) -> String {
        base64URL(sha256(Data(normalizedEmail(email).utf8)))
    }

    // MARK: - clientData

    /// The HTTP method as the server compares it (`event.httpMethod`).
    static func normalizedMethod(_ method: String) -> String {
        method.trimmingCharacters(in: .whitespaces).uppercased()
    }

    /// The API Gateway resource path the server compares (`event.resource`, such as `/feedback`). Services
    /// name paths without the leading slash (`"feedback"`), so one is added.
    static func normalizedPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("/") ? trimmed : "/" + trimmed
    }

    /// The exact clientData bytes for a protected request (`AppAttestRequestClientData`), keys in the
    /// documented order: `{"v":1,"purpose":"request","challenge":…,"method":…,"path":…,"bodySha256":…}`.
    static func requestClientData(challenge: String, method: String, path: String, bodySha256: String) -> Data {
        let json = #"{"v":1,"purpose":"request","challenge":"# + jsonString(challenge)
            + #","method":"# + jsonString(normalizedMethod(method))
            + #","path":"# + jsonString(normalizedPath(path))
            + #","bodySha256":"# + jsonString(bodySha256)
            + "}"
        return Data(json.utf8)
    }

    /// `requestClientData` over the body that will be sent.
    static func requestClientData(challenge: String, method: String, path: String, body: Data?) -> Data {
        requestClientData(challenge: challenge, method: method, path: path, bodySha256: bodySha256(body))
    }

    /// The exact clientData bytes for a sign-up (`AppAttestSignUpClientData`):
    /// `{"v":1,"purpose":"signup","challenge":…,"emailSha256":…}`.
    static func signUpClientData(challenge: String, emailSha256: String) -> Data {
        let json = #"{"v":1,"purpose":"signup","challenge":"# + jsonString(challenge)
            + #","emailSha256":"# + jsonString(emailSha256)
            + "}"
        return Data(json.utf8)
    }

    /// A JSON string literal with RFC 8259 escaping (quotes, backslash, control characters). The slash is
    /// left as is, so `/feedback` reads the same in the bytes as in the fixture.
    static func jsonString(_ value: String) -> String {
        var escaped = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": escaped += "\\\""
            case "\\": escaped += "\\\\"
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            case "\u{08}": escaped += "\\b"
            case "\u{0C}": escaped += "\\f"
            case _ where scalar.value < 0x20:
                escaped += String(format: "\\u%04x", scalar.value)
            default:
                escaped.unicodeScalars.append(scalar)
            }
        }
        return escaped + "\""
    }

    // MARK: - App version

    /// `CFBundleShortVersionString` when it is a valid `AppVersion` (one to three dot-separated numbers,
    /// at most 32 characters), else nil (then neither the header nor the metadata key is sent).
    static func appVersion(from infoDictionary: [String: Any]?) -> String? {
        guard let version = infoDictionary?["CFBundleShortVersionString"] as? String,
              isValidAppVersion(version) else {
            return nil
        }
        return version
    }

    /// This build's version, as `X-Billboard-App-Version` and `billboardAppVersion` carry it.
    static var currentAppVersion: String? {
        appVersion(from: Bundle.main.infoDictionary)
    }

    static func isValidAppVersion(_ version: String) -> Bool {
        guard !version.isEmpty, version.utf8.count <= maxAppVersionLength else { return false }
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.utf8.allSatisfy { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }
        }
    }
}

// MARK: - Marker

/// Why the client could not produce an assertion (`v1.e.<code>`). The server records any other code as `other`.
nonisolated enum AppAttestClientErrorCode: String, CaseIterable, Equatable, Sendable {
    /// `POST /app-attest/challenge` failed (network, 429, 503, unreadable answer).
    case challenge
    /// No attested key: attestation failed or is backing off.
    case attest
    /// `generateAssertion` failed.
    case assert
    /// A budget ran out (8 s for the key, 3 s for the assertion, 6 s at sign-up).
    case timeout
    /// The server's kill switch answered `clientMode: "off"`; attestation is off for 6 hours.
    case disabled
    /// The key could not be saved in the Keychain.
    case keychain
}

/// The `X-Billboard-App-Attest` value, which is also the `billboardAppAttest` sign-up metadata value
/// (`AppAttestMarker`).
nonisolated enum AppAttestMarker: Equatable, Sendable {
    /// `v1.a.<keyId>.<clientData>.<assertion>`: `keyId` is the wire key ID; `clientData` the exact signed
    /// bytes; `assertion` the CBOR bytes from `generateAssertion`.
    case assertion(keyId: String, clientData: Data, assertion: Data)
    /// `v1.u`: the device does not support App Attest (Release builds).
    case unsupported
    /// `v1.b`: a Debug build on an unsupported device, such as the Simulator.
    case debugBypass
    /// `v1.e.<code>`: the client could not produce an assertion.
    case clientError(AppAttestClientErrorCode)

    /// An assertion marker, or `v1.e.assert` when a segment breaks the `AppAttestMarker` limits (a 32-byte
    /// key ID, clientData 1-1,024 bytes, assertion 1-512 bytes, at most 2,048 characters in all).
    static func validatedAssertion(keyId: String, clientData: Data, assertion: Data) -> AppAttestMarker {
        let marker = AppAttestMarker.assertion(keyId: keyId, clientData: clientData, assertion: assertion)
        guard AppAttestWire.data(base64URL: keyId)?.count == AppAttestWire.keyIdByteCount,
              (1...AppAttestWire.maxClientDataBytes).contains(clientData.count),
              (1...AppAttestWire.maxAssertionBytes).contains(assertion.count),
              marker.value.utf8.count <= AppAttestWire.maxMarkerLength else {
            return .clientError(.assert)
        }
        return marker
    }

    var value: String {
        switch self {
        case let .assertion(keyId, clientData, assertion):
            return "v1.a.\(keyId).\(AppAttestWire.base64URL(clientData)).\(AppAttestWire.base64URL(assertion))"
        case .unsupported:
            return "v1.u"
        case .debugBypass:
            return "v1.b"
        case .clientError(let code):
            return "v1.e.\(code.rawValue)"
        }
    }

    var isAssertion: Bool {
        if case .assertion = self { return true }
        return false
    }

    /// The header to add to the protected request.
    var headers: [String: String] {
        [AppAttestWire.attestHeader: value]
    }
}

// MARK: - Server codes

/// The App Attest and minimum-version codes the server returns in `ApiError.error` (C3 4.5) or as the
/// pre-sign-up error ("PreSignUp failed with error <CODE>."). Under `watch` only the attestation routes'
/// codes occur; the rest occur only under `enforce`.
nonisolated enum AppAttestServerCode: String, CaseIterable, Equatable, Sendable {
    /// 400 on attest: the challenge is unknown, expired or used. Retry once with a new challenge.
    case challengeInvalid = "APP_ATTEST_CHALLENGE_INVALID"
    /// 400 on attest: verification failed. Discard the key.
    case rejected = "APP_ATTEST_REJECTED"
    /// 503: the server could not read or write its table. Keep the key and back off.
    case unavailable = "APP_ATTEST_UNAVAILABLE"
    /// 403 (enforce): unsupported device, Debug bypass or client error. No retry.
    case required = "APP_ATTEST_REQUIRED"
    /// 403 (enforce): invalid assertion or development key. Resend once with a fresh challenge.
    case failed = "APP_ATTEST_FAILED"
    /// 403 (enforce): unknown or revoked key. Attest a new key and resend once.
    case unknownKey = "APP_ATTEST_UNKNOWN_KEY"
    /// 403 or sign-up error (enforce): a fourth account on this install or device. No retry.
    case deviceAccountLimit = "DEVICE_ACCOUNT_LIMIT"
    /// 426 or sign-up error (enforce): this build must update. The blocking update alert.
    case appUpdateRequired = "APP_UPDATE_REQUIRED"
}
