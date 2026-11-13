import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var auth: AuthManager

    @State private var email: String
    @State private var password: String
    /// Set when sign-in finds the account's email unconfirmed: pushes the code step for it (UX-39).
    @State private var pendingConfirmation: PendingSignUpConfirmation?
    @FocusState private var focusedField: Field?

    /// Starts the form with these values (render tests); the app opens it empty.
    init(email: String = "", password: String = "") {
        _email = State(initialValue: email)
        _password = State(initialValue: password)
    }

    private enum Field: Hashable {
        case email
        case password
    }

    /// The value line under the banner (spec D 2.5.2).
    static let headline = "See what Congress is voting on, and vote too."
    static let valueLine = "Plain-English summaries of real bills. Vote Yea, Nay or Abstain, then see how others and your representatives voted."

    private var statusMessage: String? {
        if case .error(let message) = auth.status {
            return message
        }
        return nil
    }

    private var signInButton: FormButtonState {
        SignInForm.signInButton(email: email, password: password, isBusy: auth.isBusy)
    }

    private func signIn() {
        focusedField = nil
        let username = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = password
        Task {
            if await auth.signIn(username: username, password: password) == .needsEmailConfirmation {
                pendingConfirmation = PendingSignUpConfirmation(email: username, password: password)
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BillboardStyle.Space.l) {
                VStack(alignment: .leading, spacing: BillboardStyle.Space.s) {
                    Text(Self.headline)
                        .textRole(.title)
                        .foregroundStyle(BillboardColors.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)

                    // INT-11's line, word for word (pinned by ResultsGateTests).
                    Text(Self.valueLine)
                        .textRole(.body)
                        .foregroundStyle(BillboardColors.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                RecordField(
                    label: "Email",
                    text: $email,
                    prompt: "you@example.com",
                    identifier: "login.email",
                    focus: $focusedField,
                    focusValue: .email
                )
                .textInputAutocapitalization(.never)
                .keyboardType(.emailAddress)
                .textContentType(.emailAddress)
                .autocorrectionDisabled()
                .submitLabel(.next)
                .onSubmit { focusedField = .password }

                RecordField(
                    label: "Password",
                    text: $password,
                    prompt: "Your password",
                    isSecure: true,
                    identifier: "login.password",
                    focus: $focusedField,
                    focusValue: .password
                )
                .textContentType(.password)
                .submitLabel(.go)
                .onSubmit {
                    guard signInButton.isEnabled else { return }
                    signIn()
                }

                if let statusMessage {
                    RecordErrorText(statusMessage)
                        .accessibilityIdentifier("login.error")

                    // A message that sends people to us offers the way there (UX-39).
                    if SignInForm.offersContact(for: statusMessage) {
                        ContactUsButton {
                            Text(ContactUs.title)
                        }
                        .buttonStyle(BillboardButtonStyle(kind: .textLink))
                        .accessibilityIdentifier("login.contactUs")
                    }
                }

                BBActionButton(title: "Sign in", action: signIn, loadingTitle: "Signing in…", state: signInButton)
                .accessibilityIdentifier("login.submit")

                NavigationLink("Forgot password?") {
                    ForgotPasswordView()
                }
                .buttonStyle(BillboardButtonStyle(kind: .textLink))
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("login.forgotPassword")

                HairlineRule()
                    .padding(.vertical, BillboardStyle.Space.xs)

                NavigationLink("Create account") {
                    CreateAccountView()
                }
                .buttonStyle(BillboardButtonStyle(kind: .secondary, fullWidth: true))
                .accessibilityIdentifier("login.createAccount")
            }
            // The 20 pt gutter of the screens before the tabs (spec 4.10).
            .padding(.horizontal, BillboardStyle.Space.xl)
            .padding(.vertical, BillboardStyle.Space.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollDismissesKeyboard(.interactively)
        .billboardBackground()
        .navigationDestination(item: $pendingConfirmation) { pending in
            CreateAccountView(confirming: pending)
        }
        .task {
            // If we land here due to signOut or cold start, keep status in sync.
            if case .loading = auth.status {
                await auth.refresh()
            }
        }
        .preTabBar()
    }
}

/// When Sign in is enabled, and what its hint line says while it is not (spec 3.16). Pure, for tests: the
/// button is enabled exactly when there is no hint and nothing is in progress (`FormButtonState`).
enum SignInForm {
    static let missingBoth = "Add your email and password to continue."
    static let missingEmail = "Add your email to continue."
    static let missingPassword = "Add your password to continue."

    /// What a disabled Sign in says is missing; nil when both fields are filled in.
    static func hint(email: String, password: String) -> String? {
        switch (email.trimmed.isEmpty, password.isEmpty) {
        case (true, true): return missingBoth
        case (true, false): return missingEmail
        case (false, true): return missingPassword
        case (false, false): return nil
        }
    }

    static func signInButton(email: String, password: String, isBusy: Bool) -> FormButtonState {
        FormButtonState(missing: hint(email: email, password: password), isBusy: isBusy)
    }

    /// Whether the line under the form names our contact address, so a Contact us link follows it.
    static func offersContact(for message: String) -> Bool {
        message.contains(ContactUs.address)
    }
}

/// An account sign-in found unconfirmed: the email and the password just typed, so Confirm can finish
/// signing in (UX-39). Kept in memory only, for the pushed code step.
struct PendingSignUpConfirmation: Hashable, Identifiable {
    let email: String
    let password: String

    var id: String { email }
}
