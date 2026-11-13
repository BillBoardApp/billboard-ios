import SwiftUI

/// Copy of the delete screen (spec D 2.4.2). Pure, for tests.
enum DeleteAccountCopy {
    static let warning = "Deleting your account removes your Billboard data. This can't be undone."
    static let confirmWord = "DELETE"
    static let buttonTitle = "Delete account and data"
    /// The screen's inline title: the same words as the Settings row and the button (spec 4.6, 4.68).
    static let screenTitle = "Delete account and data"

    /// The button turns on only once the confirmation word is typed (any case, surrounding spaces ignored).
    static func isConfirmed(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == confirmWord
    }
}

/// Delete account and data (spec D 2.4.2; Civic Record spec 4.71), reached from Profile > Settings > Delete
/// account and data: a settings form on paper (spec 3.25) with the warning, the "Type DELETE to confirm."
/// field in the field style, and the destructive button in `danger`, `ink3` while it is disabled, with a
/// spinner and "Deleting…" while it runs. Copy unchanged.
struct DeleteAccountDataView: View {
    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var userStore: UserStore
    @Environment(\.dismiss) private var dismiss

    private enum Field: Hashable {
        case confirm
    }

    @State private var confirmText: String = ""
    @State private var isBusy: Bool = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    @FocusState private var focusedField: Field?

    private var canDelete: Bool {
        !isBusy && DeleteAccountCopy.isConfirmed(confirmText)
    }

    var body: some View {
        Form {
            Section {
                Text(DeleteAccountCopy.warning)
                    .textRole(.body)
                    .foregroundStyle(BillboardColors.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                RecordField(
                    label: "Type DELETE to confirm.",
                    text: $confirmText,
                    prompt: "DELETE",
                    isDisabled: isBusy,
                    identifier: "deleteAccount.confirm",
                    focus: $focusedField,
                    focusValue: .confirm
                )
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled(true)
                .padding(.vertical, BillboardStyle.Space.xs)
            } header: {
                RecordListHeader("Warning")
            }
            .recordListRows()

            Section {
                Button(role: .destructive) {
                    Task { await deleteAccountAndData() }
                } label: {
                    HStack(spacing: BillboardStyle.Space.s) {
                        if isBusy {
                            ProgressView()
                                .tint(BillboardColors.danger)
                                .accessibilityHidden(true)
                        }
                        SettingsRowText(
                            isBusy ? "Deleting…" : DeleteAccountCopy.buttonTitle,
                            color: canDelete || isBusy ? BillboardColors.danger : BillboardColors.dimText
                        )
                    }
                }
                .disabled(!canDelete)
                .accessibilityIdentifier("deleteAccount.submit")
            }
            .recordListRows()

            if let statusMessage {
                Section {
                    SettingsRowText(statusMessage, color: BillboardColors.secondaryText)
                }
                .recordListRows()
            }

            if let errorMessage {
                Section {
                    RecordErrorText(errorMessage, role: .body)
                }
                .recordListRows()
            }
        }
        .recordList()
        .navigationTitle(DeleteAccountCopy.screenTitle)
        .navigationBarTitleDisplayMode(.inline)
        .glassNavigationBar()
    }

    @MainActor
    private func deleteAccountAndData() async {
        errorMessage = nil
        statusMessage = "Deleting your data…"
        isBusy = true
        defer { isBusy = false }

        do {
            let snapshot = try await AccountComplianceService.deleteAccountData()
            statusMessage = "Finishing up…"

            // A "completed" response means the backend has already deleted the
            // Cognito user, so polling with this session could fail a token
            // refresh and report a finished deletion as an error. Only poll
            // when another request's deletion is still running.
            var completed = snapshot.deletionStatus == .completed
            for _ in 0..<20 where !completed {
                let status = try await AccountComplianceService.fetchAccountDataStatus()
                if status.deletionStatus == .completed {
                    completed = true
                    break
                }
                if status.deletionStatus == .failed {
                    throw AccountComplianceService.ServiceError.accountDeletionFailed(
                        status.deletionError ?? "Account data deletion failed."
                    )
                }
                try await Task.sleep(nanoseconds: 500_000_000)
            }

            if !completed {
                statusMessage = nil
                errorMessage = "This is taking longer than usual. Your data is still being deleted. Check back in a few minutes."
                return
            }

            // The backend deletes the Cognito user as its last step, so this
            // usually finds the user already gone; AuthManager treats that as
            // success and clears the local session.
            try await auth.deleteCurrentAccount()
            auth.setSignedOutLocally(userId: userStore.profile.id)
            userStore.clearForSignOut()
            dismiss()
        } catch {
            statusMessage = nil
            errorMessage = AuthErrorMessages.message(for: error, context: .deleteAccount)
        }
    }
}
