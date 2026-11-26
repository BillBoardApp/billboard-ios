import Foundation
import os

/// Download my votes (UX-40 L7): every one of the caller's votes from `GET /account-data/votes`, a page at a time.
///
/// - Pages until a page has no `nextToken` (a page can be empty and still carry one), about `pageGap` apart. The
///   token goes back as `cursor` exactly as given: the app never reads, builds or changes one.
/// - A 429 (the route's own throttle, 2 a second with a burst of 4 for all callers together, answered with no
///   Retry-After) waits 1 s, 2 s, then 4 s and asks for the same page again; a fourth 429 is the error. `APIRequest`
///   retries a GET only after a 5xx or a network failure.
/// - A 400 `INVALID_CURSOR` starts again from the first page, once. Any other failure is the error.
/// - Cancellation stops it at the next request or wait and throws `CancellationError`.
/// - After the last page, `VoteExport.removingLegacyTwins` keeps one row per bill over the whole list.
///
/// Logs hold counts only: never a bill id, a vote, a title or a cursor.
enum VoteExportService {
    static let path = "account-data/votes"
    /// The server's code for a cursor it did not give this caller (tampered, another caller's, or malformed).
    static let invalidCursorCode = "INVALID_CURSOR"
    /// The wait before each page after the first.
    static let pageGap: Duration = .milliseconds(500)
    /// The waits before asking for a throttled page again.
    static let throttleBackoff: [Duration] = [.seconds(1), .seconds(2), .seconds(4)]
    /// A stop for a server that never ends the list: far more pages than anyone has votes (500 rows a page).
    static let maxPages = 1_000

    /// Waits; throws `CancellationError` when the task is cancelled. Tests pass one that only records.
    typealias Pause = @Sendable (Duration) async throws -> Void
    nonisolated static let livePause: Pause = { duration in
        try await Task.sleep(for: duration)
    }

    private static let label = "VoteExportService account-data/votes"

    /// Every one of the caller's votes, one row per bill, in the server's order (by bill id).
    static func fetchAllVotes(pause: Pause = livePause) async throws -> [ExportedVote] {
        var votes: [ExportedVote] = []
        var cursor: String?
        var restarted = false
        var pages = 0

        while true {
            try Task.checkCancellation()
            if pages > 0 { try await pause(pageGap) }

            let page: VoteExportPage
            do {
                page = try await fetchPage(cursor: cursor, pause: pause)
            } catch {
                guard cursor != nil, !restarted, isInvalidCursor(error) else { throw error }
                AppLog.api.info("[\(label, privacy: .public)] INVALID_CURSOR after \(pages) pages; starting again from the first page")
                restarted = true
                votes = []
                cursor = nil
                continue
            }

            pages += 1
            votes += page.votes
            guard let nextToken = page.nextToken else { break }
            guard pages < maxPages else {
                AppLog.api.error("[\(label, privacy: .public)] still more after \(pages) pages; stopping")
                throw APIServiceError.invalidPayload(path)
            }
            cursor = nextToken
        }

        let kept = VoteExport.removingLegacyTwins(votes)
        AppLog.api.info("[\(label, privacy: .public)] pages=\(pages) votes=\(kept.count) legacyTwinsLeftOut=\(votes.count - kept.count)")
        return kept
    }

    /// One page, asked for again after a 429 (`throttleBackoff`).
    private static func fetchPage(cursor: String?, pause: Pause) async throws -> VoteExportPage {
        var throttled = 0
        while true {
            do {
                let data = try await APIClient.current.payload(
                    .get,
                    path,
                    query: cursor.map { ["cursor": $0] },
                    label: label,
                    authMode: .requireSignedIn
                )
                return try APIDecoding.decode(VoteExportPage.self, from: data, decoder: .usingDefaultKeys(), label: label)
            } catch {
                guard isThrottled(error), throttled < throttleBackoff.count else { throw error }
                let wait = throttleBackoff[throttled]
                throttled += 1
                AppLog.api.info("[\(label, privacy: .public)] HTTP 429 (\(throttled) of \(throttleBackoff.count)); asking again")
                try await pause(wait)
            }
        }
    }

    static func isThrottled(_ error: Error) -> Bool {
        APIErrorDebug.httpStatusCode(from: error) == 429
    }

    /// A failure whose code is `INVALID_CURSOR`. Judged by the code alone: this route sends it only with a 400, and
    /// tests cannot build Amplify's response that carries both, so the path tested is the path that runs.
    static func isInvalidCursor(_ error: Error) -> Bool {
        APIErrorResponse.errorCode(from: error) == invalidCursorCode
    }
}

// MARK: - Files

/// The two files of one export.
nonisolated struct VoteExportFileSet: Equatable, Sendable {
    /// The export's own folder, which holds both files.
    let folder: URL
    let csv: URL
    let json: URL
}

/// Where Download my votes writes its files: a fresh folder per export under the app's temporary directory, excluded
/// from backup. An export stays after its screen goes, for a share extension that reads its file late; every export
/// is removed before the next one starts, so the folder holds one at most, and at sign-out (`UserLocalDataPurge`).
/// Nothing goes to UserDefaults or the vote cache.
nonisolated struct VoteExportFolder: Sendable {
    let root: URL

    static let standard = VoteExportFolder(
        root: FileManager.default.temporaryDirectory.appendingPathComponent("VoteExport", isDirectory: true)
    )

    /// Writes both files, from the same votes, into a fresh folder.
    func write(_ votes: [ExportedVote], exportedAt: Date, timeZone: TimeZone = .current) throws -> VoteExportFileSet {
        let folder = try makeFreshFolder()
        do {
            let csv = folder.appendingPathComponent(VoteExport.fileName(.csv, at: exportedAt, timeZone: timeZone))
            let json = folder.appendingPathComponent(VoteExport.fileName(.json, at: exportedAt, timeZone: timeZone))
            try VoteExport.csv(votes).write(to: csv, options: [.withoutOverwriting, .completeFileProtection])
            try VoteExport.json(votes, exportedAt: exportedAt).write(to: json, options: [.withoutOverwriting, .completeFileProtection])
            return VoteExportFileSet(folder: folder, csv: csv, json: json)
        } catch {
            remove(folder)
            throw error
        }
    }

    /// Removes one export's folder.
    func remove(_ folder: URL) {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Removes every export (before a new one, and at sign-out).
    func removeAll() {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeFreshFolder() throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Self.excludeFromBackup(root)
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try Self.excludeFromBackup(folder)
        return folder
    }

    private static func excludeFromBackup(_ url: URL) throws {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }
}
