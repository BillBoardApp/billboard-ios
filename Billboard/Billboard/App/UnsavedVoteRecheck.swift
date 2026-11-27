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
    /// Every report is kept until it is read (they are few): an offline report and the online one after it, both
    /// waiting while the main actor is busy, still count as a return online.
    nonisolated static func online() -> AsyncStream<Bool> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
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
/// the app comes back from the background (`BillVoteStore.startUnsavedVoteRecheck()`, one request, only when there are
/// some), and once the phone is back online each is sent once more on its own (`BillsStore.startUnsavedVoteResend()`,
/// project decision 2026-11-23). UI-test launches stay off the network, as at launch.
///
/// Sign-out clears the account's data (`UserLocalDataPurge`), then takes the tabs down. A read still out holds no
/// store: the launch read's task holds the store weakly and the read alone across its wait, and the return read's task
/// holds the read alone. Both end at once when the tabs go, which cancels the read (`BillVoteStore.answer(to:)`), and
/// a read that answers after the purge writes nothing for that account (`BillVoteCache.isAccountStillHere`).
struct UnsavedVoteRecheck: ViewModifier {
    let billsStore: BillsStore
    let voteStore: BillVoteStore
    /// The phone's online reports (`NetworkPathReports.online()`, or a test's).
    let onlineReports: @Sendable () -> AsyncStream<Bool>
    /// True on a UI-test launch, which reads and sends nothing.
    let staysOffline: Bool

    @Environment(\.scenePhase) private var scenePhase
    @State private var foreground = ForegroundReturnDetector()
    /// The read on the latest return to the app, cancelled when the tabs go.
    @State private var returnRead: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .task { [weak voteStore = voteStore, staysOffline = staysOffline] in
                guard !staysOffline, let read = voteStore?.startUnsavedVoteRecheck() else { return }
                _ = await BillVoteStore.answer(to: read)
            }
            .onChange(of: scenePhase) { _, phase in
                guard foreground.didReturn(to: phase), !staysOffline else { return }
                let read = voteStore.startUnsavedVoteRecheck()
                returnRead = Task { _ = await BillVoteStore.answer(to: read) }
            }
            .onDisappear {
                returnRead?.cancel()
                returnRead = nil
            }
            .task {
                guard !staysOffline else { return }
                await Self.resendOnEachReturnOnline(onlineReports(), billsStore: billsStore)
            }
    }

    /// Starts the one automatic resend (`BillsStore.startUnsavedVoteResend()`) each time `reports` say the phone is back
    /// online (`OnlineReturnDetector`), until they end or this task is cancelled. Sign-out takes the tabs down, which
    /// cancels it: a resend still out is cancelled then too, which ends its read and sends nothing. A resend is not
    /// awaited here, so the next report is read while it runs.
    static func resendOnEachReturnOnline(_ reports: AsyncStream<Bool>, billsStore: BillsStore) async {
        var detector = OnlineReturnDetector()
        var resends: [Task<[String: VoteWriteResult], Never>] = []
        for await isOnline in reports {
            guard detector.cameOnline(isOnline) else { continue }
            resends.append(billsStore.startUnsavedVoteResend())
        }
        for resend in resends {
            resend.cancel()
        }
    }
}

extension View {
    /// Reads the votes not saved yet again on a return to the app, and sends each once more once the phone is back
    /// online (APPF-30 step 2). Tests pass their own `onlineReports`, and `staysOffline` for a UI-test launch.
    func rechecksUnsavedVotes(
        billsStore: BillsStore,
        voteStore: BillVoteStore,
        onlineReports: @escaping @Sendable () -> AsyncStream<Bool> = { NetworkPathReports.online() },
        staysOffline: Bool = AppLaunchOptions.shouldStreamlineStartupForUITests
    ) -> some View {
        modifier(UnsavedVoteRecheck(
            billsStore: billsStore,
            voteStore: voteStore,
            onlineReports: onlineReports,
            staysOffline: staysOffline
        ))
    }
}
