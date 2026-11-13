import SwiftUI

/// "Parties" under How Congress works (Civic Record spec 4.58): one roll sheet with a row per party,
/// each with its disc, its name and its members by chamber, in the 16 pt list gutter.
struct PoliticalPartiesView: View {
    @StateObject private var manifestStore = CongressMembersManifestStore()

    /// A party's row: its voting members, in all and in each chamber. The delegates are left out, as
    /// from every count; the party's page lists them.
    static func counts(for party: PoliticalParty, in manifest: [CongressMemberManifestItem]) -> (total: Int, house: Int, senate: Int) {
        let voting = CongressTabModel.votingMembers(
            manifest.filter { (PoliticalParty.from(raw: $0.party) ?? .independent) == party }
        )
        return (
            total: voting.count,
            house: voting.filter { $0.chamberNormalized == CongressChamber.house.rawValue }.count,
            senate: voting.filter { $0.chamberNormalized == CongressChamber.senate.rawValue }.count
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BillboardStyle.Space.l) {
                if manifestStore.isLoading && manifestStore.items.isEmpty {
                    CongressLoadingLine(text: "Loading members…")
                }

                if manifestStore.errorMessage != nil, manifestStore.items.isEmpty {
                    CongressLoadErrorCard(message: CongressLoadErrorCard.defaultMessage) {
                        Task { await manifestStore.load(forceRefresh: true) }
                    }
                }

                RollSheet {
                    RollRows(PoliticalParty.allCases) { _, party in
                        let counts = Self.counts(for: party, in: manifestStore.items)

                        NavigationLink {
                            PoliticalPartyDetailView(party: party)
                        } label: {
                            PoliticalPartyRow(
                                party: party,
                                totalCount: counts.total,
                                houseCount: counts.house,
                                senateCount: counts.senate
                            )
                        }
                        .buttonStyle(RowButtonStyle())
                        .accessibilityIdentifier("congress.parties.\(party.letter.lowercased())")
                    }
                }
            }
            // The 16 pt list gutter (spec 2.8).
            .padding(.horizontal, BillboardStyle.Space.l)
            .padding(.top, BillboardStyle.Space.l)
            .padding(.bottom, BillboardStyle.Space.xxl)
        }
        .billboardBackground()
        .navigationTitle("Parties")
        .navigationBarTitleDisplayMode(.inline)
        .glassNavigationBar()
        .task { await manifestStore.load(forceRefresh: false) }
        .refreshable { await manifestStore.load(forceRefresh: true) }
    }
}

/// A party on the Parties roll sheet (spec 4.58): the 24 pt party disc, the party's name in the `name`
/// role, its members by chamber in the `docket` role ("47 MEMBERS · 0 HOUSE · 47 SENATE"), and the
/// chevron. The name says the party, so the disc is decoration. One VoiceOver element.
///
/// At accessibility text sizes the row stacks as a member row does (`MemberRollRow`): the disc and the
/// chevron on the first line, then the name and the counts across the whole width, so "Independent"
/// breaks between words, never inside one, and a dot never starts a line.
struct PoliticalPartyRow: View {
    let party: PoliticalParty
    let totalCount: Int
    let houseCount: Int
    let senateCount: Int

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    static func summary(totalCount: Int, houseCount: Int, senateCount: Int) -> String {
        "\(totalCount) \(totalCount == 1 ? "member" : "members") · \(houseCount) House · \(senateCount) Senate"
    }

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: BillboardStyle.Space.s) {
                    HStack(alignment: .center, spacing: RollRowInsets.gap) {
                        disc
                        Spacer(minLength: 0)
                        RowChevron()
                    }
                    words
                }
            } else {
                HStack(alignment: .center, spacing: RollRowInsets.gap) {
                    disc
                    words
                    RowChevron()
                }
            }
        }
        .padding(RollRowInsets.standard)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(party.rawValue), \(Self.summary(totalCount: totalCount, houseCount: houseCount, senateCount: senateCount))")
    }

    private var disc: some View {
        PartyBadge(party: party, size: .regular)
            .accessibilityHidden(true)
    }

    private var words: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(party.rawValue)
                .textRole(.name)
                .foregroundStyle(BillboardColors.primaryText)
                .fixedSize(horizontal: false, vertical: true)

            Text(CongressMemberLabel.docketText(Self.summary(totalCount: totalCount, houseCount: houseCount, senateCount: senateCount)))
                .textRole(.docket)
                .foregroundStyle(BillboardColors.dimText)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
