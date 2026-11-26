import Combine
import CoreTransferable
import os
import SwiftUI
import UniformTypeIdentifiers

/// The words of Download my votes (UX-40 L7, approved with D32 to D36 on 2026-11-23). The privacy policy names the
/// way here as Profile → Settings → Download my votes (approved 2026-11-25), so the Settings row keeps this title.
enum DownloadVotesCopy {
    static let rowTitle = "Download my votes"
    static let screenTitle = "Download my votes"
    static let body = "Get a copy of every vote you've cast in Billboard: each bill, your vote, the reasons you picked, and when you voted. The file is made for you alone and goes only where you send it."
    static let csvButton = "Save as spreadsheet (CSV)"
    static let jsonButton = "Save as JSON"
    static let footer = "CSV opens in Numbers, Excel or Google Sheets. JSON is for apps and code."
    static let preparing = "Preparing your votes…"
    static let errorTitle = "Couldn't prepare your votes"
    static let tryAgain = "Try again"
    static let empty = "You haven't voted on a bill yet."
    /// VoiceOver's hint on both save buttons.
    static let buttonHint = "Opens options to save or send the file"
    /// Said to VoiceOver when both files are ready; not shown on screen, where the save buttons light up.
    static let ready = "Your votes are ready."

    static func buttonTitle(_ format: VoteExportFormat) -> String {
        switch format {
        case .csv: return csvButton
        case .json: return jsonButton
        }
    }

    static func buttonIdentifier(_ format: VoteExportFormat) -> String {
        switch format {
        case .csv: return "downloadVotes.csv"
        case .json: return "downloadVotes.json"
        }
    }
}

// MARK: - Model

/// Loads the caller's votes once per showing of the screen and writes both files from that one response.
@MainActor
final class DownloadVotesModel: ObservableObject {
    enum Phase: Equatable {
        case preparing
        case ready(VoteExportFileSet)
        case empty
        case failed
    }

    @Published private(set) var phase: Phase = .preparing

    private let service: any VoteExportServicing
    private let folder: VoteExportFolder
    private let now: () -> Date
    private let timeZone: TimeZone
    /// The files on disk now, if any.
    private var files: VoteExportFileSet?

    init(
        service: any VoteExportServicing = VoteExportService.Live(),
        folder: VoteExportFolder = .standard,
        now: @escaping () -> Date = Date.init,
        timeZone: TimeZone = .current
    ) {
        self.service = service
        self.folder = folder
        self.now = now
        self.timeZone = timeZone
    }

    /// What VoiceOver hears as the phase changes, as a queued announcement (`announcesToVoiceOver`): the loading
    /// line, then that the files are ready, the empty line or the error.
    var announcement: String? {
        switch phase {
        case .preparing: return DownloadVotesCopy.preparing
        case .ready: return DownloadVotesCopy.ready
        case .empty: return DownloadVotesCopy.empty
        case .failed: return DownloadVotesCopy.errorTitle
        }
    }

    /// Reads every page, then writes the CSV and the JSON. Any export already on disk goes first: only one screen
    /// exports at a time, and files left by an app that was closed while the screen showed must not stay. A
    /// cancelled load (the screen went, or Try again started another) stays quiet: no error, no files.
    func load() async {
        files = nil
        folder.removeAll()
        phase = .preparing
        do {
            let votes = try await service.fetchAllVotes()
            try Task.checkCancellation()
            guard !votes.isEmpty else {
                phase = .empty
                return
            }
            let written = try await Self.write(votes, to: folder, exportedAt: now(), timeZone: timeZone)
            guard !Task.isCancelled else {
                // The screen went while the files were written.
                folder.remove(written.folder)
                return
            }
            files = written
            phase = .ready(written)
        } catch {
            if error is CancellationError || Task.isCancelled { return }
            AppLog.store.error("[DownloadVotes] could not prepare the files (\(String(describing: type(of: error)), privacy: .public))")
            phase = .failed
        }
    }

    /// Encodes and writes both files off the main actor: thousands of votes as pretty-printed JSON take long enough
    /// to stall the loading line.
    @concurrent
    nonisolated private static func write(
        _ votes: [ExportedVote],
        to folder: VoteExportFolder,
        exportedAt: Date,
        timeZone: TimeZone
    ) async throws -> VoteExportFileSet {
        try folder.write(votes, exportedAt: exportedAt, timeZone: timeZone)
    }

    /// Deletes the files (the screen went). The phase stays, so nothing is said to VoiceOver on the screen it went
    /// back to; the next showing loads again (`load`), which writes new files.
    func discardFiles() {
        guard let files else { return }
        folder.remove(files.folder)
        self.files = nil
    }
}

// MARK: - Files to share

/// The CSV of an export, handed to the share sheet as a file.
nonisolated struct VoteExportCSVFile: Transferable, Sendable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .commaSeparatedText) { file in
            SentTransferredFile(file.url)
        }
    }
}

/// The JSON of an export, handed to the share sheet as a file.
nonisolated struct VoteExportJSONFile: Transferable, Sendable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .json) { file in
            SentTransferredFile(file.url)
        }
    }
}

// MARK: - Screen

/// Download my votes (UX-40 L7), from Profile → Settings: a settings list on paper (spec 3.25). The body, then the
/// two save buttons, each a ShareLink to its file, with the footer under them; below, while it loads, "Preparing
/// your votes…", on a failure a Couldn't load notice with Try again, and with no votes the empty line. It loads on
/// appear and deletes its files when it goes. VoiceOver hears the loading line, then that the files are ready, the
/// empty line or the error.
struct DownloadVotesView: View {
    @StateObject private var model: DownloadVotesModel
    /// Bumped by Try again; the load runs as the view's task, so leaving the screen cancels it.
    @State private var loadRequest = 0

    init() {
        _model = StateObject(wrappedValue: DownloadVotesModel())
    }

    /// With a given model (tests give one with a fake service).
    init(model: @autoclosure @escaping () -> DownloadVotesModel) {
        _model = StateObject(wrappedValue: model())
    }

    var body: some View {
        List {
            Section {
                Text(DownloadVotesCopy.body)
                    .textRole(.body)
                    .foregroundStyle(BillboardColors.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, BillboardStyle.Space.xs)
                    .accessibilityIdentifier("downloadVotes.body")
            }
            .recordListRows()

            Section {
                saveButton(.csv)
                saveButton(.json)
            } footer: {
                RecordListFooter(DownloadVotesCopy.footer)
            }
            .recordListRows()

            statusSection
        }
        .recordList()
        // On the list, not its rows: a list makes its rows only as they scroll into view (UX-45).
        .announcesToVoiceOver(model.announcement)
        .navigationTitle(DownloadVotesCopy.screenTitle)
        .navigationBarTitleDisplayMode(.inline)
        .glassNavigationBar()
        .accessibilityIdentifier("downloadVotes.screen")
        .task(id: loadRequest) {
            await model.load()
        }
        .onDisappear {
            model.discardFiles()
        }
    }

    /// A save button: a ShareLink to its file once the files are ready, a dimmed button before.
    private func saveButton(_ format: VoteExportFormat) -> some View {
        Group {
            if case .ready(let files) = model.phase {
                switch format {
                case .csv:
                    ShareLink(item: VoteExportCSVFile(url: files.csv), preview: SharePreview(files.csv.lastPathComponent)) {
                        DownloadVotesSaveLabel(title: DownloadVotesCopy.buttonTitle(format), isEnabled: true)
                    }
                case .json:
                    ShareLink(item: VoteExportJSONFile(url: files.json), preview: SharePreview(files.json.lastPathComponent)) {
                        DownloadVotesSaveLabel(title: DownloadVotesCopy.buttonTitle(format), isEnabled: true)
                    }
                }
            } else {
                Button {} label: {
                    DownloadVotesSaveLabel(title: DownloadVotesCopy.buttonTitle(format), isEnabled: false)
                }
                .disabled(true)
            }
        }
        .accessibilityLabel(DownloadVotesCopy.buttonTitle(format))
        .accessibilityHint(DownloadVotesCopy.buttonHint)
        .accessibilityIdentifier(DownloadVotesCopy.buttonIdentifier(format))
    }

    @ViewBuilder
    private var statusSection: some View {
        switch model.phase {
        case .preparing:
            Section {
                HStack(spacing: BillboardStyle.Space.s) {
                    ProgressView()
                        .tint(BillboardColors.interactive)
                        .accessibilityHidden(true)
                    SettingsRowText(DownloadVotesCopy.preparing, color: BillboardColors.secondaryText)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("downloadVotes.preparing")
            }
            .recordListRows()
        case .failed:
            Section {
                RecordNotice(
                    .couldNotLoad,
                    title: DownloadVotesCopy.errorTitle,
                    action: .init(title: DownloadVotesCopy.tryAgain, accessibilityIdentifier: "downloadVotes.tryAgain") {
                        loadRequest += 1
                    }
                )
                .padding(.bottom, BillboardStyle.Space.s)
            }
            .recordListRows()
        case .empty:
            Section {
                SettingsRowText(DownloadVotesCopy.empty, color: BillboardColors.secondaryText)
                    .accessibilityIdentifier("downloadVotes.empty")
            }
            .recordListRows()
        case .ready:
            EmptyView()
        }
    }
}

/// A save button's row: the title in `interactive` with a trailing share symbol, both in `ink3` while the files are
/// being prepared. No leading symbol (spec 3.25).
private struct DownloadVotesSaveLabel: View {
    let title: String
    let isEnabled: Bool

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let color = isEnabled ? BillboardColors.interactive : BillboardColors.dimText
        HStack(spacing: BillboardStyle.Space.m) {
            SettingsRowText(title, color: color)
            Spacer(minLength: BillboardStyle.Space.s)
            Image(systemName: "square.and.arrow.up")
                .font(TextRole.Face.text.font(size: TextRole.caption.scaledSize(for: dynamicTypeSize), weight: .semibold))
                .foregroundStyle(color)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
    }
}
