import SwiftUI
import UIKit
import XCTest
@testable import Billboard

/// Download my votes (UX-40 L7) on screen: drawn in light and dark at the default text size and AX5, each state
/// attached to the result bundle for review; what VoiceOver reads (the save buttons' labels and hint, the loading line
/// and the result said aloud); Try again; the files deleted when the screen goes; and the Settings row, above Delete
/// account and data, titled as the privacy policy's path ends. No network: the screen's model gets a fake service.
@MainActor
final class DownloadVotesRenderTests: XCTestCase {
    /// The privacy policy's sentence in held backend #39 (approved 2026-11-25).
    private static let privacyLine = "You can download a copy of your votes from within the app (Profile → Settings → Download my votes)."

    private var folder: VoteExportFolder!

    override func setUp() {
        super.setUp()
        folder = VoteExportFolder(
            root: FileManager.default.temporaryDirectory.appendingPathComponent("DownloadVotesRenderTests-\(UUID().uuidString)", isDirectory: true)
        )
    }

    override func tearDown() {
        folder.removeAll()
        folder = nil
        super.tearDown()
    }

    private struct Variant {
        let style: UIUserInterfaceStyle
        let size: DynamicTypeSize

        var name: String {
            "\(style == .dark ? "dark" : "light")-\(size == .accessibility5 ? "AX5" : "default")"
        }
    }

    private static let variants = [
        Variant(style: .light, size: .large),
        Variant(style: .dark, size: .large),
        Variant(style: .light, size: .accessibility5),
        Variant(style: .dark, size: .accessibility5)
    ]

    // MARK: - Drawing

    /// The ready screen in both appearances at the default size and AX5: paper behind sheet rows, ink text.
    func testTheScreenDrawsInBothAppearancesAtDefaultSizeAndAX5() throws {
        for variant in Self.variants {
            let image = try snapshot(screen(FakeVoteExportService(.success(votes))), variant: variant)
            attach(image, name: "download-votes-ready-\(variant.name)")

            let paper = variant.style == .dark ? BillboardPalette.background.dark : BillboardPalette.background.light
            let sheet = variant.style == .dark ? BillboardPalette.cardBackground.dark : BillboardPalette.cardBackground.light
            let ink = variant.style == .dark ? BillboardPalette.primaryText.dark : BillboardPalette.primaryText.light
            let margin = try SnapshotPixels.column(of: image, x: 6)
            XCTAssertTrue(margin.dropFirst(200).prefix(200).allSatisfy { SnapshotPixels.matches($0, paper, tolerance: 0.02) }, "\(variant.name): paper in the margin")
            let middle = try SnapshotPixels.column(of: image, x: Int(image.size.width) / 2)
            XCTAssertTrue(middle.contains { SnapshotPixels.matches($0, sheet, tolerance: 0.01) }, "\(variant.name): rows on sheet")
            XCTAssertTrue(try SnapshotPixels.contains(image, ink, tolerance: 0.04, fromY: 140), "\(variant.name): ink below the bar")
        }
    }

    /// Preparing, the error and the empty line, in both appearances, for review.
    func testTheOtherStatesDraw() throws {
        let states: [(String, () -> FakeVoteExportService)] = [
            ("preparing", { let service = FakeVoteExportService(.success([])); service.waitsForCancellation = true; return service }),
            ("error", { FakeVoteExportService(.failure(httpStatusError(500, path: "account-data/votes"))) }),
            ("empty", { FakeVoteExportService(.success([])) })
        ]
        for (name, service) in states {
            for variant in [Variant(style: .light, size: .large), Variant(style: .dark, size: .large), Variant(style: .light, size: .accessibility5)] {
                let image = try snapshot(screen(service()), variant: variant)
                attach(image, name: "download-votes-\(name)-\(variant.name)")
            }
        }
    }

    // MARK: - VoiceOver

    /// Each save button reads its title with the hint, at the default size and at AX5, and is a button that works once
    /// the files are ready. The body, the footer and the title are read too.
    func testVoiceOverReadsTheSaveButtonsWithTheirHint() {
        for size in [DynamicTypeSize.large, .accessibility5] {
            let host = AccessibilityTreeText.Host(
                screen(FakeVoteExportService(.success(votes))).environment(\.dynamicTypeSize, size),
                size: CGSize(width: size == .accessibility5 ? 375 : 390, height: 2400),
                settle: 0.3
            )
            defer { host.close() }
            XCTAssertTrue(host.run(until: { !host.identifiers().contains("downloadVotes.preparing") }), "\(size): the files are ready")

            XCTAssertEqual(host.label(ofIdentifier: "downloadVotes.csv"), "Save as spreadsheet (CSV)", "\(size)")
            XCTAssertEqual(host.label(ofIdentifier: "downloadVotes.json"), "Save as JSON", "\(size)")
            XCTAssertEqual(host.hint(of: "Save as spreadsheet (CSV)"), "Opens options to save or send the file", "\(size)")
            XCTAssertEqual(host.hint(of: "Save as JSON"), "Opens options to save or send the file", "\(size)")
            for identifier in ["downloadVotes.csv", "downloadVotes.json"] {
                let traits = host.traits(ofIdentifier: identifier) ?? []
                XCTAssertTrue(traits.contains(.button), "\(size) \(identifier)")
                XCTAssertFalse(traits.contains(.notEnabled), "\(size) \(identifier)")
            }
            let text = host.text()
            XCTAssertTrue(text.contains(DownloadVotesCopy.body), "\(size): \(text)")
            XCTAssertTrue(text.contains(DownloadVotesCopy.footer), "\(size): \(text)")
            XCTAssertTrue(text.contains("Download my votes"), "\(size): \(text)")
        }
    }

    /// While the files are prepared the buttons are dimmed (they have nothing to send yet) and the loading line shows.
    func testWhilePreparingTheButtonsAreDimmed() {
        let service = FakeVoteExportService(.success(votes))
        service.waitsForCancellation = true
        let host = AccessibilityTreeText.Host(screen(service), size: CGSize(width: 390, height: 1400), settle: 0.3)
        defer { host.close() }

        XCTAssertEqual(host.label(ofIdentifier: "downloadVotes.preparing"), "Preparing your votes…")
        XCTAssertEqual(host.hint(of: "Save as JSON"), "Opens options to save or send the file")
        XCTAssertTrue(host.traits(ofIdentifier: "downloadVotes.csv")?.contains(.notEnabled) ?? false)
        XCTAssertTrue(host.traits(ofIdentifier: "downloadVotes.json")?.contains(.notEnabled) ?? false)
    }

    /// VoiceOver hears the loading line, then the empty line or the error. The approved copy has no line for the
    /// files being ready, so nothing more is said then.
    func testVoiceOverHearsTheLoadingLineThenTheEmptyLineOrTheError() {
        let outcomes: [(FakeVoteExportService, [String])] = [
            (FakeVoteExportService(.success(votes)), ["Preparing your votes…"]),
            (FakeVoteExportService(.success([])), ["Preparing your votes…", "You haven't voted on a bill yet."]),
            (FakeVoteExportService(.failure(httpStatusError(500, path: "account-data/votes"))), ["Preparing your votes…", "Couldn't prepare your votes"])
        ]
        for (service, expected) in outcomes {
            let spoken = SpokenLines()
            let host = AccessibilityTreeText.Host(
                screen(service).environment(\.announceToVoiceOver, spoken.announce),
                size: CGSize(width: 390, height: 1400),
                settle: 0.3
            )
            defer { host.close() }
            XCTAssertTrue(
                host.run(until: { service.calls == 1 && !host.identifiers().contains("downloadVotes.preparing") && spoken.lines.count >= expected.count }),
                "\(spoken.lines)"
            )
            host.run(0.3)
            XCTAssertEqual(spoken.lines, expected)
        }
    }

    /// The error: a Couldn't load notice titled "Couldn't prepare your votes", and Try again loads again.
    func testTryAgainLoadsAgain() {
        let service = FakeVoteExportService(.failure(httpStatusError(500, path: "account-data/votes")), .success(votes))
        let spoken = SpokenLines()
        let host = AccessibilityTreeText.Host(
            screen(service).environment(\.announceToVoiceOver, spoken.announce),
            size: CGSize(width: 390, height: 1400),
            settle: 0.3
        )
        defer { host.close() }
        XCTAssertTrue(host.run(until: { host.identifiers().contains("downloadVotes.tryAgain") }))
        XCTAssertTrue(host.text().contains("Couldn't prepare your votes"), host.text())
        XCTAssertEqual(host.label(ofIdentifier: "downloadVotes.tryAgain"), "Try again")
        XCTAssertTrue(host.traits(ofIdentifier: "downloadVotes.csv")?.contains(.notEnabled) ?? false)

        XCTAssertTrue(host.activate(identifier: "downloadVotes.tryAgain"))
        XCTAssertTrue(host.run(until: { service.calls == 2 && !host.identifiers().contains("downloadVotes.preparing") }))
        XCTAssertFalse(host.identifiers().contains("downloadVotes.tryAgain"))
        XCTAssertFalse(host.traits(ofIdentifier: "downloadVotes.csv")?.contains(.notEnabled) ?? true)
        host.run(0.3)
        XCTAssertEqual(spoken.lines, ["Preparing your votes…", "Couldn't prepare your votes", "Preparing your votes…"])
    }

    /// With no votes, the empty line, and nothing to save.
    func testTheEmptyLine() {
        let host = AccessibilityTreeText.Host(screen(FakeVoteExportService(.success([]))), size: CGSize(width: 390, height: 1400), settle: 0.3)
        defer { host.close() }
        XCTAssertTrue(host.run(until: { host.identifiers().contains("downloadVotes.empty") }))
        XCTAssertEqual(host.label(ofIdentifier: "downloadVotes.empty"), "You haven't voted on a bill yet.")
        XCTAssertTrue(host.traits(ofIdentifier: "downloadVotes.csv")?.contains(.notEnabled) ?? false)
    }

    // MARK: - Files

    /// The files are written while the screen shows and deleted when it goes.
    func testTheFilesAreDeletedWhenTheScreenGoes() {
        let host = AccessibilityTreeText.Host(screen(FakeVoteExportService(.success(votes))), size: CGSize(width: 390, height: 1400), settle: 0.3)
        XCTAssertTrue(host.run(until: { !host.identifiers().contains("downloadVotes.preparing") }))
        let written = exportFolders()
        XCTAssertEqual(written.count, 1)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: written[0].path)) ?? []
        XCTAssertEqual(names.map { ($0 as NSString).pathExtension }.sorted(), ["csv", "json"], "\(names)")
        XCTAssertTrue(names.allSatisfy { $0.hasPrefix("Billboard votes ") }, "\(names)")

        host.close()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        XCTAssertEqual(exportFolders(), [], "no file is left once the screen is gone")
    }

    // MARK: - Settings row

    /// Settings has "Download my votes" (id settings.downloadVotes) in its own section above Delete account and data,
    /// titled as the privacy policy's path ends: Profile → Settings → Download my votes.
    func testTheSettingsRowSitsAboveDeleteAccountAndMatchesThePrivacyPolicy() throws {
        let auth = AuthManager()
        auth.cancelSignIn()
        let userStore = UserStore(preferencesService: StaticPreferencesService(items: []), congressService: FakeCongressService())
        let host = AccessibilityTreeText.Host(
            NavigationStack { ProfileSettingsMenuView() }.environmentObject(auth).environmentObject(userStore),
            size: CGSize(width: 390, height: 1200),
            settle: 0.3
        )
        defer { host.close() }

        XCTAssertEqual(host.label(ofIdentifier: "settings.downloadVotes"), "Download my votes")
        let about = try XCTUnwrap(host.frame(ofIdentifier: "settings.about"))
        let download = try XCTUnwrap(host.frame(ofIdentifier: "settings.downloadVotes"))
        let delete = try XCTUnwrap(host.frame(ofIdentifier: "settings.deleteAccount"))
        XCTAssertLessThan(about.maxY, download.minY, "below About Billboard")
        XCTAssertLessThan(download.maxY, delete.minY, "above Delete account and data")
        XCTAssertGreaterThan(delete.minY - download.maxY, 8, "in a section of its own")

        let path = try XCTUnwrap(Self.privacyLine.split(separator: "(").last?.split(separator: ")").first)
            .components(separatedBy: " → ")
        XCTAssertEqual(path, ["Profile", "Settings", "Download my votes"])
        XCTAssertEqual(path.last, DownloadVotesCopy.rowTitle)
        XCTAssertEqual(path.last, host.label(ofIdentifier: "settings.downloadVotes"))
        XCTAssertEqual(DownloadVotesCopy.screenTitle, DownloadVotesCopy.rowTitle)
        let bar = try XCTUnwrap(host.navigationController?.navigationBar)
        XCTAssertTrue(host.strings(under: bar).contains(path[1]), "the screen the row is on is titled Settings: \(host.strings(under: bar))")
    }

    // MARK: - Helpers

    private var votes: [ExportedVote] {
        [
            ExportedVote(billId: "BILLS-119hr1285", title: "Clean Energy Access Act", congress: "119", billType: "hr", billNumber: "1285", vote: .yea, reasons: ["economic_impact"], firstVotedAt: "2026-10-01T15:00:00.000Z", votedAt: "2026-10-02T15:00:00.000Z", state: "VA", district: "8", verified: true),
            ExportedVote(billId: "BILLS-119s570", title: nil, congress: "119", billType: "s", billNumber: "570", vote: .abstain, reasons: [], firstVotedAt: nil, votedAt: nil, state: nil, district: nil, verified: false)
        ]
    }

    private func screen(_ service: FakeVoteExportService) -> some View {
        let model = DownloadVotesModel(service: service, folder: folder)
        return NavigationStack {
            DownloadVotesView(model: model)
        }
    }

    /// The export folders on disk now.
    private func exportFolders() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: folder.root, includingPropertiesForKeys: nil)) ?? []
    }

    /// The view in a window on the test host's screen, drawn after it settles (lists draw only in a window), with the
    /// variant's appearance and text size (the host's trait, as Settings sets it).
    private func snapshot<Content: View>(_ view: Content, variant: Variant) throws -> UIImage {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "the hosted test app has a window scene"
        )
        let width: CGFloat = variant.size == .accessibility5 ? 375 : 390
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: CGSize(width: width, height: variant.size == .accessibility5 ? 1600 : 844))
        window.overrideUserInterfaceStyle = variant.style
        let host = UIHostingController(rootView: view.tint(BillboardColors.interactive))
        host.traitOverrides.preferredContentSizeCategory = UIContentSizeCategory(variant.size)
        window.rootViewController = host
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        host.view.layoutIfNeeded()

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    private func attach(_ image: UIImage, name: String) {
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

/// What VoiceOver was told, in order.
@MainActor
private final class SpokenLines {
    private(set) var lines: [String] = []

    var announce: @MainActor @Sendable (String) -> Void {
        { [self] line in lines.append(line) }
    }
}
