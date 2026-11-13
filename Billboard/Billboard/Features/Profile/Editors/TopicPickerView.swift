import SwiftUI

/// What the topic picker shows and saves (spec D 2.5.6, 2.5.7). Pure, for `TopicPickerModelTests`.
///
/// Topics are grouped under the 7 topic groups and always carry current names (LLM-10): a legacy
/// name from a bill or a cached profile is mapped through `SubscriptionsConfig.canonicalTopic`, so
/// a save never sends one.
struct TopicPickerModel: Equatable {
    struct TopicGroup: Equatable, Identifiable {
        let name: String
        let topics: [String]
        var id: String { name }
    }

    /// The topic groups in their usual order, each with its topics.
    static let groups: [TopicGroup] = SubscriptionsConfig.allCategories.map { name in
        TopicGroup(name: name, topics: SubscriptionsConfig.subcategoryGroups[name] ?? [])
    }

    static let lifeAreas: [String] = SubscriptionsConfig.allLifeAreas

    private static let knownTopics = Set(SubscriptionsConfig.allSubcategories)

    private(set) var selectedTopics: Set<String>
    private(set) var selectedLifeAreas: Set<String>
    /// Topic groups whose topics are showing.
    private(set) var expandedGroups: Set<String>
    private let initialTopics: Set<String>
    private let initialLifeAreas: Set<String>

    init(selectedTopics: Set<String>, selectedLifeAreas: Set<String>, expandedGroups: Set<String>) {
        self.selectedTopics = selectedTopics
        self.selectedLifeAreas = selectedLifeAreas
        self.expandedGroups = expandedGroups
        self.initialTopics = selectedTopics
        self.initialLifeAreas = selectedLifeAreas
    }

    /// After the first vote: the voted bill's topic and life areas selected, its topic group open,
    /// the other groups closed.
    static func firstVote(seedBill: Bill?) -> TopicPickerModel {
        var topics = Set<String>()
        var expanded = Set<String>()

        if let seedBill {
            if let topic = seedBill.subCategory.trimmedNonEmpty.map(SubscriptionsConfig.canonicalTopic),
               knownTopics.contains(topic) {
                topics.insert(topic)
                if let group = group(ofTopic: topic) {
                    expanded.insert(group)
                }
            }
            // A bill without a known topic still opens its group when it has one.
            if expanded.isEmpty, let group = groups.first(where: { $0.name == seedBill.category.trimmed })?.name {
                expanded.insert(group)
            }
        }

        let areas = Set((seedBill?.lifeAreas ?? []).compactMap { canonicalLifeArea($0) })
        return TopicPickerModel(selectedTopics: topics, selectedLifeAreas: areas, expandedGroups: expanded)
    }

    /// From Profile: what the profile follows (current names), with the groups that hold a followed
    /// topic open. A followed value the picker does not list is kept as is, so saving never drops it.
    static func profile(_ profile: UserProfile) -> TopicPickerModel {
        let topics = Set(SubscriptionsConfig.canonicalTopics(profile.subscribedSubCategories))
        let expanded = Set(topics.compactMap { group(ofTopic: $0) })
        let areas = Set(profile.subscribedLifeAreas.map { canonicalLifeArea($0) ?? $0 })
        return TopicPickerModel(selectedTopics: topics, selectedLifeAreas: areas, expandedGroups: expanded)
    }

    /// The topic group a topic belongs to, or nil for an unknown topic.
    static func group(ofTopic topic: String) -> String? {
        let current = SubscriptionsConfig.canonicalTopic(topic)
        return groups.first { $0.topics.contains(current) }?.name
    }

    /// The listed life area matching `name` (ignoring case and surrounding spaces), or nil.
    static func canonicalLifeArea(_ name: String) -> String? {
        let key = name.trimmed.lowercased()
        guard !key.isEmpty else { return nil }
        return lifeAreas.first { $0.lowercased() == key }
    }

    func isSelected(topic: String) -> Bool {
        selectedTopics.contains(topic)
    }

    func isSelected(lifeArea: String) -> Bool {
        selectedLifeAreas.contains(lifeArea)
    }

    func isExpanded(_ group: TopicGroup) -> Bool {
        expandedGroups.contains(group.name)
    }

    func selectedCount(in group: TopicGroup) -> Int {
        group.topics.filter(selectedTopics.contains).count
    }

    mutating func toggle(topic: String) {
        let current = SubscriptionsConfig.canonicalTopic(topic)
        if selectedTopics.contains(current) {
            selectedTopics.remove(current)
        } else {
            selectedTopics.insert(current)
        }
    }

    mutating func toggle(lifeArea: String) {
        if selectedLifeAreas.contains(lifeArea) {
            selectedLifeAreas.remove(lifeArea)
        } else {
            selectedLifeAreas.insert(lifeArea)
        }
    }

    mutating func toggleExpansion(of group: TopicGroup) {
        if expandedGroups.contains(group.name) {
            expandedGroups.remove(group.name)
        } else {
            expandedGroups.insert(group.name)
        }
    }

    /// The topics to save: listed ones in picker order, then any unlisted ones the profile had.
    var topicsToSave: [String] {
        let listed = Self.groups.flatMap(\.topics).filter(selectedTopics.contains)
        let unlisted = selectedTopics.subtracting(Self.knownTopics)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return SubscriptionsConfig.canonicalTopics(listed + unlisted)
    }

    /// The life areas to save: listed ones in picker order, then any unlisted ones the profile had.
    var lifeAreasToSave: [String] {
        let listed = Self.lifeAreas.filter(selectedLifeAreas.contains)
        let unlisted = selectedLifeAreas.subtracting(Self.lifeAreas)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return listed + unlisted
    }

    var hasSelection: Bool {
        !selectedTopics.isEmpty || !selectedLifeAreas.isEmpty
    }

    var hasChanges: Bool {
        selectedTopics != initialTopics || selectedLifeAreas != initialLifeAreas
    }
}

/// Choose topics and life areas to follow (spec D 4.1, shared editor). In `.firstVote` it is
/// "Want more bills like this?"; in `.profile` it edits what Profile follows. Neither asks for a party any
/// more (UX-36). Hosts wrap it in a `NavigationStack` and dismiss it in `onDone`.
struct TopicPickerView: View {
    enum Context {
        /// After the first saved vote, seeded from the voted bill.
        case firstVote(seedBill: Bill?)
        /// Profile's Edit, and the starter banner's "Choose topics".
        case profile
    }

    let context: Context
    /// Called after a successful save, Not now (first vote) or Cancel (Profile).
    let onDone: () -> Void

    @EnvironmentObject private var userStore: UserStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var model: TopicPickerModel?
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(context: Context, onDone: @escaping () -> Void) {
        self.context = context
        self.onDone = onDone
    }

    private var isFirstVote: Bool {
        if case .firstVote = context { return true }
        return false
    }

    /// The edited model, or the seeded one before the first edit (so the first render is complete).
    private var currentModel: TopicPickerModel {
        model ?? seededModel()
    }

    private func seededModel() -> TopicPickerModel {
        switch context {
        case .firstVote(let seedBill):
            return .firstVote(seedBill: seedBill)
        case .profile:
            return .profile(userStore.profile)
        }
    }

    private func updateModel(_ change: (inout TopicPickerModel) -> Void) {
        var updated = currentModel
        change(&updated)
        model = updated
    }

    /// Under the first-vote prompt's Save while it is disabled (spec 3.16; the project's "name what is missing,
    /// then 'to continue'" pattern): nothing is chosen, so there is nothing to save.
    static let firstVoteSaveHint = "Choose a topic or life area to continue."

    private var canSave: Bool {
        let model = currentModel
        guard !isSaving else { return false }
        return isFirstVote ? model.hasSelection : model.hasChanges
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BillboardStyle.Space.xxl) {
                header
                topicsSection(currentModel)
                lifeAreasSection(currentModel)

                if let errorMessage {
                    RecordErrorText(errorMessage)
                        .accessibilityIdentifier("topicPicker.error")
                }
            }
            .padding(.horizontal, BillboardStyle.Space.xl)
            .padding(.top, BillboardStyle.Space.l)
            .padding(.bottom, BillboardStyle.Space.xxl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .billboardBackground()
        .navigationTitle(isFirstVote ? "" : "Topics you follow")
        .navigationBarTitleDisplayMode(.inline)
        // The first-vote prompt has its own title and its buttons at the bottom.
        .toolbar(isFirstVote ? .hidden : .automatic, for: .navigationBar)
        .toolbar {
            if !isFirstVote {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onDone() }
                        .disabled(isSaving)
                        .accessibilityIdentifier("topicPicker.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(!canSave)
                        .accessibilityIdentifier("topicPicker.save")
                }
            }
        }
        .modifier(FirstVoteActionsBar(isShown: isFirstVote) { firstVoteActions })
        .interactiveDismissDisabled(isSaving)
        .onAppear(perform: seedIfNeeded)
    }

    // MARK: - Sections

    @ViewBuilder
    private var header: some View {
        if isFirstVote {
            VStack(alignment: .leading, spacing: BillboardStyle.Space.s) {
                Text("Want more bills like this?")
                    .textRole(.title)
                    .foregroundStyle(BillboardColors.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)

                Text("Follow topics and we'll put matching bills on your Bills tab. You can change this anytime in Profile.")
                    .textRole(.body)
                    .foregroundStyle(BillboardColors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Clear of the sheet's drag indicator.
            .padding(.top, BillboardStyle.Space.m)
        } else {
            Text("Bills on these topics and life areas show up on your Bills tab.")
                .textRole(.body)
                .foregroundStyle(BillboardColors.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The topic groups (spec 3.18): each a ruled group, a hairline then its head (the name, "2 selected" and
    /// a chevron that turns when open), then its topics as selectable tags.
    private func topicsSection(_ model: TopicPickerModel) -> some View {
        VStack(alignment: .leading, spacing: BillboardStyle.Space.s) {
            SectionHeader("Topics")

            VStack(alignment: .leading, spacing: 0) {
                ForEach(TopicPickerModel.groups) { group in
                    HairlineRule()
                    VStack(alignment: .leading, spacing: BillboardStyle.Space.s) {
                        TopicGroupHeader(
                            name: group.name,
                            selectedCount: model.selectedCount(in: group),
                            isExpanded: model.isExpanded(group)
                        ) {
                            withAnimation(TopicGroupChevron.animation(reduceMotion: reduceMotion)) {
                                updateModel { $0.toggleExpansion(of: group) }
                            }
                        }

                        if model.isExpanded(group) {
                            FlowLayout(spacing: BillboardStyle.Space.s) {
                                ForEach(group.topics, id: \.self) { topic in
                                    SelectableTag(title: topic, isSelected: model.isSelected(topic: topic)) {
                                        updateModel { $0.toggle(topic: topic) }
                                    }
                                    .accessibilityIdentifier("topicPicker.topic.\(topic)")
                                }
                            }
                            .padding(.bottom, BillboardStyle.Space.m)
                        }
                    }
                }
                HairlineRule()
            }
        }
    }

    private func lifeAreasSection(_ model: TopicPickerModel) -> some View {
        VStack(alignment: .leading, spacing: BillboardStyle.Space.m) {
            SectionHeader("Life areas")

            FlowLayout(spacing: BillboardStyle.Space.s) {
                ForEach(TopicPickerModel.lifeAreas, id: \.self) { lifeArea in
                    SelectableTag(title: lifeArea, isSelected: model.isSelected(lifeArea: lifeArea)) {
                        updateModel { $0.toggle(lifeArea: lifeArea) }
                    }
                    .accessibilityIdentifier("topicPicker.lifeArea.\(lifeArea)")
                }
            }
        }
    }

    /// Save and Not now at the bottom of the first-vote prompt (spec 4.67), on paper.
    private var firstVoteActions: some View {
        VStack(spacing: BillboardStyle.Space.xs) {
            BBActionButton(
                title: "Save",
                action: { Task { await save() } },
                loadingTitle: "Saving…",
                isEnabled: canSave,
                isLoading: isSaving,
                disabledHint: Self.firstVoteSaveHint
            )
            .accessibilityIdentifier("topicPicker.save")

            Button("Not now") {
                onDone()
            }
            .buttonStyle(BillboardButtonStyle(kind: .textButton))
            .disabled(isSaving)
            .accessibilityIdentifier("topicPicker.notNow")
        }
        .padding(.horizontal, BillboardStyle.Space.xl)
        .padding(.top, BillboardStyle.Space.m)
        .padding(.bottom, BillboardStyle.Space.xs)
        .frame(maxWidth: .infinity)
        .background(BillboardColors.background.ignoresSafeArea(edges: .bottom))
    }

    // MARK: - Actions

    private func seedIfNeeded() {
        guard model == nil else { return }
        model = seededModel()
    }

    private func save() async {
        guard canSave else { return }
        let model = currentModel
        errorMessage = nil
        isSaving = true
        defer { isSaving = false }

        do {
            switch context {
            case .firstVote:
                try await userStore.setInitialPreferences(
                    subCategories: model.topicsToSave,
                    lifeAreas: model.lifeAreasToSave
                )
            case .profile:
                try await userStore.updateFollowedTopics(
                    topics: model.topicsToSave,
                    lifeAreas: model.lifeAreasToSave
                )
            }
            onDone()
        } catch {
            let message = AuthErrorMessages.message(for: error, context: .general)
            errorMessage = message == AuthErrorMessages.generic
                ? "Couldn't save your topics. Try again."
                : message
        }
    }
}

/// A topic group's head (spec 3.18): the name in the `name` role, "2 selected" in the docket face (`ink3`)
/// and a `chevron.down` that turns over when the group is open (`TopicGroupChevron`); 44 pt to tap.
private struct TopicGroupHeader: View {
    let name: String
    let selectedCount: Int
    let isExpanded: Bool
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ScaledMetric(relativeTo: .footnote) private var chevronSize: CGFloat = 13

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: BillboardStyle.Space.s) {
                Text(name)
                    .textRole(.name)
                    .foregroundStyle(BillboardColors.primaryText)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: BillboardStyle.Space.s)

                if selectedCount > 0 {
                    Text("\(selectedCount) selected")
                        .textRole(.docket)
                        .foregroundStyle(BillboardColors.dimText)
                        .fixedSize()
                }

                Image(systemName: TopicGroupChevron.symbolName(isExpanded: isExpanded, reduceMotion: reduceMotion))
                    .font(TextRole.Face.text.font(size: chevronSize, weight: .semibold))
                    .foregroundStyle(BillboardColors.dimText)
                    .rotationEffect(TopicGroupChevron.rotation(isExpanded: isExpanded, reduceMotion: reduceMotion))
                    .accessibilityHidden(true)
            }
            .padding(.vertical, BillboardStyle.Space.s)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityValue(selectedCount > 0 ? "\(selectedCount) selected, \(isExpanded ? "expanded" : "collapsed")" : (isExpanded ? "expanded" : "collapsed"))
        .accessibilityHint(isExpanded ? "Hides its topics" : "Shows its topics")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("topicPicker.group.\(name)")
    }
}

/// How a topic group's chevron shows that the group is open (spec 3.18, 5.2): `chevron.down` turns 180° as the
/// group opens over 0.2 s. With Reduce Motion nothing turns: the group opens at once and the symbol is
/// `chevron.up` while it is open.
enum TopicGroupChevron {
    static let duration: Double = 0.2

    static func symbolName(isExpanded: Bool, reduceMotion: Bool) -> String {
        isExpanded && reduceMotion ? "chevron.up" : "chevron.down"
    }

    static func rotation(isExpanded: Bool, reduceMotion: Bool) -> Angle {
        .degrees(isExpanded && !reduceMotion ? 180 : 0)
    }

    /// How the group opens and closes; nil (at once) with Reduce Motion.
    static func animation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeInOut(duration: duration)
    }
}

/// The first-vote prompt's Save and Not now in a bottom bar on paper (spec 4.67), so the topics scroll under
/// it and the bar's paper meets the sheet's with no slab of another colour.
private struct FirstVoteActionsBar<Bar: View>: ViewModifier {
    let isShown: Bool
    @ViewBuilder let bar: () -> Bar

    func body(content: Content) -> some View {
        if isShown {
            content
                .safeAreaBar(edge: .bottom, spacing: 0) { bar() }
                .scrollEdgeEffectStyle(.soft, for: .bottom)
        } else {
            content
        }
    }
}
