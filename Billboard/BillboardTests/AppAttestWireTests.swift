import Foundation
import XCTest
@testable import Billboard

/// The App Attest wire formats against the frozen contract (spec C3 4.3-4.4; the platform's
/// `contracts/fixtures/openapi/AppAttest*.valid.json` and `PreSignUpClientMetadata.valid.json`). Hash vectors
/// were computed independently (Python `hashlib`).
final class AppAttestWireTests: XCTestCase {
    // From the platform fixtures named above.
    private let fixtureWireKeyId = "iInD91fLmBNJf1uM35LYM2FQ9DOE3FNDPD-tKlX7pkw"
    private let fixtureAppleKeyId = "iInD91fLmBNJf1uM35LYM2FQ9DOE3FNDPD+tKlX7pkw="
    private let fixtureMarker = "v1.a.iInD91fLmBNJf1uM35LYM2FQ9DOE3FNDPD-tKlX7pkw.eyJ2IjoxLCJwdXJwb3NlIjoic2lnbnVwIiwiY2hhbGxlbmdlIjoiUm1FeG1FaGtTdUlhb0ZtMkoyaTRXMGdYSEFldmltbU5NSVZ0a1haNE5qRSIsImVtYWlsU2hhMjU2IjoiakllMGljNDF6eTR2T2ZnT0tDeXk2QVNUS2xhaUU1Zy03clFvUUgxRHRTMCJ9.omlzaWduYXR1cmVYRgBz7CZtT7Stvz0QSqcU-fEQMv2KttiCn8QLUshvZIXXkozC69Rkbz_j83S-EdkFv0vidfqG84idgqn33F5B3TIwMQ"

    /// `AppAttestMarker.pattern` in `contracts/openapi/user-api.v1.json`.
    private let markerPattern = #"^v1\.(?:a\.[A-Za-z0-9_-]{43}\.[A-Za-z0-9_-]{1,1366}\.[A-Za-z0-9_-]{1,683}|u|b|e\.(?:challenge|attest|assert|timeout|disabled|keychain))$"#

    private func matchesMarkerPattern(_ value: String) throws -> Bool {
        let regex = try NSRegularExpression(pattern: markerPattern)
        return regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
    }

    // MARK: - Names

    func testHeaderAndMetadataNamesMatchTheContract() {
        XCTAssertEqual(AppAttestWire.attestHeader, "X-Billboard-App-Attest")
        XCTAssertEqual(AppAttestWire.appVersionHeader, "X-Billboard-App-Version")
        XCTAssertEqual(AppAttestWire.MetadataKey.appAttest, "billboardAppAttest")
        XCTAssertEqual(AppAttestWire.MetadataKey.deviceCheck, "billboardDeviceCheck")
        XCTAssertEqual(AppAttestWire.MetadataKey.appVersion, "billboardAppVersion")
    }

    func testClientErrorCodesAreTheSixTheServerRecords() {
        XCTAssertEqual(
            AppAttestClientErrorCode.allCases.map(\.rawValue),
            ["challenge", "attest", "assert", "timeout", "disabled", "keychain"]
        )
    }

    func testServerCodesMatchTheContract() {
        XCTAssertEqual(
            Set(AppAttestServerCode.allCases.map(\.rawValue)),
            [
                "APP_ATTEST_CHALLENGE_INVALID", "APP_ATTEST_REJECTED", "APP_ATTEST_UNAVAILABLE",
                "APP_ATTEST_REQUIRED", "APP_ATTEST_FAILED", "APP_ATTEST_UNKNOWN_KEY",
                "DEVICE_ACCOUNT_LIMIT", "APP_UPDATE_REQUIRED"
            ]
        )
    }

    // MARK: - base64url

    func testBase64URLUsesTheURLAlphabetWithoutPadding() {
        XCTAssertEqual(AppAttestWire.base64URL(Data([0xFB, 0xFF])), "-_8")
        XCTAssertEqual(AppAttestWire.base64URL(Data([0xFB, 0xFF, 0xBF])), "-_-_")
        XCTAssertEqual(AppAttestWire.base64URL(Data()), "")
        XCTAssertEqual(AppAttestWire.base64URL(Data("a".utf8)), "YQ")
    }

    func testBase64URLRoundTripsEveryByteAndLength() {
        let allBytes = Data((0...255).map { UInt8($0) })
        for length in 0...40 {
            let bytes = allBytes.prefix(length)
            let encoded = AppAttestWire.base64URL(Data(bytes))
            XCTAssertFalse(encoded.contains("="), "no padding")
            XCTAssertFalse(encoded.contains("+") || encoded.contains("/"), "URL alphabet")
            XCTAssertEqual(AppAttestWire.data(base64URL: encoded), Data(bytes), "length \(length)")
        }
        XCTAssertEqual(AppAttestWire.data(base64URL: AppAttestWire.base64URL(allBytes)), allBytes)
    }

    func testBase64URLDecodingIsStrict() {
        XCTAssertNil(AppAttestWire.data(base64URL: "YQ=="), "padding")
        XCTAssertNil(AppAttestWire.data(base64URL: "+/8"), "standard alphabet")
        XCTAssertNil(AppAttestWire.data(base64URL: "abcde"), "length 4n + 1")
        XCTAssertNil(AppAttestWire.data(base64URL: "ab cd"), "space")
        XCTAssertEqual(AppAttestWire.data(base64URL: ""), Data())
    }

    func testKeyIdConvertsBetweenAppleAndWireForms() {
        XCTAssertEqual(AppAttestWire.wireKeyId(fromAppleKeyId: fixtureAppleKeyId), fixtureWireKeyId)
        XCTAssertEqual(AppAttestWire.appleKeyId(fromWireKeyId: fixtureWireKeyId), fixtureAppleKeyId)
        XCTAssertEqual(fixtureWireKeyId.count, 43)

        let short = Data(repeating: 1, count: 31).base64EncodedString()
        let long = Data(repeating: 1, count: 33).base64EncodedString()
        XCTAssertNil(AppAttestWire.wireKeyId(fromAppleKeyId: short))
        XCTAssertNil(AppAttestWire.wireKeyId(fromAppleKeyId: long))
        XCTAssertNil(AppAttestWire.wireKeyId(fromAppleKeyId: fixtureWireKeyId), "a wire ID is not Apple's form")
        XCTAssertNil(AppAttestWire.appleKeyId(fromWireKeyId: AppAttestWire.base64URL(Data(repeating: 1, count: 31))))
        XCTAssertNil(AppAttestWire.appleKeyId(fromWireKeyId: fixtureAppleKeyId), "Apple's form is not a wire ID")
    }

    func testChallengeValidation() {
        XCTAssertTrue(AppAttestWire.isValidChallenge("UnkhyiRuEgI0rqLFqNM1ohQIpBXcj0DZnDzVArtK5Ro"))
        XCTAssertFalse(AppAttestWire.isValidChallenge("UnkhyiRuEgI0rqLFqNM1ohQIpBXcj0DZnDzVArtK5R"), "42 characters")
        XCTAssertFalse(AppAttestWire.isValidChallenge("UnkhyiRuEgI0rqLFqNM1ohQIpBXcj0DZnDzVArtK5Ro="), "padding")
        XCTAssertFalse(AppAttestWire.isValidChallenge("UnkhyiRuEgI0rqLFqNM1ohQIpBXcj0DZnDzVArtK5R+"), "standard alphabet")
        XCTAssertFalse(AppAttestWire.isValidChallenge(""))
    }

    // MARK: - Hashes

    func testBodyHashOfNoBodyIsTheHashOfNoBytes() {
        XCTAssertEqual(AppAttestWire.bodySha256(nil), "47DEQpj8HBSa-_TImW-5JCeuQeRkm5NMpJWZG3hSuFU")
        XCTAssertEqual(AppAttestWire.bodySha256(Data()), "47DEQpj8HBSa-_TImW-5JCeuQeRkm5NMpJWZG3hSuFU")
    }

    func testBodyHashIsOverTheExactBytes() {
        let body = Data(#"{"billId":"BILLS-119hr1ih","feedback":"Yea"}"#.utf8)
        XCTAssertEqual(AppAttestWire.bodySha256(body), "4Fkle1jHxi7Dfv2U1NuEAW7XQ6oeRtIfYxR1XvWHF50")
        let reordered = Data(#"{"feedback":"Yea","billId":"BILLS-119hr1ih"}"#.utf8)
        XCTAssertNotEqual(AppAttestWire.bodySha256(reordered), AppAttestWire.bodySha256(body))
    }

    func testEmailHashIsOverTheTrimmedLowerCasedAddress() {
        let expected = "0puTyx6EEEzOhT_C-BWU9wy3q4X5XbflbSR5XC8N4wg" // SHA-256 of "voter@example.com"
        XCTAssertEqual(AppAttestWire.emailSha256("voter@example.com"), expected)
        XCTAssertEqual(AppAttestWire.emailSha256("  Voter@Example.COM \n"), expected)
        XCTAssertEqual(AppAttestWire.normalizedEmail(" A@B.Org "), "a@b.org")
        XCTAssertEqual(AppAttestWire.emailSha256("voter@example.com").count, 43)
    }

    func testAttestationClientDataHashIsTheHashOfTheChallengeText() {
        let challenge = "UnkhyiRuEgI0rqLFqNM1ohQIpBXcj0DZnDzVArtK5Ro"
        XCTAssertEqual(
            AppAttestWire.base64URL(AppAttestWire.attestationClientDataHash(challenge: challenge)),
            "SHJI9U2MQN2irDs5d2z2-GXTTfthQ2SXo-OwG-ssn0A"
        )
        XCTAssertEqual(AppAttestWire.attestationClientDataHash(challenge: challenge).count, 32)
    }

    // MARK: - clientData

    func testRequestClientDataBytesAreExactAndMatchTheFixture() throws {
        let data = AppAttestWire.requestClientData(
            challenge: "UnkhyiRuEgI0rqLFqNM1ohQIpBXcj0DZnDzVArtK5Ro",
            method: "post",
            path: "feedback",
            bodySha256: "13W9j4MdFaAe5_Ij6saOKFgKiICysDRngQEz-xTLMQ8"
        )
        XCTAssertEqual(
            String(decoding: data, as: UTF8.self),
            #"{"v":1,"purpose":"request","challenge":"UnkhyiRuEgI0rqLFqNM1ohQIpBXcj0DZnDzVArtK5Ro","method":"POST","path":"/feedback","bodySha256":"13W9j4MdFaAe5_Ij6saOKFgKiICysDRngQEz-xTLMQ8"}"#
        )
        // AppAttestRequestClientData.valid.json
        let fixture: NSDictionary = [
            "v": 1,
            "purpose": "request",
            "challenge": "UnkhyiRuEgI0rqLFqNM1ohQIpBXcj0DZnDzVArtK5Ro",
            "method": "POST",
            "path": "/feedback",
            "bodySha256": "13W9j4MdFaAe5_Ij6saOKFgKiICysDRngQEz-xTLMQ8"
        ]
        XCTAssertEqual(try JSONSerialization.jsonObject(with: data) as? NSDictionary, fixture)
    }

    func testRequestClientDataIsStableAndBindsTheBody() {
        let body = Data(#"{"billId":"A","feedback":"Nay"}"#.utf8)
        let first = AppAttestWire.requestClientData(challenge: "c", method: "POST", path: "/feedback", body: body)
        let second = AppAttestWire.requestClientData(challenge: "c", method: "POST", path: "/feedback", body: body)
        XCTAssertEqual(first, second)
        XCTAssertTrue(String(decoding: first, as: UTF8.self).contains(AppAttestWire.bodySha256(body)))
        let other = AppAttestWire.requestClientData(challenge: "c", method: "POST", path: "/feedback", body: Data("x".utf8))
        XCTAssertNotEqual(first, other)
    }

    func testSignUpClientDataMatchesThePlatformFixtureBytes() throws {
        let data = AppAttestWire.signUpClientData(
            challenge: "RmExmEhkSuIaoFm2J2i4W0gXHAevimmNMIVtkXZ4NjE",
            emailSha256: "jIe0ic41zy4vOfgOKCyy6ASTKlaiE5g-7rQoQH1DtS0"
        )
        XCTAssertEqual(
            String(decoding: data, as: UTF8.self),
            #"{"v":1,"purpose":"signup","challenge":"RmExmEhkSuIaoFm2J2i4W0gXHAevimmNMIVtkXZ4NjE","emailSha256":"jIe0ic41zy4vOfgOKCyy6ASTKlaiE5g-7rQoQH1DtS0"}"#
        )
        // The clientData segment of PreSignUpClientMetadata.valid.json's billboardAppAttest is these exact bytes.
        let segments = fixtureMarker.split(separator: ".").map(String.init)
        XCTAssertEqual(AppAttestWire.data(base64URL: segments[3]), data)
    }

    func testMethodAndPathAreNormalizedAsTheServerCompares() {
        XCTAssertEqual(AppAttestWire.normalizedMethod(" post "), "POST")
        XCTAssertEqual(AppAttestWire.normalizedPath("feedback"), "/feedback")
        XCTAssertEqual(AppAttestWire.normalizedPath("/feedback"), "/feedback")
        XCTAssertEqual(AppAttestWire.normalizedPath(" feedback "), "/feedback")
    }

    func testJSONStringEscapingRoundTrips() throws {
        let values = ["plain", "quote\"back\\slash", "line\nbreak\ttab\r", "ctrl\u{01}\u{1F}", "café ✓", "/feedback", ""]
        for value in values {
            let literal = AppAttestWire.jsonString(value)
            let parsed = try JSONSerialization.jsonObject(with: Data("[\(literal)]".utf8)) as? [String]
            XCTAssertEqual(parsed, [value], literal)
        }
        XCTAssertEqual(AppAttestWire.jsonString("/feedback"), #""/feedback""#, "the slash is not escaped")
        XCTAssertEqual(AppAttestWire.jsonString("\u{01}"), #""\u0001""#)
    }

    // MARK: - Marker

    func testMarkerFormsMatchTheContractPattern() throws {
        XCTAssertEqual(AppAttestMarker.unsupported.value, "v1.u")
        XCTAssertEqual(AppAttestMarker.debugBypass.value, "v1.b")
        for code in AppAttestClientErrorCode.allCases {
            let marker = AppAttestMarker.clientError(code)
            XCTAssertEqual(marker.value, "v1.e.\(code.rawValue)")
            XCTAssertTrue(try matchesMarkerPattern(marker.value), marker.value)
            XCTAssertFalse(marker.isAssertion)
        }
        XCTAssertTrue(try matchesMarkerPattern("v1.u"))
        XCTAssertTrue(try matchesMarkerPattern("v1.b"))
        XCTAssertEqual(AppAttestMarker.unsupported.headers, ["X-Billboard-App-Attest": "v1.u"])
    }

    func testAssertionMarkerReproducesThePlatformFixture() throws {
        let segments = fixtureMarker.split(separator: ".").map(String.init)
        let clientData = AppAttestWire.signUpClientData(
            challenge: "RmExmEhkSuIaoFm2J2i4W0gXHAevimmNMIVtkXZ4NjE",
            emailSha256: "jIe0ic41zy4vOfgOKCyy6ASTKlaiE5g-7rQoQH1DtS0"
        )
        let assertion = try XCTUnwrap(AppAttestWire.data(base64URL: segments[4]))
        let marker = AppAttestMarker.validatedAssertion(keyId: fixtureWireKeyId, clientData: clientData, assertion: assertion)

        XCTAssertTrue(marker.isAssertion)
        XCTAssertEqual(marker.value, fixtureMarker)
        XCTAssertTrue(try matchesMarkerPattern(marker.value))
        XCTAssertEqual(marker.headers, [AppAttestWire.attestHeader: fixtureMarker])
    }

    func testAssertionMarkerEnforcesTheContractLimits() throws {
        let keyId = fixtureWireKeyId
        let clientData = Data(repeating: 0x41, count: 200)
        let assertion = Data(repeating: 0x42, count: 200)
        XCTAssertTrue(AppAttestMarker.validatedAssertion(keyId: keyId, clientData: clientData, assertion: assertion).isAssertion)

        let shortKey = AppAttestWire.base64URL(Data(repeating: 1, count: 31))
        XCTAssertEqual(AppAttestMarker.validatedAssertion(keyId: shortKey, clientData: clientData, assertion: assertion), .clientError(.assert))
        XCTAssertEqual(AppAttestMarker.validatedAssertion(keyId: "not base64url!", clientData: clientData, assertion: assertion), .clientError(.assert))
        XCTAssertEqual(AppAttestMarker.validatedAssertion(keyId: keyId, clientData: Data(), assertion: assertion), .clientError(.assert))
        XCTAssertEqual(AppAttestMarker.validatedAssertion(keyId: keyId, clientData: clientData, assertion: Data()), .clientError(.assert))
        XCTAssertEqual(
            AppAttestMarker.validatedAssertion(keyId: keyId, clientData: Data(repeating: 0x41, count: 1025), assertion: assertion),
            .clientError(.assert)
        )
        XCTAssertEqual(
            AppAttestMarker.validatedAssertion(keyId: keyId, clientData: clientData, assertion: Data(repeating: 0x42, count: 513)),
            .clientError(.assert)
        )
        // Each segment at its own limit would make a 2,099-character header: over the 2,048 cap.
        XCTAssertEqual(
            AppAttestMarker.validatedAssertion(
                keyId: keyId,
                clientData: Data(repeating: 0x41, count: 1024),
                assertion: Data(repeating: 0x42, count: 512)
            ),
            .clientError(.assert)
        )
        let largest = AppAttestMarker.validatedAssertion(
            keyId: keyId,
            clientData: Data(repeating: 0x41, count: 1024),
            assertion: Data(repeating: 0x42, count: 470)
        )
        XCTAssertTrue(largest.isAssertion)
        XCTAssertLessThanOrEqual(largest.value.count, 2048)
        XCTAssertTrue(try matchesMarkerPattern(largest.value))
    }

    // MARK: - App version

    func testAppVersionFollowsTheContractPattern() {
        for valid in ["1", "1.2", "1.2.3", "10.20.30", "0.0.1"] {
            XCTAssertTrue(AppAttestWire.isValidAppVersion(valid), valid)
        }
        for invalid in ["", "1.2.3.4", "1.a", "1..2", ".1", "1.", "v1.2", " 1.2", "1.2 (3)", String(repeating: "1", count: 33)] {
            XCTAssertFalse(AppAttestWire.isValidAppVersion(invalid), invalid)
        }
        XCTAssertEqual(AppAttestWire.appVersion(from: ["CFBundleShortVersionString": "1.2"]), "1.2")
        XCTAssertNil(AppAttestWire.appVersion(from: ["CFBundleShortVersionString": "1.2 beta"]))
        XCTAssertNil(AppAttestWire.appVersion(from: [:]))
        XCTAssertNil(AppAttestWire.appVersion(from: nil))
    }
}

// MARK: - Service

/// `AppAttestService` requests and answers (C3 3.2-3.3, OpenAPI `AppAttest*` components), through a recording
/// `APIClient` transport.
final class AppAttestServiceTests: XCTestCase {
    private func json(_ string: String) -> Data {
        Data(string.utf8)
    }

    private func errorBody(_ code: String) -> Error {
        NSError(domain: "AppAttestServiceTests", code: 400, userInfo: ["body": Data(#"{"error":"\#(code)"}"#.utf8)])
    }

    private func jsonObject(_ data: Data?) throws -> NSDictionary {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(data)) as? NSDictionary)
    }

    @MainActor
    private func run<T>(_ transport: RecordingTransport, _ operation: () async throws -> T) async throws -> T {
        try await APIClient.$current.withValue(transport.client) {
            try await operation()
        }
    }

    @MainActor
    func testChallengeRequestIsAPublicPostWithThePurpose() async throws {
        let transport = RecordingTransport()
        transport.responses = [json(#"{"clientMode":"on","challenge":"UnkhyiRuEgI0rqLFqNM1ohQIpBXcj0DZnDzVArtK5Ro","expiresAt":"2026-10-08T12:05:00.000Z"}"#)]

        let result = try await run(transport) {
            try await AppAttestService.issueChallenge(purpose: .assert)
        }

        XCTAssertEqual(
            result,
            .on(challenge: "UnkhyiRuEgI0rqLFqNM1ohQIpBXcj0DZnDzVArtK5Ro", expiresAt: "2026-10-08T12:05:00.000Z")
        )
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(request.method, .post)
        XCTAssertEqual(request.path, "app-attest/challenge")
        XCTAssertNil(request.queryParameters)
        XCTAssertEqual(request.label, "AppAttestService app-attest/challenge")
        XCTAssertEqual(request.authMode, .autoFetch, "the route has no authorizer; it works signed out")
        XCTAssertEqual(try jsonObject(request.body), ["purpose": "assert"])
    }

    @MainActor
    func testChallengeForAttestationSendsPurposeAttest() async throws {
        let transport = RecordingTransport()
        transport.responses = [json(#"{"clientMode":"off"}"#)]

        let result = try await run(transport) {
            try await AppAttestService.issueChallenge(purpose: .attest)
        }

        XCTAssertEqual(result, .off)
        XCTAssertEqual(try jsonObject(transport.requests.first?.body), ["purpose": "attest"])
    }

    @MainActor
    func testChallengeInsideAProxyEnvelopeIsRead() async throws {
        let transport = RecordingTransport()
        transport.responses = [json(#"{"body":"{\"clientMode\":\"off\"}"}"#)]

        let result = try await run(transport) {
            try await AppAttestService.issueChallenge(purpose: .assert)
        }

        XCTAssertEqual(result, .off)
    }

    func testUnreadableChallengesAreRejected() {
        let bodies = [
            #"{"clientMode":"on"}"#,
            #"{"clientMode":"on","challenge":"short"}"#,
            #"{"clientMode":"on","challenge":"UnkhyiRuEgI0rqLFqNM1ohQIpBXcj0DZnDzVArtK5Ro="}"#,
            #"{"clientMode":"maybe"}"#,
            #"{}"#,
            "",
            "not json"
        ]
        for body in bodies {
            XCTAssertThrowsError(try AppAttestService.parseChallenge(Data(body.utf8)), body) { error in
                XCTAssertEqual(error as? AppAttestServiceError, .invalidResponse, body)
            }
        }
    }

    @MainActor
    func testRegisterSendsTheWireKeyIdAndStandardBase64Attestation() async throws {
        let transport = RecordingTransport()
        transport.responses = [json(#"{"status":"attested","environment":"production"}"#)]
        let attestation = Data([0xFB, 0xFF, 0xBF, 0x00, 0x01])

        let registration = try await run(transport) {
            try await AppAttestService.registerKey(
                keyId: "iInD91fLmBNJf1uM35LYM2FQ9DOE3FNDPD-tKlX7pkw",
                challenge: "UnkhyiRuEgI0rqLFqNM1ohQIpBXcj0DZnDzVArtK5Ro",
                attestation: attestation
            )
        }

        XCTAssertEqual(registration, AppAttestRegistration(status: .attested, environment: "production"))
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.method, .post)
        XCTAssertEqual(request.path, "app-attest/attest")
        XCTAssertEqual(request.label, "AppAttestService app-attest/attest")
        XCTAssertEqual(request.authMode, .autoFetch)
        XCTAssertEqual(
            try jsonObject(request.body),
            [
                "keyId": "iInD91fLmBNJf1uM35LYM2FQ9DOE3FNDPD-tKlX7pkw",
                "challenge": "UnkhyiRuEgI0rqLFqNM1ohQIpBXcj0DZnDzVArtK5Ro",
                "attestation": "+/+/AAE="
            ]
        )
        let rawBody = String(decoding: try XCTUnwrap(request.body), as: UTF8.self)
        XCTAssertTrue(rawBody.contains("+/+/AAE="), "standard base64 with padding, slashes not escaped: \(rawBody)")
    }

    func testRegistrationAnswers() throws {
        XCTAssertEqual(
            try AppAttestService.parseRegistration(Data(#"{"status":"already_attested","environment":"development"}"#.utf8)),
            AppAttestRegistration(status: .alreadyAttested, environment: "development")
        )
        for body in [#"{"status":"done","environment":"production"}"#, #"{"status":"attested"}"#, #"{"status":"attested","environment":""}"#, "[]"] {
            XCTAssertThrowsError(try AppAttestService.parseRegistration(Data(body.utf8)), body) { error in
                XCTAssertEqual(error as? AppAttestServiceError, .invalidResponse, body)
            }
        }
    }

    @MainActor
    func testFailuresMapToWhatTheManagerDoes() async throws {
        let cases: [(Error, AppAttestServiceError)] = [
            (errorBody("APP_ATTEST_CHALLENGE_INVALID"), .challengeInvalid),
            (errorBody("APP_ATTEST_REJECTED"), .rejected),
            (errorBody("APP_ATTEST_UNAVAILABLE"), .unavailable),
            (errorBody("INVALID_REQUEST"), .unavailable),
            (NSError(domain: "AppAttestServiceTests", code: 403), .unavailable), // a firewall block has no code
            (URLError(.notConnectedToInternet), .unavailable)
        ]
        for (failure, expected) in cases {
            let transport = RecordingTransport()
            transport.failure = { _ in failure }
            do {
                _ = try await run(transport) {
                    try await AppAttestService.registerKey(
                        keyId: "iInD91fLmBNJf1uM35LYM2FQ9DOE3FNDPD-tKlX7pkw",
                        challenge: "UnkhyiRuEgI0rqLFqNM1ohQIpBXcj0DZnDzVArtK5Ro",
                        attestation: Data([1])
                    )
                }
                XCTFail("expected \(expected)")
            } catch {
                XCTAssertEqual(error as? AppAttestServiceError, expected, "\(failure)")
            }
        }
    }

    @MainActor
    func testCancellationPassesThrough() async throws {
        let transport = RecordingTransport()
        transport.failure = { _ in CancellationError() }
        do {
            _ = try await run(transport) {
                try await AppAttestService.issueChallenge(purpose: .assert)
            }
            XCTFail("expected a cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }

    func testLiveBackendReadsTheServerCodeOfAFailedRequest() async {
        let backend = LiveAppAttestBackend()
        let code = await backend.serverCode(of: errorBody("APP_ATTEST_UNKNOWN_KEY"))
        XCTAssertEqual(code, "APP_ATTEST_UNKNOWN_KEY")
        let none = await backend.serverCode(of: URLError(.timedOut))
        XCTAssertNil(none)
    }
}

// MARK: - Update alert

/// The blocking update prompt (spec D 2.8.4) and its once-per-launch notification.
final class AppUpdateRequiredAlertTests: XCTestCase {
    func testCopyAndLink() {
        XCTAssertEqual(AppUpdatePrompt.title, "Update Billboard")
        XCTAssertEqual(
            AppUpdatePrompt.message,
            "This version of Billboard can't vote or create accounts any more. Update to continue."
        )
        XCTAssertEqual(AppUpdatePrompt.openAppStoreTitle, "Open App Store")
        XCTAssertEqual(AppUpdatePrompt.appStoreURL?.absoluteString, "https://apps.apple.com/app/id6757132060")
        XCTAssertEqual(Notification.Name.billboardAppUpdateRequired.rawValue, "BillBoard.appUpdateRequired")
    }

    @MainActor
    func testSignalPostsOncePerLaunch() {
        let center = NotificationCenter()
        var received = 0
        let observer = center.addObserver(forName: .billboardAppUpdateRequired, object: nil, queue: nil) { _ in
            received += 1
        }
        defer { center.removeObserver(observer) }
        let signal = AppUpdateRequiredSignal(center: center)

        XCTAssertFalse(signal.hasPosted)
        XCTAssertTrue(signal.post())
        XCTAssertFalse(signal.post())
        XCTAssertFalse(signal.post())

        XCTAssertTrue(signal.hasPosted)
        XCTAssertEqual(received, 1)
    }

    func testAlertStaysUpUntilTheAppIsUpdated() {
        var state = AppUpdateRequiredAlertState()
        state.sceneBecameActive()
        XCTAssertFalse(state.isPresented, "nothing to show before the server asks")
        XCTAssertFalse(state.needsReshow)

        state.require()
        XCTAssertTrue(state.isRequired)
        XCTAssertTrue(state.isPresented)
        XCTAssertFalse(state.needsReshow)

        state.isPresented = false // Open App Store closes the alert
        XCTAssertTrue(state.needsReshow)

        state.sceneBecameActive() // back from the App Store without updating
        XCTAssertTrue(state.isPresented)
        XCTAssertFalse(state.needsReshow)
    }
}
