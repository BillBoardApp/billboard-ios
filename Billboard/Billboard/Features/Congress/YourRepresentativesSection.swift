import SwiftUI

/// "Your representatives" at the top of the Congress tab (spec D 2.5.8, Civic Record spec 4.55; R1
/// showed it on the Bills tab as `YourRepresentativesCard`): the user's two senators and House member
/// on a roll sheet, with how many of their bills changed in the Bills tab's window. Without an address
/// it asks for one.
struct YourRepresentativesSection: View {
    /// The Bills tab's window, so the counts match what the Bills tab shows.
    let historyWindow: BillboardHistoryWindow

    @EnvironmentObject private var userStore: UserStore
    @EnvironmentObject private var congressManifestStore: CongressMembersManifestStore
    @EnvironmentObject private var billsStore: BillsStore

    /// Counts by member ID, recomputed only when the bills, the window or the members change
    /// (not on every redraw, such as each keystroke in member search).
    @State private var billCounts: [String: Int] = [:]
    @State private var hasBillCounts = false

    private var state: CongressRepresentativesState {
        CongressTabModel.representativesState(
            profileLoaded: userStore.hasRefreshedOnce,
            state: userStore.profile.state,
            district: userStore.profile.district,
            manifest: congressManifestStore.items,
            manifestIsLoading: congressManifestStore.isLoading,
            manifestHasLoaded: congressManifestStore.hasLoadedOnce,
            manifestFailed: congressManifestStore.errorMessage != nil
        )
    }

    private var representatives: [CongressMemberManifestItem] {
        if case .members(let members) = state { return members }
        return []
    }

    private var billsAreReady: Bool {
        billsStore.hasLoadedOnce || !billsStore.manifestItems.isEmpty
    }

    private var countRefreshKey: String {
        let ids = representatives.map(\.id).joined(separator: "|")
        let latest = billsStore.manifestItems.compactMap(\.updatedAt).max() ?? ""
        return "\(historyWindow.rawValue)|\(ids)|\(billsStore.manifestItems.count)|\(latest)|\(billsAreReady)"
    }

    private func refreshBillCounts() {
        guard billsAreReady else { return }
        billCounts = CongressTabModel.recentSponsoredBillCounts(
            memberIDs: representatives.map(\.id),
            manifestItems: billsStore.manifestItems,
            window: historyWindow
        )
        hasBillCounts = true
    }

    var body: some View {
        YourRepresentativesContent(
            state: state,
            billCounts: hasBillCounts ? billCounts : nil,
            historyWindow: historyWindow,
            districtCode: YourRepresentativesContent.districtCode(state: userStore.profile.state, district: userStore.profile.district),
            onAddAddress: {
                NotificationCenter.default.post(name: .billboardRequestLocationEditor, object: nil)
            },
            onRetry: {
                Task { await congressManifestStore.load(forceRefresh: true) }
            }
        )
        .onAppear { refreshBillCounts() }
        .onChange(of: countRefreshKey) { _, _ in
            refreshBillCounts()
        }
    }
}

/// The section's content for a given state, without stores, so it can be rendered in tests (Civic
/// Record spec 4.55): the SectionHeader with the user's district as its counter ("VA-11", read
/// "Virginia's 11th district"), then a roll sheet with the column heads MEMBER and BILLS THIS WEEK
/// and one row per member, or a RecordNotice for each state without members.
struct YourRepresentativesContent: View {
    let state: CongressRepresentativesState
    /// Bill counts by member ID; nil until the bills have loaded.
    let billCounts: [String: Int]?
    let historyWindow: BillboardHistoryWindow
    /// The user's district as a code ("VA-11", "AK at-large", "VA" without a district); nil without a
    /// location.
    var districtCode: String? = nil
    let onAddAddress: () -> Void
    /// "Try again" when the members could not be loaded.
    var onRetry: (() -> Void)? = nil

    static let title = "Your representatives"
    static let loadingText = "Loading your representatives…"
    static let needsLocationText = "Add your address to see who represents you."
    static let unavailableText = "Your representatives aren't available right now. Pull down to try again."

    static func notFoundText(region: String) -> String {
        "We couldn't find the members for \(region). Check your address."
    }

    /// What VoiceOver reads for `notFoundText`: the region in the one spoken form (project decision of
    /// 2026-10-21), "We couldn't find the members for Virginia's 11th district. Check your address."
    static func notFoundSpokenText(region: String) -> String {
        notFoundText(region: SpokenForm.districtOrCode(region))
    }

    /// The header's counter: "VA-11", "AK at-large", or the state code alone without a district (as
    /// Profile's Where you vote writes it); nil without a state.
    static func districtCode(state: String, district: String) -> String? {
        guard let code = DistrictPickerModel.stateCode(from: state) else { return nil }
        return district.trimmedNonEmpty == nil ? code : DistrictPickerModel.locationLabel(state: code, district: district)
    }

    /// "Bills this week", "Bills in the last 2 weeks": the figure column's head, from the Bills tab's window.
    static func figureColumnHead(_ window: BillboardHistoryWindow) -> String {
        "Bills \(CongressTabModel.windowPhrase(window))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: BillboardStyle.Space.m) {
            SectionHeader(Self.title, trailing: districtCode.map { .district($0) } ?? .none)

            content
        }
        // A container, so the controls inside keep their own ids.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("congress.representatives")
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loadingProfile, .loadingMembers:
            CongressLoadingLine(text: Self.loadingText)

        case .needsLocation:
            RecordNotice(
                .nothingYet,
                title: Self.needsLocationText,
                action: .init(title: "Add address", accessibilityIdentifier: "congress.representatives.addAddress", perform: onAddAddress)
            )

        case .notFound(let region):
            RecordNotice(
                .notFound,
                title: Self.notFoundText(region: region),
                spokenTitle: Self.notFoundSpokenText(region: region),
                action: .init(title: "Check address", accessibilityIdentifier: "congress.representatives.checkAddress", perform: onAddAddress)
            )

        case .membersUnavailable:
            RecordNotice(
                .couldNotLoad,
                title: "Couldn't load your representatives",
                message: Self.unavailableText,
                action: onRetry.map { retry in
                    .init(title: "Try again", accessibilityIdentifier: "congress.representatives.retry", perform: retry)
                }
            )

        case .members(let members):
            RollSheet(columnHeads: .init(leading: "Member", trailing: Self.figureColumnHead(historyWindow))) {
                RollRows(members) { index, member in
                    // A value the Congress tab's path keeps across tab switches (`CongressRoute`).
                    NavigationLink(value: CongressRoute.member(member)) {
                        CongressRepresentativeRow(
                            member: member,
                            billCount: billCounts.map { $0[member.id] ?? 0 },
                            billCountText: countText(for: member)
                        )
                    }
                    .buttonStyle(RowButtonStyle())
                    .accessibilityIdentifier("congress.representatives.member.\(index)")
                }
            }
        }
    }

    private func countText(for member: CongressMemberManifestItem) -> String {
        guard let billCounts else {
            return CongressTabModel.billCountText(nil, window: historyWindow)
        }
        return CongressTabModel.billCountText(billCounts[member.id] ?? 0, window: historyWindow)
    }
}

/// One representative on the roll sheet (spec 3.15): the 44 pt monogram with the party disc, "Sen. Tim
/// Kaine", "D · SENATE · VA", and the figure for their bills in the Bills tab's window. VoiceOver: "Senator
/// Tim Kaine, Democrat, Virginia, 2 bills this week" (R2's label).
struct CongressRepresentativeRow: View {
    let member: CongressMemberManifestItem
    /// Nil while the bills load.
    let billCount: Int?
    /// "2 bills this week", or "Updating…" while the bills load.
    let billCountText: String

    private var party: PoliticalParty? { CongressMemberLabel.party(of: member) }
    private var chamber: CongressChamber? { CongressMemberLabel.chamber(of: member) }

    var accessibilityText: String {
        CongressMemberLabel.spokenDescription(
            name: member.name,
            party: party,
            state: member.state,
            district: member.district,
            chamber: chamber
        ) + ", " + billCountText
    }

    var body: some View {
        MemberRollRow(
            name: CongressMemberLabel.titledName(member.name, chamber: chamber),
            monogramName: member.name,
            party: party,
            affiliation: CongressMemberLabel.affiliation(party: party, state: member.state, district: member.district, chamber: chamber),
            photoURL: member.depictionImageUrl,
            monogramSize: .roll,
            trailing: .figure(billCount),
            figureText: billCountText,
            accessibilityLabel: accessibilityText
        )
    }
}

/// A section's loading line (spec 3.20): the spinner in ink with the R2 caption in `caption` `ink2`.
struct CongressLoadingLine: View {
    let text: String

    var body: some View {
        HStack(alignment: .center, spacing: BillboardStyle.Space.s) {
            ProgressView()
                .tint(BillboardColors.interactive)
                .accessibilityHidden(true)
            Text(text)
                .textRole(.caption)
                .foregroundStyle(BillboardColors.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, BillboardStyle.Space.s)
        .accessibilityElement(children: .combine)
    }
}
