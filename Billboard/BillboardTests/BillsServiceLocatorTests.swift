import XCTest
@testable import Billboard

/// `BillsService.deriveLocator(from:)` turns a bill guid such as `BILLS-119hjres131eh`
/// into the congress / bill type / bill number used by `GET /processed-bill`.
final class BillsServiceLocatorTests: XCTestCase {
    @MainActor
    func testDerivesLocatorFromVersionedGuid() throws {
        let locator = try XCTUnwrap(BillsService.deriveLocator(from: "BILLS-119hjres131eh"))
        XCTAssertEqual(locator.congress, "119")
        XCTAssertEqual(locator.billType, "hjres")
        XCTAssertEqual(locator.billID, "131")
    }

    @MainActor
    func testDerivesLocatorWithoutVersionSuffix() throws {
        let locator = try XCTUnwrap(BillsService.deriveLocator(from: "BILLS-119hr1"))
        XCTAssertEqual(locator.congress, "119")
        XCTAssertEqual(locator.billType, "hr")
        XCTAssertEqual(locator.billID, "1")
    }

    @MainActor
    func testDerivesMultiDigitSenateBillNumber() throws {
        let locator = try XCTUnwrap(BillsService.deriveLocator(from: "BILLS-118s2025is"))
        XCTAssertEqual(locator.congress, "118")
        XCTAssertEqual(locator.billType, "s")
        XCTAssertEqual(locator.billID, "2025")
    }

    @MainActor
    func testTrimsWhitespaceAndLowercasesBillType() throws {
        let locator = try XCTUnwrap(BillsService.deriveLocator(from: "  bills-119SRES5ATS \n"))
        XCTAssertEqual(locator.congress, "119")
        XCTAssertEqual(locator.billType, "sres")
        XCTAssertEqual(locator.billID, "5")
    }

    @MainActor
    func testRejectsGuidsThatAreNotBillVersions() {
        let invalid = [
            "",
            "   ",
            "119hr1",
            "BILLS-",
            "BILLS-119hr",
            "BILLS-hr1",
            "BILLS-119hr1-ih",
            "BILLS-119hr1ih2",
            "PLAW-119publ1"
        ]

        for guid in invalid {
            XCTAssertNil(BillsService.deriveLocator(from: guid), "Expected no locator for \(guid.debugDescription)")
        }
    }
}

/// `AccountComplianceService.deleteAccountData()` opts in to server-side Cognito
/// user deletion (SEC-07). The backend handler (`accountData/index.ts`) deletes the
/// sign-in account only when `deleteSignIn` is "1" or "true", so a renamed key or
/// changed value would silently leave the Cognito user behind.
final class AccountComplianceServiceRequestTests: XCTestCase {
    @MainActor
    func testDeleteAccountDataOptsInToServerSideSignInDeletion() {
        let parameters = AccountComplianceService.deleteAccountDataQueryParameters
        XCTAssertEqual(parameters.count, 1)
        let value = parameters["deleteSignIn"]
        XCTAssertNotNil(value)
        XCTAssertTrue(["1", "true"].contains(value?.lowercased() ?? ""))
    }
}
