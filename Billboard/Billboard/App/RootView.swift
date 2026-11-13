import SwiftUI
import Amplify
import Combine
import os

struct RootView: View {
    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var userStore: UserStore
    @AppStorage(AppNotificationStorage.notificationsEnabledKey) private var notificationsEnabled = true
    @State private var userScope: String?
    /// Bumped by the loading screen's Try Again to rerun the signed-in bootstrap.
    @State private var bootstrapAttempt = 0
    /// Where this launch's resubmission of a stored sign-up age answer stands (spec D 2.5.2).
    @State private var adultAnswerRetry: SignedInGate.AdultAnswerRetryState = .notStarted

    /// The signed-in account's email, for the stored sign-up age answer.
    private var signedInEmail: String? {
        userStore.profile.email.trimmedNonEmpty ?? auth.username.trimmedNonEmpty
    }

    private var signedInGate: SignedInGate {
        SignedInGate(
            hasRefreshedOnce: userStore.hasRefreshedOnce,
            requiresAdultAnswer: userStore.requiresAdultAttestation,
            hasStoredAdultAnswer: AdultAnswerStore().hasPendingAnswer(email: signedInEmail),
            adultAnswerRetry: adultAnswerRetry,
            isUnderageBlocked: userStore.isUnderageBlocked,
            shouldShowLocationSetup: userStore.shouldShowOnboarding,
            isCompletingLocationSetup: userStore.isCompletingOnboarding,
            lacksLocation: userStore.lacksLocationAfterRefresh
        )
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Full-screen navy background for loading states and status bar area.
            BillboardColors.navy
                .ignoresSafeArea()

            Group {
                switch auth.status {
            case .loading:
                LaunchLoadingView {
                    Task { await auth.refresh() }
                }
                .task { await auth.refresh() }

            case .signedIn:
                Group {
                    if userScope == nil {
                        // Waiting for Cognito user lookup.
                        LaunchLoadingView { bootstrapAttempt += 1 }
                    } else if let userScope {
                        let screen = signedInGate.screen
                        ZStack {
                            // Mount TabsBar as soon as we know the signed-in scope so the
                            // heavy bill cache restore/load can start while profile refresh
                            // is still in flight. Interaction stays blocked until compliance
                            // and the location setup are done.
                            TabsBar(userScope: userScope, isInteractive: screen == .tabs)
                                .opacity(screen == .tabs ? 1 : 0)
                                .allowsHitTesting(screen == .tabs)
                                .accessibilityHidden(screen != .tabs)

                            switch screen {
                            case .loading:
                                LaunchLoadingView { bootstrapAttempt += 1 }
                            case .ageGate:
                                NavigationStack {
                                    AdultAttestationGateView()
                                }
                            case .ineligible:
                                NavigationStack {
                                    AccountIneligibleView()
                                }
                            case .locationSetup:
                                NavigationStack {
                                    LocationSetupView()
                                }
                            case .tabs:
                                EmptyView()
                            }
                        }
                    }
                }
                .task(id: bootstrapAttempt) {
                    // R1 set this flag to show the age gate after a failed sign-up answer; R2
                    // retries the stored answer instead, so a value left by R1 is dropped.
                    UserDefaults.standard.removeObject(forKey: AccountComplianceStorage.pendingSignupAgeGateKey)

                    // 1. Resolve userScope (fast — usually cached, ~200ms if not).
                    //    Caches are keyed by this scope, so never fall back to a
                    //    shared placeholder: if no per-account id can be found,
                    //    sign out instead.
                    guard let userId = await resolveSignedInUserId() else {
                        guard !Task.isCancelled else { return }
                        AppLog.auth.error("Could not resolve the signed-in user id; signing out rather than sharing a cache scope")
                        await auth.recoverFromInvalidSession(message: "We couldn't load your account. Please sign in again.")
                        return
                    }
                    userScope = userId

                    // Show the last known signed-in snapshot immediately while fresh profile
                    // attributes and preferences load in the background.
                    userStore.prepareForRefreshBootstrap()
                    userStore.hydrateCachedProfileIfAvailable(userId: userId)

                    // Keep APNs registration in sync once we know a signed-in user exists,
                    // but avoid kicking this off from multiple lifecycle hooks.
                    if notificationsEnabled {
                        NotificationCenter.default.post(name: .billboardShouldSyncPushRegistration, object: nil)
                    }

                    // 2. Fetch user attributes + preferences via fast-path
                    //    (skips redundant fetchAuthSession/getCurrentUser calls).
                    let attributes = (try? await Amplify.Auth.fetchUserAttributes()) ?? []
                    await userStore.refresh(userId: userId, attributes: attributes)

                    // 3. A sign-up age answer the server has not recorded yet: resubmit it
                    //    instead of asking again (spec D 2.5.2).
                    await resubmitStoredAdultAnswerIfNeeded()

                    // 4. Best-effort push registration (non-blocking).
                    if notificationsEnabled, userStore.canPerformUserWrites, let token = PushTokenStore.load() {
                        try? await PushRegistrationService().registerDeviceIfSignedIn(apnsTokenHex: token)
                    }
                }
                .onChange(of: auth.status) { _, newStatus in
                    if newStatus != .signedIn {
                        adultAnswerRetry = .notStarted
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .billboardDidRegisterPushToken)) { note in
                    guard let token = note.userInfo?["token"] as? String else { return }
                    PushTokenStore.save(token)
                    guard notificationsEnabled else { return }
                    guard userStore.canPerformUserWrites else { return }

                    // Best-effort immediate registration (only succeeds when signed-in).
                    Task {
                        do {
                            try await PushRegistrationService().registerDeviceIfSignedIn(apnsTokenHex: token)
                        } catch {
                            // Best-effort; errors are logged by PushRegistrationService.
                        }
                    }
                }
                .onChange(of: notificationsEnabled) { _, enabled in
                    guard enabled else { return }
                    NotificationCenter.default.post(name: .billboardShouldSyncPushRegistration, object: nil)
                    guard auth.status == .signedIn else { return }
                    guard userStore.canPerformUserWrites else { return }
                    guard let token = PushTokenStore.load() else { return }

                    Task {
                        do {
                            try await PushRegistrationService().registerDeviceIfSignedIn(apnsTokenHex: token)
                        } catch {
                            // Best-effort; errors are logged by PushRegistrationService.
                        }
                    }
                }
                .onChange(of: userStore.compliance) { _, compliance in
                    // The server has an answer now (from sign-up, a retry or the gate): the stored
                    // sign-up answer is no longer needed.
                    if compliance.adultStatus != .unknown {
                        AdultAnswerStore().clear(email: signedInEmail)
                    }
                }

            case .newPasswordRequired:
                NavigationStack {
                    NewPasswordRequiredView()
                }

            case .signedOut, .error:
                NavigationStack {
                    LoginView()
                }
                .onAppear {
                    userScope = nil
                    adultAnswerRetry = .notStarted
                    userStore.clearForSignOut()
                }
            }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .billboardAuthSessionInvalidated)) { note in
            guard auth.status == .signedIn else { return }
            let message = (note.userInfo?["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedMessage = message?.isEmpty == false
                ? message!
                : "Your session expired. Please sign in again."
            Task {
                await auth.recoverFromInvalidSession(message: resolvedMessage)
            }
        }
        // Controls on the screens before the tabs (sign-in, the age gate, "Where do you vote?") take the
        // app's interactive ink, as the tabs do (`TabsBar`); without it a menu picker drew in system blue.
        // Links and buttons are navy ink app-wide; teal means only Yea.
        .tint(BillboardColors.interactive)
        // The blocking "Update Billboard" alert after a 426 `APP_UPDATE_REQUIRED` or a sign-up refused with it
        // (spec D 2.8.1). Applied once, here, so it covers sign-in, setup and the tabs.
        .appUpdateRequiredAlert()
    }

    /// Resubmits the age answer given at sign-up when the server still has none for this account:
    /// up to three attempts this launch (`AdultAnswerRetry`). The root shows the loading screen
    /// meanwhile, never the age gate. A failure keeps the answer for the next launch.
    private func resubmitStoredAdultAnswerIfNeeded() async {
        guard !Task.isCancelled else { return }
        let email = signedInEmail
        let store = AdultAnswerStore()

        guard userStore.requiresAdultAttestation, store.hasPendingAnswer(email: email) else {
            if userStore.hasLoadedCompliance, userStore.compliance.adultStatus != .unknown {
                store.clear(email: email)
            }
            adultAnswerRetry = .finished
            return
        }

        adultAnswerRetry = .running
        let outcome = await AdultAnswerRetry.run(
            sleep: AdultAnswerRetry.taskSleep,
            isStillNeeded: { userStore.requiresAdultAttestation },
            attempt: { try await userStore.submitAdultAttestation(isAdult: true) }
        )

        switch outcome {
        case .confirmed, .noLongerNeeded:
            if userStore.compliance.adultStatus != .unknown {
                store.clear(email: email)
            }
            adultAnswerRetry = .finished
        case .failed(let attempts):
            AppLog.auth.error("Stored sign-up age answer not accepted after \(attempts, privacy: .public) attempts; retrying next launch")
            adultAnswerRetry = .finished
        case .cancelled:
            // A restarted bootstrap runs it again.
            adultAnswerRetry = .notStarted
        }
    }

    /// The Cognito user id for the signed-in session, retried briefly because the
    /// lookup can fail transiently right after sign-in. Falls back to the username
    /// captured during this session's sign-in (still unique to the account).
    /// Returns nil when neither is available or the task was cancelled.
    private func resolveSignedInUserId() async -> String? {
        let retryDelaysNanoseconds: [UInt64] = [0, 300_000_000, 1_000_000_000]
        for delay in retryDelaysNanoseconds {
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            guard !Task.isCancelled else { return nil }

            do {
                let currentUser = try await Amplify.Auth.getCurrentUser()
                if let userId = currentUser.userId.trimmedNonEmpty {
                    return userId
                }
            } catch {
                AppLog.auth.error("getCurrentUser failed: \(String(describing: error), privacy: .private)")
            }
        }

        return auth.username.trimmedNonEmpty
    }
}

/// What the signed-in root shows over the (always mounted, hidden) tabs. Pure, for
/// `OnboardingGateTests`.
struct SignedInGate: Equatable {
    enum Screen: Equatable {
        /// The first profile refresh has not finished, or a stored sign-up age answer is being
        /// resubmitted.
        case loading
        /// "Confirm your age": only for an account with no answer on the server and none stored on
        /// this device (accounts created before R2, or on another device).
        case ageGate
        /// The account is recorded as under 18, or deleted.
        case ineligible
        /// "Where do you vote?"
        case locationSetup
        case tabs
    }

    enum AdultAnswerRetryState: Equatable {
        case notStarted
        case running
        /// Done for this launch (confirmed, not needed, or failed until the next launch).
        case finished
    }

    var hasRefreshedOnce: Bool
    /// `UserStore.requiresAdultAttestation`: the server reported no age answer.
    var requiresAdultAnswer: Bool
    /// An answer given at sign-up on this device waits for the server (`AdultAnswerStore`).
    var hasStoredAdultAnswer: Bool
    var adultAnswerRetry: AdultAnswerRetryState
    var isUnderageBlocked: Bool
    /// `UserStore.shouldShowOnboarding`: no state or district.
    var shouldShowLocationSetup: Bool
    /// `UserStore.isCompletingOnboarding`: the setup screen holds itself until its Continue.
    var isCompletingLocationSetup: Bool
    /// `UserStore.lacksLocationAfterRefresh`: no state or district, whether or not writes are allowed.
    var lacksLocation: Bool = false

    var screen: Screen {
        guard hasRefreshedOnce else { return .loading }

        if requiresAdultAnswer {
            if !hasStoredAdultAnswer {
                return .ageGate
            }
            // Never ask twice: wait for the stored answer to be resubmitted. If that fails the
            // account carries on without writes and the next launch tries again.
            if adultAnswerRetry != .finished {
                return .loading
            }
        }

        if isUnderageBlocked {
            return .ineligible
        }
        if shouldShowLocationSetup || isCompletingLocationSetup {
            return .locationSetup
        }
        // The stored sign-up answer could not be resent this launch, so writes look disallowed
        // (`shouldShowLocationSetup` is false). The server still accepts this account's writes (it
        // refuses only under-18 and deleted accounts), so a new account still gets "Where do you
        // vote?" and then the tour, instead of tabs with no district.
        if requiresAdultAnswer && hasStoredAdultAnswer && lacksLocation {
            return .locationSetup
        }
        return .tabs
    }
}

/// Cold-start and bootstrap loading state (Civic Record spec 4.2): the wordmark and a white spinner on
/// navy, like the launch screen, then "Still loading…" and Try again after 15 seconds. No teal.
struct LaunchLoadingView: View {
    let onRetry: () -> Void

    @State private var showsSlowLoadingHelp: Bool
    @State private var attempt = 0

    private static let slowLoadingDelayNanoseconds: UInt64 = 15_000_000_000

    /// `showsSlowLoadingHelp` starts the screen in its 15-second state (render tests).
    init(showsSlowLoadingHelp: Bool = false, onRetry: @escaping () -> Void) {
        self.onRetry = onRetry
        _showsSlowLoadingHelp = State(initialValue: showsSlowLoadingHelp)
    }

    var body: some View {
        VStack(spacing: 20) {
            Wordmark(size: .compact)

            ProgressView()
                .tint(BillboardColors.textOnNavy)

            if showsSlowLoadingHelp {
                VStack(spacing: 12) {
                    Text("Still loading…")
                        .textRole(.body)
                        .foregroundStyle(BillboardColors.textOnNavyDim)
                        .multilineTextAlignment(.center)

                    BBActionButton(
                        title: "Try again",
                        action: {
                            showsSlowLoadingHelp = false
                            attempt += 1
                            onRetry()
                        },
                        kind: .primaryOnNavy
                    )
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BillboardColors.navy.ignoresSafeArea())
        .animation(.easeInOut(duration: 0.2), value: showsSlowLoadingHelp)
        .task(id: attempt) {
            guard !showsSlowLoadingHelp else { return }
            try? await Task.sleep(nanoseconds: Self.slowLoadingDelayNanoseconds)
            guard !Task.isCancelled else { return }
            showsSlowLoadingHelp = true
        }
    }
}
