import SwiftUI

/// The Congress tab (spec D 2.5.8, Civic Record spec 4.54), top to bottom under the page title: your
/// representatives, the members you follow, "Find a member" and "How Congress works", each under a
/// SectionHeader, in the 16 pt list gutter. Everything comes from the members manifest the tab shell
/// already loads (`CongressMembersManifestStore`), the profile and the loaded bills; the tab sends no
/// request of its own beyond refreshing that manifest.
struct CongressTab: View {
    let isActive: Bool
    /// The search text and filter, kept by the tab shell: it builds only the selected tab, so state
    /// held here would be lost on every tab switch.
    @Binding var search: CongressSearchState

    @EnvironmentObject private var manifestStore: CongressMembersManifestStore
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var userStore: UserStore
    @AppStorage(BillboardDisplayStorage.historyWindowDaysKey) private var historyWindowDays = BillboardHistoryWindow.default.rawValue

    /// The window the Bills tab is showing (it can be widened for the session), so "bills this
    /// week" counts the same bills.
    private var historyWindow: BillboardHistoryWindow {
        appState.sessionBillboardHistoryWindow ?? BillboardHistoryWindow.from(rawValue: historyWindowDays)
    }

    private var followedMembers: [CongressMemberManifestItem] {
        CongressTabModel.followedMembers(followedIDs: userStore.profile.subscribedMemberIDs, in: manifestStore.items)
    }

    private var isLoadingFollowedMembers: Bool {
        if !userStore.hasRefreshedOnce && userStore.profile.subscribedMemberIDs.isEmpty { return true }
        return !userStore.profile.subscribedMemberIDs.isEmpty && manifestStore.items.isEmpty && manifestStore.isLoading
    }

    /// The profile follows members but the manifest that names them could not be loaded.
    private var areFollowedMembersUnavailable: Bool {
        !userStore.profile.subscribedMemberIDs.isEmpty && manifestStore.items.isEmpty && !manifestStore.isLoading && manifestStore.hasLoadedOnce
    }

    private var isLoadingMembers: Bool {
        manifestStore.items.isEmpty && (manifestStore.isLoading || !manifestStore.hasLoadedOnce)
    }

    private var hasUserState: Bool {
        !userStore.profile.state.uppercasedTrimmed.isEmpty
    }

    private func requestLocationEditor() {
        NotificationCenter.default.post(name: .billboardRequestLocationEditor, object: nil)
    }

    /// Unfollow only a member who is followed: `toggleMemberSubscription` flips the current
    /// state, so a second tap during the update must not follow them again.
    private func unfollow(_ member: CongressMemberManifestItem) {
        guard CongressTabModel.isFollowed(member, followedIDs: userStore.profile.subscribedMemberIDs) else { return }
        userStore.toggleMemberSubscription(manifestId: member.id)
    }

    var body: some View {
        let manifest = manifestStore.items
        let followed = followedMembers
        // The voting seats: the delegates are in the lists, not in the counts.
        let seats = CongressTabModel.chamberCounts(in: manifest)
        let houseCount = seats.house
        let senateCount = seats.senate
        let session = CongressCalendar.session(on: Date())

        ScrollView {
            VStack(alignment: .leading, spacing: CongressTabLayout.sectionSpacing) {
                // The page title on paper under the compact masthead (spec 3.21); the deck's Congress is
                // computed, its counts are the members list's voting seats. Its own 4 pt inset puts it at 20 pt.
                PageTitle(
                    title: "Congress",
                    deck: CongressDeck.unbrokenText(session: session, houseCount: houseCount, senateCount: senateCount),
                    deckAccessibilityLabel: CongressDeck.spokenText(session: session, houseCount: houseCount, senateCount: senateCount)
                )

                if manifestStore.errorMessage != nil, manifest.isEmpty, !manifestStore.isLoading {
                    CongressLoadErrorCard(message: CongressLoadErrorCard.defaultMessage) {
                        Task { await manifestStore.load(forceRefresh: true) }
                    }
                }

                YourRepresentativesSection(historyWindow: historyWindow)

                CongressFollowedMembersSection(
                    members: followed,
                    isLoading: isLoadingFollowedMembers,
                    isUnavailable: areFollowedMembersUnavailable,
                    onUnfollow: { unfollow($0) }
                )

                CongressMemberSearchSection(
                    searchText: $search.text,
                    filter: $search.filter,
                    results: CongressTabModel.inlineResults(
                        in: manifest,
                        query: search.text,
                        filter: search.filter,
                        userState: userStore.profile.state
                    ),
                    followedMemberIDs: Set(followed.map(\.id)),
                    hasUserState: hasUserState,
                    isLoadingMembers: isLoadingMembers,
                    totalMemberCount: manifest.count,
                    userState: userStore.profile.state,
                    onAddAddress: { requestLocationEditor() }
                )

                CongressHowItWorksSection(houseCount: houseCount, senateCount: senateCount)
            }
            .padding(.horizontal, CongressTabLayout.gutter)
            .padding(.bottom, CongressTabLayout.bottomPadding)
        }
        .scrollDismissesKeyboard(.interactively)
        .billboardBackground()
        .refreshable {
            await manifestStore.load(forceRefresh: true)
        }
        .task(id: isActive) {
            guard isActive else { return }
            await manifestStore.load(forceRefresh: false)
        }
        .accessibilityIdentifier("congress.screen")
    }
}

// MARK: - Tab state and routes

/// The "Find a member" search text and filter (`TabsBar` keeps them across tab switches).
struct CongressSearchState: Equatable {
    var text = ""
    var filter: CongressMemberFilter = .all
}

/// The Congress tab's own pushes, as values: the tab shell's `congressPath` keeps them, so a tab
/// switch (which rebuilds the tab) brings back the screen that was open. Screens these push may
/// push further with their own links; a tab switch returns to the first of those.
enum CongressRoute: Hashable {
    /// A member's profile (your representatives, members you follow, search matches).
    case member(CongressMemberManifestItem)
    /// "See all members", opened with the search and filter as they were.
    case allMembers(filter: CongressMemberFilter, state: String?, searchText: String)
    case parties
    case chamber(CongressChamber)

    /// "See all members" for the current search: My state opens on the user's state.
    static func seeAllMembers(filter: CongressMemberFilter, userState: String, searchText: String) -> CongressRoute {
        .allMembers(
            filter: filter,
            state: filter == .myState ? userState.uppercasedTrimmed : nil,
            searchText: searchText.trimmed
        )
    }

    @ViewBuilder
    var destination: some View {
        switch self {
        case .member(let member):
            CongressMemberProfileLoaderView(manifest: member)
        case .allMembers(let filter, let state, let searchText):
            CongressMembersDirectoryView(
                initialSelection: CongressMembersDirectoryView.ExploreSelection(filter),
                initialState: state,
                initialSearchText: searchText
            )
        case .parties:
            PoliticalPartiesView()
        case .chamber(let chamber):
            CongressChamberInfoView(chamber: chamber)
        }
    }
}

extension CongressDeck {
    /// The deck as the Congress tab sets it: `text` with a no-break space before each dot and inside
    /// "House 435" and "Senate 100", so at large sizes the line breaks only after a dot or inside
    /// "119th Congress", and a dot never starts a line (as `CongressMemberLabel.docketText` does for
    /// affiliations).
    static func unbrokenText(session: CongressCalendar.Session, houseCount: Int, senateCount: Int) -> String {
        guard houseCount > 0 || senateCount > 0 else { return session.congressTitle }
        let noBreak = "\u{00A0}"
        return "\(session.congressTitle)\(noBreak)· House\(noBreak)\(houseCount)\(noBreak)· Senate\(noBreak)\(senateCount)"
    }
}

/// The Congress tab's measures (Civic Record spec 2.8, 3.5): the 16 pt list gutter (the page title's own
/// 4 pt inset puts it at 20 pt, in line with the masthead), 28 pt between sections (the mockup's 12 pt
/// gap plus the section head's 16 pt margin), and 12 pt from a section's head to its content.
enum CongressTabLayout {
    static let gutter = BillboardStyle.Space.l
    static let sectionSpacing = BillboardStyle.Space.xxl
    static let headToContent = BillboardStyle.Space.m
    /// Under the last section, above the tab capsule's clearance.
    static let bottomPadding = BillboardStyle.Space.xxl
}

// MARK: - Members you follow

/// The members the user follows (Civic Record spec 4.56): a roll sheet without column heads, each row
/// with the 36 pt monogram and an Unfollow capsule (under the name at accessibility sizes). Following
/// members puts their bills on the Bills tab; their profile has the Follow button.
struct CongressFollowedMembersSection: View {
    let members: [CongressMemberManifestItem]
    let isLoading: Bool
    /// The profile follows members, but the members list could not be loaded.
    var isUnavailable: Bool = false
    let onUnfollow: (CongressMemberManifestItem) -> Void

    static let title = "Members you follow"
    static let emptyText = "Follow members to see their bills on your Bills tab."
    static let unavailableText = "The members you follow aren't available right now. Pull down to try again."

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var trailing: SectionHeader.Trailing {
        guard !members.isEmpty else { return .none }
        return .counter("\(members.count)", spoken: members.count == 1 ? "1 member" : "\(members.count) members")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CongressTabLayout.headToContent) {
            SectionHeader(Self.title, trailing: trailing)

            if isLoading {
                CongressLoadingLine(text: "Loading members…")
            } else if members.isEmpty && isUnavailable {
                RecordNotice(.couldNotLoad, title: "Couldn't load the members you follow", message: Self.unavailableText)
            } else if members.isEmpty {
                RecordNotice(.nothingYet, title: Self.emptyText)
                    .accessibilityIdentifier("congress.followed.empty")
            } else {
                RollSheet {
                    RollRows(members) { index, member in
                        row(index: index, member: member)
                    }
                }
            }
        }
        // A container, so the controls inside keep their own ids.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("congress.followed")
    }

    /// The member's link and the Unfollow capsule beside it; at accessibility sizes the capsule goes under
    /// the name, so the name keeps the row's width.
    @ViewBuilder
    private func row(index: Int, member: CongressMemberManifestItem) -> some View {
        let unfollow = CongressUnfollowButton(memberName: member.name) {
            onUnfollow(member)
        }
        .accessibilityIdentifier("congress.followed.unfollow.\(index)")

        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 0) {
                link(index: index, member: member, insets: EdgeInsets(
                    top: RollRowInsets.vertical,
                    leading: RollRowInsets.leading,
                    bottom: BillboardStyle.Space.s,
                    trailing: RollRowInsets.trailing
                ))
                unfollow
                    .padding(.leading, RollRowInsets.leading)
                    .padding(.trailing, RollRowInsets.trailing)
                    .padding(.bottom, RollRowInsets.vertical)
            }
        } else {
            HStack(alignment: .center, spacing: 0) {
                link(index: index, member: member, insets: EdgeInsets(
                    top: RollRowInsets.vertical,
                    leading: RollRowInsets.leading,
                    bottom: RollRowInsets.vertical,
                    trailing: RollRowInsets.gap
                ))
                unfollow
                    .padding(.trailing, RollRowInsets.trailing)
            }
        }
    }

    private func link(index: Int, member: CongressMemberManifestItem, insets: EdgeInsets) -> some View {
        NavigationLink(value: CongressRoute.member(member)) {
            CongressMemberRow(manifest: member, showsChevron: false, insets: insets)
        }
        .buttonStyle(RowButtonStyle())
        .accessibilityIdentifier("congress.followed.member.\(index)")
    }
}

/// Unfollow on a followed member's row: a secondary capsule (ink outline, 44 pt, spec 3.16). VoiceOver
/// reads "Unfollow Tim Kaine"; Voice Control also takes the visible word.
struct CongressUnfollowButton: View {
    let memberName: String
    let action: () -> Void

    var body: some View {
        Button("Unfollow", action: action)
            .buttonStyle(BillboardButtonStyle(kind: .secondary, fullWidth: false))
            .fixedSize()
            .accessibilityLabel("Unfollow \(memberName)")
            .accessibilityInputLabels(["Unfollow", "Unfollow \(memberName)"])
    }
}

// MARK: - Find a member

/// A search capsule ("Name, state or district") and the All / House / Senate / My state filter, with
/// up to 20 matches inline on a roll sheet and "See all members" for the full directory (Civic Record
/// spec 4.57).
struct CongressMemberSearchSection: View {
    @Binding var searchText: String
    @Binding var filter: CongressMemberFilter
    let results: CongressTabModel.InlineResults?
    let followedMemberIDs: Set<String>
    let hasUserState: Bool
    let isLoadingMembers: Bool
    let totalMemberCount: Int
    let userState: String
    let onAddAddress: () -> Void

    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: CongressTabLayout.headToContent) {
            SectionHeader("Find a member")

            CongressSearchCapsule(text: $searchText, isFocused: $isSearchFocused)

            Picker("Show", selection: $filter) {
                ForEach(CongressMemberFilter.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("congress.search.filter")

            CongressMemberSearchResults(
                query: searchText,
                filter: filter,
                results: results,
                followedMemberIDs: followedMemberIDs,
                hasUserState: hasUserState,
                isLoadingMembers: isLoadingMembers,
                onAddAddress: onAddAddress
            )

            RollSheet {
                NavigationLink(value: CongressRoute.seeAllMembers(filter: filter, userState: userState, searchText: searchText)) {
                    RollLinkRow(title: "See all members")
                }
                .buttonStyle(RowButtonStyle())
                .accessibilityIdentifier("congress.nav.members")
            }
        }
        // A container, so the controls inside keep their own ids.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("congress.search")
    }
}

/// The inline "Find a member" field (spec 3.17): the search capsule (`SearchCapsule`, as the Bills tab's
/// "Search bills" row) with the example in `ink3`, the text in `body` `ink`, and a clear button while there
/// is text. It grows with the text at large sizes.
struct CongressSearchCapsule: View {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding

    static let prompt = "Name, state or district"

    @ScaledMetric(relativeTo: .body) private var glyphSize: CGFloat = 16

    var body: some View {
        SearchCapsule(trailingPadding: text.isEmpty ? BillboardStyle.Space.l : 4) {
            TextField(text: $text, prompt: Text(Self.prompt).foregroundStyle(BillboardColors.dimText)) {
                Text("Find a member")
            }
            .textRole(.body)
            .foregroundStyle(BillboardColors.primaryText)
            .tint(BillboardColors.interactive)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
            .submitLabel(.search)
            .focused(isFocused)
            .onSubmit { isFocused.wrappedValue = false }
            .accessibilityLabel("Find a member")
            .accessibilityHint(Self.prompt)
            .accessibilityIdentifier("congress.search.field")

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(TextRole.Face.text.font(size: glyphSize, weight: .regular))
                        .foregroundStyle(BillboardColors.dimText)
                        .billboardMinimumHitTarget()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
    }
}

/// The inline matches under the search field (no store, so it can be rendered in tests): a roll sheet
/// of member rows with "Following" on the followed ones and a truncation note under it, or a notice.
struct CongressMemberSearchResults: View {
    let query: String
    let filter: CongressMemberFilter
    let results: CongressTabModel.InlineResults?
    let followedMemberIDs: Set<String>
    let hasUserState: Bool
    let isLoadingMembers: Bool
    let onAddAddress: () -> Void

    var body: some View {
        if isLoadingMembers {
            CongressLoadingLine(text: "Loading members…")
        } else if filter == .myState && !hasUserState {
            RecordNotice(
                .nothingYet,
                title: "Add your address to see the members from your state.",
                action: .init(title: "Add address", accessibilityIdentifier: "congress.search.addAddress", perform: onAddAddress)
            )
        } else if let results {
            if results.members.isEmpty {
                RecordNotice(.notFound, title: emptyText)
                    .accessibilityIdentifier("congress.search.empty")
            } else {
                VStack(alignment: .leading, spacing: BillboardStyle.Space.s) {
                    RollSheet {
                        RollRows(results.members) { index, member in
                            NavigationLink(value: CongressRoute.member(member)) {
                                CongressMemberRow(
                                    manifest: member,
                                    isSubscribed: followedMemberIDs.contains(member.id)
                                )
                            }
                            .buttonStyle(RowButtonStyle())
                            .accessibilityIdentifier("congress.search.member.\(index)")
                        }
                    }

                    if results.isTruncated {
                        Text("Showing \(results.members.count) of \(results.totalCount). Type more to narrow the list, or see all members.")
                            .textRole(.caption)
                            .foregroundStyle(BillboardColors.dimText)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("congress.search.truncated")
                    }
                }
            }
        }
    }

    private var emptyText: String {
        let trimmed = query.trimmed
        return trimmed.isEmpty ? "No members to show." : "No members match “\(trimmed)”."
    }
}

// MARK: - How Congress works

/// One slip of ruled rows (Civic Record spec 4.58): Parties, House of Representatives and Senate, each
/// with a line under it and a chevron. No flag or columns symbols, no glow borders.
struct CongressHowItWorksSection: View {
    let houseCount: Int
    let senateCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: CongressTabLayout.headToContent) {
            SectionHeader("How Congress works")

            RollSheet {
                NavigationLink(value: CongressRoute.parties) {
                    RollLinkRow(title: "Parties", subtitle: "Members and bills by party")
                }
                .accessibilityIdentifier("congress.nav.politicalParties")
                .buttonStyle(RowButtonStyle())

                HairlineRule()

                NavigationLink(value: CongressRoute.chamber(.house)) {
                    RollLinkRow(
                        title: CongressChamber.house.displayName,
                        subtitle: houseCount > 0 ? "\(houseCount) members" : "Members and bills"
                    )
                }
                .accessibilityIdentifier("congress.nav.house")
                .buttonStyle(RowButtonStyle())

                HairlineRule()

                NavigationLink(value: CongressRoute.chamber(.senate)) {
                    RollLinkRow(
                        title: CongressChamber.senate.displayName,
                        subtitle: senateCount > 0 ? "\(senateCount) members" : "Members and bills"
                    )
                }
                .accessibilityIdentifier("congress.nav.senate")
                .buttonStyle(RowButtonStyle())
            }
        }
        // A container, so the controls inside keep their own ids.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("congress.howItWorks")
    }
}

// MARK: - Load error

/// The members list could not be loaded (spec 3.20, 4.54): a RecordNotice with the COULDN'T LOAD stamp
/// and "Try again".
struct CongressLoadErrorCard: View {
    static let defaultMessage = "Check your connection, then try again."
    static let title = "Couldn't load members"

    let message: String
    let onRetry: () -> Void

    var body: some View {
        RecordNotice(
            .couldNotLoad,
            title: Self.title,
            message: message,
            action: .init(title: "Try again", accessibilityIdentifier: "congress.loadError.retry", perform: onRetry)
        )
        // R2's id for the card, kept (spec 4.77); a container, so Try again keeps its own id.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("congress.loadError")
    }
}
