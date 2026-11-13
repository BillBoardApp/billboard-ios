import SwiftUI

/// A party's page, set as a document (Civic Record spec 4.58): the front matter with the party disc and
/// the states it holds seats in, then ruled sections: Composition (the voting seats), Bills by topic
/// group, Bills by topic and the members on a roll sheet (delegates included). No "Bills sponsored"
/// figure or pass share in 1.2 (project decision 2026-10-31; party pass rates stay out, UX-39 N8).
struct PoliticalPartyDetailView: View {
    @EnvironmentObject private var billsStore: BillsStore
    @EnvironmentObject private var userStore: UserStore

    @StateObject private var manifestStore = CongressMembersManifestStore()

    let party: PoliticalParty

    private var members: [CongressMemberManifestItem] {
        // The store keeps items in roster order (last name, then first name).
        manifestStore.items
            .filter { (PoliticalParty.from(raw: $0.party) ?? .independent) == party }
    }

    private var isInitialLoading: Bool {
        if manifestStore.isLoading { return true }
        if !manifestStore.hasLoadedOnce && manifestStore.items.isEmpty { return true }
        if !userStore.hasRefreshedOnce { return true }
        return false
    }

    /// Delegates included: a delegate's bills are House bills.
    private var sponsorIDs: Set<UUID> {
        Set(members.map { UUID.deterministic(from: $0.id) })
    }

    private var subscribedIDs: Set<UUID> {
        Set(userStore.profile.subscribedMemberIDs)
    }

    private func isSubscribed(_ member: CongressMemberManifestItem) -> Bool {
        subscribedIDs.contains(UUID.deterministic(from: member.id))
    }

    private var proposedBills: [Bill] {
        CongressMetrics.billsProposed(bySponsorIDs: sponsorIDs, in: billsStore.bills)
    }

    private var representedStates: String {
        let states = Array(Set(members.compactMap { $0.state })).sorted()
        return states.isEmpty ? "—" : states.joined(separator: ", ")
    }

    /// Composition: the party's voting members, then those in each chamber with their share of them
    /// ("House of Representatives", "215 · 83%"); the delegates are left out, as from every count.
    static func compositionRows(for members: [CongressMemberManifestItem]) -> [(label: String, value: String)] {
        let voting = CongressTabModel.votingMembers(members)
        let total = voting.count
        let house = voting.filter { $0.chamberNormalized == CongressChamber.house.rawValue }.count
        let senate = voting.filter { $0.chamberNormalized == CongressChamber.senate.rawValue }.count
        return [
            (label: "Total members", value: "\(total)"),
            (label: CongressChamber.house.displayName, value: "\(house) · \(CongressMetrics.ratioString(numerator: house, denominator: total))"),
            (label: CongressChamber.senate.displayName, value: "\(senate) · \(CongressMetrics.ratioString(numerator: senate, denominator: total))")
        ]
    }

    @MainActor
    private func loadStatsData(forceRefresh: Bool) async {
        await manifestStore.load(forceRefresh: forceRefresh)
        if forceRefresh {
            await billsStore.load(forceRefresh: true, mode: .manifestOnly, loadFullManifest: true)
        } else {
            await billsStore.ensureFullManifestLoaded()
        }
    }

    var body: some View {
        CongressDocumentScroll(
            title: party.rawValue,
            party: party,
            docket: "States: \(representedStates)"
        ) {
            RecordSection("Composition", showsRule: false) {
                CongressFigureList(rows: Self.compositionRows(for: members))
            }

            RecordSection("Bills by topic group") {
                CongressFigureList(rows: CongressMetrics.categoryRateRows(for: proposedBills), emptyText: "No bills yet")
            }

            RecordSection("Bills by topic") {
                CongressFigureList(rows: CongressMetrics.topicRateRows(for: proposedBills), emptyText: "No bills yet")
            }

            RecordSection("Members") {
                if isInitialLoading {
                    CongressLoadingLine(text: "Loading members…")
                } else if members.isEmpty {
                    RecordNotice(.nothingYet, title: "No members")
                } else {
                    RollSheet {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            RollRows(members) { index, member in
                                NavigationLink {
                                    CongressMemberProfileLoaderView(manifest: member)
                                } label: {
                                    CongressMemberRow(manifest: member, isSubscribed: isSubscribed(member))
                                }
                                .buttonStyle(RowButtonStyle())
                                .accessibilityIdentifier("congress.party.member.\(index)")
                            }
                        }
                    }
                }
            }
        }
        .background(BillboardColors.document.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .glassNavigationBar()
        .task { await loadStatsData(forceRefresh: false) }
        .refreshable { await loadStatsData(forceRefresh: true) }
    }
}
