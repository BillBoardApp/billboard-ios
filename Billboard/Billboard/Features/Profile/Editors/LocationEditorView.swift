import SwiftUI

/// How a location edit ended (spec D 4.1), passed to `LocationEditorView`'s `onDone`.
struct LocationEditorResult: Equatable {
    enum Method: Equatable {
        /// "Find my district": the address was geocoded (verified, or capped as not verified).
        case address
        /// "Choose your district": picked by the user, not verified.
        case chosenDistrict
    }

    /// Postal code, such as "VA".
    let state: String
    /// As stored in the profile: "11", or "At-Large".
    let district: String
    let method: Method
    /// The server's verification state after the save.
    let verification: DistrictVerificationStatus
    /// The district's senators and House member, from the members manifest (may be empty offline).
    let representatives: [CongressMemberManifestItem]
    /// The representatives were followed (setup always tries; Profile only on request).
    let followedRepresentatives: Bool

    var isVerified: Bool { verification.verified }
    /// Geocoded, but the address already has the most verified accounts allowed (C2 INT-03).
    var isAddressCapped: Bool { verification.isAddressCapped }
    /// "VA-11", "AK at-large".
    var locationLabel: String { DistrictPickerModel.locationLabel(state: state, district: district) }

    func withFollowedRepresentatives(_ followed: Bool) -> LocationEditorResult {
        LocationEditorResult(
            state: state,
            district: district,
            method: method,
            verification: verification,
            representatives: representatives,
            followedRepresentatives: followed
        )
    }
}

/// "Where do you vote?" (spec D 2.5.3): one screen to set the district, by address (verified) or by
/// picking it (not verified). Shared by first-run setup (`LocationSetupView`) and Profile's Change.
///
/// Hosts wrap it in a `NavigationStack`. In `.profile` it shows a Cancel button and dismisses itself
/// after `onDone`; in `.setup` it has no way out but Continue, and follows the representatives.
struct LocationEditorView: View {
    enum Context: Equatable {
        case setup
        case profile
    }

    let context: Context
    /// Called when the district is saved, as the success panel appears (before Continue or Done).
    let onSaved: (LocationEditorResult) -> Void
    /// Called at Continue (setup) or Done (Profile).
    let onDone: (LocationEditorResult) -> Void
    /// Setup's "Sign out", a plain text button at the end of the form (spec 4.16, frame 18); nil in Profile.
    /// The success panel (frame 19) has only Continue.
    let onSignOut: (() -> Void)?
    let isSignOutDisabled: Bool

    private let congressService: any CongressServicing

    /// - Parameters:
    ///   - congressService: nil means `CongressService.Live()`.
    ///   - savedResult: opens on the success panel for this saved district (render tests); nil opens the form.
    init(
        context: Context,
        congressService: (any CongressServicing)? = nil,
        onSignOut: (() -> Void)? = nil,
        isSignOutDisabled: Bool = false,
        savedResult: LocationEditorResult? = nil,
        onSaved: @escaping (LocationEditorResult) -> Void = { _ in },
        onDone: @escaping (LocationEditorResult) -> Void
    ) {
        self.context = context
        self.congressService = congressService ?? CongressService.Live()
        self.onSignOut = onSignOut
        self.isSignOutDisabled = isSignOutDisabled
        self.onSaved = onSaved
        self.onDone = onDone
        _savedResult = State(initialValue: savedResult)
    }

    private enum Mode: Equatable {
        case address
        case chooseDistrict
    }

    private enum Field: Hashable {
        case line1
        case line2
        case city
        case zip
    }

    enum FollowState: Equatable {
        case idle
        case following
        case failed
    }

    static let addressNotFoundMessage = "We couldn't find that address. Check it, or choose your district instead."
    static let addressCappedMessage = "This address already has the most verified accounts allowed. Your district is saved, but your votes count as not verified."
    /// Legal-facing (project-approved 2026-10-17). True as built: the address goes through the user
    /// API to the Census geocoder and the server keeps only the district and salted hashes of the
    /// address; `VerificationAddressStore` keeps it on this iPhone (Keychain, not synced). No "once":
    /// every Find my district sends it again, and one lookup can be several geocoder requests.
    static let privacyNote = "We send your address to the U.S. Census Bureau to find your district. We don't keep your street address on our servers; your iPhone remembers it so you can change it later. We keep only a scrambled code of it so one address can't verify unlimited accounts."
    static let chosenDistrictNote = "If you choose your district yourself, your votes count in national results but not in state or district results."

    @EnvironmentObject private var userStore: UserStore
    @Environment(\.dismiss) private var dismiss

    @State private var form = LocationForm()
    @State private var mode: Mode = .address
    @State private var savedResult: LocationEditorResult?
    @State private var isBusy = false
    @State private var errorMessage: String?
    @State private var manifest: [CongressMemberManifestItem] = []
    @State private var followState: FollowState = .idle
    @State private var hasPrefilled = false
    @FocusState private var focusedField: Field?

    private var districtChoices: [DistrictChoice] {
        guard let stateCode = form.stateCode else { return [] }
        return DistrictPickerModel.districtChoices(for: stateCode, manifest: manifest)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BillboardStyle.Space.l) {
                if let savedResult {
                    LocationSavedPanel(
                        result: savedResult,
                        context: context,
                        followState: followState,
                        unfollowedRepresentativeCount: unfollowedRepresentativeIDs(savedResult).count,
                        onContinue: { following in Task { await finishSetup(savedResult, following: following) } },
                        onFollow: { Task { await followFromProfile(savedResult) } },
                        onDone: {
                            let unfollowed = unfollowedRepresentativeIDs(savedResult)
                            onDone(savedResult.withFollowedRepresentatives(unfollowed.isEmpty && !savedResult.representatives.isEmpty))
                            dismiss()
                        }
                    )
                } else {
                    intro
                    switch mode {
                    case .address:
                        addressForm
                    case .chooseDistrict:
                        districtChooser
                    }

                    // The end of the form (frame 18), on its own 44 pt row so its target stays clear of the
                    // link above. Not on the success panel (frame 19): Continue is the way on from there.
                    if let onSignOut {
                        Button("Sign out", action: onSignOut)
                            .buttonStyle(BillboardButtonStyle(kind: .textButton))
                            .disabled(isSignOutDisabled)
                            .accessibilityIdentifier("setup.signOut")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                }
            }
            // The 20 pt gutter of the screens before the tabs (spec 4.10).
            .padding(.horizontal, BillboardStyle.Space.xl)
            .padding(.top, BillboardStyle.Space.xl)
            .padding(.bottom, BillboardStyle.Space.xxl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollDismissesKeyboard(.interactively)
        .billboardBackground()
        .navigationTitle(context == .profile ? "Where you vote" : "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if context == .profile, savedResult == nil {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isBusy)
                        .accessibilityIdentifier("location.cancel")
                }
            }
        }
        .interactiveDismissDisabled(isBusy || (context == .profile && savedResult != nil))
        .task {
            prefillIfNeeded()
            await loadManifest()
        }
    }

    // MARK: - Form

    private var intro: some View {
        VStack(alignment: .leading, spacing: BillboardStyle.Space.s) {
            // In Profile the navigation bar carries the title.
            if context == .setup {
                Text("Where do you vote?")
                    .textRole(.title)
                    .foregroundStyle(BillboardColors.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
            }

            Text("We use your address to find your district and your representatives.")
                .textRole(.body)
                .foregroundStyle(BillboardColors.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var addressForm: some View {
        VStack(alignment: .leading, spacing: BillboardStyle.Space.l) {
            RecordField(
                label: "Street address",
                text: $form.line1,
                prompt: "123 Main St",
                isDisabled: isBusy,
                identifier: "location.street",
                focus: $focusedField,
                focusValue: .line1
            )
            .textContentType(.streetAddressLine1)
            .autocorrectionDisabled()
            .submitLabel(.next)
            .onSubmit { focusedField = .line2 }

            RecordField(
                label: "Apt or unit (optional)",
                text: $form.line2,
                prompt: "Apt 4B",
                isDisabled: isBusy,
                identifier: "location.unit",
                focus: $focusedField,
                focusValue: .line2
            )
            .textContentType(.streetAddressLine2)
            .autocorrectionDisabled()
            .submitLabel(.next)
            .onSubmit { focusedField = .city }

            RecordField(
                label: "City",
                text: $form.city,
                prompt: "Fairfax",
                isDisabled: isBusy,
                identifier: "location.city",
                focus: $focusedField,
                focusValue: .city
            )
            .textContentType(.addressCity)
            .autocorrectionDisabled()
            .submitLabel(.next)
            .onSubmit { focusedField = .zip }

            // State and ZIP share a line (frame 18), one above the other at accessibility sizes.
            if dynamicTypeSize.isAccessibilitySize {
                statePicker
                zipField
            } else {
                HStack(alignment: .top, spacing: BillboardStyle.Space.m) {
                    statePicker
                    zipField
                }
            }

            // Legal-facing: word for word (`privacyNote`).
            Text(Self.privacyNote)
                .textRole(.caption)
                .foregroundStyle(BillboardColors.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("location.privacyNote")

            BBActionButton(
                title: "Find my district",
                action: { Task { await findDistrict() } },
                loadingTitle: "Finding your district…",
                isEnabled: form.canFindDistrict && !isBusy,
                isLoading: isBusy,
                disabledHint: form.findDistrictHint
            )
            .accessibilityIdentifier("location.find")

            errorText

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    errorMessage = nil
                    form.reconcileDistrict(with: districtChoices)
                    mode = .chooseDistrict
                }
            } label: {
                Text("Don't want to share your address? Choose your district")
                    .multilineTextAlignment(.center)
            }
            .buttonStyle(BillboardButtonStyle(kind: .textLink))
            .frame(maxWidth: .infinity)
            .disabled(isBusy)
            .accessibilityIdentifier("location.chooseDistrict")
        }
    }

    private var zipField: some View {
        RecordField(
            label: "ZIP",
            text: $form.zip,
            prompt: "22030",
            isDisabled: isBusy,
            identifier: "location.zip",
            focus: $focusedField,
            focusValue: .zip
        )
        .textContentType(.postalCode)
        .keyboardType(.numbersAndPunctuation)
        .autocorrectionDisabled()
        .submitLabel(.go)
        .onSubmit(findDistrictFromKeyboard)
    }

    private var districtChooser: some View {
        VStack(alignment: .leading, spacing: BillboardStyle.Space.l) {
            statePicker

            RecordMenuField(
                label: "District",
                selection: $form.district,
                options: districtChoices.map { .init(value: $0.value, title: $0.label) },
                unsetValue: "",
                isDisabled: isBusy || form.stateCode == nil,
                identifier: "location.district"
            )

            Text(Self.chosenDistrictNote)
                .textRole(.caption)
                .foregroundStyle(BillboardColors.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            BBActionButton(
                title: "Continue",
                action: { Task { await saveChosenDistrict() } },
                loadingTitle: "Saving…",
                isEnabled: form.canChooseDistrict(choices: districtChoices) && !isBusy,
                isLoading: isBusy,
                disabledHint: form.chooseDistrictHint(choices: districtChoices)
            )
            .accessibilityIdentifier("location.chooseDistrict.continue")

            errorText

            Button("Use my address instead") {
                withAnimation(.easeInOut(duration: 0.2)) {
                    errorMessage = nil
                    mode = .address
                }
            }
            .buttonStyle(BillboardButtonStyle(kind: .textLink))
            .frame(maxWidth: .infinity)
            .disabled(isBusy)
            .accessibilityIdentifier("location.useAddress")
        }
    }

    /// The State menu in the field style (spec 3.17): the state's name in ink, "Choose" in ink 3 until one is
    /// picked; never system blue.
    private var statePicker: some View {
        RecordMenuField(
            label: "State",
            selection: $form.state,
            options: DistrictPickerModel.states.map { .init(value: $0.code, title: $0.name) },
            unsetValue: "",
            isDisabled: isBusy,
            identifier: "location.state"
        )
        .onChange(of: form.state) { _, _ in
            form.reconcileDistrict(with: districtChoices)
        }
    }

    @ViewBuilder
    private var errorText: some View {
        if let errorMessage {
            RecordErrorText(errorMessage)
                .accessibilityIdentifier("location.error")
        }
    }

    // MARK: - Actions

    private func prefillIfNeeded() {
        guard !hasPrefilled else { return }
        hasPrefilled = true

        let profile = userStore.profile
        if let stateCode = DistrictPickerModel.stateCode(from: profile.state) {
            form.state = stateCode
            form.district = DistrictPickerModel.normalizedDistrict(profile.district, state: stateCode) ?? ""
        }
        if let draft = VerificationAddressStore.load(userId: profile.id.trimmedNonEmpty) {
            form.line1 = draft.line1
            form.line2 = draft.line2 ?? ""
            form.city = draft.city
            form.zip = draft.zip
            if form.state.isEmpty, let draftState = DistrictPickerModel.stateCode(from: draft.state) {
                form.state = draftState
            }
        }
    }

    /// Any cached members manifest at once, then a fresh one when the cache is stale or missing.
    private func loadManifest() async {
        if manifest.isEmpty, let cached = congressService.cachedCongressMembersManifest(), !cached.isEmpty {
            manifest = cached
        }
        guard congressService.cachedCongressMembersManifest(maxAge: ManifestCachePolicy.ttl)?.isEmpty != false else { return }
        if let fresh = try? await congressService.getCongressMembersManifest(), !fresh.isEmpty {
            manifest = fresh
        }
    }

    private func findDistrictFromKeyboard() {
        focusedField = nil
        guard form.canFindDistrict, !isBusy else { return }
        Task { await findDistrict() }
    }

    private func findDistrict() async {
        guard form.canFindDistrict, let stateCode = form.stateCode, !isBusy else { return }
        focusedField = nil
        errorMessage = nil
        isBusy = true
        defer { isBusy = false }

        let line1 = form.line1.trimmed
        let line2 = form.line2.trimmedNonEmpty
        let city = form.city.trimmed
        let zip = form.zip.trimmed

        do {
            let status = try await userStore.verifyDistrictWithAddress(
                line1: line1,
                line2: line2,
                city: city,
                state: stateCode,
                zip: zip
            )
            guard let resolved = status.resolved,
                  let resolvedState = DistrictPickerModel.stateCode(from: resolved.state),
                  let resolvedDistrict = DistrictPickerModel.normalizedDistrict(resolved.districtId, state: resolvedState)
            else {
                showError(Self.addressNotFoundMessage)
                return
            }

            VerificationAddressStore.save(
                line1: line1,
                line2: line2,
                city: city,
                state: resolvedState,
                zip: zip,
                userId: userStore.profile.id.trimmedNonEmpty
            )
            form.state = resolvedState
            form.district = resolvedDistrict
            await showSaved(state: resolvedState, district: resolvedDistrict, method: .address, verification: status)
        } catch {
            showError(Self.message(for: error))
        }
    }

    private func saveChosenDistrict() async {
        guard let stateCode = form.stateCode,
              let district = form.chosenDistrict,
              form.canChooseDistrict(choices: districtChoices),
              !isBusy
        else { return }
        errorMessage = nil
        isBusy = true
        defer { isBusy = false }

        do {
            try await userStore.updateLocation(state: stateCode, district: district)
            let status = try await DistrictVerificationService.submitManualSelection(state: stateCode, district: district)
            VerificationAddressStore.clear(userId: userStore.profile.id.trimmedNonEmpty)
            await showSaved(state: stateCode, district: district, method: .chosenDistrict, verification: status)
        } catch {
            showError(Self.message(for: error))
        }
    }

    /// Shows a failed find or save under the button and says it to VoiceOver, whose focus stays on
    /// the button (only a success was announced, so a failure was silent).
    private func showError(_ message: String) {
        errorMessage = message
        AccessibilityNotification.Announcement(message).post()
    }

    private func showSaved(
        state: String,
        district: String,
        method: LocationEditorResult.Method,
        verification: DistrictVerificationStatus
    ) async {
        if manifest.isEmpty {
            await loadManifest()
        }
        let result = LocationEditorResult(
            state: state,
            district: district,
            method: method,
            verification: verification,
            representatives: DistrictPickerModel.representatives(in: manifest, state: state, district: district),
            followedRepresentatives: false
        )
        followState = .idle
        withAnimation(.easeInOut(duration: 0.2)) {
            savedResult = result
        }
        onSaved(result)
        AccessibilityNotification.Announcement(
            DistrictPickerModel.successHeadline(state: state, district: district)
        ).post()
    }

    private func unfollowedRepresentativeIDs(_ result: LocationEditorResult) -> [String] {
        let followed = Set(userStore.profile.subscribedMemberIDs)
        return result.representatives
            .map(\.id)
            .filter { !followed.contains(UUID.deterministic(from: $0)) }
    }

    /// Setup's Continue: follows the representatives (today's `subscribeToCongressMembers`), then
    /// finishes. A failed follow keeps the panel with Try again and Continue without following.
    private func finishSetup(_ result: LocationEditorResult, following: Bool) async {
        guard followState != .following else { return }
        let toFollow = following ? unfollowedRepresentativeIDs(result) : []
        if !toFollow.isEmpty {
            followState = .following
            do {
                try await userStore.subscribeToCongressMembers(manifestIds: toFollow)
            } catch {
                followState = .failed
                return
            }
        }
        followState = .idle
        onDone(result.withFollowedRepresentatives(following && !result.representatives.isEmpty))
    }

    private func followFromProfile(_ result: LocationEditorResult) async {
        let toFollow = unfollowedRepresentativeIDs(result)
        guard !toFollow.isEmpty, followState != .following else { return }
        followState = .following
        do {
            try await userStore.subscribeToCongressMembers(manifestIds: toFollow)
            followState = .idle
        } catch {
            followState = .failed
        }
    }

    /// User copy for a failed save: the service's own copy (offline, rate limited, address not
    /// found), else a plain fallback.
    static func message(for error: Error) -> String {
        let message = AuthErrorMessages.message(for: error, context: .general)
        return message == AuthErrorMessages.generic
            ? "Couldn't save your district. Try again."
            : message
    }
}

/// The success panel (Civic Record spec 4.16, frame 19): "You're in VA-11." in the `title` role (VoiceOver:
/// "You're in Virginia's 11th district."), the VERIFIED stamp in ink or NOT VERIFIED in ink 3 with how the
/// district was found (or the address-cap notice), the representatives as a roll sheet (monograms with party
/// discs, affiliation lines led by the party letter), then setup's Continue or Profile's Follow and Done. No
/// seal or pin symbols, no green.
struct LocationSavedPanel: View {
    let result: LocationEditorResult
    let context: LocationEditorView.Context
    let followState: LocationEditorView.FollowState
    /// Representatives on the panel the profile does not follow yet.
    let unfollowedRepresentativeCount: Int
    /// Setup: true follows the representatives first ("Continue"); false skips that ("Continue
    /// without following", offered after a failed follow).
    let onContinue: (Bool) -> Void
    /// Profile: "Follow your representatives".
    let onFollow: () -> Void
    /// Profile: "Done".
    let onDone: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.legibilityWeight) private var legibilityWeight

    /// Profile's Follow your representatives: a secondary capsule, or from AX4 the ink text button that setup's
    /// "Continue without following" is, centred, so its words stay whole (project decision of 2026-10-29). At AX5
    /// "representatives" is about 318 pt wide in the button face; a capsule in a 375 pt phone's 335 pt column leaves it
    /// 303 pt inside its padding, full width or not, so it broke as "representative / s", and with less padding the
    /// capsule's round ends cut through the word. At AX4 it is 277 pt, but 303.3 pt with Bold Text, so the text button
    /// starts there; up to AX3 the capsule keeps it whole. At AX5 with Bold Text the word is 348 pt, wider than the
    /// column, so the label is also set at 93% there (`TextRole.boldTextAX5Scale`).
    static func followButtonKind(at size: DynamicTypeSize) -> BillboardButtonKind {
        size >= followTextButtonSize ? .textButton : .secondary
    }

    /// The size from which Follow your representatives is the text button.
    static let followTextButtonSize: DynamicTypeSize = .accessibility4

    /// The headline as VoiceOver reads it: the district code in words.
    static func spokenHeadline(state: String, district: String) -> String {
        let headline = DistrictPickerModel.successHeadline(state: state, district: district)
        let label = DistrictPickerModel.locationLabel(state: state, district: district)
        guard headline == "You're in \(label).", let spoken = SpokenForm.district(label) else { return headline }
        return "You're in \(spoken)."
    }

    /// The line under the stamp: how the district was set. The address cap has its own notice.
    var statusNote: String? {
        if result.isAddressCapped { return nil }
        if result.isVerified { return "Found from your address." }
        return result.method == .chosenDistrict ? "You chose this district." : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: BillboardStyle.Space.l) {
            VStack(alignment: .leading, spacing: BillboardStyle.Space.s) {
                Text(DistrictPickerModel.successHeadline(state: result.state, district: result.district))
                    .textRole(.title)
                    .foregroundStyle(BillboardColors.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(Self.spokenHeadline(state: result.state, district: result.district))
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("location.success.headline")

                StatusStamp(result.isVerified ? .verified : .notVerified)
                    .padding(.top, BillboardStyle.Space.xs)

                if result.isAddressCapped {
                    RecordNoticeText(LocationEditorView.addressCappedMessage)
                        .accessibilityIdentifier("location.success.capped")
                } else if let statusNote {
                    Text(statusNote)
                        .textRole(.body)
                        .foregroundStyle(BillboardColors.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if result.representatives.isEmpty {
                Text("We couldn't load your representatives right now. You can find them in Congress.")
                    .textRole(.body)
                    .foregroundStyle(BillboardColors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: BillboardStyle.Space.m) {
                    SectionHeader("Your representatives")
                    RollSheet {
                        RollRows(result.representatives) { _, member in
                            RepresentativeRow(member: member)
                        }
                    }
                }
                .padding(.top, BillboardStyle.Space.s)
            }

            switch context {
            case .setup:
                setupActions
            case .profile:
                profileActions
            }
        }
    }

    @ViewBuilder
    private var setupActions: some View {
        if !result.representatives.isEmpty {
            Text("We'll follow them for you. You can change this in Congress.")
                .textRole(.body)
                .foregroundStyle(BillboardColors.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }

        BBActionButton(
            title: followState == .failed ? "Try again" : "Continue",
            action: { onContinue(true) },
            loadingTitle: "Following…",
            isEnabled: followState != .following,
            isLoading: followState == .following
        )
        .accessibilityIdentifier("location.continue")

        if followState == .failed {
            RecordErrorText("We couldn't follow your representatives. Try again, or continue and follow them in Congress.")

            Button("Continue without following") {
                onContinue(false)
            }
            .buttonStyle(BillboardButtonStyle(kind: .textButton))
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("location.continueWithoutFollowing")
        }
    }

    @ViewBuilder
    private var profileActions: some View {
        if unfollowedRepresentativeCount > 0 {
            let follow = BBActionButton(
                title: "Follow your representatives",
                action: onFollow,
                loadingTitle: "Following…",
                isEnabled: followState != .following,
                isLoading: followState == .following,
                kind: Self.followButtonKind(at: dynamicTypeSize),
                labelScale: TextRole.boldTextAX5Scale(at: dynamicTypeSize, legibilityWeight: legibilityWeight)
            )
            Group {
                if dynamicTypeSize >= Self.followTextButtonSize {
                    follow.frame(maxWidth: .infinity)
                } else {
                    follow
                }
            }
            .accessibilityIdentifier("location.followRepresentatives")

            if followState == .failed {
                RecordErrorText("We couldn't follow your representatives. Try again in a moment.")
            }
        } else if !result.representatives.isEmpty {
            Text("You follow your representatives.")
                .textRole(.body)
                .foregroundStyle(BillboardColors.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }

        BBActionButton(
            title: "Done",
            action: onDone,
            isEnabled: followState != .following
        )
        .accessibilityIdentifier("location.done")
    }
}

/// One representative on the success panel (spec 3.15): the 44 pt monogram with the party disc, "Sen. Tim
/// Kaine" in the `name` role and "D · Senate · VA" in the docket face. Not a link: setup has nowhere to go.
private struct RepresentativeRow: View {
    let member: CongressMemberManifestItem

    var body: some View {
        let party = CongressMemberLabel.party(of: member)
        let chamber = CongressMemberLabel.chamber(of: member)
        MemberRollRow(
            name: CongressMemberLabel.titledName(member.name, chamber: chamber),
            monogramName: member.name,
            party: party,
            affiliation: CongressMemberLabel.affiliation(party: party, state: member.state, district: member.district, chamber: chamber),
            photoURL: member.depictionImageUrl,
            monogramSize: .roll,
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
