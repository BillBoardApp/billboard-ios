import Network
import SwiftUI

/// Tells when the phone is back online (APPF-30 step 2) from the network path's reports: the first report of a run
/// that is online (the phone may have come back while the app was not running), and every report that is online after
/// one that was not. Further online reports, such as Wi-Fi to cellular, do not count.
struct OnlineReturnDetector: Equatable {
    private var wasOnline: Bool?

    /// True when `isOnline` is the phone being back online.
    mutating func cameOnline(_ isOnline: Bool) -> Bool {
        defer { wasOnline = isOnline }
        return isOnline && wasOnline != true
    }
}

/// The network path's reports, from `NWPathMonitor`.
enum NetworkPathReports {
    /// Whether the phone is online (the path is satisfied), at once and then on each change, until the stream ends.
    nonisolated static func online() -> AsyncStream<Bool> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in
                continuation.yield(path.status == .satisfied)
            }
            continuation.onTermination = { _ in
                monitor.cancel()
            }
            monitor.start(queue: DispatchQueue(label: "billboard.network-path", qos: .utility))
        }
    }
}

/// APPF-30 step 2: the votes not saved yet, outside bill detail. Their rows are read again, quietly, at launch and when
/// the app comes back from the background (`BillVoteStore.recheckUnsavedVotes()`, one request, only when there are
/// some), and once the phone is back online each is sent once more on its own (`BillsStore.resendUnsavedVotesOnce()`,
/// project decision 2026-11-23). UI-test launches stay off the network, as at launch.
struct UnsavedVoteRecheck: ViewModifier {
    let billsStore: BillsStore
    let voteStore: BillVoteStore

    @Environment(\.scenePhase) private var scenePhase
    @State private var foreground = ForegroundReturnDetector()

    func body(content: Content) -> some View {
        content
            .task {
                guard !AppLaunchOptions.shouldStreamlineStartupForUITests else { return }
                await voteStore.recheckUnsavedVotes()
            }
            .onChange(of: scenePhase) { _, phase in
                guard foreground.didReturn(to: phase), !AppLaunchOptions.shouldStreamlineStartupForUITests else { return }
                Task { await voteStore.recheckUnsavedVotes() }
            }
            .task {
                guard !AppLaunchOptions.shouldStreamlineStartupForUITests else { return }
                var detector = OnlineReturnDetector()
                for await isOnline in NetworkPathReports.online() {
                    guard detector.cameOnline(isOnline) else { continue }
                    // Unstructured, so a send is not cancelled with this task (sign-out ends the store with it).
                    Task { await billsStore.resendUnsavedVotesOnce() }
                }
            }
    }
}

extension View {
    /// Reads the votes not saved yet again on a return to the app, and sends each once more once the phone is back
    /// online (APPF-30 step 2).
    func rechecksUnsavedVotes(billsStore: BillsStore, voteStore: BillVoteStore) -> some View {
        modifier(UnsavedVoteRecheck(billsStore: billsStore, voteStore: voteStore))
    }
}
