import SwiftUI

enum CongressChamber: String {
    case house = "House"
    case senate = "Senate"

    var displayName: String {
        switch self {
        case .house: return "House of Representatives"
        case .senate: return rawValue
        }
    }

}

/// The House or the Senate, set as a document (Civic Record spec 4.58): the front matter with the
/// number of members, then ruled sections: Composition by party, Bills by topic group, Bills by topic
/// and the members on a roll sheet. The counts and shares are the voting seats; the House's delegates
/// are on the roll and named in the docket (project decision 2026-10-31). No hemicycle in 1.2, and no
/// "Bills sponsored" figure: its pass share read flags nothing sets, so it was 0% for everyone, and it
/// counted only the Bills window's bills (project decision 2026-10-31; 1.3 can add whole-Congress figures).
struct CongressChamberInfoView: View {
    @EnvironmentObject private var billsStore: BillsStore
    @EnvironmentObject private var userStore: UserStore

    @StateObject private var manifestStore = CongressMembersManifestStore()

    let chamber: CongressChamber

    private var members: [CongressMemberManifestItem] {
        // The store keeps items in roster order (last name, then first name).
        manifestStore.items
            .filter { $0.chamberNormalized == chamber.rawValue }
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

    /// Composition: each party's voting members and their share of the chamber's voting members
    /// ("Democratic (D)", "215 · 50%"), every party listed; the delegates are left out.
    static func compositionRows(for members: [CongressMemberManifestItem]) -> [(label: String, value: String)] {
        let voting = CongressTabModel.votingMembers(members)
        let total = voting.count
        let grouped = Dictionary(grouping: voting, by: { PoliticalParty.from(raw: $0.party) ?? .independent })
        return PoliticalParty.allCases.map { party in
            let count = grouped[party]?.count ?? 0
            let pct = CongressMetrics.ratioString(numerator: count, denominator: total)
            return (label: "\(party.rawValue) (\(party.letter))", value: "\(count) · \(pct)")
        }
    }

    /// The docket under the title: the voting members, then the delegates when there are any, so the
    /// count says why the House's roll is longer ("433 members · 6 delegates"; "100 members" for the
    /// Senate). It is the only count that names the delegates. Set with `CongressMemberLabel.docketText`,
    /// so at large sizes the dot ends a line rather than starting one.
    static func docket(for members: [CongressMemberManifestItem]) -> String {
        let voting = CongressTabModel.votingMembers(members).count
        let delegates = members.count - voting
        var parts = ["\(voting) \(voting == 1 ? "member" : "members")"]
        if delegates > 0 {
            parts.append("\(delegates) \(delegates == 1 ? "delegate" : "delegates")")
        }
        return CongressMemberLabel.docketText(parts.joined(separator: " · "))
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
            title: chamber.displayName,
            docket: isInitialLoading ? "Loading members…" : Self.docket(for: members)
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
                                .accessibilityIdentifier("congress.\(chamber.rawValue.lowercased()).member.\(index)")
                                .buttonStyle(RowButtonStyle())
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
