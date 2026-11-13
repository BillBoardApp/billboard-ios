import Amplify
import SwiftUI

struct ForgotPasswordView: View {
    @EnvironmentObject private var auth: AuthManager
    @Environment(\.dismiss) private var dismiss

    @State private var email: String

    @State private var confirmationCode: String
    @State private var newPassword: String
    @State private var confirmNewPassword: String

    @State private var isBusy: Bool = false
    @State private var errorMessage: String?
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case email
        case code
        case newPassword
        case confirmNewPassword
    }

    enum Step: Equatable {
        case request
        case confirm(details: AuthCodeDeliveryDetails?)
        case done
    }

    @State private var step: Step

    /// Starts on `step` with these values (render tests); the app opens "Reset password" empty.
    init(
        step: Step = .request,
        email: String = "",
        code: String = "",
        newPassword: String = "",
        confirmNewPassword: String = ""
    ) {
        _step = State(initialValue: step)
        _email = State(initialValue: email)
        _confirmationCode = State(initialValue: code)
        _newPassword = State(initialValue: newPassword)
        _confirmNewPassword = State(initialValue: confirmNewPassword)
    }

    private var sendCodeButton: FormButtonState {
        ForgotPasswordForm.sendCodeButton(email: email, isBusy: isBusy)
    }

    private var updatePasswordButton: FormButtonState {
        ForgotPasswordForm.updatePasswordButton(
            code: confirmationCode,
            newPassword: newPassword,
            confirmPassword: confirmNewPassword,
            isBusy: isBusy
        )
    }

    private var showsPasswordMismatch: Bool {
        !confirmNewPassword.isEmpty && newPassword != confirmNewPassword
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BillboardStyle.Space.l) {
                switch step {
                case .request:
                    title("Reset password")

                    RecordField(
                        label: "Email",
                        text: $email,
                        prompt: "you@example.com",
                        focus: $focusedField,
                        focusValue: .email
                    )
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .onSubmit {
                        guard sendCodeButton.isEnabled else { return }
                        Task { await requestReset() }
                    }

                    BBActionButton(
                        title: "Send code",
                        action: { Task { await requestReset() } },
                        loadingTitle: "Sending…",
                        state: sendCodeButton
                    )

                case .confirm:
                    title("Enter code")

                    // Same copy whether or not the email has an account.
                    Text(AuthErrorMessages.resetCodeSent)
                        .textRole(.body)
                        .foregroundStyle(BillboardColors.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)

                    RecordField(
                        label: "Confirmation code",
                        text: $confirmationCode,
                        prompt: "123456",
                        focus: $focusedField,
                        focusValue: .code
                    )
                    .textInputAutocapitalization(.never)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .newPassword }

                    VStack(alignment: .leading, spacing: BillboardStyle.Space.s) {
                        RecordField(
                            label: "New password",
                            text: $newPassword,
                            prompt: "At least 8 characters",
                            isSecure: true,
                            focus: $focusedField,
                            focusValue: .newPassword
                        )
                        .textContentType(.newPassword)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .confirmNewPassword }

                        PasswordRequirementsHint(password: newPassword)
                    }

                    RecordField(
                        label: "Confirm new password",
                        text: $confirmNewPassword,
                        prompt: "Type it again",
                        isSecure: true,
                        errorMessage: showsPasswordMismatch ? PasswordMismatchHint.message : nil,
                        focus: $focusedField,
                        focusValue: .confirmNewPassword
                    )
                    .textContentType(.newPassword)
                    .submitLabel(.go)
                    .onSubmit {
                        focusedField = nil
                        guard updatePasswordButton.isEnabled else { return }
                        Task { await confirmReset() }
                    }

                    BBActionButton(
                        title: "Update password",
                        action: { Task { await confirmReset() } },
                        loadingTitle: "Updating…",
                        state: updatePasswordButton
                    )

                case .done:
                    title("Password updated")

                    Text("You can sign in with your new password.")
                        .textRole(.body)
                        .foregroundStyle(BillboardColors.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)

                    BBActionButton(
                        title: "Back to sign in",
                        action: { dismiss() }
                    )
                }

                if let errorMessage {
                    RecordErrorText(errorMessage)
                }
            }
            // The 20 pt gutter of the screens before the tabs (spec 4.10).
            .padding(.horizontal, BillboardStyle.Space.xl)
            .padding(.vertical, BillboardStyle.Space.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollDismissesKeyboard(.interactively)
        .billboardBackground()
        .preTabBar()
    }

    /// A step's title in the `title` role (spec 4.12).
    private func title(_ text: String) -> some View {
        Text(text)
            .textRole(.title)
            .foregroundStyle(BillboardColors.primaryText)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }

    @MainActor
    private func requestReset() async {
        errorMessage = nil
        isBusy = true
        defer { isBusy = false }

        let trimmedUsername = email.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let result = try await auth.resetPassword(username: trimmedUsername)
            switch result.nextStep {
            case .confirmResetPasswordWithCode(let details, _):
                step = .confirm(details: details)
            case .done:
                step = .done
            }
        } catch {
            if AuthErrorMessages.isUnknownAccountForPasswordReset(error) {
                // Continue exactly as if a code had been sent, so this screen
                // never reveals whether an account exists for the email.
                step = .confirm(details: nil)
            } else {
                errorMessage = AuthErrorMessages.message(for: error, context: .resetPassword)
            }
        }
    }

    @MainActor
    private func confirmReset() async {
        errorMessage = nil
        isBusy = true
        defer { isBusy = false }

        let trimmedUsername = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCode = confirmationCode.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            try await auth.confirmResetPassword(username: trimmedUsername, newPassword: newPassword, code: trimmedCode)
            step = .done
        } catch {
            errorMessage = AuthErrorMessages.message(for: error, context: .confirmResetPassword)
        }
    }
}

/// When Forgot password's buttons are enabled, and what their hint lines say while they are not (spec 3.16).
/// Pure, for tests: each button is enabled exactly when its hint is nil and nothing is in progress
/// (`FormButtonState`).
enum ForgotPasswordForm {
    static let missingEmail = "Add your email to continue."
    static let missingCode = "Add the code to continue."
    /// With the code missing, the line names the code and what the new password still needs, as one line
    /// (the pattern of "Add your street address, a city and a state to continue.").
    static let missingCodeAndPassword = "Add the code and a new password to continue."
    static let missingCodeAndRequirements = "Add the code and use a password that meets the requirements above to continue."
    static let missingCodeAndConfirmation = "Add the code and confirm your new password to continue."
    static let missingCodeAndMatch = "Add the code and make both passwords match to continue."

    /// What a disabled Send code says is missing; nil when the email is filled in.
    static func requestHint(email: String) -> String? {
        email.trimmed.isEmpty ? missingEmail : nil
    }

    static func sendCodeButton(email: String, isBusy: Bool) -> FormButtonState {
        FormButtonState(missing: requestHint(email: email), isBusy: isBusy)
    }

    /// What a disabled Update password ("Enter code") says is missing. While the code is missing, the line
    /// names it together with whatever the new password still needs; once the code is in, it is Set a new
    /// password's line (`NewPasswordForm`). Nil when the code is filled in and the new password meets the
    /// requirements and matches its confirmation.
    static func confirmHint(code: String, newPassword: String, confirmPassword: String) -> String? {
        guard code.trimmed.isEmpty else {
            return NewPasswordForm.hint(newPassword: newPassword, confirmPassword: confirmPassword)
        }
        switch NewPasswordHints.need(password: newPassword, confirmation: confirmPassword) {
        case nil: return missingCode
        case .password: return missingCodeAndPassword
        case .requirements: return missingCodeAndRequirements
        case .confirmation: return missingCodeAndConfirmation
        case .match: return missingCodeAndMatch
        }
    }

    static func updatePasswordButton(code: String, newPassword: String, confirmPassword: String, isBusy: Bool) -> FormButtonState {
        FormButtonState(
            missing: confirmHint(code: code, newPassword: newPassword, confirmPassword: confirmPassword),
            isBusy: isBusy
        )
    }
}
