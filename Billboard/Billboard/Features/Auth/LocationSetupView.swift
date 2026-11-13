import SwiftUI

/// First-run "Where do you vote?" (spec D 2.5.3), shown by `RootView` while the profile has no
/// state or district. It replaces R1's `OnboardingView`: no topics, party or life areas here (topics
/// are asked after the first vote).
///
/// The screen holds itself (`UserStore.isCompletingOnboarding`) from the moment it appears until
/// Continue, because the profile has a district as soon as it is saved and the success panel still
/// has to show. Saving the district also asks for the tour, which starts once the tabs are usable.
struct LocationSetupView: View {
    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var userStore: UserStore
    @AppStorage(ProductTutorialStorage.pendingAutoShowKey) private var shouldAutoShowTutorial = false

    var body: some View {
        LocationEditorView(
            context: .setup,
            // A plain text button at the end of the content (Civic Record spec 4.16), not a slab in a
            // safe-area inset.
            onSignOut: {
                userStore.setCompletingOnboarding(false)
                Task { await auth.signOut() }
            },
            isSignOutDisabled: auth.isBusy,
            onSaved: { _ in
                // A new account's district is set: show the tour once the tabs appear, even if the
                // app is closed on the success panel.
                shouldAutoShowTutorial = true
            },
            onDone: { _ in
                userStore.setCompletingOnboarding(false)
            }
        )
        .preTabBar()
        .task {
            // Hold the screen through the success panel (see the type's note).
            userStore.setCompletingOnboarding(true)
            await userStore.refreshComplianceStatus()
        }
        .onDisappear {
            // Replaced by another root screen (signed out, or a compliance gate): stop holding.
            userStore.setCompletingOnboarding(false)
        }
    }
}
