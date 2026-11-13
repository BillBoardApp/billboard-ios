import SwiftUI

/// "Life areas" from Search (Civic Record spec 4.27): one roll sheet of ruled rows, each life area's name
/// with its bill count in the docket face and a chevron, in the 16 pt list gutter.
struct CongressLifeAreaInsightsListView: View {
    @EnvironmentObject private var billsStore: BillsStore
    @EnvironmentObject private var billAlertsStore: BillAlertsStore

    private let lifeAreas = SubscriptionsConfig.allLifeAreas

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BillboardStyle.Space.l) {
                if lifeAreas.isEmpty {
                    RecordNotice(.nothingYet, title: "No life areas")
                } else {
                    CongressInsightList(items: lifeAreas.map { CongressInsightList.Item(name: $0, billCount: billsCount(for: $0)) }) { name in
                        CongressLifeAreaDetailView(lifeArea: name)
                    }
                }
            }
            .padding(.horizontal, BillboardStyle.Space.l)
            .padding(.top, BillboardStyle.Space.l)
            .padding(.bottom, BillboardStyle.Space.xxl)
        }
        .billboardBackground()
        .navigationTitle("Life areas")
        .navigationBarTitleDisplayMode(.inline)
        .glassNavigationBar()
        .task {
            await billsStore.ensureFullManifestLoaded()
        }
    }

    private func billsCount(for lifeArea: String) -> Int {
        billsStore.bills.filter { $0.lifeAreas.contains(lifeArea) }.count
    }
}

/// A life area's bills (spec 4.27): a SectionHeader with the life area's name and its bill count, its top
/// topic groups as ink index tags, the bill slips, and "Load older bills". A bill opens the full page with
/// the vote panel, a decided bill's too (project decision 1).
struct CongressLifeAreaDetailView: View {
    @EnvironmentObject private var readState: AppReadState
    @EnvironmentObject private var billsStore: BillsStore
    @EnvironmentObject private var billAlertsStore: BillAlertsStore

    let lifeArea: String

    private var relatedBills: [Bill] {
        billsStore.bills.filter { $0.lifeAreas.contains(lifeArea) }
    }

    private var relatedUpdates: [BillAlert] {
        billAlertsStore.alerts
            .filter { $0.lifeAreas.contains(lifeArea) }
            .sorted { $0.date > $1.date }
    }

    /// The topic groups with the most bills and updates in this life area, most first (ties by name).
    private var topCategories: [String] {
        var counts: [String: Int] = [:]
        for update in relatedUpdates {
            counts[update.category, default: 0] += 1
        }
        for bill in relatedBills {
            counts[bill.category, default: 0] += 1
        }
        return counts
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(3)
            .map(\.key)
    }

    var body: some View {
        ScrollView {
            CongressBillListContent(
                title: lifeArea,
                bills: relatedBills,
                topCategories: topCategories,
                emptyText: "No bills in this life area",
                canLoadMore: billsStore.canLoadMore,
                isLoadingMore: billsStore.isLoadingMore,
                onLoadMore: { Task { await billsStore.loadMore() } }
            ) { billID in
                Self.billPage(billID)
            }
        }
        .billboardBackground()
        .navigationTitle(lifeArea)
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

extension CongressLifeAreaDetailView {
    /// The page a bill in a life area's list opens: the full
    /// page with the vote bar, a decided bill's too (Civic Record project decision 1). `DecidedBillVotingTests`
    /// opens it from here.
    static func billPage(_ billID: UUID) -> BillDetail {
        BillDetail(billID: billID)
    }
}
