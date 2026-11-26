import Amplify
import CoreTransferable
import Foundation
import UniformTypeIdentifiers
import XCTest
@testable import Billboard

/// Download my votes (UX-40 L7): the page decoding against the contract fixture, the paging through
/// `GET /account-data/votes` (waits, 429 backoff, INVALID_CURSOR restart, errors, cancellation, the cursor sent back as
/// given), the duplicate guard over the whole list, the CSV and JSON writers, the file names, the temporary folder and
/// the share items. The screen's model is in `DownloadVotesModelTests`. No network: requests go through a scripted
/// `APIClient` transport.
@MainActor
final class VoteExportTests: XCTestCase {
    private var folder: VoteExportFolder!

    override func setUp() {
        super.setUp()
        folder = VoteExportFolder(
            root: FileManager.default.temporaryDirectory.appendingPathComponent("VoteExportTests-\(UUID().uuidString)", isDirectory: true)
        )
    }

    override func tearDown() {
        folder.removeAll()
        folder = nil
        super.tearDown()
    }

    // MARK: - Contract

    /// billboard-backend contracts/fixtures/openapi/VoteExport.valid.json, inlined.
    private static let contractFixture = #"""
    {
      "votes": [
        {
          "billId": "BILLS-119hr1285",
          "title": "Clean Energy Access Act",
          "congress": "119",
          "billType": "hr",
          "billNumber": "1285",
          "vote": "Yea",
          "reasons": ["economic_impact", "taxes_spending"],
          "firstVotedAt": "2026-10-01T15:00:00.000Z",
          "votedAt": "2026-10-02T15:00:00.000Z",
          "state": "VA",
          "district": "8",
          "verified": true
        },
        {
          "billId": "BILLS-119s570",
          "title": null,
          "congress": "119",
          "billType": "s",
          "billNumber": "570",
          "vote": "Abstain",
          "reasons": [],
          "firstVotedAt": null,
          "votedAt": null,
          "state": null,
          "district": null,
          "verified": false
        }
      ],
      "nextToken": "sample-cursor-page-2"
    }
    """#

    func testDecodesTheContractFixtureWithANullTitleAndNullTimes() throws {
        let page = try JSONDecoder.usingDefaultKeys().decode(VoteExportPage.self, from: Data(Self.contractFixture.utf8))

        XCTAssertEqual(page.nextToken, "sample-cursor-page-2")
        XCTAssertEqual(page.votes.count, 2)
        XCTAssertEqual(page.votes[0], ExportedVote(
            billId: "BILLS-119hr1285",
            title: "Clean Energy Access Act",
            congress: "119",
            billType: "hr",
            billNumber: "1285",
            vote: .yea,
            reasons: ["economic_impact", "taxes_spending"],
            firstVotedAt: "2026-10-01T15:00:00.000Z",
            votedAt: "2026-10-02T15:00:00.000Z",
            state: "VA",
            district: "8",
            verified: true
        ))
        let second = page.votes[1]
        XCTAssertEqual(second.billId, "BILLS-119s570")
        XCTAssertNil(second.title)
        XCTAssertEqual(second.vote, .abstain)
        XCTAssertEqual(second.reasons, [])
        XCTAssertNil(second.firstVotedAt)
        XCTAssertNil(second.votedAt)
        XCTAssertNil(second.state)
        XCTAssertNil(second.district)
        XCTAssertFalse(second.verified)
    }

    /// The last page has no nextToken.
    func testALastPageHasNoNextToken() throws {
        let page = try JSONDecoder.usingDefaultKeys().decode(VoteExportPage.self, from: Data(#"{"votes":[]}"#.utf8))
        XCTAssertEqual(page.votes, [])
        XCTAssertNil(page.nextToken)
    }

    /// billId, vote, reasons and verified are never null in the contract: a row without one is refused, and so is a
    /// vote other than Yea, Nay or Abstain.
    func testARowWithoutARequiredFieldIsRefused() throws {
        let complete: [String: Any] = [
            "billId": "BILLS-119hr1", "title": NSNull(), "congress": "119", "billType": "hr", "billNumber": "1",
            "vote": "Nay", "reasons": [], "firstVotedAt": NSNull(), "votedAt": NSNull(), "state": NSNull(),
            "district": NSNull(), "verified": false
        ]
        XCTAssertNoThrow(try decodeRow(complete))

        for key in ["billId", "vote", "reasons", "verified"] {
            var missing = complete
            missing.removeValue(forKey: key)
            XCTAssertThrowsError(try decodeRow(missing), "missing \(key)")
            var null = complete
            null[key] = NSNull()
            XCTAssertThrowsError(try decodeRow(null), "null \(key)")
        }
        for vote in ["yea", "Yes", "Skip", ""] {
            var other = complete
            other["vote"] = vote
            XCTAssertThrowsError(try decodeRow(other), vote)
        }
    }

    // MARK: - Paging

    /// Two pages and an empty one that still carries a nextToken: every page is read, about 500 ms apart, and each
    /// cursor goes back exactly as the server gave it.
    func testPagesUntilThereIsNoNextTokenAndSendsEachCursorBackUnchanged() async throws {
        let firstToken = "sample-cursor_page-1"
        let transport = ScriptedTransport([
            .success(try page([vote("BILLS-119hr1"), vote("BILLS-119hr2")], nextToken: firstToken)),
            .success(try page([], nextToken: "empty-page_still-more")),
            .success(try page([vote("BILLS-119s3")], nextToken: nil))
        ])
        let pauses = PauseRecorder()

        let votes = try await APIClient.$current.withValue(transport.client) {
            try await VoteExportService.fetchAllVotes(pause: pauses.pause)
        }

        XCTAssertEqual(votes.map(\.billId), ["BILLS-119hr1", "BILLS-119hr2", "BILLS-119s3"])
        XCTAssertEqual(transport.cursors, [nil, firstToken, "empty-page_still-more"])
        XCTAssertNil(transport.requests[0].queryParameters, "the first page sends no cursor")
        for request in transport.requests {
            XCTAssertEqual(request.method, .get)
            XCTAssertEqual(request.path, "account-data/votes")
            XCTAssertEqual(request.authMode, .requireSignedIn)
            XCTAssertNil(request.body)
        }
        XCTAssertEqual(pauses.pauses, [.milliseconds(500), .milliseconds(500)])
    }

    /// A 429 waits a second and asks for the same page again, with the same cursor.
    func testAThrottledPageIsAskedForAgainWithTheSameCursor() async throws {
        let transport = ScriptedTransport([
            .success(try page([vote("BILLS-119hr1")], nextToken: "page-2")),
            .failure(httpStatusError(429, path: "account-data/votes")),
            .success(try page([vote("BILLS-119hr2")], nextToken: nil))
        ])
        let pauses = PauseRecorder()

        let votes = try await APIClient.$current.withValue(transport.client) {
            try await VoteExportService.fetchAllVotes(pause: pauses.pause)
        }

        XCTAssertEqual(votes.map(\.billId), ["BILLS-119hr1", "BILLS-119hr2"])
        XCTAssertEqual(transport.cursors, [nil, "page-2", "page-2"])
        XCTAssertEqual(pauses.pauses, [.milliseconds(500), .seconds(1)])
    }

    /// 429 after 429: it waits 1 s, 2 s and 4 s, asking again after each, then gives up with the error.
    func testThrottlingThatDoesNotEndIsTheError() async throws {
        let transport = ScriptedTransport(Array(repeating: .failure(httpStatusError(429, path: "account-data/votes")), count: 4))
        let pauses = PauseRecorder()

        do {
            _ = try await APIClient.$current.withValue(transport.client) {
                try await VoteExportService.fetchAllVotes(pause: pauses.pause)
            }
            XCTFail("expected the 429 to end the load")
        } catch {
            XCTAssertEqual(APIErrorDebug.httpStatusCode(from: error), 429)
        }
        XCTAssertEqual(transport.cursors, [nil, nil, nil, nil])
        XCTAssertEqual(pauses.pauses, [.seconds(1), .seconds(2), .seconds(4)])
    }

    /// The screen ends in its error state when the throttle does not let up.
    func testThrottlingThatDoesNotEndShowsTheErrorState() async throws {
        let transport = ScriptedTransport(Array(repeating: .failure(httpStatusError(429, path: "account-data/votes")), count: 4))
        let model = DownloadVotesModel(service: PacedVoteExportService(pause: PauseRecorder().pause), folder: folder)

        await APIClient.$current.withValue(transport.client) {
            await model.load()
        }

        XCTAssertEqual(model.phase, .failed)
        XCTAssertEqual(transport.requests.count, 4)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.root.path))
    }

    /// INVALID_CURSOR starts again from the first page, once, and the votes read before it are not kept twice.
    func testAnInvalidCursorStartsAgainFromTheFirstPageOnce() async throws {
        let transport = ScriptedTransport([
            .success(try page([vote("BILLS-119hr1")], nextToken: "stale")),
            .failure(backendError("INVALID_CURSOR")),
            .success(try page([vote("BILLS-119hr1")], nextToken: "fresh")),
            .success(try page([vote("BILLS-119hr2")], nextToken: nil))
        ])
        let pauses = PauseRecorder()

        let votes = try await APIClient.$current.withValue(transport.client) {
            try await VoteExportService.fetchAllVotes(pause: pauses.pause)
        }

        XCTAssertEqual(votes.map(\.billId), ["BILLS-119hr1", "BILLS-119hr2"])
        XCTAssertEqual(transport.cursors, [nil, "stale", nil, "fresh"])
        XCTAssertEqual(pauses.pauses, Array(repeating: .milliseconds(500), count: 3))
    }

    /// A second INVALID_CURSOR is the error, and so is one on the first page, which sends no cursor.
    func testASecondInvalidCursorIsTheError() async throws {
        let transport = ScriptedTransport([
            .success(try page([vote("BILLS-119hr1")], nextToken: "stale")),
            .failure(backendError("INVALID_CURSOR")),
            .success(try page([vote("BILLS-119hr1")], nextToken: "stale-again")),
            .failure(backendError("INVALID_CURSOR"))
        ])
        await assertFails(transport, requests: 4)

        let firstPage = ScriptedTransport([.failure(backendError("INVALID_CURSOR"))])
        await assertFails(firstPage, requests: 1)
    }

    /// INVALID_CURSOR is told by its code, the path the app runs (Amplify's error that carries a status and a body
    /// cannot be built in tests); a plain 400 or another code is not it.
    func testAnInvalidCursorIsToldByItsCode() {
        XCTAssertTrue(VoteExportService.isInvalidCursor(backendError("INVALID_CURSOR")))
        XCTAssertFalse(VoteExportService.isInvalidCursor(backendError("MISSING_BILL_ID")))
        XCTAssertFalse(VoteExportService.isInvalidCursor(httpStatusError(400, path: "account-data/votes")))
        XCTAssertFalse(VoteExportService.isInvalidCursor(httpStatusError(429, path: "account-data/votes")))
    }

    /// A plain 400, another code, or a 500 is the error at once, with no restart and no wait.
    func testOtherFailuresAreTheError() async throws {
        let failures: [Error] = [
            httpStatusError(400, path: "account-data/votes"),
            backendError("MISSING_BILL_ID"),
            httpStatusError(500, path: "account-data/votes"),
            httpStatusError(401, path: "account-data/votes")
        ]
        for failure in failures {
            let transport = ScriptedTransport([
                .success(try page([vote("BILLS-119hr1")], nextToken: "page-2")),
                .failure(failure)
            ])
            await assertFails(transport, requests: 2)
        }
    }

    /// A page the app cannot read is the error.
    func testAPageThatDoesNotDecodeIsTheError() async throws {
        await assertFails(ScriptedTransport([.success(Data(#"{"votes":[{"billId":"BILLS-119hr1"}]}"#.utf8))]), requests: 1)
        await assertFails(ScriptedTransport([.success(Data())]), requests: 1)
    }

    /// A cancelled load asks nothing more and throws `CancellationError`, whether it is cancelled before the first page
    /// or during the wait between pages.
    func testACancelledLoadStopsAndThrowsCancellation() async throws {
        let untouched = ScriptedTransport([])
        let task = Task { @MainActor in
            try await APIClient.$current.withValue(untouched.client) {
                try await VoteExportService.fetchAllVotes(pause: PauseRecorder().pause)
            }
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected a cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertEqual(untouched.requests.count, 0)

        let transport = ScriptedTransport([
            .success(try page([vote("BILLS-119hr1")], nextToken: "page-2")),
            .success(try page([vote("BILLS-119hr2")], nextToken: nil))
        ])
        let cancelling: VoteExportService.Pause = { _ in throw CancellationError() }
        do {
            _ = try await APIClient.$current.withValue(transport.client) {
                try await VoteExportService.fetchAllVotes(pause: cancelling)
            }
            XCTFail("expected a cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertEqual(transport.requests.count, 1)
    }

    // MARK: - Duplicate guard

    /// A legacy suffixed row beside its plain row is left out; a suffixed row with no plain twin stays.
    func testALegacyTwinIsLeftOutAndALoneSuffixedRowStays() {
        let votes = [
            vote("BILLS-119hr1181"),
            vote("BILLS-119hr1181rh", vote: .nay),
            vote("BILLS-119hr1182ih"),
            vote("not-a-bill-guid"),
            vote("not-a-bill-guid")
        ]
        XCTAssertEqual(
            VoteExport.removingLegacyTwins(votes).map(\.billId),
            ["BILLS-119hr1181", "BILLS-119hr1182ih", "not-a-bill-guid", "not-a-bill-guid"]
        )
    }

    /// The plain row wins wherever it comes in the list, and of two suffixed rows without one the first stays.
    func testThePlainRowWinsInAnyOrder() {
        let votes = [
            vote("BILLS-119hr7ih"),
            vote("BILLS-119hr7rh"),
            vote("BILLS-119hr7", vote: .nay),
            vote("BILLS-119s9is"),
            vote("BILLS-119s9rs")
        ]
        let kept = VoteExport.removingLegacyTwins(votes)
        XCTAssertEqual(kept.map(\.billId), ["BILLS-119hr7", "BILLS-119s9is"])
        XCTAssertEqual(kept.first?.vote, .nay)
    }

    /// The guard runs over every page: BILLS-119hr11810 sorts between BILLS-119hr1181 and BILLS-119hr1181rh, so the twin
    /// can come a page after its plain row.
    func testATwinOnALaterPageIsLeftOut() async throws {
        let transport = ScriptedTransport([
            .success(try page([vote("BILLS-119hr1181"), vote("BILLS-119hr11810")], nextToken: "page-2")),
            .success(try page([vote("BILLS-119hr1181rh", vote: .nay), vote("BILLS-119hr1182")], nextToken: nil))
        ])

        let votes = try await APIClient.$current.withValue(transport.client) {
            try await VoteExportService.fetchAllVotes(pause: PauseRecorder().pause)
        }

        XCTAssertEqual(votes.map(\.billId), ["BILLS-119hr1181", "BILLS-119hr11810", "BILLS-119hr1182"])
        XCTAssertEqual(votes.first?.vote, .yea)
    }

    // MARK: - CSV

    private static let header = "Bill,Congress,Title,Your vote,Reasons,First voted,Last changed,State,District,Verified"

    /// The fixture's two votes, word for word: the byte order mark, the header as approved, CRLF line ends, the Bill
    /// from the type and number, the 119th, reason labels, UTC times, empty cells for nulls, and a null title as the
    /// bill id.
    func testTheCSVOfTheFixture() throws {
        let page = try JSONDecoder.usingDefaultKeys().decode(VoteExportPage.self, from: Data(Self.contractFixture.utf8))
        let data = VoteExport.csv(page.votes)

        XCTAssertEqual(Array(data.prefix(3)), [0xEF, 0xBB, 0xBF], "UTF-8 byte order mark")
        // Read past the mark by hand: Foundation's UTF-8 decoding drops it.
        let text = try XCTUnwrap(String(bytes: data.dropFirst(3), encoding: .utf8))
        XCTAssertEqual(
            text,
            Self.header + "\r\n"
                + "H.R. 1285,119th,Clean Energy Access Act,Yea,Economic Impact / Jobs; Taxes / Spending,2026-10-01T15:00:00Z,2026-10-02T15:00:00Z,VA,8,Verified\r\n"
                + "S. 570,119th,BILLS-119s570,Abstain,,,,,,Not verified\r\n"
        )
    }

    /// The header is the approved one, kept in one list of columns.
    func testTheHeaderIsTheApprovedOne() {
        XCTAssertEqual(VoteExport.columns.map(\.header).joined(separator: ","), Self.header)
        XCTAssertEqual(VoteExport.columns.count, 10)
    }

    /// RFC 4180: a field with a comma, a quote or a line break goes in quotes, its quotes doubled; others stay bare.
    func testCSVQuotesCommasQuotesAndLineBreaks() throws {
        XCTAssertEqual(VoteExport.csvField("Plain title"), "Plain title")
        XCTAssertEqual(VoteExport.csvField("Jobs, Wages and Growth Act"), "\"Jobs, Wages and Growth Act\"")
        XCTAssertEqual(VoteExport.csvField(#"The "Fair" Act"#), #""The ""Fair"" Act""#)
        XCTAssertEqual(VoteExport.csvField("Line one\nLine two"), "\"Line one\nLine two\"")
        XCTAssertEqual(VoteExport.csvField("Line one\r\nLine two"), "\"Line one\r\nLine two\"")
        XCTAssertEqual(VoteExport.csvField("Carriage\rreturn"), "\"Carriage\rreturn\"")

        let row = try csvRows([vote("BILLS-119hr1", title: "A \"quoted\", long\ntitle")])[1]
        XCTAssertEqual(row, "H.R. 1,119th,\"A \"\"quoted\"\", long\ntitle\",Yea,,,,,,Not verified")
    }

    /// Reasons are the app's labels joined with "; ", Need More Information included; a key the app does not know is
    /// humanized as Why people voted shows it.
    func testReasonLabels() throws {
        let votes = [
            vote("BILLS-119hr1", reasons: ["economic_impact", "need_more_info", "some_new_reason"]),
            vote("BILLS-119hr2", vote: .abstain, reasons: ["need_more_info"])
        ]
        let rows = try csvRows(votes)
        XCTAssertEqual(cells(rows[1])[4], "Economic Impact / Jobs; Need More Information; Some New Reason")
        XCTAssertEqual(cells(rows[2])[4], "Need More Information")
        XCTAssertEqual(votes[0].reasonLabels, ["Economic Impact / Jobs", "Need More Information", "Some New Reason"])
    }

    /// Verified and Not verified; the vote as Yea, Nay or Abstain.
    func testVoteAndVerifiedCells() throws {
        let rows = try csvRows([
            vote("BILLS-119hr1", vote: .yea, verified: true),
            vote("BILLS-119hr2", vote: .nay, verified: false),
            vote("BILLS-119hr3", vote: .abstain, verified: true)
        ])
        XCTAssertEqual(rows[1...3].map { Array(cells($0)[3...]) }, [
            ["Yea", "", "", "", "", "", "Verified"],
            ["Nay", "", "", "", "", "", "Not verified"],
            ["Abstain", "", "", "", "", "", "Verified"]
        ])
    }

    /// Bill: from the bill type and number, else from the bill id, else the bill id itself. A null title prints the
    /// bill id.
    func testBillAndTitleCells() throws {
        let rows = try csvRows([
            ExportedVote(billId: "BILLS-119sjres12is", title: nil, congress: "119", billType: "sjres", billNumber: "12", vote: .yea, reasons: [], firstVotedAt: nil, votedAt: nil, state: nil, district: nil, verified: false),
            ExportedVote(billId: "BILLS-119hconres5", title: "  ", congress: "119", billType: nil, billNumber: nil, vote: .nay, reasons: [], firstVotedAt: nil, votedAt: nil, state: nil, district: nil, verified: false),
            ExportedVote(billId: "legacy-id", title: nil, congress: nil, billType: nil, billNumber: nil, vote: .abstain, reasons: [], firstVotedAt: nil, votedAt: nil, state: nil, district: nil, verified: false)
        ])
        XCTAssertEqual(Array(cells(rows[1])[0...2]), ["S.J.Res. 12", "119th", "BILLS-119sjres12is"])
        XCTAssertEqual(Array(cells(rows[2])[0...2]), ["H.Con.Res. 5", "119th", "BILLS-119hconres5"])
        XCTAssertEqual(Array(cells(rows[3])[0...2]), ["legacy-id", "", "legacy-id"])
    }

    /// Congress: the ordinal of the row's Congress ("119th"; 111th to 113th take "th"), empty when it is null.
    func testCongressOrdinals() {
        let expected: [String?: String] = [
            "111": "111th", "112": "112th", "113": "113th", "114": "114th", "119": "119th", "120": "120th",
            "121": "121st", "122": "122nd", "123": "123rd", "124": "124th", "201": "201st", "211": "211th", nil: ""
        ]
        for (congress, label) in expected {
            let row = ExportedVote(billId: "BILLS-1hr1", title: nil, congress: congress, billType: "hr", billNumber: "1", vote: .yea, reasons: [], firstVotedAt: nil, votedAt: nil, state: nil, district: nil, verified: false)
            XCTAssertEqual(row.congressLabel, label, String(describing: congress))
            XCTAssertEqual(VoteExport.columns[1].value(row), label)
        }
    }

    /// First voted and Last changed are ISO 8601 in UTC; State, District and the times are empty when null.
    func testTimesStateAndDistrictCells() throws {
        let rows = try csvRows([
            ExportedVote(billId: "BILLS-119hr1", title: "T", congress: "119", billType: "hr", billNumber: "1", vote: .yea, reasons: [], firstVotedAt: "2026-10-01T15:00:00.123Z", votedAt: "2026-10-02T15:00:00Z", state: "AK", district: "0", verified: true),
            ExportedVote(billId: "BILLS-119hr2", title: "T", congress: "119", billType: "hr", billNumber: "2", vote: .yea, reasons: [], firstVotedAt: nil, votedAt: nil, state: nil, district: nil, verified: true)
        ])
        XCTAssertEqual(Array(cells(rows[1])[5...8]), ["2026-10-01T15:00:00Z", "2026-10-02T15:00:00Z", "AK", "0"])
        XCTAssertEqual(Array(cells(rows[2])[5...8]), ["", "", "", ""])
        XCTAssertEqual(VoteExport.utcTime("not a time"), "not a time")
    }

    // MARK: - JSON

    /// The JSON is pretty-printed with sorted keys: exportedAt, then each vote's server fields (nulls written out) with
    /// its bill number and reason labels. Its votes read back as the server sent them. The app only writes the
    /// document, so the test reads it as plain JSON.
    func testTheJSONReadsBackAsWritten() throws {
        let page = try JSONDecoder.usingDefaultKeys().decode(VoteExportPage.self, from: Data(Self.contractFixture.utf8))
        let exportedAt = Date(timeIntervalSince1970: 1_795_000_000)
        let data = try VoteExport.json(page.votes, exportedAt: exportedAt)

        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.hasPrefix("{\n  \"exportedAt\" : \""), text)
        XCTAssertLessThan(try XCTUnwrap(text.range(of: "\"exportedAt\"")).lowerBound, try XCTUnwrap(text.range(of: "\"votes\"")).lowerBound)

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["exportedAt", "votes"])
        XCTAssertEqual(object["exportedAt"] as? String, exportedAt.formatted(.iso8601))
        let rows = try XCTUnwrap(object["votes"] as? [[String: Any]])
        XCTAssertEqual(rows.map { $0["bill"] as? String }, ["H.R. 1285", "S. 570"])
        XCTAssertEqual(rows.map { $0["reasonLabels"] as? [String] }, [["Economic Impact / Jobs", "Taxes / Spending"], []])
        let second = try XCTUnwrap(rows.last)
        XCTAssertEqual(Set(second.keys), [
            "bill", "billId", "billNumber", "billType", "congress", "district", "firstVotedAt", "reasonLabels", "reasons",
            "state", "title", "verified", "vote", "votedAt"
        ])
        XCTAssertTrue(second["title"] is NSNull, "a null stays null")
        XCTAssertEqual(second["vote"] as? String, "Abstain")
        XCTAssertEqual(second["verified"] as? Bool, false)

        // The server's fields read back as the wire type.
        let votes = try XCTUnwrap(object["votes"])
        let wire = try JSONDecoder().decode([ExportedVote].self, from: JSONSerialization.data(withJSONObject: votes))
        XCTAssertEqual(wire, page.votes)
    }

    // MARK: - File names

    /// The file names carry the device's own calendar day.
    func testFileNamesUseTheLocalDate() throws {
        let instant = try Date("2026-11-22T03:30:00Z", strategy: .iso8601)
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let pacific = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))

        XCTAssertEqual(VoteExport.fileName(.csv, at: instant, timeZone: utc), "Billboard votes 2026-11-22.csv")
        XCTAssertEqual(VoteExport.fileName(.json, at: instant, timeZone: utc), "Billboard votes 2026-11-22.json")
        XCTAssertEqual(VoteExport.fileName(.csv, at: instant, timeZone: pacific), "Billboard votes 2026-11-21.csv")
    }

    // MARK: - Files and privacy

    /// Both files go in a fresh folder that is excluded from backup, written from the same votes.
    func testTheFilesGoInAFreshFolderExcludedFromBackup() throws {
        let votes = [vote("BILLS-119hr1"), vote("BILLS-119hr2", vote: .nay)]
        let exportedAt = try Date("2026-11-22T12:00:00Z", strategy: .iso8601)
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))

        let first = try folder.write(votes, exportedAt: exportedAt, timeZone: utc)
        let second = try folder.write(votes, exportedAt: exportedAt, timeZone: utc)

        XCTAssertNotEqual(first.folder, second.folder, "a fresh folder each time")
        XCTAssertEqual(first.folder.deletingLastPathComponent().standardizedFileURL, folder.root.standardizedFileURL)
        XCTAssertEqual(first.csv.lastPathComponent, "Billboard votes 2026-11-22.csv")
        XCTAssertEqual(first.json.lastPathComponent, "Billboard votes 2026-11-22.json")
        XCTAssertEqual(try Data(contentsOf: first.csv), VoteExport.csv(votes))
        XCTAssertEqual(try Data(contentsOf: first.json), try VoteExport.json(votes, exportedAt: exportedAt))
        for url in [folder.root, first.folder] {
            let fresh = URL(fileURLWithPath: url.path, isDirectory: true)
            XCTAssertEqual(try fresh.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true, url.lastPathComponent)
        }
    }

    /// Each save button hands the share sheet its file, by its own name, as CSV or as JSON.
    func testTheShareItemsHandOverTheirFiles() async throws {
        let written = try folder.write([vote("BILLS-119hr1")], exportedAt: Date())
        let csvItem = VoteExportCSVFile(url: written.csv)
        let jsonItem = VoteExportJSONFile(url: written.json)

        XCTAssertEqual(VoteExportCSVFile.exportedContentTypes(), [.commaSeparatedText])
        XCTAssertEqual(VoteExportJSONFile.exportedContentTypes(), [.json])
        let csvData = try await csvItem.exported(as: .commaSeparatedText)
        let jsonData = try await jsonItem.exported(as: .json)
        XCTAssertEqual(csvData, try Data(contentsOf: written.csv))
        XCTAssertEqual(jsonData, try Data(contentsOf: written.json))
        let csvName = try await csvItem.withExportedFile(contentType: .commaSeparatedText) { $0.lastPathComponent }
        let jsonName = try await jsonItem.withExportedFile(contentType: .json) { $0.lastPathComponent }
        XCTAssertEqual(csvName, written.csv.lastPathComponent)
        XCTAssertEqual(jsonName, written.json.lastPathComponent)
    }

}

// MARK: - Helpers

private extension VoteExportTests {
    func vote(
        _ billId: String,
        title: String? = "A bill",
        vote: VoteType = .yea,
        reasons: [String] = [],
        verified: Bool = false
    ) -> ExportedVote {
        ExportedVote(
            billId: billId,
            title: title,
            congress: billId.hasPrefix("BILLS-") ? "119" : nil,
            billType: nil,
            billNumber: nil,
            vote: vote,
            reasons: reasons,
            firstVotedAt: nil,
            votedAt: nil,
            state: nil,
            district: nil,
            verified: verified
        )
    }

    func page(_ votes: [ExportedVote], nextToken: String?) throws -> Data {
        var object: [String: Any] = ["votes": try JSONSerialization.jsonObject(with: JSONEncoder().encode(votes))]
        if let nextToken { object["nextToken"] = nextToken }
        return try JSONSerialization.data(withJSONObject: object)
    }

    func decodeRow(_ row: [String: Any]) throws -> ExportedVote {
        try JSONDecoder.usingDefaultKeys().decode(ExportedVote.self, from: JSONSerialization.data(withJSONObject: row))
    }

    /// The CSV's lines without the byte order mark: the header first.
    func csvRows(_ votes: [ExportedVote]) throws -> [String] {
        let data = VoteExport.csv(votes)
        XCTAssertEqual(Array(data.prefix(3)), [0xEF, 0xBB, 0xBF], "UTF-8 byte order mark")
        // Read past the mark by hand: Foundation's UTF-8 decoding drops it.
        let text = try XCTUnwrap(String(bytes: data.dropFirst(3), encoding: .utf8))
        XCTAssertTrue(text.hasSuffix("\r\n"))
        var rows = text.components(separatedBy: "\r\n")
        XCTAssertEqual(rows.removeLast(), "", "every line ends in CRLF")
        return rows
    }

    /// A CSV line's cells, for lines without quoted fields.
    func cells(_ row: String) -> [String] {
        row.components(separatedBy: ",")
    }

    func assertFails(_ transport: ScriptedTransport, requests: Int, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await APIClient.$current.withValue(transport.client) {
                try await VoteExportService.fetchAllVotes(pause: PauseRecorder().pause)
            }
            XCTFail("expected the load to fail", file: file, line: line)
        } catch {
            XCTAssertFalse(error is CancellationError, file: file, line: line)
        }
        XCTAssertEqual(transport.requests.count, requests, file: file, line: line)
    }
}

// MARK: - Fakes

/// Answers each request with the next scripted result and records it; a request past the script fails the test.
@MainActor
private final class ScriptedTransport {
    private(set) var requests: [APIClient.Request] = []
    private var script: [Result<Data, Error>]

    init(_ script: [Result<Data, Error>]) {
        self.script = script
    }

    var client: APIClient {
        APIClient(transport: { [self] request in
            try await self.respond(to: request)
        })
    }

    /// The cursor each request sent, nil for none.
    var cursors: [String?] {
        requests.map { $0.queryParameters?["cursor"] }
    }

    private func respond(to request: APIClient.Request) throws -> Data {
        requests.append(request)
        guard !script.isEmpty else {
            XCTFail("unexpected request \(requests.count)")
            throw FakeServiceError()
        }
        return try script.removeFirst().get()
    }
}

/// Records the waits the service asks for, and returns at once (or throws when the task is cancelled).
@MainActor
private final class PauseRecorder {
    private(set) var pauses: [Duration] = []

    var pause: VoteExportService.Pause {
        { [self] duration in
            await self.record(duration)
            try Task.checkCancellation()
        }
    }

    private func record(_ duration: Duration) {
        pauses.append(duration)
    }
}

/// The live paging with a test's waits, for the screen model.
@MainActor
private struct PacedVoteExportService: VoteExportServicing {
    let pause: VoteExportService.Pause

    func fetchAllVotes() async throws -> [ExportedVote] {
        try await VoteExportService.fetchAllVotes(pause: pause)
    }
}
