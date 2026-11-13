import Amplify
import Combine
import Foundation
import os

@MainActor
final class UserStore: ObservableObject {
    private static let defaults = UserDefaults.standard
    private enum CacheKeys {
        static let cachedProfilePrefix = "BillBoard.userProfile.cached.v1."
    }
    private static let defaultCompliance = ComplianceSnapshot(
        adultStatus: .unknown,
        adultMethod: nil,
        adultStatusSetAt: nil,
        deletionStatus: .notRequested,
        canWrite: false
    )

    @Published private(set) var profile: UserProfile = .placeholder() {
        didSet {
            guard !suppressProfileCacheWrite else { return }
            persistCachedProfileIfPossible(profile)
        }
    }
    @Published private(set) var compliance: ComplianceSnapshot = UserStore.defaultCompliance
    /// True once `GET /me` answered for this session. Until then `compliance.adultStatus` is
    /// `.unknown` because nothing is known, not because the account has no age answer, so the age
    /// gate (`requiresAdultAttestation`) must not show.
    @Published private(set) var hasLoadedCompliance: Bool = false
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var hasRefreshedOnce: Bool = false
    @Published private(set) var errorMessage: String?
    /// True while "Where do you vote?" (`LocationSetupView`) is on screen. The profile has a location
    /// as soon as the district is saved, before the success panel's Continue, so the root keeps the
    /// setup screen and deep links wait until this clears (`SignedInGate`, `DeepLinkGate`).
    @Published private(set) var isCompletingOnboarding: Bool = false
    private var suppressProfileCacheWrite = false

    private let preferencesService: any PreferencesServicing
    private let congressService: any CongressServicing
    /// The sign-up age answer kept on this device until the server records it (spec D 2.5.2).
    private let adultAnswerStore: AdultAnswerStore

    init(
        preferencesService: any PreferencesServicing = PreferencesService.Live(),
        congressService: any CongressServicing = CongressService.Live(),
        adultAnswerStore: AdultAnswerStore = AdultAnswerStore()
    ) {
        self.preferencesService = preferencesService
        self.congressService = congressService
        self.adultAnswerStore = adultAnswerStore
    }

    #if DEBUG
    private static var didLogPreferencesSummary: Bool = false
    #endif

    private var effectiveAdultStatus: AdultEligibilityStatus {
        if compliance.adultStatus != .unknown {
            return compliance.adultStatus
        }

        guard let userId = cachedAdultStatusUserID else {
            return .unknown
        }

        return cachedAdultStatus(for: userId) ?? .unknown
    }

    /// The server has no age answer for this account (as far as this session has heard from it).
    /// The root shows the age gate only when no sign-up answer is stored either (spec D 2.5.2).
    var requiresAdultAttestation: Bool {
        hasRefreshedOnce
            && hasLoadedCompliance
            && compliance.adultStatus == .unknown
            && compliance.deletionStatus != .inProgress
            && compliance.deletionStatus != .completed
    }

    var isUnderageBlocked: Bool {
        effectiveAdultStatus == .selfReportedUnder18 || compliance.deletionStatus == .completed
    }

    var canPerformUserWrites: Bool {
        effectiveAdultStatus == .attestedAdult && compliance.deletionStatus != .inProgress && compliance.deletionStatus != .completed
    }

    /// The topic picker's Save (`setInitialPreferences`, `updateFollowedTopics`): every account
    /// `canPerformUserWrites` allows, and also one whose age status is still unknown while the answer it
    /// gave at sign-up waits on this device to be resent (spec D 2.5.2). The server refuses writes only
    /// for under-18 and deleted accounts, and that account is never asked its age again, so it goes
    /// through "Where do you vote?", the tour and the first-vote topic prompt (`SignedInGate`).
    var canSaveFollowedTopics: Bool {
        if canPerformUserWrites { return true }
        guard effectiveAdultStatus == .unknown,
              compliance.deletionStatus != .inProgress,
              compliance.deletionStatus != .completed else { return false }
        return adultAnswerStore.hasPendingAnswer(email: profile.email)
    }

    func refresh() async {
        isLoading = true
        errorMessage = nil
        // A cancelled refresh did not finish: `shouldShowOnboarding` reads a finished one without an
        // error as a loaded profile (APPF-22).
        var isFinished = true
        defer {
            isLoading = false
            if isFinished { hasRefreshedOnce = true }
        }

        #if DEBUG
        print("[UserStore] refresh() starting")
        #endif

        do {
            let session = try await Amplify.Auth.fetchAuthSession()
            guard session.isSignedIn else {
                setProfile(.placeholder(), persist: false)
                #if DEBUG
                print("[UserStore] not signed in; using placeholder profile")
                #endif
                return
            }

            let currentUser = try await Amplify.Auth.getCurrentUser()
            let attributes = try await Amplify.Auth.fetchUserAttributes()

            // Always populate the base profile from Cognito attributes.
            // Preferences are best-effort so a backend hiccup doesn't blank the whole profile UI.
            let base = UserProfileMapper.baseProfile(userId: currentUser.userId, attributes: attributes)
            if profile.id.trimmedNonEmpty != base.id.trimmedNonEmpty {
                setProfile(base, persist: false)
            }

            await refreshComplianceStatus()

            let preferences: [PreferencesItem]
            do {
                preferences = try await preferencesService.getPreferences()
            } catch {
                // Leaving the screen mid-load is not a failure, nor a finished refresh (APPF-22).
                isFinished = !APIErrorResponse.isCancellation(error)
                guard isFinished else { return }
                setUserFacingError(
                    "Could not load your preferences right now.",
                    debug: error,
                    context: "refresh() preferences fetch failed"
                )

                return
            }

            let summary = PreferencesInterpreter.summarize(preferences)

            #if DEBUG
            if !Self.didLogPreferencesSummary {
                Self.didLogPreferencesSummary = true

                let kindCounts = Dictionary(grouping: preferences, by: { $0.kind })
                    .mapValues { $0.count }

                let typeCounts = Dictionary(grouping: preferences, by: { ($0.type ?? "(nil)").trimmingCharacters(in: .whitespacesAndNewlines) })
                    .mapValues { $0.count }

                let congressRawValues = preferences
                    .filter { $0.kind == .congressMember }
                    .map { $0.value }
                    .filter { !$0.isEmpty }

                let invalidCongressIDs = congressRawValues.filter { UUID(uuidString: $0) == nil }
                let mappedFromManifestIDs = invalidCongressIDs.filter { !$0.isEmpty }

                print("[Preferences] total=\(preferences.count) kindCounts=\(kindCounts) typeCounts=\(typeCounts)")
                print("[Preferences] congressMember raw=\(congressRawValues.count) parsedUnique=\(summary.subscribedMemberIDs.count) invalidUUID=\(invalidCongressIDs.count) mappedFromManifestID=\(mappedFromManifestIDs.count)")
                if let sample = invalidCongressIDs.prefix(3).first {
                    print("[Preferences] invalid congressMember sample=\(sample)")
                }
            }
            #endif

            setProfile(base.applying(summary))

            #if DEBUG
            print(
                "[UserStore] refresh() completed userId=\(currentUser.userId) " +
                "subs: topics=\(summary.subscribedSubCategories.count) " +
                "lifeAreas=\(summary.subscribedLifeAreas.count) " +
                "members=\(summary.subscribedMemberIDs.count) " +
                "contentTypes=\(summary.selectedBillContentTypes.count)"
            )
            #endif
        } catch {
            isFinished = !APIErrorResponse.isCancellation(error)
            guard isFinished else { return }
            setUserFacingError(
                "Could not load your profile right now.",
                debug: error,
                context: "refresh() failed"
            )
            // Keep whatever we last had (or placeholder)
        }
    }

    /// Fast-path refresh: accepts pre-fetched Cognito data so we skip the
    /// redundant fetchAuthSession / getCurrentUser / fetchUserAttributes calls
    /// that the full `refresh()` performs. Only the backend preferences call remains.
    func refresh(userId: String, attributes: [AuthUserAttribute]) async {
        isLoading = true
        errorMessage = nil
        // A cancelled refresh did not finish: `shouldShowOnboarding` reads a finished one without an
        // error as a loaded profile (APPF-22).
        var isFinished = true
        defer {
            isLoading = false
            if isFinished { hasRefreshedOnce = true }
        }

        #if DEBUG
        print("[UserStore] refresh(userId:attributes:) fast-path starting")
        #endif

        let base = UserProfileMapper.baseProfile(userId: userId, attributes: attributes)
        if profile.id.trimmedNonEmpty != base.id.trimmedNonEmpty {
            setProfile(base, persist: false)
        }
        await refreshComplianceStatus()

        let preferences: [PreferencesItem]
        do {
            preferences = try await preferencesService.getPreferences()
        } catch {
            // Leaving the screen mid-load is not a failure, nor a finished refresh (APPF-22).
            isFinished = !APIErrorResponse.isCancellation(error)
            guard isFinished else { return }
            setUserFacingError(
                "Could not load your preferences right now.",
                debug: error,
                context: "refresh(userId:attributes:) preferences fetch failed"
            )
            return
        }

        let summary = PreferencesInterpreter.summarize(preferences)

        #if DEBUG
        if !Self.didLogPreferencesSummary {
            Self.didLogPreferencesSummary = true

            let kindCounts = Dictionary(grouping: preferences, by: { $0.kind })
                .mapValues { $0.count }

            let typeCounts = Dictionary(grouping: preferences, by: { ($0.type ?? "(nil)").trimmingCharacters(in: .whitespacesAndNewlines) })
                .mapValues { $0.count }

            print("[Preferences] total=\(preferences.count) kindCounts=\(kindCounts) typeCounts=\(typeCounts)")
        }
        #endif

        setProfile(base.applying(summary))

        #if DEBUG
        print(
            "[UserStore] refresh(userId:attributes:) completed " +
            "subs: topics=\(summary.subscribedSubCategories.count) " +
            "lifeAreas=\(summary.subscribedLifeAreas.count) " +
            "members=\(summary.subscribedMemberIDs.count) " +
            "contentTypes=\(summary.selectedBillContentTypes.count)"
        )
        #endif
    }

    func clearForSignOut() {
        setProfile(.placeholder(), persist: false)
        compliance = Self.defaultCompliance
        hasLoadedCompliance = false
        errorMessage = nil
        isLoading = false
        hasRefreshedOnce = false
        isCompletingOnboarding = false
    }

    /// Marks the store as actively refreshing before we surface a cached snapshot.
    /// This keeps downstream observers from treating cache hydration as a completed
    /// network-backed refresh and kicking off duplicate startup work.
    func prepareForRefreshBootstrap() {
        isLoading = true
        errorMessage = nil
    }

    func hydrateCachedProfileIfAvailable(userId: String) {
        guard let normalizedUserId = userId.trimmedNonEmpty else { return }
        guard let cached = Self.cachedProfile(for: normalizedUserId) else { return }

        setProfile(cached, persist: false)
        errorMessage = nil
        hasRefreshedOnce = true

        if let cachedAdultStatus = cachedAdultStatus(for: normalizedUserId) {
            compliance = ComplianceSnapshot(
                adultStatus: cachedAdultStatus,
                adultMethod: nil,
                adultStatusSetAt: nil,
                deletionStatus: .notRequested,
                canWrite: cachedAdultStatus == .attestedAdult
            )
        }
    }

    func refreshComplianceStatus() async {
        do {
            compliance = try await AccountComplianceService.fetchMe()
            hasLoadedCompliance = true
            await persistAdultStatusIfKnown(compliance)
            #if DEBUG
            print(
                "[UserStore] compliance refreshed: " +
                "adultStatus=\(effectiveAdultStatus.rawValue) " +
                "deletionStatus=\(compliance.deletionStatus.rawValue) " +
                "canWrite=\(compliance.canWrite)"
            )
            #endif
        } catch {
            #if DEBUG
            print("[UserStore] refreshComplianceStatus() failed: \(error.localizedDescription)")
            #endif
        }
    }

    func submitAdultAttestation(isAdult: Bool) async throws {
        _ = try await AccountComplianceService.submitAdultAttestation(isAdult: isAdult)
        try await confirmComplianceAfterAttestation(expectAdult: isAdult)
    }

    private func confirmComplianceAfterAttestation(expectAdult: Bool) async throws {
        let maxAttempts = 6
        var lastError: Error?

        for attempt in 1...maxAttempts {
            do {
                let snapshot = try await AccountComplianceService.fetchMe()
                compliance = snapshot
                hasLoadedCompliance = true
                await persistAdultStatusIfKnown(snapshot)

                if didConfirmAdultAttestation(snapshot, expectAdult: expectAdult) {
                    return
                }
            } catch {
                // A cancelled check stops the confirmation instead of retrying it (APPF-22).
                if APIErrorResponse.isCancellation(error) { throw CancellationError() }
                lastError = error
            }

            if attempt < maxAttempts {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }

        if let lastError {
            throw lastError
        }

        throw AccountComplianceService.ServiceError.attestationNotApplied
    }

    private func didConfirmAdultAttestation(_ snapshot: ComplianceSnapshot, expectAdult: Bool) -> Bool {
        if snapshot.deletionStatus == .inProgress || snapshot.deletionStatus == .completed {
            return true
        }

        if expectAdult {
            return snapshot.adultStatus == .attestedAdult || snapshot.adultStatus == .selfReportedUnder18
        }

        return snapshot.adultStatus == .selfReportedUnder18
    }

    private var cachedAdultStatusUserID: String? {
        profile.id.trimmedNonEmpty
    }

    private func cachedAdultStatus(for userId: String) -> AdultEligibilityStatus? {
        guard let rawValue = Self.defaults.string(forKey: cachedAdultStatusKey(for: userId)) else {
            return nil
        }
        return AdultEligibilityStatus(rawValue: rawValue)
    }

    private func persistAdultStatusIfKnown(_ snapshot: ComplianceSnapshot) async {
        guard snapshot.adultStatus != .unknown else { return }
        guard let userId = await resolveCachedAdultStatusUserID() else { return }

        Self.defaults.set(snapshot.adultStatus.rawValue, forKey: cachedAdultStatusKey(for: userId))
    }

    private func resolveCachedAdultStatusUserID() async -> String? {
        if let cachedAdultStatusUserID {
            return cachedAdultStatusUserID
        }

        do {
            let currentUser = try await Amplify.Auth.getCurrentUser()
            return currentUser.userId.trimmedNonEmpty
        } catch {
            return nil
        }
    }

    private func cachedAdultStatusKey(for userId: String) -> String {
        "\(AccountComplianceStorage.cachedAdultStatusKeyPrefix)\(userId)"
    }

    private static func cachedProfileKey(for userId: String) -> String {
        "\(CacheKeys.cachedProfilePrefix)\(userId)"
    }

    /// Reads the cached profile from disk. A copy left in UserDefaults by an
    /// older build is moved to the file cache and deleted on first read.
    private static func cachedProfile(for userId: String) -> UserProfile? {
        if let data = UserProfileDiskCache.data(userId: userId) {
            return decodeCachedProfile(data)
        }

        guard let legacyData = defaults.data(forKey: cachedProfileKey(for: userId)) else {
            return nil
        }

        UserProfileDiskCache.store(legacyData, userId: userId)
        defaults.removeObject(forKey: cachedProfileKey(for: userId))
        return decodeCachedProfile(legacyData)
    }

    /// Topic names are canonicalized (LLM-10): a profile cached by R1 may hold "Social Justice" or
    /// "Identity Politics", and the picker and the Bills matching must see the new names before the
    /// preferences refresh lands (a DELETE with an old name would also delete the new row).
    private static func decodeCachedProfile(_ data: Data) -> UserProfile? {
        do {
            return try JSONDecoder.usingDefaultKeys().decode(UserProfile.self, from: data).canonicalizingTopics()
        } catch {
            AppLog.decodingFailure(error, decoding: UserProfile.self, label: "UserStore cached profile", logger: AppLog.store)
            return nil
        }
    }

    static func clearCachedProfile(userId: String?, defaults: UserDefaults = .standard) {
        guard let userId = userId.trimmedNonEmpty else { return }
        UserProfileDiskCache.remove(userId: userId)
        defaults.removeObject(forKey: cachedProfileKey(for: userId))
    }

    static func clearAllCachedProfiles(defaults: UserDefaults = .standard) {
        UserProfileDiskCache.removeAll()
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(CacheKeys.cachedProfilePrefix) {
            defaults.removeObject(forKey: key)
        }
    }

    private func setProfile(_ updated: UserProfile, persist: Bool = true) {
        let previousSuppressState = suppressProfileCacheWrite
        suppressProfileCacheWrite = !persist
        profile = updated
        suppressProfileCacheWrite = previousSuppressState
    }

    private func persistCachedProfileIfPossible(_ profile: UserProfile) {
        guard let userId = profile.id.trimmedNonEmpty else { return }
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(profile) else { return }

        UserProfileDiskCache.store(data, userId: userId)
        // Drop any copy an older build left in UserDefaults.
        Self.defaults.removeObject(forKey: Self.cachedProfileKey(for: userId))
    }

    // MARK: - Onboarding helpers

    func setCompletingOnboarding(_ isCompleting: Bool) {
        isCompletingOnboarding = isCompleting
    }

    /// True when the profile has no state or no district, so "Where do you vote?" is needed.
    /// Topics are no longer required (spec D 2.5.3): they are asked after the first vote.
    var needsOnboarding: Bool {
        OnboardingGate.needsLocationSetup(profile)
    }

    /// Only show onboarding once we have a successful refresh snapshot.
    /// If refresh failed (for example, offline cold start), avoid forcing
    /// users into account setup based on placeholder data.
    var shouldShowOnboarding: Bool {
        lacksLocationAfterRefresh && canPerformUserWrites
    }

    /// A finished refresh without an error shows no state or district: `shouldShowOnboarding` without
    /// its write check. The root uses it for an account whose sign-up age answer has not reached the
    /// server yet (`SignedInGate`): the server accepts that account's writes.
    var lacksLocationAfterRefresh: Bool {
        hasRefreshedOnce && !isLoading && errorMessage == nil && needsOnboarding
    }

    /// Updates the Cognito-backed profile location fields.
    ///
    /// Implementation notes:
    /// - `state` is stored in a Cognito custom attribute `custom:state`.
    /// - `district` is stored in a Cognito custom attribute `custom:district`.
    func updateLocation(state: String, district: String) async throws {
        let cleanedState = state.uppercasedTrimmed
        let cleanedDistrict = district.trimmed

        guard !cleanedState.isEmpty else { return }
        guard !cleanedDistrict.isEmpty else { return }

        let previous = profile
        setProfile(profile.updating(state: cleanedState, district: cleanedDistrict))

        do {
            _ = try await Amplify.Auth.update(userAttribute: AuthUserAttribute(.custom("state"), value: cleanedState))
            _ = try await Amplify.Auth.update(userAttribute: AuthUserAttribute(.custom("district"), value: cleanedDistrict))
        } catch {
            setProfile(previous)
            setUserFacingError(
                "Couldn't save your location.",
                debug: error,
                context: "updateLocation() failed"
            )
            throw error
        }
    }

    /// Verifies district using a full street address (higher-confidence mode).
    ///
    /// Call this when user supplies a real address. The API resolves state/district from address.
    /// We then mirror resolved state/district into Cognito custom attributes.
    @discardableResult
    func verifyDistrictWithAddress(
        line1: String,
        line2: String? = nil,
        city: String,
        state: String,
        zip: String,
        claimedDistrict: String? = nil
    ) async throws -> DistrictVerificationStatus {
        let status = try await DistrictVerificationService.submitAddress(
            line1: line1,
            line2: line2,
            city: city,
            state: state,
            zip: zip,
            claimedDistrict: claimedDistrict
        )

        if let resolved = status.resolved {
            let resolvedState = resolved.state.uppercasedTrimmed
            let resolvedDistrict =
                DistrictNormalization.normalize(resolved.districtId, userState: resolvedState)
                ?? resolved.districtId.trimmed

            let previous = profile
            setProfile(profile.updating(state: resolvedState, district: resolvedDistrict))

            do {
                _ = try await Amplify.Auth.update(userAttribute: AuthUserAttribute(.custom("state"), value: resolvedState))
                _ = try await Amplify.Auth.update(userAttribute: AuthUserAttribute(.custom("district"), value: resolvedDistrict))
            } catch {
                setProfile(previous)
                setUserFacingError(
                    "Couldn't save your verified district.",
                    debug: error,
                    context: "verifyDistrictWithAddress() profile sync failed"
                )
                throw error
            }
        }

        return status
    }

    /// Manual location mode (no address), useful to intentionally remove address-based verification.
    @discardableResult
    func removeAddressVerificationKeepLocation() async throws -> DistrictVerificationStatus {
        let cleanedState = profile.state.uppercasedTrimmed
        let cleanedDistrict = profile.district.trimmed

        guard !cleanedState.isEmpty else {
            throw DistrictVerificationService.ServiceError.invalidInput("State is required.")
        }
        guard !cleanedDistrict.isEmpty else {
            throw DistrictVerificationService.ServiceError.invalidInput("District is required.")
        }

        return try await DistrictVerificationService.removeAddressByManualSelection(
            state: cleanedState,
            district: cleanedDistrict
        )
    }

    /// Sets initial preferences in bulk. Intended for the first-run onboarding flow.
    func setInitialPreferences(subCategories: [String], lifeAreas: [String]) async throws {
        guard canSaveFollowedTopics else {
            await refreshComplianceStatus()
            throw ValidationError.userWritesNotAllowed
        }

        // Current topic names only (LLM-10): the picker never offers an old name, and this keeps it so.
        let cleanedSubCategories = SubscriptionsConfig.canonicalTopics(subCategories.compactMap { $0.trimmedNonEmpty })
        let cleanedLifeAreas = lifeAreas
            .compactMap { $0.trimmedNonEmpty }

        let previous = profile
        setProfile(profile.updating(
            subscribedSubCategories: Array(Set(cleanedSubCategories)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending },
            subscribedLifeAreas: Array(Set(cleanedLifeAreas)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        ))

        let items = PreferencesMutations.categoryItems(for: cleanedSubCategories)
            + PreferencesMutations.lifeAreaItems(for: cleanedLifeAreas)

        do {
            if !items.isEmpty {
                try await preferencesService.putPreferences(items)
            }
        } catch {
            if APIErrorDebug.httpStatusCode(from: error) == 403 {
                await refreshComplianceStatus()
            }
            setProfile(previous)
            setUserFacingError(
                "Couldn't save your topics.",
                debug: error,
                context: "setInitialPreferences() failed"
            )
            throw error
        }
    }

    /// Subscribes the user to the provided congress member manifest IDs in bulk.
    func subscribeToCongressMembers(manifestIds: [String]) async throws {
        let cleaned = manifestIds
            .compactMap { $0.trimmedNonEmpty }

        guard !cleaned.isEmpty else { return }

        let newUUIDs = cleaned.map { UUID.deterministic(from: $0) }
        let previous = profile

        let next = Array(Set(profile.subscribedMemberIDs).union(newUUIDs)).sorted { $0.uuidString < $1.uuidString }
        setProfile(profile.updating(subscribedMemberIDs: next))

        let items = PreferencesMutations.congressMemberItems(values: cleaned)

        do {
            try await preferencesService.putPreferences(items)
        } catch {
            setProfile(previous)
            setUserFacingError(
                "Couldn't follow those members.",
                debug: error,
                context: "subscribeToCongressMembers() failed"
            )
            throw error
        }
    }

    // MARK: - Follow mutations (optimistic + backend sync)

    /// Replaces the followed topics and life areas (the topic picker's Save, spec D 2.5.7): adds,
    /// then deletes, each list's difference from the profile, and restores both on any failure.
    ///
    /// Names are compared as current names (LLM-10), so a legacy name still in the profile is never
    /// sent in a DELETE: the server deletes the old and the new row for either name, which would
    /// remove the topic just followed.
    func updateFollowedTopics(topics: [String], lifeAreas: [String]) async throws {
        guard canSaveFollowedTopics else {
            await refreshComplianceStatus()
            throw ValidationError.userWritesNotAllowed
        }

        let byName: (String, String) -> Bool = { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        let previousTopics = SubscriptionsConfig.canonicalTopics(profile.subscribedSubCategories)
        let previousLifeAreas = profile.subscribedLifeAreas
        let updatedTopics = SubscriptionsConfig.canonicalTopics(topics.compactMap { $0.trimmedNonEmpty }).sorted(by: byName)
        let updatedLifeAreas = Array(Set(lifeAreas.compactMap { $0.trimmedNonEmpty })).sorted(by: byName)

        let (topicsToAdd, topicsToRemove) = PreferencesMutations.diffStrings(previous: previousTopics, updated: updatedTopics)
        let (areasToAdd, areasToRemove) = PreferencesMutations.diffStrings(previous: previousLifeAreas, updated: updatedLifeAreas)
        let addItems = PreferencesMutations.categoryItems(for: topicsToAdd) + PreferencesMutations.lifeAreaItems(for: areasToAdd)
        let removeItems = PreferencesMutations.categoryItems(for: topicsToRemove) + PreferencesMutations.lifeAreaItems(for: areasToRemove)
        guard !addItems.isEmpty || !removeItems.isEmpty else { return }

        let previous = profile
        setProfile(profile.updating(subscribedSubCategories: updatedTopics, subscribedLifeAreas: updatedLifeAreas))

        do {
            if !addItems.isEmpty {
                try await preferencesService.putPreferences(addItems)
            }
            if !removeItems.isEmpty {
                try await preferencesService.deletePreferences(removeItems)
            }
        } catch {
            if APIErrorDebug.httpStatusCode(from: error) == 403 {
                await refreshComplianceStatus()
            }
            setProfile(profile.updating(
                subscribedSubCategories: previous.subscribedSubCategories,
                subscribedLifeAreas: previous.subscribedLifeAreas
            ))
            setUserFacingError(
                "Couldn't update the topics you follow.",
                debug: error,
                context: "updateFollowedTopics() failed"
            )
            throw error
        }
    }

    /// Replace the subscribed sub-categories with `newSubs` (optimistic + backend sync).
    func updateSubscribedSubCategories(_ newSubs: [String]) {
        Task { await updateSubscribedSubCategoriesAsync(newSubs) }
    }

    private func updateSubscribedSubCategoriesAsync(_ newSubs: [String]) async {
        // Compared as current names (LLM-10): see `updateFollowedTopics`.
        let previous = SubscriptionsConfig.canonicalTopics(profile.subscribedSubCategories)
        let updated = SubscriptionsConfig.canonicalTopics(newSubs)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        setProfile(profile.updating(subscribedSubCategories: updated))

        // Compute diffs: additions and removals
        let (toAdd, toRemove) = PreferencesMutations.diffStrings(previous: previous, updated: updated)

        #if DEBUG
        print("[UserStore] updateSubscribedSubCategoriesAsync() diffs -> toAdd=\(toAdd) toRemove=\(toRemove)")
        #endif

        // Build PreferenceItem payloads
        let addItems = PreferencesMutations.categoryItems(for: toAdd)
        let removeItems = PreferencesMutations.categoryItems(for: toRemove)

        #if DEBUG
        print("[UserStore] updateSubscribedSubCategoriesAsync() prepared payloads -> addItems=\(addItems) removeItems=\(removeItems)")
        #endif
        do {
            // First add new prefs (if any), then delete removed prefs (if any).
            if !addItems.isEmpty {
                #if DEBUG
                print("[UserStore] calling PreferencesService.putPreferences(addItems.count=\(addItems.count))")
                #endif
                try await preferencesService.putPreferences(addItems)
            }

            if !removeItems.isEmpty {
                #if DEBUG
                print("[UserStore] calling PreferencesService.deletePreferences(removeItems.count=\(removeItems.count))")
                #endif
                try await preferencesService.deletePreferences(removeItems)
            }
        } catch {
            // rollback on any failure
            setProfile(profile.updating(subscribedSubCategories: previous))
            setUserFacingError(
                "Couldn't update the topics you follow.",
                debug: error,
                context: "updateSubscribedSubCategoriesAsync() failed"
            )
        }
    }

    /// Replace the subscribed life areas with `newAreas` (optimistic + backend sync).
    func updateSubscribedLifeAreas(_ newAreas: [String]) {
        Task { await updateSubscribedLifeAreasAsync(newAreas) }
    }

    private func updateSubscribedLifeAreasAsync(_ newAreas: [String]) async {
        let previous = profile.subscribedLifeAreas
        let updated = newAreas.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        setProfile(profile.updating(subscribedLifeAreas: updated))

        // Compute diffs: additions and removals
        let (toAdd, toRemove) = PreferencesMutations.diffStrings(previous: previous, updated: updated)

        #if DEBUG
        print("[UserStore] updateSubscribedLifeAreasAsync() diffs -> toAdd=\(toAdd) toRemove=\(toRemove)")
        #endif

        // Build PreferenceItem payloads
        let addItems = PreferencesMutations.lifeAreaItems(for: toAdd)
        let removeItems = PreferencesMutations.lifeAreaItems(for: toRemove)

        #if DEBUG
        print("[UserStore] updateSubscribedLifeAreasAsync() prepared payloads -> addItems=\(addItems) removeItems=\(removeItems)")
        #endif

        do {
            if !addItems.isEmpty {
                #if DEBUG
                print("[UserStore] calling PreferencesService.putPreferences(addItems.count=\(addItems.count))")
                #endif
                try await preferencesService.putPreferences(addItems)
            }

            if !removeItems.isEmpty {
                #if DEBUG
                print("[UserStore] calling PreferencesService.deletePreferences(removeItems.count=\(removeItems.count))")
                #endif
                try await preferencesService.deletePreferences(removeItems)
            }
        } catch {
            // rollback on any failure
            setProfile(profile.updating(subscribedLifeAreas: previous))
            setUserFacingError(
                "Couldn't update the life areas you follow.",
                debug: error,
                context: "updateSubscribedLifeAreasAsync() failed"
            )
        }
    }

    func updateSelectedBillContentTypes(_ newTypes: [BillContentTypePreference]) {
        Task { await updateSelectedBillContentTypesAsync(newTypes) }
    }

    private func updateSelectedBillContentTypesAsync(_ newTypes: [BillContentTypePreference]) async {
        let allTypes = Set(BillContentTypePreference.allCases)
        let cleanedSet = Set(newTypes)
        guard !cleanedSet.isEmpty else { return }

        let previous = profile.selectedBillContentTypes
        let explicitSelection = cleanedSet == allTypes
            ? []
            : Array(cleanedSet).sorted { $0.sortOrder < $1.sortOrder }

        setProfile(profile.updating(selectedBillContentTypes: explicitSelection))

        let (toAddRaw, toRemoveRaw) = PreferencesMutations.diffStrings(
            previous: previous.map(\.rawValue),
            updated: explicitSelection.map(\.rawValue)
        )

        let addItems = PreferencesMutations.contentTypeItems(
            for: toAddRaw.compactMap(BillContentTypePreference.init(rawValue:))
        )
        let removeItems = PreferencesMutations.contentTypeItems(
            for: toRemoveRaw.compactMap(BillContentTypePreference.init(rawValue:))
        )

        do {
            if !addItems.isEmpty {
                try await preferencesService.putPreferences(addItems)
            }

            if !removeItems.isEmpty {
                try await preferencesService.deletePreferences(removeItems)
            }
        } catch {
            setProfile(profile.updating(selectedBillContentTypes: previous))
            setUserFacingError(
                "Couldn't update your bill types.",
                debug: error,
                context: "updateSelectedBillContentTypesAsync() failed"
            )
        }
    }


    func removeMember(_ memberId: UUID) {
        Task {
            let manifestId = resolveManifestID(for: memberId)
            await removeMemberAsync(memberId, manifestId: manifestId)
        }
    }

    func toggleMemberSubscription(manifestId: String) {
        Task {
            let uuid = UUID.deterministic(from: manifestId)
            let subscribed = profile.subscribedMemberIDs.contains(uuid)
            await setMemberSubscribedAsync(manifestId: manifestId, subscribed: !subscribed)
        }
    }

    private func removeMemberAsync(_ memberId: UUID, manifestId: String?) async {
        let previous = profile.subscribedMemberIDs
        let updated = profile.subscribedMemberIDs.filter { $0 != memberId }
        setProfile(profile.updating(subscribedMemberIDs: updated))

        do {
            let value = PreferencesMutations.congressMemberItemValue(manifestId: manifestId, uuid: memberId)
            let item = PreferencesMutations.congressMemberItems(values: [value]).first
            #if DEBUG
            print("[UserStore] removeMemberAsync() calling delete for item=\(String(describing: item))")
            #endif
            if let item {
                try await preferencesService.deletePreferences([item])
            }
        } catch {
            setProfile(profile.updating(subscribedMemberIDs: previous))
            setUserFacingError(
                "Couldn't unfollow that member.",
                debug: error,
                context: "removeMemberAsync() failed"
            )
        }
    }

    private func setMemberSubscribedAsync(manifestId: String, subscribed: Bool) async {
        let cleanedManifestId = manifestId.trimmed
        guard !cleanedManifestId.isEmpty else { return }

        let memberUUID = UUID.deterministic(from: cleanedManifestId)
        let previous = profile.subscribedMemberIDs

        let next: [UUID]
        if subscribed {
            next = Array(Set(previous).union([memberUUID])).sorted { $0.uuidString < $1.uuidString }
        } else {
            next = previous.filter { $0 != memberUUID }
        }

        setProfile(profile.updating(subscribedMemberIDs: next))

        let item = PreferencesMutations.congressMemberItems(values: [cleanedManifestId]).first

        do {
            if subscribed {
                if let item {
                    try await preferencesService.putPreferences([item])
                }
            } else {
                if let item {
                    try await preferencesService.deletePreferences([item])
                }
            }
        } catch {
            setProfile(profile.updating(subscribedMemberIDs: previous))
            setUserFacingError(
                "Couldn't update the members you follow.",
                debug: error,
                context: "setMemberSubscribedAsync() failed"
            )
        }
    }

    // MARK: - Watch sync

    /// Add a bill GUID to the backend watchlist (optimistic + backend sync).
    ///
    /// - Parameter rollbackOnFailure:
    ///   When true, restore the previous watch list if backend sync fails.
    ///   Backfill callers can pass false to avoid retry loops when auth/backend is temporarily forbidden.
    func addWatch(guid: String, rollbackOnFailure: Bool = true) {
        addWatches(guids: [guid], rollbackOnFailure: rollbackOnFailure)
    }

    /// Add many bill GUIDs to the backend watchlist in a single request.
    ///
    /// Used by cache backfill so we don't issue one network request per bill.
    func addWatches(guids: [String], rollbackOnFailure: Bool = true) {
        let cleanedUnique = Array(
            Set(
                guids.compactMap { $0.trimmedNonEmpty }
            )
        ).sorted()
        guard !cleanedUnique.isEmpty else { return }

        let previous = profile.watchedBillGUIDs
        let previousSet = Set(previous)
        let toAdd = cleanedUnique.filter { !previousSet.contains($0) }
        guard !toAdd.isEmpty else { return }

        let updated = Array(previousSet.union(toAdd)).sorted()
        setProfile(profile.updating(watchedBillGUIDs: updated))

        Task {
            guard canPerformUserWrites else {
                if rollbackOnFailure {
                    setProfile(profile.updating(watchedBillGUIDs: previous))
                }
                #if DEBUG
                print("[UserStore] addWatches() skipped; user writes are currently ineligible")
                #endif
                return
            }

            do {
                let items = PreferencesMutations.watchItems(for: toAdd)
                try await preferencesService.putPreferences(items)
            } catch {
                if APIErrorDebug.httpStatusCode(from: error) == 403 {
                    await refreshComplianceStatus()
                }
                if rollbackOnFailure {
                    setProfile(profile.updating(watchedBillGUIDs: previous))
                }
                #if DEBUG
                print("[UserStore] addWatches() error -> \(PreferencesService.debugString(for: error))")
                #endif
            }
        }
    }

    /// Remove a bill GUID from the backend watchlist (optimistic + backend sync).
    func removeWatch(guid: String) {
        let cleaned = guid.trimmed
        guard !cleaned.isEmpty else { return }
        guard profile.watchedBillGUIDs.contains(cleaned) else { return }

        let previous = profile.watchedBillGUIDs
        let updated = previous.filter { $0 != cleaned }
        setProfile(profile.updating(watchedBillGUIDs: updated))

        Task {
            do {
                let items = PreferencesMutations.watchItems(for: [cleaned])
                try await preferencesService.deletePreferences(items)
            } catch {
                setProfile(profile.updating(watchedBillGUIDs: previous))
                #if DEBUG
                print("[UserStore] removeWatch() error -> \(PreferencesService.debugString(for: error))")
                #endif
            }
        }
    }

    private func resolveManifestID(for memberId: UUID) -> String? {
        guard let manifest = congressService.cachedCongressMembersManifest(), !manifest.isEmpty else {
            return nil
        }

        return manifest.first(where: { UUID.deterministic(from: $0.id) == memberId })?.id
    }

    private enum ValidationError: UserFacingError {
        case userWritesNotAllowed

        nonisolated var errorDescription: String? {
            switch self {
            case .userWritesNotAllowed:
                return "Confirm your age before changing what you follow."
            }
        }
    }

    private func setUserFacingError(_ message: String, debug error: Error, context: String) {
        errorMessage = message
        #if DEBUG
        print("[UserStore] \(context): \(PreferencesService.debugString(for: error))")
        #endif
    }

}

@MainActor
enum UserLocalDataPurge {
    static func purge(userId: String?, defaults: UserDefaults = .standard) {
        guard let userId = userId.trimmedNonEmpty else {
            clearAllKnownUserData(defaults: defaults)
            return
        }

        UserStore.clearCachedProfile(userId: userId, defaults: defaults)
        defaults.removeObject(forKey: "\(AccountComplianceStorage.cachedAdultStatusKeyPrefix)\(userId)")
        UserDefaultsReadStateStore.clear(scope: .user(userId), defaults: defaults)
        BillsStore.clearCachedBills(scope: userId, defaults: defaults)
        BillVoteCache.clearPersistence(scope: userId, defaults: defaults)
        BillAlertsStore.clearCache(scope: userId, defaults: defaults)
        CivicScoreStore.clearCache(scope: userId, userDefaults: defaults)
        WeeklyDigestStore.clearCache(scope: userId, defaults: defaults)
        clearLegacyUserData(defaults: defaults)
    }

    private static func clearLegacyUserData(defaults: UserDefaults) {
        BillsStore.clearCachedBills(scope: nil, defaults: defaults)
        BillVoteCache.clearLegacyPersistence(defaults: defaults)
        BillAlertsStore.clearLegacyCache(defaults: defaults)
        CivicScoreStore.clearLegacyCache(userDefaults: defaults)
    }

    private static func clearAllKnownUserData(defaults: UserDefaults) {
        UserStore.clearAllCachedProfiles(defaults: defaults)
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(AccountComplianceStorage.cachedAdultStatusKeyPrefix) {
            defaults.removeObject(forKey: key)
        }
        clearLegacyUserData(defaults: defaults)
    }
}

/// Whether a profile needs "Where do you vote?" (spec D 2.5.3). Pure, for `OnboardingGateTests`.
enum OnboardingGate {
    /// True when the profile has no state or no district. Topics, life areas and followed members do
    /// not count: topics are asked after the first vote, and a profile without them gets the starter
    /// feed.
    static func needsLocationSetup(_ profile: UserProfile) -> Bool {
        let stateOk = profile.state.trimmedNonEmpty != nil
        let districtOk = profile.district.trimmedNonEmpty != nil
        return !(stateOk && districtOk)
    }
}

/// On-disk cache of the last known `UserProfile` per user (email, birth year,
/// party, district), kept out of UserDefaults.
///
/// Files live in Application Support, are written with
/// `completeFileProtectionUntilFirstUserAuthentication`, and the directory is
/// excluded from backups because the profile is re-fetched after sign-in.
enum UserProfileDiskCache {
    private static let directoryName = "UserProfileCache"

    static func data(userId: String) -> Data? {
        guard let fileURL = fileURL(userId: userId) else { return nil }
        return try? Data(contentsOf: fileURL)
    }

    static func store(_ data: Data, userId: String) {
        guard let fileURL = fileURL(userId: userId) else { return }
        do {
            try prepareDirectory(at: fileURL.deletingLastPathComponent())
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            AppLog.store.error("UserProfileDiskCache write failed: \(String(describing: error), privacy: .private)")
        }
    }

    static func remove(userId: String) {
        guard let fileURL = fileURL(userId: userId) else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }

    static func removeAll() {
        guard let directory = directoryURL() else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    private static func directoryURL() -> URL? {
        guard let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return supportDirectory.appendingPathComponent(directoryName, isDirectory: true)
    }

    private static func fileURL(userId: String) -> URL? {
        guard let userId = userId.trimmedNonEmpty, let directory = directoryURL() else { return nil }
        return directory
            .appendingPathComponent(safeFileName(for: userId))
            .appendingPathExtension("json")
    }

    private static func prepareDirectory(at url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        var directory = url
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try directory.setResourceValues(resourceValues)
    }

    /// Cognito user ids are UUIDs; anything else is reduced to a safe file name.
    private static func safeFileName(for userId: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let sanitized = String(userId.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return sanitized.isEmpty ? "profile" : sanitized
    }
}
