import Foundation
import os
import XCTest
@testable import Billboard

/// Download my votes (UX-40 L7), the screen's model: one response written as both files, what VoiceOver is told in
/// each state, the files kept after the screen goes until it shows again (one export at most on disk), a cancelled
/// load (while it waits or while it writes) that stays quiet and leaves no files, Try again, and sign-out deleting
/// every export. No network: the model gets a fake service.
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
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: files.json)) as? [String: Any])
        XCTAssertEqual(csvRows.count - 2, 3, "one header, one row per vote, a final CRLF")
        XCTAssertEqual((document["votes"] as? [Any])?.count, 3)
        XCTAssertEqual(model.announcement, "Your votes are ready.")
    }

    /// The files stay after the screen goes, for a share extension that reads its file late. The next showing
    /// removes them before it writes its own, so the folder never holds more than one export.
    func testAnExportStaysUntilTheNextShowingWhichReplacesIt() async throws {
        var earlier: VoteExportFileSet?
        for showing in 1...3 {
            let model = DownloadVotesModel(service: FakeVoteExportService(.success([vote("BILLS-119hr\(showing)")])), folder: folder)
            if let earlier {
                XCTAssertTrue(FileManager.default.fileExists(atPath: earlier.csv.path), "showing \(showing): the last export is still there")
                XCTAssertTrue(FileManager.default.fileExists(atPath: earlier.json.path), "showing \(showing)")
            }
            await model.load()
            guard case .ready(let files) = model.phase else { return XCTFail("showing \(showing): expected ready, got \(model.phase)") }
            let kept = (try? FileManager.default.contentsOfDirectory(atPath: folder.root.path)) ?? []
            XCTAssertEqual(kept, [files.folder.lastPathComponent], "showing \(showing): one export at most")
            earlier = files
        }
    }

    /// A load cancelled while it writes the files (the screen went) removes what it wrote and stays quiet.
    func testACancelWhileTheFilesAreWrittenLeavesNoFiles() async throws {
        let written = OSAllocatedUnfairLock<VoteExportFileSet?>(initialState: nil)
        let model = DownloadVotesModel(
            service: FakeVoteExportService(.success([vote("BILLS-119hr1")])),
            folder: folder,
            writer: { votes, folder, exportedAt, timeZone in
                let files = try folder.write(votes, exportedAt: exportedAt, timeZone: timeZone)
                written.withLock { $0 = files }
                // The screen goes while the files are written.
                withUnsafeCurrentTask { $0?.cancel() }
                return files
            }
        )

        let task = Task { await model.load() }
        await task.value

        let files = try XCTUnwrap(written.withLock { $0 }, "the writer ran")
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.folder.path), "what was written is removed")
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: folder.root.path)) ?? [], [])
        XCTAssertEqual(model.phase, .preparing, "no error, no files offered")
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

    /// The screen's task runs again whenever the screen shows again (after a full-screen extension, say): a request
    /// that loaded to an end is not loaded again, so its files stay. Try again's new request loads; so does a request
    /// whose load was cancelled before it ended.
    func testARequestLoadsOnceUnlessItWasCancelled() async throws {
        let service = FakeVoteExportService(.success([vote("BILLS-119hr1")]))
        let model = DownloadVotesModel(service: service, folder: folder)

        await model.load(request: 0)
        guard case .ready(let files) = model.phase else { return XCTFail("expected ready, got \(model.phase)") }
        await model.load(request: 0)
        XCTAssertEqual(service.calls, 1)
        XCTAssertEqual(model.phase, .ready(files))
        XCTAssertTrue(FileManager.default.fileExists(atPath: files.csv.path), "the files stay")

        await model.load(request: 1)
        XCTAssertEqual(service.calls, 2, "Try again loads")

        service.waitsForCancellation = true
        let task = Task { await model.load(request: 2) }
        while service.calls == 2 { await Task.yield() }
        task.cancel()
        await task.value
        XCTAssertEqual(model.phase, .preparing)
        service.waitsForCancellation = false
        await model.load(request: 2)
        XCTAssertEqual(service.calls, 4, "a cancelled request loads when the screen shows again")
        guard case .ready = model.phase else { return XCTFail("expected ready, got \(model.phase)") }
    }

    /// Sign-out deletes every export, on both purge paths (an account, and no account).
    func testSignOutDeletesEveryExport() throws {
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
