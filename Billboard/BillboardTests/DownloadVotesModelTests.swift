import Foundation
import XCTest
@testable import Billboard

/// Download my votes (UX-40 L7), the screen's model: one response written as both files, what VoiceOver is told in
/// each state, the files deleted when the screen goes and before the next load, a cancelled load that stays quiet
/// and leaves no files, Try again, and sign-out deleting every export. No network: the model gets a fake service.
@MainActor
final class DownloadVotesModelTests: XCTestCase {
    private var folder: VoteExportFolder!

    override func setUp() {
        super.setUp()
        folder = VoteExportFolder(
            root: FileManager.default.temporaryDirectory.appendingPathComponent("DownloadVotesModelTests-\(UUID().uuidString)", isDirectory: true)
        )
    }

    override func tearDown() {
        folder.removeAll()
        folder = nil
        super.tearDown()
    }

    func testReadyStateWritesBothFilesFromOneResponse() async throws {
        let service = FakeVoteExportService(.success([vote("BILLS-119hr1"), vote("BILLS-119hr1rh"), vote("BILLS-119s2")]))
        let model = DownloadVotesModel(service: service, folder: folder)
        XCTAssertEqual(model.phase, .preparing)
        XCTAssertEqual(model.announcement, "Preparing your votes…")

        await model.load()

        guard case .ready(let files) = model.phase else { return XCTFail("expected ready, got \(model.phase)") }
        XCTAssertEqual(service.calls, 1)
        let csvRows = try XCTUnwrap(String(data: Data(contentsOf: files.csv), encoding: .utf8)).components(separatedBy: "\r\n")
        let document = try JSONDecoder().decode(VoteExportDocument.self, from: Data(contentsOf: files.json))
        XCTAssertEqual(csvRows.count - 2, 3, "one header, one row per vote, a final CRLF")
        XCTAssertEqual(document.votes.count, 3)
        XCTAssertNil(model.announcement, "the approved copy has no line for ready: nothing is said")
    }

    /// A new load first removes every export on disk, such as one left by an app that was closed while the screen
    /// showed, whether it ends with files, with no votes or in the error state; only a new export stays.
    func testANewLoadRemovesAnExportLeftFromBefore() async throws {
        let error = httpStatusError(500, path: "account-data/votes")
        for result in [Result<[ExportedVote], Error>.success([vote("BILLS-119hr2")]), .success([]), .failure(error)] {
            let left = try folder.write([vote("BILLS-119hr1")], exportedAt: Date())
            let model = DownloadVotesModel(service: FakeVoteExportService(result), folder: folder)
            await model.load()
            XCTAssertFalse(FileManager.default.fileExists(atPath: left.folder.path), "\(model.phase)")
            let kept = (try? FileManager.default.contentsOfDirectory(atPath: folder.root.path)) ?? []
            if case .ready(let files) = model.phase {
                XCTAssertEqual(kept, [files.folder.lastPathComponent], "only the new export")
            } else {
                XCTAssertEqual(kept, [], "\(model.phase)")
            }
        }
    }

    func testEmptyState() async {
        let model = DownloadVotesModel(service: FakeVoteExportService(.success([])), folder: folder)
        await model.load()
        XCTAssertEqual(model.phase, .empty)
        XCTAssertEqual(model.announcement, "You haven't voted on a bill yet.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.root.path), "no files for no votes")
    }

    func testErrorStateAndTryAgain() async {
        let service = FakeVoteExportService(.failure(httpStatusError(500, path: "account-data/votes")), .success([vote("BILLS-119hr1")]))
        let model = DownloadVotesModel(service: service, folder: folder)

        await model.load()
        XCTAssertEqual(model.phase, .failed)
        XCTAssertEqual(model.announcement, "Couldn't prepare your votes")

        await model.load()
        guard case .ready = model.phase else { return XCTFail("expected ready, got \(model.phase)") }
        XCTAssertEqual(service.calls, 2)
    }

    /// A load cancelled while it waits for the server stays quiet: no error, no files.
    func testACancelledLoadStaysQuiet() async {
        let service = FakeVoteExportService(.success([vote("BILLS-119hr1")]))
        service.waitsForCancellation = true
        let model = DownloadVotesModel(service: service, folder: folder)

        let task = Task { await model.load() }
        while service.calls == 0 { await Task.yield() }
        task.cancel()
        await task.value

        XCTAssertEqual(model.phase, .preparing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.root.path))
    }

    /// The model deletes its files when the screen goes, and sign-out deletes every export (both purge paths).
    func testTheFilesAreDeletedOnDisappearAndAtSignOut() async throws {
        let model = DownloadVotesModel(service: FakeVoteExportService(.success([vote("BILLS-119hr1")])), folder: folder)
        await model.load()
        guard case .ready(let files) = model.phase else { return XCTFail("expected ready, got \(model.phase)") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: files.csv.path))
        model.discardFiles()
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.folder.path))

        let suiteName = "DownloadVotesModelTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        for userId in ["account-a", nil] {
            let written = try VoteExportFolder.standard.write([vote("BILLS-119hr1")], exportedAt: Date())
            XCTAssertTrue(FileManager.default.fileExists(atPath: written.json.path))
            UserLocalDataPurge.purge(userId: userId, defaults: defaults)
            XCTAssertFalse(FileManager.default.fileExists(atPath: VoteExportFolder.standard.root.path), String(describing: userId))
        }
    }

    // MARK: - Helpers

    private func vote(_ billId: String) -> ExportedVote {
        ExportedVote(
            billId: billId,
            title: "A bill",
            congress: "119",
            billType: nil,
            billNumber: nil,
            vote: .yea,
            reasons: [],
            firstVotedAt: nil,
            votedAt: nil,
            state: nil,
            district: nil,
            verified: false
        )
    }
}

// MARK: - Fakes

/// Answers successive loads with these results (the last repeats) after a short wait, as the network takes one, so a
/// screen shows its loading line first; can wait until it is cancelled instead.
@MainActor
final class FakeVoteExportService: VoteExportServicing {
    private var results: [Result<[ExportedVote], Error>]
    private(set) var calls = 0
    var waitsForCancellation = false

    init(_ results: Result<[ExportedVote], Error>...) {
        self.results = results
    }

    func fetchAllVotes() async throws -> [ExportedVote] {
        calls += 1
        try await Task.sleep(for: waitsForCancellation ? .seconds(60) : .milliseconds(30))
        let result = results.count > 1 ? results.removeFirst() : results[0]
        return try result.get()
    }
}
