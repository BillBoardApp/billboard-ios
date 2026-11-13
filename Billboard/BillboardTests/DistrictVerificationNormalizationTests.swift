import XCTest
@testable import Billboard

/// `DistrictVerificationService.normalizeDistrictForAPI(_:state:)` converts what a user types
/// into the district value the verification API expects: a plain number or "AL" (at-large).
/// Also the answers of `POST /district-verification` (spec D 2.8.4): the re-verification
/// limit, an address the geocoder cannot match, and the address-cap result.
final class DistrictVerificationNormalizationTests: XCTestCase {
    @MainActor
    func testPlainDistrictNumbersAreTrimmedAndUnpadded() throws {
        XCTAssertEqual(try DistrictVerificationService.normalizeDistrictForAPI("12", state: "CA"), "12")
        XCTAssertEqual(try DistrictVerificationService.normalizeDistrictForAPI(" 7 ", state: "TX"), "7")
        XCTAssertEqual(try DistrictVerificationService.normalizeDistrictForAPI("07", state: "NY"), "7")
    }

    @MainActor
    func testDigitsAreExtractedFromFreeText() throws {
        XCTAssertEqual(try DistrictVerificationService.normalizeDistrictForAPI("District 5", state: "OH"), "5")
    }

    @MainActor
    func testAtLargeSpellingsNormalizeToAL() throws {
        let spellings: [(district: String, state: String)] = [
            ("AL", "AK"),
            ("al", "AK"),
            ("0", "WY"),
            ("00", "WY"),
            ("at-large", "VT"),
            ("At-Large", "DE")
        ]

        for (district, state) in spellings {
            XCTAssertEqual(
                try DistrictVerificationService.normalizeDistrictForAPI(district, state: state),
                "AL",
                "\(district) in \(state)"
            )
        }
    }

    @MainActor
    func testMatchingStatePrefixIsStripped() throws {
        XCTAssertEqual(try DistrictVerificationService.normalizeDistrictForAPI("CA-12", state: "CA"), "12")
        XCTAssertEqual(try DistrictVerificationService.normalizeDistrictForAPI("CA12", state: "CA"), "12")
        XCTAssertEqual(try DistrictVerificationService.normalizeDistrictForAPI("ca-12", state: "CA"), "12")
        XCTAssertEqual(try DistrictVerificationService.normalizeDistrictForAPI("NY-AL", state: "NY"), "AL")
        XCTAssertEqual(try DistrictVerificationService.normalizeDistrictForAPI("AK-AL", state: "AK"), "AL")
    }

    @MainActor
    func testEmptyInputIsRejected() {
        assertInvalidInput("", state: "CA")
        assertInvalidInput("   ", state: "CA")
    }

    @MainActor
    func testInputWithoutADistrictIsRejected() {
        assertInvalidInput("abc", state: "CA")
        assertInvalidInput("000", state: "CA")
    }

    @MainActor
    private func assertInvalidInput(
        _ district: String,
        state: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try DistrictVerificationService.normalizeDistrictForAPI(district, state: state),
            "\(district.debugDescription) in \(state)",
            file: file,
            line: line
        ) { error in
            guard case .invalidInput? = error as? DistrictVerificationService.ServiceError else {
                return XCTFail("Expected invalidInput, got \(error)", file: file, line: line)
            }
        }
    }

    // MARK: - Server answers (spec D 2.5.3, 2.8.4)

    @MainActor
    private func submitAddress(failingWith error: Error) async -> Error? {
        let transport = RecordingTransport()
        transport.failure = { _ in error }
        do {
            _ = try await APIClient.$current.withValue(transport.client) {
                try await DistrictVerificationService.submitAddress(
                    line1: "1600 Pennsylvania Ave NW",
                    city: "Washington",
                    state: "DC",
                    zip: "20500"
                )
            }
            return nil
        } catch {
            return error
        }
    }

    @MainActor
    func testTheReverificationLimitHasItsOwnCopy() async throws {
        let error = await submitAddress(failingWith: backendError("VERIFICATION_RATE_LIMITED"))

        XCTAssertEqual(
            error as? DistrictVerificationService.ServiceError,
            .requestFailed("You can verify a new address 3 times in 30 days. Try again later, or choose your district instead.")
        )
        XCTAssertEqual(
            AuthErrorMessages.message(for: try XCTUnwrap(error), context: .general),
            "You can verify a new address 3 times in 30 days. Try again later, or choose your district instead.",
            "the editor shows the service's copy as is"
        )
    }

    @MainActor
    func testStatusesWithoutACodeKeepTheirCopy() async {
        let notFound = await submitAddress(failingWith: httpStatusError(422, path: "district-verification"))
        XCTAssertEqual(
            notFound as? DistrictVerificationService.ServiceError,
            .invalidInput("We couldn't find that address. Check it, or choose your district instead.")
        )

        let throttled = await submitAddress(failingWith: httpStatusError(429, path: "district-verification"))
        XCTAssertEqual(
            throttled as? DistrictVerificationService.ServiceError,
            .requestFailed("Too many attempts. Wait a few minutes, then try again.")
        )

        let offline = await submitAddress(failingWith: URLError(.notConnectedToInternet))
        XCTAssertEqual(
            offline as? DistrictVerificationService.ServiceError,
            .requestFailed("You appear to be offline. Check your connection and try again.")
        )
    }

    @MainActor
    func testAnUnknownCodeFallsBackToTheStatusCopy() {
        let mapped = DistrictVerificationService.mapServiceError(from: backendError("SOMETHING_NEW"))

        XCTAssertEqual(
            mapped as? DistrictVerificationService.ServiceError,
            .requestFailed("We couldn't verify your district. Please try again.")
        )
    }

    @MainActor
    func testTheAddressCapResultReadsAsNotVerified() async throws {
        let transport = RecordingTransport()
        transport.responses = [Data(#"""
        {"verified":false,"status":"self_attested","method":"address_capped","verifiedAt":"2026-10-08T12:00:00.000Z",
         "resolved":{"state":"VA","districtId":"11"},"repsSignalEligible":false,"limitReason":"address_limit"}
        """#.utf8)]

        let status = try await APIClient.$current.withValue(transport.client) {
            try await DistrictVerificationService.submitAddress(line1: "1 Main St", city: "Fairfax", state: "VA", zip: "22030")
        }

        XCTAssertFalse(status.verified)
        XCTAssertEqual(status.limitReason, "address_limit")
        XCTAssertTrue(status.isAddressCapped)
        XCTAssertEqual(status.resolved, DistrictVerificationResolved(state: "VA", districtId: "11"))
        XCTAssertEqual(transport.requests.map(\.headers), [[:]], "district verification is not an App Attest protected route")
    }
}
