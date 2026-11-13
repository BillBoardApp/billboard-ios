import SwiftUI

/// "Confirm your age" (spec D 2.5.2). Shown only for an account with no age answer on the server
/// and none stored on this device: accounts created before R2, or created on another device whose
/// answer never reached the server. New accounts answer once, on Create account.
struct AdultAttestationGateView: View {
    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var userStore: UserStore

    @State private var isBusy: Bool = false
    @State private var errorMessage: String?
    @State private var isConfirmingUnder18: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BillboardStyle.Space.l) {
                Text("Confirm your age")
                    .textRole(.title)
                    .foregroundStyle(BillboardColors.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)

                Text("Billboard is for people 18 and older.")
                    .textRole(.body)
                    .foregroundStyle(BillboardColors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                if let errorMessage {
                    RecordErrorText(errorMessage)
                }

                BBActionButton(
                    title: "I'm 18 or older",
                    action: { Task { await submit(isAdult: true) } },
                    isEnabled: !isBusy,
                    isLoading: isBusy
                )
                .accessibilityIdentifier("ageGate.adult")

                // Each text button stands on its own full-width 44 pt row (spec 2.8): the style's 44 pt target
                // does not add height, so stacked bare they would overlap, and "I'm under 18" can't be undone.
                VStack(spacing: 0) {
                    Button("I'm under 18") {
                        isConfirmingUnder18 = true
                    }
                    .buttonStyle(BillboardButtonStyle(kind: .destructive))
                    .disabled(isBusy)
                    .accessibilityIdentifier("ageGate.under18")
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .confirmationDialog(
                        "Confirm you're under 18?",
                        isPresented: $isConfirmingUnder18,
                        titleVisibility: .visible
                    ) {
                        Button("I'm under 18", role: .destructive) {
                            Task { await submit(isAdult: false) }
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("This account won't be able to vote or use Billboard, and you can't change this answer later.")
                    }

                    Button("Sign out") {
                        Task { await auth.signOut() }
                    }
                    .buttonStyle(BillboardButtonStyle(kind: .textButton))
                    .disabled(isBusy)
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .frame(maxWidth: .infinity)
            }
            // The 20 pt gutter of the screens before the tabs (spec 4.14).
            .padding(.horizontal, BillboardStyle.Space.xl)
            .padding(.vertical, BillboardStyle.Space.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .billboardBackground()
        .preTabBar()
    }

    @MainActor
    private func submit(isAdult: Bool) async {
        errorMessage = nil
        isBusy = true
        defer { isBusy = false }

        do {
            try await userStore.submitAdultAttestation(isAdult: isAdult)
            await userStore.refreshComplianceStatus()
        } catch {
            errorMessage = AuthErrorMessages.message(for: error, context: .ageAttestation)
        }
    }
}

/// "This account can't use Billboard" (spec 4.15): the title, why, then the destructive capsule "Delete
/// account and data" (`danger` fill) and the primary "Sign out" 12 pt under it.
struct AccountIneligibleView: View {
    @EnvironmentObject private var auth: AuthManager

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BillboardStyle.Space.l) {
                Text("This account can't use Billboard")
                    .textRole(.title)
                    .foregroundStyle(BillboardColors.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)

                Text("This account is recorded as under 18, so it can't use Billboard.")
                    .textRole(.body)
                    .foregroundStyle(BillboardColors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: BillboardStyle.Space.m) {
                    NavigationLink(DeleteAccountCopy.buttonTitle) {
                        DeleteAccountDataView()
                    }
                    .buttonStyle(BillboardButtonStyle(kind: .destructiveFill))
                    .accessibilityIdentifier("ineligible.deleteAccount")

                    BBActionButton(
                        title: "Sign out",
                        action: { Task { await auth.signOut() } }
                    )
                }
            }
            // The 20 pt gutter of the screens before the tabs (spec 4.15).
            .padding(.horizontal, BillboardStyle.Space.xl)
            .padding(.vertical, BillboardStyle.Space.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .billboardBackground()
        .preTabBar()
    }
}
