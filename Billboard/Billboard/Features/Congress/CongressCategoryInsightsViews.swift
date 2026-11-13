import SwiftUI

/// "Topic groups" from Search (Civic Record spec 4.27): one roll sheet of ruled rows, each topic group's
/// name with its bill count in the docket face and a chevron, in the 16 pt list gutter. No symbols, no
/// coloured borders.
struct CongressCategoryInsightsListView: View {
    @EnvironmentObject private var billsStore: BillsStore
    @EnvironmentObject private var billAlertsStore: BillAlertsStore

    private let categories = SubscriptionsConfig.allCategories

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BillboardStyle.Space.l) {
                if categories.isEmpty {
                    RecordNotice(.nothingYet, title: "No topic groups")
                } else {
                    CongressInsightList(items: categories.map { CongressInsightList.Item(name: $0, billCount: billsCount(for: $0)) }) { name in
                        CongressCategoryDetailView(category: name)
                    }
                }
            }
            .padding(.horizontal, BillboardStyle.Space.l)
            .padding(.top, BillboardStyle.Space.l)
            .padding(.bottom, BillboardStyle.Space.xxl)
        }
        .billboardBackground()
        .navigationTitle("Topic groups")
        .navigationBarTitleDisplayMode(.inline)
        .glassNavigationBar()
        .task {
            await billsStore.ensureFullManifestLoaded()
        }
    }

    private func billsCount(for category: String) -> Int {
        billsStore.bills.filter { $0.category == category }.count
    }
}

/// A topic group's bills (spec 4.27): a SectionHeader with the group's name and its bill count, the bill
/// slips, and "Load older bills". A bill opens the full page with the vote panel, a decided bill's too
/// (project decision 1).
struct CongressCategoryDetailView: View {
    @EnvironmentObject private var readState: AppReadState
    @EnvironmentObject private var billsStore: BillsStore
    @EnvironmentObject private var billAlertsStore: BillAlertsStore

    let category: String

    private var relatedBills: [Bill] {
        billsStore.bills.filter { $0.category == category }
    }

    var body: some View {
        ScrollView {
            CongressBillListContent(
                title: category,
                bills: relatedBills,
                emptyText: "No bills in this topic group",
                canLoadMore: billsStore.canLoadMore,
                isLoadingMore: billsStore.isLoadingMore,
                onLoadMore: { Task { await billsStore.loadMore() } }
            ) { billID in
                Self.billPage(billID)
            }
        }
        .billboardBackground()
        .navigationTitle(category)
        .navigationBarTitleDisplayMode(.inline)
        .glassNavigationBar()
        .task {
            await billsStore.ensureFullManifestLoaded()
        }
        .refreshable {
            await billsStore.load(forceRefresh: true, mode: .manifestOnly, loadFullManifest: true)
        }
    }
}

/// A topic group's or life area's bills (spec 4.27), without the stores so it can be rendered in tests:
/// a SectionHeader with the name and the bill count, a life area's top topic groups as ink index tags, the
/// bill slips, each opening `billPage` (the full page with the vote panel), and "Load older bills".
struct CongressBillListContent<BillPage: View>: View {
    let title: String
    let bills: [Bill]
    /// A life area's topic groups with the most bills and updates, most first; none for a topic group.
    var topCategories: [String] = []
    let emptyText: String
    let canLoadMore: Bool
    let isLoadingMore: Bool
    let onLoadMore: () -> Void
    @ViewBuilder let billPage: (UUID) -> BillPage

    var body: some View {
        LazyVStack(alignment: .leading, spacing: BillboardStyle.Space.m) {
            SectionHeader(title, trailing: CongressInsightsCopy.countTrailing(bills.count))

            if !topCategories.isEmpty {
                VStack(alignment: .leading, spacing: BillboardStyle.Space.s) {
                    Text("Top topic groups")
                        .textRole(.label)
                        .foregroundStyle(BillboardColors.dimText)
                        .accessibilityAddTraits(.isHeader)
                    FlowLayout(spacing: BillboardStyle.Space.s) {
                        ForEach(topCategories, id: \.self) { category in
                            IndexTag(title: category, systemImage: "tag", accessibilityLabel: "Topic group: \(category)")
                        }
                    }
                }
                .padding(.bottom, BillboardStyle.Space.xs)
            }

            if bills.isEmpty {
                RecordNotice(.nothingYet, title: emptyText)
            } else {
                ForEach(bills) { bill in
                    NavigationLink {
                        billPage(bill.id)
                    } label: {
                        BillCard(bill: bill)
                    }
                    .buttonStyle(RowButtonStyle())
                }
            }

            if canLoadMore {
                CongressLoadOlderBillsButton(isLoading: isLoadingMore, action: onLoadMore)
            }

            // Alerts are still received (push + stored), but are not shown as a standalone UI.
        }
        .padding(.horizontal, BillboardStyle.Space.l)
        .padding(.top, BillboardStyle.Space.l)
        .padding(.bottom, BillboardStyle.Space.xxl)
    }
}

/// The ruled list of topic groups or life areas (spec 4.27): a roll sheet of `RollLinkRow`s, the name and
/// its bill count ("12", read "12 bills"), each opening its detail screen.
struct CongressInsightList<Destination: View>: View {
    struct Item: Identifiable {
        let name: String
        let billCount: Int
        var id: String { name }
    }

    let items: [Item]
    @ViewBuilder let destination: (String) -> Destination

    var body: some View {
        RollSheet {
            LazyVStack(alignment: .leading, spacing: 0) {
                RollRows(items) { _, item in
                    NavigationLink {
                        destination(item.name)
                    } label: {
                        RollLinkRow(
                            title: item.name,
                            figure: "\(item.billCount)",
                            spokenFigure: CongressInsightsCopy.billCount(item.billCount)
                        )
                    }
                    .buttonStyle(RowButtonStyle())
                }
            }
        }
    }
}

/// "Load older bills" under a topic group's or life area's slips (spec 4.27): a full-width secondary
/// capsule, with a spinner and "Loading older bills…" while it loads.
struct CongressLoadOlderBillsButton: View {
    let isLoading: Bool
    let action: () -> Void

    var body: some View {
        BBActionButton(
            title: "Load older bills",
            action: action,
            loadingTitle: "Loading older bills…",
            isEnabled: !isLoading,
            isLoading: isLoading,
            kind: .secondary,
            expandToMaxWidth: true
        )
        .padding(.top, BillboardStyle.Space.xs)
    }
}

/// Shared wording for the topic-group and life-area screens.
enum CongressInsightsCopy {
    /// "1 bill", "12 bills".
    static func billCount(_ count: Int) -> String {
        "\(count) \(count == 1 ? "bill" : "bills")"
    }

    /// A detail screen's SectionHeader counter: the bill count in the docket face, read "12 bills".
    static func countTrailing(_ count: Int) -> SectionHeader.Trailing {
        .counter("\(count)", spoken: billCount(count))
    }
}

extension CongressCategoryDetailView {
    /// The page a bill in a topic's list opens: the full
    /// page with the vote bar, a decided bill's too (Civic Record project decision 1). `DecidedBillVotingTests`
    /// opens it from here.
    static func billPage(_ billID: UUID) -> BillDetail {
        BillDetail(billID: billID)
    }
}
