import SwiftUI

// MARK: - Hydration state

extension BillDetail {
    /// What restarts the screen's hydration task: the opened bill, and whether the shown bill's
    /// details are current (nil while the bill is not loaded).
    struct HydrationTaskKey: Equatable {
        let billID: UUID
        let isCurrent: Bool?
    }

    static func hydrationTaskKey(billID: UUID, bill: Bill?, in billsStore: BillsStore) -> HydrationTaskKey {
        HydrationTaskKey(billID: billID, isCurrent: bill.map(billsStore.isBillDetailHydrated))
    }

    /// The screen shows `bill` when it has details, including stale ones being fetched again, or has
    /// no guid to load them with; otherwise it shows the loading or error state.
    static func isDetailReady(_ bill: Bill?, in billsStore: BillsStore) -> Bool {
        guard let bill else { return false }
        if billsStore.hasBillDetails(bill) { return true }
        guard let guid = bill.guid?.trimmingCharacters(in: .whitespacesAndNewlines) else { return true }
        return guid.isEmpty
    }
}

// MARK: - Linked bills (APPF-26)

extension BillDetail {
    /// The on-demand load of a bill a deep link, push or share link opened that is not loaded.
    enum LinkedBillPhase: Equatable {
        /// Not started, or finished with the bill loaded.
        case idle
        case loading
        /// The request failed; user-facing copy.
        case failed(String)
        /// The API reported no such bill.
        case notFound
    }

    /// What the screen shows while its bill is not loaded.
    enum MissingBillContent: Equatable {
        /// The linked bill is being fetched, or its fetch is about to start.
        case loading
        /// The fetch failed: the message, with Retry.
        case failed(String)
        /// "Bill not found".
        case notFound
    }

    /// A screen opened from a link fetches its bill, so it shows loading (also before the fetch starts)
    /// or the fetch's failure, and "Bill not found" only when the API reported no such bill. A screen
    /// with no link guid has nothing to fetch: "Bill not found", as before APPF-26.
    static func missingBillContent(linkGUID: String?, phase: LinkedBillPhase) -> MissingBillContent {
        guard BillsStore.trimmedOrNil(linkGUID) != nil else { return .notFound }
        switch phase {
        case .idle, .loading:
            return .loading
        case .failed(let message):
            return .failed(message)
        case .notFound:
            return .notFound
        }
    }

    /// The phase after `BillsStore.loadLinkedBill` returned `result`; nil for a cancelled load, which
    /// leaves the screen as it is (it was left, or the bill arrived while the request was in flight).
    static func linkedBillPhase(after result: LinkedBillLoad) -> LinkedBillPhase? {
        switch result {
        case .loaded:
            return .idle
        case .notFound:
            return .notFound
        case .failed(let message):
            return .failed(message)
        case .cancelled:
            return nil
        }
    }
}

// MARK: - Loading and failure states

/// The bill page while its bill or the bill's details load (spec 4.48): an ink spinner and "Loading bill
/// details…" in `caption` ink 2 (spec 3.20), centred on the document ground.
struct BillDetailLoadingView: View {
    static let text = "Loading bill details…"

    var body: some View {
        VStack(spacing: BillboardStyle.Space.m) {
            ProgressView()
                .tint(BillboardColors.interactive)
            Text(Self.text)
                .textRole(.caption)
                .foregroundStyle(BillboardColors.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, BillboardStyle.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .background(BillboardColors.document.ignoresSafeArea())
    }
}

/// A failed load with Retry (spec 4.48): the bill's details, or a linked bill that is not loaded (APPF-26).
/// A COULDN'T LOAD record notice with the message, and a primary Retry.
struct BillDetailLoadErrorView: View {
    let title: String
    let message: String
    let retry: () -> Void

    static let retryIdentifier = "bill.detail.retry"

    var body: some View {
        BillDetailNoticePage {
            RecordNotice(.couldNotLoad, title: title, message: message)
            Button("Retry", action: retry)
                .buttonStyle(BillboardButtonStyle(kind: .primary))
                .accessibilityIdentifier(Self.retryIdentifier)
                .padding(.top, BillboardStyle.Space.l)
        }
    }
}

/// The bill page while its bill is not loaded: the linked bill's load (APPF-26), its failure, or a NOT
/// FOUND record notice, "Bill not found".
struct BillDetailMissingBillView: View {
    let content: BillDetail.MissingBillContent
    let retry: () -> Void

    static let notFoundTitle = "Bill not found"

    var body: some View {
        switch content {
        case .loading:
            BillDetailLoadingView()
        case .failed(let message):
            BillDetailLoadErrorView(title: "Couldn't load this bill.", message: message, retry: retry)
        case .notFound:
            BillDetailNoticePage {
                RecordNotice(.notFound, title: Self.notFoundTitle)
            }
        }
    }
}

/// A record notice set at the top of the document ground, in its gutter, scrolling at large text sizes.
private struct BillDetailNoticePage<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, BillboardStyle.Space.xl)
            .padding(.top, BillboardStyle.Space.m)
            .padding(.bottom, BillboardStyle.Space.xxl)
        }
        .background(BillboardColors.document.ignoresSafeArea())
    }
}
