import SwiftUI

struct CongressMembersDirectoryView: View {
    init(
        initialSelection: ExploreSelection = .myReps,
        initialState: String? = nil,
        initialSearchText: String = ""
    ) {
        _exploreSelection = State(initialValue: initialSelection)
        _selectedState = State(initialValue: initialState?.trimmedNonEmpty)
        _searchText = State(initialValue: initialSearchText)
    }

    @EnvironmentObject private var userStore: UserStore

    /// Always assigned through `sorted(_:)`, so it stays in roster order and filters need no re-sort.
    @State private var manifest: [CongressMemberManifestItem] = []
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?
    @State private var hasLoadedOnce: Bool = false
    @State private var searchText: String
    @State private var selectedState: String?

    enum ExploreSelection: String, CaseIterable, Identifiable {
        case myReps = "Your representatives"
        case all = "All"
        case house = "House"
        case senate = "Senate"
        case state = "State"

        var id: String { rawValue }

        /// The segment's short title.
        var title: String {
            switch self {
            case .myReps: return "Mine"
            case .all: return "All"
            case .house: return "House"
            case .senate: return "Senate"
            case .state: return "State"
            }
        }

        /// The directory view that matches a Congress tab filter ("My state" opens the state list).
        init(_ filter: CongressMemberFilter) {
            switch filter {
            case .all: self = .all
            case .house: self = .house
            case .senate: self = .senate
            case .myState: self = .state
            }
        }
    }

    @State private var exploreSelection: ExploreSelection

    private var subscribedIDs: Set<UUID> {
        Set(userStore.profile.subscribedMemberIDs)
    }

    private func isSubscribed(_ member: CongressMemberManifestItem) -> Bool {
        subscribedIDs.contains(UUID.deterministic(from: member.id))
    }

    /// A member's page. (R2's "bills by member" list was never built from here and is gone, spec 4.57.)
    private func destinationView(for member: CongressMemberManifestItem) -> some View {
        CongressMemberProfileLoaderView(manifest: member)
    }

    private var houseMembers: [CongressMemberManifestItem] {
        CongressTabModel.members(in: manifest, filter: .house, userState: "")
    }

    private var senateMembers: [CongressMemberManifestItem] {
        CongressTabModel.members(in: manifest, filter: .senate, userState: "")
    }

    private var otherMembers: [CongressMemberManifestItem] {
        manifest.filter { CongressMemberLabel.chamber(of: $0) == nil }
    }

    private var hasSearch: Bool {
        !CongressTabModel.searchTokens(searchText).isEmpty
    }

    /// Search by name, state or district, the same way as "Find a member" on the Congress tab.
    private func matching(_ members: [CongressMemberManifestItem]) -> [CongressMemberManifestItem] {
        CongressTabModel.searchResults(in: members, query: searchText, filter: .all, userState: "")
    }

    private var uniqueStates: [String] {
        let states = Set(manifest.compactMap { $0.state?.uppercasedTrimmed }.filter { !$0.isEmpty })
        return states.sorted()
    }

    private var stateMembersForDisplay: [CongressMemberManifestItem] {
        guard let state = selectedState, !state.isEmpty else { return [] }
        return matching(CongressTabModel.members(in: manifest, filter: .myState, userState: state))
    }

    private var hasSelectedState: Bool {
        !(selectedState ?? "").isEmpty
    }

    private var myRepresentatives: [CongressMemberManifestItem] {
        CongressTabModel.representatives(
            state: userStore.profile.state,
            district: userStore.profile.district,
            in: manifest
        )
    }

    static let noMatchText = CongressDirectorySection<EmptyView>.noMatchText

    /// A section of the directory (spec 4.57) for the members it shows, each row opening the member's page.
    private func directorySection(
        _ title: String,
        count: Int? = nil,
        members: [CongressMemberManifestItem],
        emptyText: String,
        emptyAction: RecordNotice.Action? = nil
    ) -> some View {
        CongressDirectorySection(
            title: title,
            count: count,
            members: members,
            emptyText: emptyText,
            emptyAction: emptyAction,
            isSubscribed: isSubscribed
        ) { member in
            destinationView(for: member)
        }
    }

    private var isInitialLoading: Bool {
        // Don't show empty-state copy based on placeholder profile/empty manifest.
        if errorMessage != nil { return false }
        if isLoading { return true }
        if !hasLoadedOnce && manifest.isEmpty { return true }
        if !userStore.hasRefreshedOnce { return true }
        return false
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BillboardStyle.Space.l) {
                // Explore selector
                VStack(alignment: .leading, spacing: BillboardStyle.Space.s) {
                    Picker("Show", selection: $exploreSelection) {
                        ForEach(ExploreSelection.allCases) { selection in
                            Text(selection.title).tag(selection)
                        }
                    }
                    .pickerStyle(.segmented)

                    if exploreSelection == .state {
                        Picker("State", selection: Binding(get: { selectedState ?? "" }, set: { selectedState = $0.isEmpty ? nil : $0 })) {
                            Text("Choose a state").tag("")
                            ForEach(uniqueStates, id: \.self) { state in
                                Text(CongressTabModel.stateName(for: state) ?? state).tag(state)
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(BillboardColors.interactive)
                    }
                }

                if isInitialLoading {
                    CongressLoadingLine(text: "Loading members…")
                } else {
                    if errorMessage != nil {
                        CongressLoadErrorCard(message: CongressLoadErrorCard.defaultMessage) {
                            Task { await loadManifest() }
                        }
                    }

                    switch exploreSelection {
                    case .myReps:
                        // The user's senators and the House member for their district.
                        if userStore.profile.state.uppercasedTrimmed.isEmpty {
                            directorySection(
                                YourRepresentativesContent.title,
                                members: [],
                                emptyText: YourRepresentativesContent.needsLocationText,
                                emptyAction: .init(title: "Add address", accessibilityIdentifier: "congress.directory.addAddress") {
                                    NotificationCenter.default.post(name: .billboardRequestLocationEditor, object: nil)
                                }
                            )
                        } else {
                            directorySection(
                                YourRepresentativesContent.title,
                                members: matching(myRepresentatives),
                                emptyText: hasSearch ? Self.noMatchText : "We couldn't find your representatives. Check your address in Profile."
                            )
                        }

                    case .all:
                        directorySection(
                            "All members",
                            // The voting seats, as every count is; the list keeps the delegates.
                            count: CongressTabModel.votingMembers(manifest).count,
                            members: matching(manifest),
                            emptyText: manifest.isEmpty ? "No members available" : Self.noMatchText
                        )

                    case .house:
                        directorySection(
                            CongressChamber.house.displayName,
                            count: CongressTabModel.votingMembers(houseMembers).count,
                            members: matching(houseMembers),
                            emptyText: houseMembers.isEmpty ? "No House members" : Self.noMatchText
                        )

                    case .senate:
                        directorySection(
                            CongressChamber.senate.displayName,
                            count: senateMembers.count,
                            members: matching(senateMembers),
                            emptyText: senateMembers.isEmpty ? "No Senate members" : Self.noMatchText
                        )

                    case .state:
                        directorySection(
                            selectedState.flatMap { CongressTabModel.stateName(for: $0) ?? $0 } ?? "State",
                            members: hasSelectedState ? stateMembersForDisplay : [],
                            emptyText: !hasSelectedState ? "Choose a state to see its members"
                                : (hasSearch ? Self.noMatchText : "No members for this state")
                        )
                    }

                    // Members whose chamber the manifest does not name.
                    if exploreSelection == .house || exploreSelection == .senate, !otherMembers.isEmpty {
                        directorySection("Other", members: matching(otherMembers), emptyText: Self.noMatchText)
                    }

                    if manifest.isEmpty && !isLoading && errorMessage == nil && exploreSelection != .all {
                        RecordNotice(.nothingYet, title: "No members available")
                    }
                }
            }
            // The 16 pt list gutter (spec 2.8).
            .padding(.horizontal, BillboardStyle.Space.l)
            .padding(.top, BillboardStyle.Space.s)
            .padding(.bottom, BillboardStyle.Space.xxl)
        }
        .billboardBackground()
        .navigationTitle("Members")
        .navigationBarTitleDisplayMode(.inline)
        .glassNavigationBar()
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Name, state or district")
        .autocorrectionDisabled(true)
        .textInputAutocapitalization(.never)
        .task { await loadManifest(forceRefresh: false) }
        .refreshable { await loadManifest(forceRefresh: true) }
    }

    private func sorted(_ items: [CongressMemberManifestItem]) -> [CongressMemberManifestItem] {
        CongressMemberManifestItem.rosterSorted(items)
    }

    private func loadManifest(forceRefresh: Bool = false) async {
        if isLoading { return }

        if !forceRefresh,
           manifest.isEmpty,
           let cachedAny = CongressService.cachedCongressMembersManifest(),
           !cachedAny.isEmpty {
            await MainActor.run { manifest = sorted(cachedAny) }

            // Only skip the network refresh if the cached manifest is still fresh.
            if let cachedFresh = CongressService.cachedCongressMembersManifest(maxAge: ManifestCachePolicy.ttl),
               !cachedFresh.isEmpty {
                await MainActor.run { hasLoadedOnce = true }
                return
            }
        }

        await MainActor.run {
            isLoading = true
            errorMessage = nil
        }

        do {
            let items = try await CongressService.getCongressMembersManifest()
            await MainActor.run {
                manifest = sorted(items)
                isLoading = false
                hasLoadedOnce = true
            }
        } catch {
            // Treat cancellations as a non-error (likely task/navigation-driven).
            if APIErrorResponse.isCancellation(error) {
#if DEBUG
                let ts = ISO8601DateFormatter().string(from: Date())
                let stack = Thread.callStackSymbols.prefix(30).joined(separator: "\n")
                print("[MembersDirectory] loadManifest cancelled at \(ts)\nStack:\n\(stack)")
#endif
                await MainActor.run {
                    isLoading = false
                }
                return
            }

            await MainActor.run {
                errorMessage = "Could not load members right now."
                isLoading = false
                hasLoadedOnce = true
            }
            #if DEBUG
            print("[MembersDirectory] loadManifest failed: \(CongressService.debugString(for: error))")
            #endif
        }
    }
}

/// One section of the Members directory (Civic Record spec 4.57), without the store so it can be rendered
/// in tests: a SectionHeader (with the member count as its counter when there is one), then the members
/// on a roll sheet (rows 3.15, "Following" on the followed ones), or a RecordNotice with R2's words when
/// there are none: NOT FOUND for a search with no matches, NOTHING YET otherwise (spec 3.20).
struct CongressDirectorySection<Destination: View>: View {
    let title: String
    var count: Int? = nil
    let members: [CongressMemberManifestItem]
    let emptyText: String
    var emptyAction: RecordNotice.Action? = nil
    let isSubscribed: (CongressMemberManifestItem) -> Bool
    @ViewBuilder let destination: (CongressMemberManifestItem) -> Destination

    static var noMatchText: String { "No matching members" }

    private var trailing: SectionHeader.Trailing {
        guard let count else { return .none }
        return .counter("\(count)", spoken: count == 1 ? "1 member" : "\(count) members")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: BillboardStyle.Space.m) {
            SectionHeader(title, trailing: trailing)

            if members.isEmpty {
                RecordNotice(emptyText == Self.noMatchText ? .notFound : .nothingYet, title: emptyText, action: emptyAction)
            } else {
                RollSheet {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        RollRows(members) { index, member in
                            NavigationLink {
                                destination(member)
                            } label: {
                                CongressMemberRow(manifest: member, isSubscribed: isSubscribed(member))
                            }
                            .accessibilityIdentifier("congress.directory.member.\(index)")
                            .buttonStyle(RowButtonStyle())
                        }
                    }
                }
            }
        }
    }
}

/// Loads full member details from the processed endpoint and falls back to manifest data on errors.
struct CongressMemberProfileLoaderView: View {
    @EnvironmentObject private var userStore: UserStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    let manifest: CongressMemberManifestItem

    @State private var member: CongressMember?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var civicProfileMode: CongressMemberCivicProfileCardMode = .unavailable

    private var isSubscribed: Bool {
        userStore.profile.subscribedMemberIDs.contains(UUID.deterministic(from: manifest.id))
    }

    var body: some View {
        Group {
            if let member {
                CongressMemberProfileView(member: member, civicProfileMode: civicProfileMode)
            } else if let errorMessage, !isLoading {
                CongressMemberLoadErrorView(
                    message: errorMessage,
                    onRetry: { Task { await load() } },
                    onUseBasicProfile: {
                        member = fallbackMember
                        civicProfileMode = civicProfileModeFor(chamber: fallbackMember.chamber)
                    }
                )
                .navigationTitle(manifest.name)
            } else {
                CongressMemberLoadingView()
                    .navigationTitle(manifest.name)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .glassNavigationBar()
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                CongressFollowToolbarButton(
                    isFollowing: isSubscribed,
                    glyphColor: DocumentToolbarGlyph.color(
                        dark: colorScheme == .dark,
                        increaseContrast: colorSchemeContrast == .increased,
                        reduceTransparency: reduceTransparency
                    )
                ) {
                    userStore.toggleMemberSubscription(manifestId: manifest.id)
                }
            }
        }
        .task(id: manifest.id) { await load() }
    }

    private var fallbackMember: CongressMember {
        let resolvedParty = PoliticalParty.from(raw: manifest.party) ?? .independent
        let resolvedChamber = manifest.chamberNormalized ?? "Member"
        let resolvedState = manifest.state ?? ""

        return CongressMember(
            id: UUID.deterministic(from: manifest.id),
            name: manifest.name,
            state: resolvedState,
            chamber: resolvedChamber,
            imageUrl: manifest.depictionImageUrl,
            currentCongressBillsSupportedCount: manifest.currentCongressBillsSupportedCount,
            trackedSponsoredCount: manifest.trackedSponsoredCount,
            trackedSupportedCount: manifest.trackedSupportedCount,
            biography: "",
            party: resolvedParty,
            district: manifest.district,
            termsServed: 0,
            serviceStartYear: Calendar.current.component(.year, from: Date())
        )
    }

    @MainActor
    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
#if DEBUG
            print("[CongressMemberProfileLoaderView] fetching processed member for manifest id=\(manifest.id)")
#endif
            let processed = try await CongressService.getProcessedCongressMember(bioguideId: manifest.id)
            let mapped = processed.toCongressMember(fallback: manifest)
            let resolvedMode: CongressMemberCivicProfileCardMode
            if supportsCivicProfile(chamber: mapped.chamber) {
                do {
                    let profile = try await CongressService.getCongressMemberCivicProfile(bioguideId: manifest.id)
                    resolvedMode = .profile(profile)
                } catch {
                    if APIErrorResponse.isCancellation(error) { throw CancellationError() }
#if DEBUG
                    print("[CongressMemberProfileLoaderView] failed to fetch civic profile for id=\(manifest.id):\n\(CongressService.debugString(for: error))")
#endif
                    resolvedMode = .unavailable
                }
            } else {
                resolvedMode = civicProfileModeFor(chamber: mapped.chamber)
            }

            member = mapped
            civicProfileMode = resolvedMode
        } catch {
            // If the task was cancelled (navigation, refresh, etc.), treat it as non-fatal
            if APIErrorResponse.isCancellation(error) {
#if DEBUG
                let ts = ISO8601DateFormatter().string(from: Date())
                let stack = Thread.callStackSymbols.prefix(30).joined(separator: "\n")
                print("[CongressMemberProfileLoaderView] load cancelled for id=\(manifest.id) at \(ts)\nStack:\n\(stack)")
#endif
                return
            }

            errorMessage = "Check your connection and try again, or use the basic profile."
            #if DEBUG
            print("[CongressMemberProfileLoaderView] failed to fetch member id=\(manifest.id):\n\(CongressService.debugString(for: error))")
            #endif
        }
    }

    private func civicProfileModeFor(chamber: String) -> CongressMemberCivicProfileCardMode {
        supportsCivicProfile(chamber: chamber) ? .loading : .unavailable
    }

    private func supportsCivicProfile(chamber: String) -> Bool {
        chamber == "House" || chamber == "Senate"
    }
}

/// The member page while it loads (spec 4.59, 3.20): the spinner in ink and "Loading member…" on the
/// document ground.
struct CongressMemberLoadingView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CongressLoadingLine(text: "Loading member…")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, BillboardStyle.Space.xl)
        .padding(.top, BillboardStyle.Space.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(BillboardColors.document.ignoresSafeArea())
    }
}

/// "Couldn't load this member" (spec 4.59): a RecordNotice with COULDN'T LOAD, the R2 message and
/// "Try again" (a secondary capsule), then the text link "Use basic profile", which shows the page from
/// the members list alone.
struct CongressMemberLoadErrorView: View {
    let message: String
    let onRetry: () -> Void
    let onUseBasicProfile: () -> Void

    static let title = "Couldn't load this member"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BillboardStyle.Space.s) {
                RecordNotice(
                    .couldNotLoad,
                    title: Self.title,
                    message: message,
                    action: .init(title: "Try again", accessibilityIdentifier: "member.loadError.retry", perform: onRetry)
                )
                MemberBasicProfileButton(action: onUseBasicProfile)
            }
            .padding(.horizontal, BillboardStyle.Space.xl)
            .padding(.top, BillboardStyle.Space.l)
            .padding(.bottom, BillboardStyle.Space.xxl)
        }
        .background(BillboardColors.document.ignoresSafeArea())
    }
}

/// Follow / Following in the member page's bar (spec 4.59): a system toolbar item, so iOS draws it as
/// a glass capsule, with `plus.circle` + "Follow" or `checkmark.circle` + "Following" in ink and a
/// selection haptic when it changes. VoiceOver reads the action it performs ("Follow" or "Unfollow");
/// Voice Control also takes the visible word. The identifier stays `member.subscription` for the UI
/// tests.
///
/// Drawn as the bill page's Watch is (`DocumentToolbarLabel`): the symbol and the word side by side, at
/// the bar's fixed size with the Large Content Viewer, in ink fixed to the page's appearance
/// (`glyphColor`), since the member page is pushed from the navy Congress root and a held swipe back
/// draws the bar in the root's dark appearance.
struct CongressFollowToolbarButton: View {
    let isFollowing: Bool
    /// `DocumentToolbarGlyph.color(...)` from the member page's environment, or nil for the system's.
    var glyphColor: Color? = nil
    let action: () -> Void

    static func title(isFollowing: Bool) -> String { isFollowing ? "Following" : "Follow" }
    static func accessibilityLabel(isFollowing: Bool) -> String { isFollowing ? "Unfollow" : "Follow" }
    static func systemImage(isFollowing: Bool) -> String { isFollowing ? "checkmark.circle" : "plus.circle" }

    var body: some View {
        Button(action: action) {
            DocumentToolbarLabel(
                title: Self.title(isFollowing: isFollowing),
                systemImage: Self.systemImage(isFollowing: isFollowing),
                glyphColor: glyphColor
            )
        }
        .sensoryFeedback(.selection, trigger: isFollowing)
        .accessibilityLabel(Self.accessibilityLabel(isFollowing: isFollowing))
        .accessibilityInputLabels([Self.title(isFollowing: isFollowing), Self.accessibilityLabel(isFollowing: isFollowing)])
        .accessibilityIdentifier("member.subscription")
        .documentToolbarLargeContent(Self.title(isFollowing: isFollowing), systemImage: Self.systemImage(isFollowing: isFollowing))
    }
}

/// A member's page, set as a document like the bill page (Civic Record spec 4.59): white in light,
/// night paper in dark, a 20 pt gutter (`CongressMemberPageContent`). The bar's inline title is the
/// member's name once the name has scrolled under it.
///
/// Not INT-11: everything here is the official record or the user's own profile.
struct CongressMemberProfileView: View {
    let member: CongressMember
    let civicProfileMode: CongressMemberCivicProfileCardMode

    /// The bottom of the front matter in the page's coordinates.
    @State private var nameBottom: CGFloat = 0

    var body: some View {
        ScrollView {
            CongressMemberPageContent(member: member, civicProfileMode: civicProfileMode) { bottom in
                nameBottom = bottom
            }
        }
        .modifier(DocumentInlineTitle(title: member.name, titleBottom: nameBottom))
        .background(BillboardColors.document.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The member page's content (spec 4.59), without the scroll view so it can be rendered in tests: the
/// front matter (the 72 pt monogram or photo with the party disc, the name in `billTitle`, the docket
/// line led by the party letter) and its double rule, then ruled sections: Basics, Bio, Service, Career
/// activity, Tracked by Billboard and the Civic Profile.
struct CongressMemberPageContent: View {
    let member: CongressMember
    let civicProfileMode: CongressMemberCivicProfileCardMode
    /// Told where the front matter ends, in the page's coordinates, for the bar's title.
    var onNameBottomChange: ((CGFloat) -> Void)? = nil

    private static let coordinateSpace = "memberPage"

    private var chamber: CongressChamber? { CongressMemberLabel.chamber(named: member.chamber) }
    private var stateForLabels: String { member.stateCode ?? member.state }

    var basicsRows: [Ledger.Row] {
        var rows: [Ledger.Row] = [
            .init("Party", member.party.displayName),
            .init("State", CongressTabModel.stateName(for: stateForLabels) ?? member.state)
        ]

        if let district = CongressMemberLabel.districtWords(state: stateForLabels, district: member.district, chamber: chamber) {
            rows.append(.init("District", district))
        }

        rows.append(.init("Chamber", member.chamberDisplayName))
        return rows.filter { !$0.answer.trimmed.isEmpty }
    }

    var serviceRows: [Ledger.Row] {
        [
            .init("Terms served", "\(member.termsServed)"),
            .init("Service start", "\(member.serviceStartYear)"),
            .init("Years in office", "\(max(0, Calendar.current.component(.year, from: Date()) - member.serviceStartYear))")
        ]
    }

    /// Career totals and Billboard's tracked counts are different measures, so each gets its own
    /// section and caption.
    static let careerCaption = "Career totals from Congress.gov."
    /// Fixed at the 119th: the server polls only the 119th Congress, so this is not computed from the date.
    static let trackedCaption = "Counts only 119th Congress bills in Billboard."

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CongressMemberFrontMatter(member: member)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.frame(in: .named(Self.coordinateSpace)).maxY
                } action: { bottom in
                    onNameBottomChange?(bottom)
                }

            DoubleRule()
                .padding(.horizontal, BillboardStyle.Space.xl)
                .padding(.top, 2)

            RecordSection("Basics", showsRule: false) {
                Ledger(rows: basicsRows)
            }
            // A container, so the controls inside keep their own ids.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("member.basics")

            if !member.biography.isEmpty {
                RecordSection("Bio") {
                    Text(member.biography)
                        .textRole(.prose)
                        .foregroundStyle(BillboardColors.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            RecordSection("Service") {
                Ledger(rows: serviceRows, answerRole: .figure)
            }

            let careerRows = member.careerActivityRows
            if !careerRows.isEmpty {
                activitySection("Career activity", rows: careerRows, caption: Self.careerCaption)
            }

            let trackedRows = member.trackedActivityRows
            if !trackedRows.isEmpty {
                activitySection("Tracked by Billboard", rows: trackedRows, caption: Self.trackedCaption)
            }

            CongressMemberCivicProfileCard(mode: civicProfileMode, memberName: member.name)
        }
        .padding(.bottom, BillboardStyle.Space.xxl)
        .coordinateSpace(name: Self.coordinateSpace)
    }

    /// A ledger of counts (figures in the docket face) with a caption saying where they come from.
    private func activitySection(_ title: String, rows: [(label: String, value: String)], caption: String) -> some View {
        RecordSection(title) {
            Ledger(rows: rows.map { Ledger.Row($0.label, $0.value) }, answerRole: .figure)
            Text(caption)
                .textRole(.caption)
                .foregroundStyle(BillboardColors.dimText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The member page's front matter (spec 4.59), centred: the 72 pt monogram (the photo when there is
/// one) with the party disc on a ring of the document, the name in `billTitle`, and the docket line led
/// by the party letter ("D · SENATE · VIRGINIA", "R · HOUSE · TEXAS 7TH DISTRICT"). One VoiceOver
/// header: "Senator Tim Kaine, Democrat, Virginia".
struct CongressMemberFrontMatter: View {
    let member: CongressMember

    private var chamber: CongressChamber? { CongressMemberLabel.chamber(named: member.chamber) }
    private var stateForLabels: String { member.stateCode ?? member.state }

    var body: some View {
        VStack(spacing: 0) {
            CongressMemberAvatar(
                url: member.imageUrl,
                name: member.name,
                size: .page,
                party: member.party,
                groundColor: BillboardColors.document
            )

            Text(member.name)
                .textRole(.billTitle)
                .foregroundStyle(BillboardColors.primaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, BillboardStyle.Space.m)

            if let affiliation = CongressMemberLabel.pageAffiliation(
                party: member.party,
                state: stateForLabels,
                district: member.district,
                chamber: chamber
            ) {
                Text(CongressMemberLabel.docketText(affiliation))
                    .textRole(.docket)
                    .foregroundStyle(BillboardColors.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, BillboardStyle.Space.xl)
        .padding(.top, BillboardStyle.Space.l)
        .padding(.bottom, BillboardStyle.Space.l)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(CongressMemberLabel.spokenDescription(
            name: member.name,
            party: member.party,
            state: stateForLabels,
            district: member.district,
            chamber: chamber
        ))
        .accessibilityAddTraits(.isHeader)
    }
}

/// "Use basic profile" under "Couldn't load this member" (spec 4.59): a text link in ink, underlined,
/// with a 44 pt hit area.
struct MemberBasicProfileButton: View {
    let action: () -> Void

    static let title = "Use basic profile"

    var body: some View {
        Button(Self.title, action: action)
            .buttonStyle(BillboardButtonStyle(kind: .textLink))
            .accessibilityIdentifier("member.useBasicProfile")
    }
}
