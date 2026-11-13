import Amplify
import os
import SwiftUI

/// Create account (spec D 2.5.2): what Billboard is, the sign-up form with the age asked once (a
/// required "I'm 18 or older" toggle), the email code, then the first sign-in.
///
/// The age answer is stored on the device (`AdultAnswerStore`) when the form is submitted and sent
/// after the first sign-in. If that send fails, the signed-in bootstrap (`RootView`) resends it on
/// this and later launches; the age gate is never shown for it.
struct CreateAccountView: View {
    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var userStore: UserStore
    @Environment(\.dismiss) private var dismiss

    @State private var email: String
    @State private var password: String
    @State private var confirmPassword: String
    @State private var isAdultConfirmed: Bool

    @State private var confirmationCode: String

    @State private var isBusy: Bool = false
    @State private var errorMessage: String?
    /// Counts the times Confirm or Resend found the sign-up gone (REL-53) and opened the form again: each
    /// scrolls the form down to the expired line under Create account (`restartSignUp`).
    @State private var expiredSignUpRestarts: Int
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case email
        case password
        case confirmPassword
        case code
    }

    enum Step: Equatable {
        case enterDetails
        case confirmCode(details: AuthCodeDeliveryDetails?)
        case done
    }

    /// Where the screen started: Create account, or Sign in for an account whose email was never confirmed
    /// (UX-39), which opens straight on the code step.
    enum Origin: Equatable {
        case signUp
        case signIn
    }

    /// The code step's line when sign-in opened it and no code has been sent from this screen yet.
    static func unconfirmedSignInMessage(email: String) -> String {
        "Your email isn't confirmed yet. Enter the code we emailed to \(email) when you signed up. If you can't find it, or it has expired, tap Resend code."
    }

    /// The three lines under the title (spec D 2.5.2).
    static let valueBullets = [
        "Plain-English summaries of bills in Congress, written with AI from the official text",
        "Vote Yea, Nay or Abstain on any bill",
        // Other users' votes show only after the user votes (INT-11).
        "See how other users voted after you vote, and how your representatives voted"
    ]

    @State private var step: Step
    private let origin: Origin

    /// Starts on `step` with these values (render tests); the app opens the empty form with the switch off.
    /// `signUpExpired` opens the form as `restartSignUp` leaves it: the expired line, scrolled into view.
    init(
        step: Step = .enterDetails,
        origin: Origin = .signUp,
        email: String = "",
        password: String = "",
        confirmPassword: String = "",
        isAdultConfirmed: Bool = false,
        code: String = "",
        signUpExpired: Bool = false
    ) {
        _step = State(initialValue: step)
        self.origin = origin
        _email = State(initialValue: email)
        _password = State(initialValue: password)
        _confirmPassword = State(initialValue: confirmPassword)
        _isAdultConfirmed = State(initialValue: isAdultConfirmed)
        _confirmationCode = State(initialValue: code)
        _errorMessage = State(initialValue: signUpExpired ? AuthErrorMessages.signUpExpired : nil)
        _expiredSignUpRestarts = State(initialValue: signUpExpired ? 1 : 0)
    }

    /// The error line's scroll target.
    private static let errorLineID = "signup.error"

    /// The code step for an account sign-in found unconfirmed (UX-39): Confirm, then sign in with the password
    /// just typed; Resend code; Back to sign in.
    init(confirming pending: PendingSignUpConfirmation) {
        self.init(step: .confirmCode(details: nil), origin: .signIn, email: pending.email, password: pending.password)
    }

    private var trimmedEmail: String {
        email.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func deliveryMessage(for details: AuthCodeDeliveryDetails) -> String {
        switch details.destination {
        case .email(let destination):
            return "A code was sent to \(destination ?? "your email")."
        case .sms(let destination):
            return "A code was sent via SMS to \(destination ?? "your phone")."
        case .phone(let destination):
            return "A code was sent to \(destination ?? "your phone")."
        case .unknown(let destination):
            return "A code was sent to \(destination ?? "your account destination")."
        }
    }

    private var createAccountButton: FormButtonState {
        CreateAccountForm.createAccountButton(
            email: email,
            password: password,
            confirmPassword: confirmPassword,
            isAdultConfirmed: isAdultConfirmed,
            isBusy: isBusy
        )
    }

    private var confirmButton: FormButtonState {
        CreateAccountForm.confirmButton(code: confirmationCode, isBusy: isBusy)
    }

    private var showsPasswordMismatch: Bool {
        !confirmPassword.isEmpty && password != confirmPassword
    }

    /// The done step's Sign in is Sign in's form with the email kept from sign-up (valid by then).
    private var signInButton: FormButtonState {
        SignInForm.signInButton(email: trimmedEmail, password: password, isBusy: isBusy || auth.isBusy)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: BillboardStyle.Space.l) {
                    switch step {
                    case .enterDetails:
                        Text("Create your account")
                            .textRole(.title)
                            .foregroundStyle(BillboardColors.primaryText)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)

                        // A plain list with dotted rules between the lines (spec 4.11); no check glyphs. The
                        // first line is the approved AI line and the last INT-11's, both word for word.
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(Self.valueBullets.enumerated()), id: \.offset) { index, line in
                                if index > 0 {
                                    DottedRule()
                                }
                                Text(line)
                                    .textRole(.body)
                                    .foregroundStyle(BillboardColors.secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, BillboardStyle.Space.s)
                            }
                        }

                        RecordField(
                            label: "Email",
                            text: $email,
                            prompt: "you@example.com",
                            identifier: "signup.email",
                            focus: $focusedField,
                            focusValue: .email
                        )
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .autocorrectionDisabled()
                        .submitLabel(.next)
                        .onSubmit { focusedField = .password }

                        VStack(alignment: .leading, spacing: BillboardStyle.Space.s) {
                            RecordField(
                                label: "Password",
                                text: $password,
                                prompt: "At least 8 characters",
                                isSecure: true,
                                identifier: "signup.password",
                                focus: $focusedField,
                                focusValue: .password
                            )
                            .textContentType(.newPassword)
                            .submitLabel(.next)
                            .onSubmit { focusedField = .confirmPassword }

                            PasswordRequirementsHint(password: password)
                        }

                        RecordField(
                            label: "Confirm password",
                            text: $confirmPassword,
                            prompt: "Type it again",
                            isSecure: true,
                            errorMessage: showsPasswordMismatch ? PasswordMismatchHint.message : nil,
                            identifier: "signup.confirmPassword",
                            focus: $focusedField,
                            focusValue: .confirmPassword
                        )
                        .textContentType(.newPassword)
                        .submitLabel(.go)
                        .onSubmit(submitDetailsFromKeyboard)

                        AdultConfirmationToggle(isOn: $isAdultConfirmed, isDisabled: isBusy)

                        // The hint line names the first thing still missing, top to bottom.
                        BBActionButton(
                            title: "Create account",
                            action: { Task { await signUp() } },
                            loadingTitle: "Creating…",
                            state: createAccountButton
                        )
                        .accessibilityIdentifier("signup.submit")

                    case .confirmCode(let details):
                        Text("Confirm your account")
                            .textRole(.title)
                            .foregroundStyle(BillboardColors.primaryText)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)

                        if let details {
                            Text(deliveryMessage(for: details))
                                .textRole(.body)
                                .foregroundStyle(BillboardColors.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("signup.code.sent")
                        } else if origin == .signIn {
                            Text(Self.unconfirmedSignInMessage(email: trimmedEmail))
                                .textRole(.body)
                                .foregroundStyle(BillboardColors.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("signup.code.unconfirmed")
                        }

                        RecordField(
                            label: "Confirmation code",
                            text: $confirmationCode,
                            prompt: "123456",
                            identifier: "signup.code",
                            focus: $focusedField,
                            focusValue: .code
                        )
                        .textInputAutocapitalization(.never)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .submitLabel(.go)
                        .onSubmit {
                            guard confirmButton.isEnabled else { return }
                            Task { await confirmSignUp() }
                        }

                        BBActionButton(
                            title: "Confirm",
                            action: { Task { await confirmSignUp() } },
                            loadingTitle: "Confirming…",
                            state: confirmButton
                        )

                        VStack(spacing: 0) {
                            Button("Resend code") {
                                Task { await resendCode() }
                            }
                            .buttonStyle(BillboardButtonStyle(kind: .textLink))
                            .disabled(isBusy)

                            Button("Back to sign in") {
                                dismiss()
                            }
                            .buttonStyle(BillboardButtonStyle(kind: .textLink))
                            .disabled(isBusy)
                        }
                        .frame(maxWidth: .infinity)

                    case .done:
                        Text("Account ready")
                            .textRole(.title)
                            .foregroundStyle(BillboardColors.primaryText)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)

                        Text("Sign in to finish setting up Billboard.")
                            .textRole(.body)
                            .foregroundStyle(BillboardColors.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Email")
                                .textRole(.subheadline)
                                .foregroundStyle(BillboardColors.primaryText)
                                .accessibilityHidden(true)
                            Text(trimmedEmail)
                                .textRole(.body)
                                .foregroundStyle(BillboardColors.primaryText)
                                .modifier(RecordFieldChrome())
                                .accessibilityLabel("Email: \(trimmedEmail)")
                        }

                        RecordField(
                            label: "Password",
                            text: $password,
                            prompt: "Your password",
                            isSecure: true,
                            focus: $focusedField,
                            focusValue: .password
                        )
                        .textContentType(.password)
                        .submitLabel(.go)
                        .onSubmit {
                            guard signInButton.isEnabled else { return }
                            Task { await signInToNewAccount() }
                        }

                        BBActionButton(
                            title: "Sign in",
                            action: { Task { await signInToNewAccount() } },
                            loadingTitle: "Signing in…",
                            state: signInButton
                        )

                        Button("Back to sign in") {
                            dismiss()
                        }
                        .buttonStyle(BillboardButtonStyle(kind: .textLink))
                        .frame(maxWidth: .infinity)
                        .disabled(isBusy)
                    }

                    if let errorMessage {
                        RecordErrorText(errorMessage)
                            .accessibilityIdentifier("signup.error")
                            .id(Self.errorLineID)
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
            // The form opened again after an expired sign-up: down to the expired line under Create account,
            // which is below the fold on every phone (on an iPhone SE, Create account ends at 775 pt of 667).
            .task(id: expiredSignUpRestarts) {
                guard expiredSignUpRestarts > 0 else { return }
                // Once the form has replaced the code step.
                await Task.yield()
                proxy.scrollTo(Self.errorLineID, anchor: .bottom)
            }
        }
    }

    private func submitDetailsFromKeyboard() {
        focusedField = nil
        guard createAccountButton.isEnabled else { return }
        Task { await signUp() }
    }

    @MainActor
    private func signUp() async {
        errorMessage = nil
        isBusy = true
        defer { isBusy = false }

        guard isAdultConfirmed else {
            errorMessage = CreateAccountForm.adultRequiredHint
            return
        }

        // Asked once: kept on the device until the server records it after the first sign-in.
        let answers = AdultAnswerStore()
        answers.saveAdultAnswer(email: trimmedEmail)

        do {
            let result = try await auth.signUp(username: trimmedEmail, password: password)
            switch result.nextStep {
            case .confirmUser(let details, _, _):
                step = .confirmCode(details: details)
            case .completeAutoSignIn, .done:
                // Try to sign in immediately.
                await finalizeNewAccountSignIn()
            }
        } catch {
            // No account was created for this submission.
            answers.clear(email: trimmedEmail)
            errorMessage = AuthErrorMessages.message(for: error, context: .signUp)
        }
    }

    @MainActor
    private func confirmSignUp() async {
        errorMessage = nil
        isBusy = true
        defer { isBusy = false }

        let trimmedCode = confirmationCode.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            let result = try await auth.confirmSignUp(username: trimmedEmail, code: trimmedCode)
            if result.isSignUpComplete {
                await finalizeNewAccountSignIn()
            } else {
                step = .done
            }
        } catch let error where AuthErrorMessages.isUserNotFound(error) {
            restartSignUp()
        } catch {
            errorMessage = AuthErrorMessages.message(for: error, context: .confirmSignUp)
        }
    }

    /// The account behind the code step is gone (an unconfirmed sign-up is deleted after a while, REL-53):
    /// back to the form with the email and password kept, so the person can sign up again. The form scrolls
    /// down to the expired line under Create account, and VoiceOver says it, as it says Resend code's line:
    /// otherwise the long form opened at its top with no reason given.
    @MainActor
    private func restartSignUp() {
        AppLog.auth.info("Code step: the unconfirmed sign-up no longer exists; back to the form")
        confirmationCode = ""
        step = .enterDetails
        errorMessage = AuthErrorMessages.signUpExpired
        expiredSignUpRestarts += 1
        AccessibilityNotification.Announcement(AuthErrorMessages.signUpExpired).post()
    }

    /// Sign-in from the "Account ready" step, keeping the email from sign-up.
    @MainActor
    private func signInToNewAccount() async {
        focusedField = nil
        errorMessage = nil
        isBusy = true
        defer { isBusy = false }

        await finalizeNewAccountSignIn()
    }

    @MainActor
    private func finalizeNewAccountSignIn() async {
        let outcome = await auth.signIn(username: trimmedEmail, password: password)
        if outcome == .needsEmailConfirmation {
            // Cognito still has the email unconfirmed: the code step again, not "Account ready".
            step = .confirmCode(details: nil)
            return
        }
        guard case .signedIn = auth.status else {
            // Keep the email and offer sign-in right here instead of sending
            // the user back to an empty sign-in form.
            step = .done
            if case .error(let message) = auth.status {
                errorMessage = message
            }
            return
        }

        // Send the answer given on the form. On failure the signed-in bootstrap resends the stored
        // answer (up to three times per launch) instead of asking again (spec D 2.5.2).
        let answers = AdultAnswerStore()
        guard answers.hasPendingAnswer(email: trimmedEmail) else {
            dismiss()
            return
        }
        do {
            try await userStore.submitAdultAttestation(isAdult: true)
            answers.clear(email: trimmedEmail)
            await userStore.refreshComplianceStatus()
        } catch {
            AppLog.auth.error("Sign-up age answer not sent yet; the signed-in bootstrap retries it")
        }
        dismiss()
    }

    @MainActor
    private func resendCode() async {
        errorMessage = nil
        isBusy = true
        defer { isBusy = false }

        do {
            let details = try await auth.resendSignUpCode(username: trimmedEmail)
            // Say where the new code went ("A code was sent to y***@e***."); Resend used to give no sign.
            step = .confirmCode(details: details)
            AccessibilityNotification.Announcement(deliveryMessage(for: details)).post()
        } catch let error where AuthErrorMessages.isUserNotFound(error) {
            restartSignUp()
        } catch {
            errorMessage = AuthErrorMessages.message(for: error, context: .resendCode)
        }
    }
}

/// When Create account (and the code step's Confirm) is enabled, and what the hint line under the disabled
/// button says (spec 3.16, 4.11). Pure, for tests: a button is enabled exactly when its hint is nil and
/// nothing is in progress (`FormButtonState`).
enum CreateAccountForm {
    static let missingEmailAndPassword = "Add your email and a password to continue."
    static let missingEmail = "Add your email to continue."
    /// The field's placeholder is the example.
    static let incompleteEmail = "Add your full email, like you@example.com, to continue."
    static let missingPassword = "Add a password to continue."
    /// "Confirm password" is the field's label.
    static let missingConfirmation = "Confirm your password to continue."
    static let adultRequiredHint = "Confirm you're 18 or older to continue."
    static let missingCode = "Add the code to continue."

    /// An address with an "@" and a dot after it; Cognito checks the rest.
    static func isValidEmail(_ email: String) -> Bool {
        let e = email.trimmed
        guard let atIndex = e.firstIndex(of: "@") else { return false }
        return e[e.index(after: atIndex)...].contains(".")
    }

    /// One line naming the first thing still missing. The age line comes first, whatever else is missing, so it is
    /// visible from the start while "I'm 18 or older" is off (project decision, 2026-10-21; spec 4.11). Then, in the order of
    /// the form: the email, the password, its requirements and the confirmation. Nil when the form is complete.
    static func hint(email: String, password: String, confirmPassword: String, isAdultConfirmed: Bool) -> String? {
        guard isAdultConfirmed else { return adultRequiredHint }
        let hasEmail = !email.trimmed.isEmpty
        if !hasEmail, password.isEmpty { return missingEmailAndPassword }
        if !hasEmail { return missingEmail }
        if !isValidEmail(email) { return incompleteEmail }
        switch NewPasswordHints.need(password: password, confirmation: confirmPassword) {
        case .password: return missingPassword
        case .requirements: return NewPasswordHints.unmetRequirements
        case .confirmation: return missingConfirmation
        case .match: return NewPasswordHints.mismatch
        case nil: return nil
        }
    }

    static func createAccountButton(
        email: String,
        password: String,
        confirmPassword: String,
        isAdultConfirmed: Bool,
        isBusy: Bool
    ) -> FormButtonState {
        FormButtonState(
            missing: hint(email: email, password: password, confirmPassword: confirmPassword, isAdultConfirmed: isAdultConfirmed),
            isBusy: isBusy
        )
    }

    /// What the code step's disabled Confirm says is missing; nil when a code is filled in.
    static func codeHint(code: String) -> String? {
        code.trimmed.isEmpty ? missingCode : nil
    }

    static func confirmButton(code: String, isBusy: Bool) -> FormButtonState {
        FormButtonState(missing: codeHint(code: code), isBusy: isBusy)
    }
}

/// The required "I'm 18 or older" row (off by default; spec 4.11). Billboard asks it once, here: a slip with
/// the switch in `controlOn` and the line under it in `caption` `ink2`.
struct AdultConfirmationToggle: View {
    @Binding var isOn: Bool
    var isDisabled = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: BillboardStyle.Radius.slip, style: .continuous)
        VStack(alignment: .leading, spacing: 2) {
            Toggle(isOn: $isOn) {
                Text("I'm 18 or older")
                    .textRole(.body)
                    .foregroundStyle(BillboardColors.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .billboardToggle()
            .frame(minHeight: 44)
            .disabled(isDisabled)
            .accessibilityIdentifier("signup.adult")

            Text("Billboard is for adults 18 and older.")
                .textRole(.caption)
                .foregroundStyle(BillboardColors.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, BillboardStyle.Space.l)
        .padding(.vertical, BillboardStyle.Space.m)
        .background(shape.fill(BillboardColors.cardBackground))
        .overlay(shape.strokeBorder(BillboardColors.separator, lineWidth: 1))
    }
}
