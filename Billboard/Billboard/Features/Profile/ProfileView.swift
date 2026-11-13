import SwiftUI

// MARK: - Section models (pure, for tests)

/// "Where you vote" (spec D 2.5.7): the district and how it was set, from the profile and the
/// server's verification status.
struct WhereYouVoteSummary: Equatable {
    enum Verification: Equatable {
        /// The status has not loaded yet.
        case checking
        /// Address-checked: "Verified".
        case verified
        /// Picked by the user: "Not verified (district chosen by you)".
        case chosenByYou
        /// The address geocoded but already has the most verified accounts allowed (C2 INT-03).
        case addressCapped
        case notVerified
        /// The status could not be loaded; only the district is shown.
        case unavailable
    }

    /// "VA-11", "AK at-large", or nil when the profile has no state.
    let locationLabel: String?
    let verification: Verification

    static let missingLocationText = "Add your address to see your district and representatives."

    static func make(
        state: String,
        district: String,
        status: DistrictVerificationStatus?,
        isLoading: Bool
    ) -> WhereYouVoteSummary {
        let label: String?
        if let code = DistrictPickerModel.stateCode(from: state) {
            label = district.trimmedNonEmpty == nil ? code : DistrictPickerModel.locationLabel(state: code, district: district)
        } else {
            label = nil
        }

        let verification: Verification
        if let status {
            verification = Self.verification(for: status)
        } else {
            verification = isLoading ? .checking : .unavailable
        }
        return WhereYouVoteSummary(locationLabel: label, verification: verification)
    }

    static func verification(for status: DistrictVerificationStatus) -> Verification {
        if status.isAddressCapped { return .addressCapped }
        if status.verified { return .verified }
        if status.method == DistrictVerificationStatus.methodManualStateDistrict || status.status == "self_attested" {
            return .chosenByYou
        }
        return .notVerified
    }

    /// The status after the district, or nil when there is nothing to add.
    var statusText: String? {
        switch verification {
        case .checking: return "Checking…"
        case .verified: return "Verified"
        case .chosenByYou: return "Not verified (district chosen by you)"
        case .addressCapped, .notVerified: return "Not verified"
        case .unavailable: return nil
        }
    }

    /// "VA-11 · Verified", "VA-11 · Not verified (district chosen by you)".
    var line: String {
        guard let locationLabel else { return Self.missingLocationText }
        guard let statusText else { return locationLabel }
        return "\(locationLabel) · \(statusText)"
    }

    /// The address-cap explanation (the same words as the setup screen's success panel).
    var note: String? {
        verification == .addressCapped && locationLabel != nil ? LocationEditorView.addressCappedMessage : nil
    }

    var isVerified: Bool { verification == .verified }

    /// The stamp beside the district (Civic Record spec 4.61): VERIFIED in ink, or NOT VERIFIED in ink 3;
    /// none while the status loads or when it could not be read.
    var stamp: StatusStamp.Kind? {
        switch verification {
        case .verified: return .verified
        case .chosenByYou, .addressCapped, .notVerified: return .notVerified
        case .checking, .unavailable: return nil
        }
    }

    /// The line beside or under the stamp: "District chosen by you", "Checking…"; nil otherwise.
    var stampNote: String? {
        switch verification {
        case .chosenByYou: return "District chosen by you"
        case .checking: return "Checking…"
        case .verified, .addressCapped, .notVerified, .unavailable: return nil
        }
    }

    /// What VoiceOver reads for the section's content: "Virginia's 11th district, Verified", "Virginia's
    /// 11th district, Not verified, District chosen by you", or the missing-location line.
    var accessibilityText: String {
        guard let locationLabel else { return Self.missingLocationText }
        // "WY at-large" is "Wyoming's at-large district", as the member rows say a seat.
        return [SpokenForm.districtOrCode(locationLabel), stamp?.spokenWord, stampNote].compactMap { $0 }.joined(separator: ", ")
    }
}

/// "Topics you follow": topics (current names, LLM-10) and life areas as chips.
struct FollowedTopicsSummary: Equatable {
    struct Chip: Equatable, Identifiable {
        enum Kind: Equatable {
            case topic
            case lifeArea
        }

        let title: String
        let kind: Kind
        var id: String { "\(kind == .topic ? "topic" : "lifeArea").\(title)" }
    }

    static let emptyText = "You don't follow any topics yet."
    /// Chips shown before "and N more", so a long list does not push the rest of Profile away.
    static let chipLimit = 12

    let topics: [String]
    let lifeAreas: [String]

    init(topics: [String], lifeAreas: [String]) {
        self.topics = topics
        self.lifeAreas = lifeAreas
    }

    init(profile: UserProfile) {
        topics = Array(Set(SubscriptionsConfig.canonicalTopics(profile.subscribedSubCategories)))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        lifeAreas = Array(Set(profile.subscribedLifeAreas.compactMap(\.trimmedNonEmpty)))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    var isEmpty: Bool { topics.isEmpty && lifeAreas.isEmpty }

    var allChips: [Chip] {
        topics.map { Chip(title: $0, kind: .topic) } + lifeAreas.map { Chip(title: $0, kind: .lifeArea) }
    }

    var visibleChips: [Chip] { Array(allChips.prefix(Self.chipLimit)) }

    var hiddenCount: Int { max(0, allChips.count - Self.chipLimit) }

    /// The topics shown in the TOPICS row (spec 4.61), within the shared cap.
    var visibleTopics: [String] { visibleChips.filter { $0.kind == .topic }.map(\.title) }

    /// The life areas shown in the LIFE AREAS row, within the shared cap (topics come first).
    var visibleLifeAreas: [String] { visibleChips.filter { $0.kind == .lifeArea }.map(\.title) }

    /// The line after a row's tags when the cap hid some of them: "and 3 more"; when it hid them all,
    /// how many there are ("4 life areas"). Nil when nothing is hidden.
    static func moreText(shown: Int, total: Int, singular: String, plural: String) -> String? {
        let hidden = total - shown
        guard hidden > 0 else { return nil }
        if shown == 0 { return total == 1 ? "1 \(singular)" : "\(total) \(plural)" }
        return "and \(hidden) more"
    }

    /// What VoiceOver reads for the section: "You follow 3 topics and 1 life area. Topics: Healthcare, Housing,
    /// Taxation. Life areas: Housing." Each list says what kind it is, as the rows' labels and glyphs do.
    var accessibilityText: String {
        var parts = ["You follow \(countText)."]
        if !topics.isEmpty { parts.append("Topics: \(topics.joined(separator: ", ")).") }
        if !lifeAreas.isEmpty { parts.append("Life areas: \(lifeAreas.joined(separator: ", ")).") }
        return parts.joined(separator: " ")
    }

    /// "3 topics and 2 life areas", for VoiceOver and the header.
    var countText: String {
        let topicText = topics.count == 1 ? "1 topic" : "\(topics.count) topics"
        guard !lifeAreas.isEmpty else { return topicText }
        let areaText = lifeAreas.count == 1 ? "1 life area" : "\(lifeAreas.count) life areas"
        return topics.isEmpty ? areaText : "\(topicText) and \(areaText)"
    }
}

/// "Members you follow": how many, and the first few by name.
struct FollowedMembersSummary: Equatable {
    static let previewLimit = 3
    static let emptyText = "You don't follow any members yet."

    let count: Int
    /// The first members in roster order, from the members manifest (empty until it loads).
    let preview: [CongressMemberManifestItem]

    static func make(subscribedIDs: [UUID], manifest: [CongressMemberManifestItem]) -> FollowedMembersSummary {
        let followed = Set(subscribedIDs)
        let matches = manifest.filter { followed.contains(UUID.deterministic(from: $0.id)) }
        let sorted = CongressMemberManifestItem.rosterSorted(matches)
        return FollowedMembersSummary(count: followed.count, preview: Array(sorted.prefix(previewLimit)))
    }

    /// "You follow 1 member." / "You follow 5 members."
    var countText: String {
        guard count > 0 else { return Self.emptyText }
        return count == 1 ? "You follow 1 member." : "You follow \(count) members."
    }

    /// Followed members not listed in the preview.
    var remainingCount: Int { max(0, count - preview.count) }
}

// MARK: - Section head

/// The head of a Profile section whose trailing item is not a counter or a text button (Civic Record spec
/// 3.5): the 2 pt ink rule, 8 pt, the title in the `heading` role and, on the same baseline, the trailing
/// view (the Civic Profile's info button). At accessibility sizes the trailing view
/// goes under the title. The other sections use `SectionHeader`.
struct ProfileSectionHead<Trailing: View>: View {
    let title: String
    @ViewBuilder let trailing: Trailing

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(_ title: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: BillboardStyle.Space.s) {
            HeavyRule(width: 2)
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: BillboardStyle.Space.xs) {
                    titleText
                    trailing
                }
            } else {
                HStack(alignment: .center, spacing: 10) {
                    titleText
                    Spacer(minLength: 0)
                    trailing
                }
            }
        }
    }

    private var titleText: some View {
        Text(title)
            .textRole(.heading)
            .foregroundStyle(BillboardColors.primaryText)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The space between a section's head and its content on Profile.
enum ProfileLayout {
    /// Under a section head.
    static let headToContent: CGFloat = BillboardStyle.Space.m
    /// Between sections (spec 2.8: tab-root sections are 28 pt apart).
    static let sectionGap: CGFloat = BillboardStyle.Space.xxl
}

// MARK: - Section content (drawn from plain values, for render tests)

/// "Where you vote" (spec 4.61): the district in the figure face with its VERIFIED or NOT VERIFIED stamp, on
/// paper under a section head with "Change" (or "Add"). An address over the cap adds its notice.
struct WhereYouVoteContent: View {
    let summary: WhereYouVoteSummary
    let onChange: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: ProfileLayout.headToContent) {
            SectionHeader(
                "Where you vote",
                trailing: .button(
                    summary.locationLabel == nil ? "Add" : "Change",
                    accessibilityLabel: summary.locationLabel == nil ? "Add where you vote" : "Change where you vote",
                    accessibilityIdentifier: "profile.location.change",
                    action: onChange
                )
            )

            VStack(alignment: .leading, spacing: BillboardStyle.Space.s) {
                district
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(summary.accessibilityText)
                    .accessibilityIdentifier("profile.location")

                if let note = summary.note {
                    RecordNoticeText(note)
                        .accessibilityIdentifier("profile.location.capped")
                }
            }
        }
    }

    @ViewBuilder
    private var district: some View {
        if let label = summary.locationLabel {
            // On one line while it fits, else the stamp and its note under the district.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 10) {
                    districtParts(label)
                }
                VStack(alignment: .leading, spacing: BillboardStyle.Space.s) {
                    districtParts(label)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(WhereYouVoteSummary.missingLocationText)
                .textRole(.body)
                .foregroundStyle(BillboardColors.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// "VA-11" in the figure face, the stamp, and "District chosen by you" or "Checking…".
    @ViewBuilder
    private func districtParts(_ label: String) -> some View {
        Text(label)
            .textRole(.figureLarge)
            .foregroundStyle(BillboardColors.primaryText)
            .fixedSize()
        if let stamp = summary.stamp {
            StatusStamp(stamp)
                .fixedSize()
        }
        if let note = summary.stampNote {
            Text(note)
                .textRole(.caption)
                .foregroundStyle(BillboardColors.dimText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// "Topics you follow" (spec 4.61): two ledger rows, TOPICS and LIFE AREAS, each holding index tags, so the
/// topic "Housing" and the life area "Housing" sit in different labelled rows with different glyphs and
/// spoken prefixes. Up to 12 tags, then "and 3 more".
struct FollowedTopicsContent: View {
    let summary: FollowedTopicsSummary
    let onEdit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: ProfileLayout.headToContent) {
            SectionHeader(
                "Topics you follow",
                trailing: .button(
                    "Edit",
                    accessibilityLabel: "Edit topics you follow",
                    accessibilityIdentifier: "profile.topics.edit",
                    action: onEdit
                )
            )

            if summary.isEmpty {
                Text(FollowedTopicsSummary.emptyText)
                    .textRole(.body)
                    .foregroundStyle(BillboardColors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("profile.topics.empty")
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    if !summary.topics.isEmpty {
                        row(
                            label: "Topics",
                            tags: summary.visibleTopics.map { IndexTag(.topic($0)) },
                            more: FollowedTopicsSummary.moreText(
                                shown: summary.visibleTopics.count,
                                total: summary.topics.count,
                                singular: "topic",
                                plural: "topics"
                            )
                        )
                        .padding(.bottom, 10)
                    }
                    if !summary.topics.isEmpty, !summary.lifeAreas.isEmpty {
                        DottedRule()
                    }
                    if !summary.lifeAreas.isEmpty {
                        row(
                            label: "Life areas",
                            tags: summary.visibleLifeAreas.map { IndexTag(.lifeArea($0)) },
                            more: FollowedTopicsSummary.moreText(
                                shown: summary.visibleLifeAreas.count,
                                total: summary.lifeAreas.count,
                                singular: "life area",
                                plural: "life areas"
                            )
                        )
                        .padding(.top, summary.topics.isEmpty ? 0 : 10)
                    }
                }
                // One element: what is followed, by kind and name (the UI tests read this label).
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(summary.accessibilityText)
                .accessibilityIdentifier("profile.topics")
            }
        }
    }

    private func row(label: String, tags: [IndexTag], more: String?) -> some View {
        LedgerRow(label: label, column: .topics) {
            FlowLayout(spacing: 6) {
                ForEach(Array(tags.enumerated()), id: \.offset) { _, tag in
                    tag
                }
            }
            if let more {
                Text(more)
                    .textRole(.caption)
                    .foregroundStyle(BillboardColors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
        }
    }
}

/// "Members you follow" (spec 4.61): the count in the head's counter, the first three members as roll-sheet
/// rows (the monogram with the party disc, the affiliation led by the party letter, "R · House · VA-1"), and
/// the text link "Manage in Congress".
struct FollowedMembersContent: View {
    let summary: FollowedMembersSummary
    let onManage: () -> Void

    /// Manage in Congress: the tab shell opens the Congress tab on its root, Members you follow
    /// (`TabsBar` pops a Congress screen left open there).
    static func requestManageInCongress(center: NotificationCenter = .default) {
        center.post(name: .billboardRequestCongressFollows, object: nil)
    }

    private var header: SectionHeader {
        guard summary.count > 0 else { return SectionHeader("Members you follow") }
        return SectionHeader(
            "Members you follow",
            trailing: .counter("\(summary.count)", spoken: summary.count == 1 ? "1 member" : "\(summary.count) members")
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ProfileLayout.headToContent) {
            header

            if summary.count == 0 {
                Text(summary.countText)
                    .textRole(.body)
                    .foregroundStyle(BillboardColors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("profile.members.count")
            } else if summary.preview.isEmpty {
                // The members list has not loaded: the count alone.
                Text(summary.countText)
                    .textRole(.body)
                    .foregroundStyle(BillboardColors.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("profile.members.count")
            } else {
                RollSheet {
                    RollRows(summary.preview) { _, member in
                        row(member)
                    }
                }

                if summary.remainingCount > 0 {
                    Text("and \(summary.remainingCount) more")
                        .textRole(.caption)
                        .foregroundStyle(BillboardColors.secondaryText)
                }
            }

            Button("Manage in Congress", action: onManage)
                .buttonStyle(BillboardButtonStyle(kind: .textLink))
                .accessibilityHint("Opens the Congress tab")
                .accessibilityIdentifier("profile.members.manage")
        }
    }

    private func row(_ member: CongressMemberManifestItem) -> some View {
        let party = CongressMemberLabel.party(of: member)
        let chamber = CongressMemberLabel.chamber(of: member)
        return MemberRollRow(
            name: member.name,
            party: party,
            affiliation: CongressMemberLabel.affiliation(party: party, state: member.state, district: member.district, chamber: chamber),
            photoURL: member.depictionImageUrl,
            monogramSize: .row,
            trailing: .none,
            accessibilityLabel: CongressMemberLabel.spokenDescription(
                name: member.name,
                party: party,
                state: member.state,
                district: member.district,
                chamber: chamber
            )
        )
    }
}

/// The top of Profile (spec 4.60): the user's monogram (initials from the display name, no party disc), the
/// name and email, and the ink gear that opens Settings. At accessibility sizes the monogram and the gear
/// share the first line and the name and email take the full width under them.
struct ProfileHeader: View {
    let displayName: String
    let email: String

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .title3) private var gearSize: CGFloat = 20

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: BillboardStyle.Space.s) {
                HStack(alignment: .center, spacing: BillboardStyle.Space.m) {
                    MemberMonogram(name: displayName, size: .profile, groundColor: BillboardColors.background)
                    Spacer(minLength: 0)
                    settingsLink
                }
                identity
            }
        } else {
            HStack(alignment: .center, spacing: BillboardStyle.Space.m) {
                MemberMonogram(name: displayName, size: .profile, groundColor: BillboardColors.background)
                identity
                Spacer(minLength: 0)
                settingsLink
            }
        }
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(displayName)
                .textRole(.name)
                .foregroundStyle(BillboardColors.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            if !email.isEmpty {
                EmailText(email)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: dynamicTypeSize.isAccessibilitySize)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var settingsLink: some View {
        NavigationLink {
            ProfileSettingsMenuView()
        } label: {
            Image(systemName: "gearshape")
                .font(TextRole.Face.text.font(size: gearSize, weight: .semibold))
                .foregroundStyle(BillboardColors.interactive)
                .billboardMinimumHitTarget()
                .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
        .accessibilityLabel("Settings")
        .accessibilityInputLabels(["Settings"])
        .accessibilityIdentifier("profile.settings")
    }
}

/// The user's email in the `body` role, `ink2`, for the Profile and Settings headers (spec 4.60, 4.68). An address
/// has no place to break a line, so a long one broke between any two letters ("alex.morgan@example.co", then
/// "m"); a zero-width space before the "@" and before each dot of the domain lets it wrap there instead.
/// VoiceOver reads the address as written.
struct EmailText: View {
    let email: String

    init(_ email: String) {
        self.email = email
    }

    var body: some View {
        Text(Self.wrappable(email))
            .textRole(.body)
            .foregroundStyle(BillboardColors.secondaryText)
            .accessibilityLabel(email)
    }

    /// `email` with a zero-width space before its "@" and before each dot after it; unchanged without an "@".
    static func wrappable(_ email: String) -> String {
        guard let at = email.lastIndex(of: "@") else { return email }
        let breakOpportunity = "\u{200B}"
        let local = String(email[..<at])
        let domain = String(email[email.index(after: at)...]).replacingOccurrences(of: ".", with: breakOpportunity + ".")
        return local + breakOpportunity + "@" + domain
    }
}

// MARK: - Profile

/// The Profile tab (spec D 2.5.7), top to bottom: header and Settings; Where you vote (Change opens
/// the location editor); Topics you follow (Edit opens the topic picker); Members you follow;
/// Notifications; the civic profile chart. Every row is edited in place, with the same endpoints R1's
/// Personal Info and Subscriptions screens used. Your votes by topic is gone (UX-39 N11): it counted
/// only the bills loaded on the device, and the server sends no counts by topic.
struct ProfileView: View {
    let isActive: Bool

    private enum Sheet: String, Identifiable {
        case location
        case topics

        var id: String { rawValue }
    }

    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var userStore: UserStore
    @EnvironmentObject private var civicProfileStore: CivicProfileStore
    @EnvironmentObject private var civicScoreStore: CivicScoreStore
    @EnvironmentObject private var congressManifestStore: CongressMembersManifestStore
    @StateObject private var notificationSettingsStore = NotificationSettingsStore()
    @State private var districtVerificationStatus: DistrictVerificationStatus?
    @State private var isLoadingDistrictVerification = false
    @State private var activeSheet: Sheet?

    @State private var hasFinishedFirstVerificationLoad = false

    /// "Checking…" until the first status read finishes (UI-test launches skip that read).
    private var isCheckingVerification: Bool {
        if isLoadingDistrictVerification { return true }
        guard !hasFinishedFirstVerificationLoad, userStore.profile.id.trimmedNonEmpty != nil else { return false }
        return !AppLaunchOptions.shouldStreamlineStartupForUITests
    }

    private var whereYouVote: WhereYouVoteSummary {
        WhereYouVoteSummary.make(
            state: userStore.profile.state,
            district: userStore.profile.district,
            status: districtVerificationStatus,
            isLoading: isCheckingVerification
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // The page title on paper under the compact masthead (spec 3.21); Profile has no deck.
                PageTitle(title: "Profile")

                ProfileHeader(
                    displayName: userStore.profile.displayName,
                    email: userStore.profile.email
                )
                .padding(.top, BillboardStyle.Space.m)

                // Sections in order (spec 4.60), each under a section head on paper: no cards.
                VStack(alignment: .leading, spacing: ProfileLayout.sectionGap) {
                    WhereYouVoteContent(summary: whereYouVote) {
                        activeSheet = .location
                    }

                    FollowedTopicsContent(summary: FollowedTopicsSummary(profile: userStore.profile)) {
                        activeSheet = .topics
                    }

                    FollowedMembersContent(
                        summary: FollowedMembersSummary.make(
                            subscribedIDs: userStore.profile.subscribedMemberIDs,
                            manifest: congressManifestStore.items
                        ),
                        onManage: openCongressTab
                    )

                    NotificationsSection(store: notificationSettingsStore)

                    CivicProfileCard(
                        profile: civicProfileStore.profile,
                        isLoading: civicProfileStore.isLoading,
                        phase: civicProfileStore.phase,
                        onRetry: { Task { await civicProfileStore.refresh() } }
                    )
                }
                .padding(.top, ProfileLayout.sectionGap)
            }
            // The 16 pt list gutter; the page title sets the space under the masthead, and the safe area
            // from the tab capsule clears the last row (spec 4.9).
            .padding(.horizontal, BillboardStyle.Space.l)
            .padding(.bottom, BillboardStyle.Space.xxl)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .billboardBackground()
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            // The masthead chips' score and streak too (UX-39 N11).
            await civicScoreStore.refresh()
            await refreshProfileData()
            await notificationSettingsStore.load()
        }
        .task(id: isActive) {
            guard isActive else { return }
            await refreshProfileDataIfNeededForCurrentLaunch()
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard isActive, newPhase == .active else { return }
            Task { await refreshProfileDataIfNeededForCurrentLaunch() }
        }
        .onChange(of: userStore.profile.id) { _, _ in
            districtVerificationStatus = nil
            hasFinishedFirstVerificationLoad = false
            Task { await loadDistrictVerificationStatus() }
        }
        .sheet(item: $activeSheet) { sheet in
            sheetContent(sheet)
                .withoutTabCapsuleClearance()
        }
        .accessibilityIdentifier("profile.screen")
    }

    @ViewBuilder
    private func sheetContent(_ sheet: Sheet) -> some View {
        switch sheet {
        case .location:
            NavigationStack {
                LocationEditorView(
                    context: .profile,
                    onSaved: { result in
                        // Show the new status at once; Done re-reads it from the server.
                        districtVerificationStatus = result.verification
                    },
                    onDone: { _ in
                        activeSheet = nil
                        Task { await loadDistrictVerificationStatus() }
                    }
                )
                .glassNavigationBar()
            }
            .presentationBackground(BillboardColors.background)
            .environmentObject(userStore)
        case .topics:
            NavigationStack {
                TopicPickerView(context: .profile) {
                    activeSheet = nil
                }
                .glassNavigationBar()
            }
            .presentationBackground(BillboardColors.background)
            .environmentObject(userStore)
        }
    }

    // MARK: - Actions

    private func openCongressTab() {
        FollowedMembersContent.requestManageInCongress()
    }

    @MainActor
    private func loadDistrictVerificationStatus() async {
        guard userStore.profile.id.trimmedNonEmpty != nil else { return }
        isLoadingDistrictVerification = true
        defer {
            isLoadingDistrictVerification = false
            hasFinishedFirstVerificationLoad = true
        }

        do {
            districtVerificationStatus = try await DistrictVerificationService.fetchStatus()
        } catch {
            #if DEBUG
            print("[ProfileView] Failed to fetch district verification status: \(error.localizedDescription)")
            #endif
        }
    }

    @MainActor
    private func refreshProfileData() async {
        await civicProfileStore.refresh()
        await loadDistrictVerificationStatus()
    }

    @MainActor
    private func refreshProfileDataIfNeededForCurrentLaunch() async {
        guard !AppLaunchOptions.shouldStreamlineStartupForUITests else { return }
        await refreshProfileData()
    }
}
