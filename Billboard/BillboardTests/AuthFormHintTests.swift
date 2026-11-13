import XCTest
@testable import Billboard

/// The hint line under each disabled auth button (spec 3.16; project decision of 2026-10-21): Sign in, Forgot
/// password's Send code and Update password, and Set a new password's Update password. Each form's line
/// and its button's enabled state are one `FormButtonState`, so every state that disables the button has
/// the right line, every state that enables it has none, and a busy (loading) button is never enabled.
/// Create account's lines are in `CreateAccountFormTests`; `FirstRunRenderTests` checks each screen's wiring.
@MainActor
final class AuthFormHintTests: XCTestCase {
    private enum Filled { case missing, present }
    private enum NewPassword { case missing, unmet, met }

    /// Typed passwords by whether they meet the pool's requirements (8+ characters, upper and lower case,
    /// a number, a symbol), labelled here rather than by `PasswordPolicy`.
    private static let newPasswords: [(String, NewPassword)] = [
        ("", .missing),
        ("Pl-1", .unmet), ("placeholder-1", .unmet), ("PLACEHOLDER-1", .unmet), ("Placeholder-x", .unmet),
        ("Placeholder1", .unmet), ("placeholder", .unmet),
        ("Placeholder-1", .met), ("Another#Pass2", .met), ("Long enough 9", .met)
    ]

    private static func confirmations(for password: String) -> [String] {
        ["", password, password + "x", "Placeholder-1"]
    }

    // MARK: - Sign in

    func testSignInHintNamesWhatIsMissingAndIsNilExactlyWhenEnabled() {
        let emails: [(String, Filled)] = [("", .missing), ("  ", .missing), ("\n", .missing), ("you", .present), ("you@example.com", .present)]
        let passwords: [(String, Filled)] = [("", .missing), (" ", .present), ("x", .present), ("Your password 1", .present)]

        var seen: Set<String?> = []
        for (email, emailState) in emails {
            for (password, passwordState) in passwords {
                let expected: String?
                switch (emailState, passwordState) {
                case (.missing, .missing): expected = "Add your email and password to continue."
                case (.missing, .present): expected = "Add your email to continue."
                case (.present, .missing): expected = "Add your password to continue."
                case (.present, .present): expected = nil
                }
                let state = "email \(email.debugDescription), password \(password.debugDescription)"
                let button = SignInForm.signInButton(email: email, password: password, isBusy: false)
                XCTAssertEqual(SignInForm.hint(email: email, password: password), expected, state)
                XCTAssertEqual(button, FormButtonState(missing: expected, isBusy: false), state)
                XCTAssertEqual(button.isEnabled, expected == nil, state)
                XCTAssertFalse(SignInForm.signInButton(email: email, password: password, isBusy: true).isEnabled, "busy: \(state)")
                seen.insert(button.missing)
            }
        }
        XCTAssertEqual(seen.count, 4, "\(seen)")
    }

    // MARK: - Forgot password

    func testSendCodeHintNamesTheEmailAndIsNilExactlyWhenEnabled() {
        for email in ["", " ", "\n\t"] {
            let button = ForgotPasswordForm.sendCodeButton(email: email, isBusy: false)
            XCTAssertEqual(button.missing, "Add your email to continue.", email.debugDescription)
            XCTAssertFalse(button.isEnabled)
        }
        for email in ["you", "you@example.com", " you@example.com "] {
            XCTAssertNil(ForgotPasswordForm.requestHint(email: email), email)
            XCTAssertTrue(ForgotPasswordForm.sendCodeButton(email: email, isBusy: false).isEnabled, email)
            XCTAssertFalse(ForgotPasswordForm.sendCodeButton(email: email, isBusy: true).isEnabled, email)
        }
    }

    /// With the code missing, the line names the code and whatever the new password still needs, in one line
    /// (the "Add your street address, a city and a state to continue." pattern); with the code in, it is Set
    /// a new password's line.
    func testUpdatePasswordHintWalksTheCodeStepAndIsNilExactlyWhenEnabled() {
        let codes: [(String, Filled)] = [("", .missing), ("  ", .missing), ("123456", .present), (" 123456 ", .present)]

        var seen: Set<String?> = []
        var count = 0
        for (code, codeState) in codes {
            for (password, passwordState) in Self.newPasswords {
                for confirmation in Self.confirmations(for: password) {
                    // What the new password still needs, if anything, in Set a new password's words.
                    let passwordLine: String?
                    if passwordState == .missing {
                        passwordLine = "Add a new password to continue."
                    } else if passwordState == .unmet {
                        passwordLine = "Use a password that meets the requirements above to continue."
                    } else if confirmation.isEmpty {
                        passwordLine = "Confirm your new password to continue."
                    } else if confirmation != password {
                        passwordLine = "Make both passwords match to continue."
                    } else {
                        passwordLine = nil
                    }
                    let expected: String?
                    switch (codeState, passwordLine) {
                    case (.present, _):
                        expected = passwordLine
                    case (.missing, nil):
                        expected = "Add the code to continue."
                    case (.missing, "Add a new password to continue."?):
                        expected = "Add the code and a new password to continue."
                    case (.missing, let line?):
                        // "Use a password …" becomes "Add the code and use a password …".
                        expected = "Add the code and " + line.prefix(1).lowercased() + String(line.dropFirst())
                    }

                    let state = "code \(code.debugDescription), password \(password.debugDescription), "
                        + "confirmation \(confirmation.debugDescription)"
                    let hint = ForgotPasswordForm.confirmHint(code: code, newPassword: password, confirmPassword: confirmation)
                    let button = ForgotPasswordForm.updatePasswordButton(
                        code: code,
                        newPassword: password,
                        confirmPassword: confirmation,
                        isBusy: false
                    )
                    XCTAssertEqual(hint, expected, state)
                    XCTAssertEqual(button, FormButtonState(missing: expected, isBusy: false), state)
                    XCTAssertEqual(button.isEnabled, expected == nil, "hint nil <=> enabled: \(state)")
                    XCTAssertFalse(
                        ForgotPasswordForm.updatePasswordButton(
                            code: code,
                            newPassword: password,
                            confirmPassword: confirmation,
                            isBusy: true
                        ).isEnabled,
                        "busy: \(state)"
                    )
                    seen.insert(hint)
                    count += 1
                }
            }
        }
        XCTAssertEqual(count, codes.count * Self.newPasswords.count * 4)
        XCTAssertEqual(seen.count, 10, "every line and the enabled state are reached: \(seen)")
        for line in [
            "Add the code and a new password to continue.",
            "Add the code and use a password that meets the requirements above to continue.",
            "Add the code and confirm your new password to continue.",
            "Add the code and make both passwords match to continue.",
            "Add the code to continue."
        ] {
            XCTAssertTrue(seen.contains(line), line)
        }
    }

    // MARK: - Set a new password

    func testSetANewPasswordHintIsNilExactlyWhenEnabled() {
        var seen: Set<String?> = []
        for (password, passwordState) in Self.newPasswords {
            for confirmation in Self.confirmations(for: password) {
                let expected: String?
                switch passwordState {
                case .missing:
                    expected = "Add a new password to continue."
                case .unmet:
                    expected = "Use a password that meets the requirements above to continue."
                case .met where confirmation.isEmpty:
                    expected = "Confirm your new password to continue."
                case .met where confirmation != password:
                    expected = "Make both passwords match to continue."
                case .met:
                    expected = nil
                }

                let state = "password \(password.debugDescription), confirmation \(confirmation.debugDescription)"
                let hint = NewPasswordForm.hint(newPassword: password, confirmPassword: confirmation)
                let button = NewPasswordForm.updatePasswordButton(newPassword: password, confirmPassword: confirmation, isBusy: false)
                XCTAssertEqual(hint, expected, state)
                XCTAssertEqual(button, FormButtonState(missing: expected, isBusy: false), state)
                XCTAssertEqual(button.isEnabled, expected == nil, "hint nil <=> enabled: \(state)")
                XCTAssertFalse(
                    NewPasswordForm.updatePasswordButton(newPassword: password, confirmPassword: confirmation, isBusy: true).isEnabled,
                    "busy: \(state)"
                )
                seen.insert(hint)
            }
        }
        XCTAssertEqual(seen.count, 5, "every line and the enabled state are reached: \(seen)")
    }

    // MARK: - Shared

    /// The requirements line follows `PasswordRequirementsHint`: a password it calls met never gets the
    /// requirements line, and one it still lists rules for always does.
    func testRequirementsLineAgreesWithThePasswordHelperText() {
        for (password, _) in Self.newPasswords where !password.isEmpty {
            let helper = PasswordRequirementsHint(password: password)
            let line = NewPasswordForm.hint(newPassword: password, confirmPassword: password)
            if helper.isMet {
                XCTAssertNil(line, password)
            } else {
                XCTAssertEqual(line, NewPasswordHints.unmetRequirements, password)
                XCTAssertTrue(helper.text.hasPrefix("Still needed: "), helper.text)
            }
        }
        XCTAssertEqual(PasswordRequirementsHint(password: "Placeholder-1").text, "Password meets the requirements.")
    }

    /// The length rule is never stricter than the pool, however Cognito counts characters: it counts UTF-16
    /// code units, never fewer than the code points or the characters on screen. A password with accents typed
    /// as combining marks, or with a skin-tone emoji, is not held back by a button the pool would let through.
    func testLengthRuleIsNeverStricterThanThePool() {
        // 7 characters on screen, 10 code points, 12 UTF-16 units: 8 or more however the pool counts.
        let combining = "Ab1!" + "e\u{301}" + "e\u{301}" + "\u{1F44D}\u{1F3FD}"
        XCTAssertEqual(combining.count, 7)
        XCTAssertEqual(combining.unicodeScalars.count, 10)
        XCTAssertTrue(PasswordPolicy.isSatisfied(.length, by: combining))
        XCTAssertEqual(PasswordPolicy.unmetRules(in: combining), [])
        XCTAssertEqual(PasswordRequirementsHint(password: combining).text, "Password meets the requirements.")
        XCTAssertNil(NewPasswordForm.hint(newPassword: combining, confirmPassword: combining))
        XCTAssertTrue(
            CreateAccountForm.createAccountButton(
                email: "you@example.com",
                password: combining,
                confirmPassword: combining,
                isAdultConfirmed: true,
                isBusy: false
            ).isEnabled
        )

        for password in [combining, "Placeholder-1", "Ab1!\u{1F600}", "P\u{E4}ssw\u{F6}rt-1", "Pa\u{308}ssword-1"] {
            XCTAssertGreaterThanOrEqual(password.utf16.count, password.unicodeScalars.count, password)
            XCTAssertGreaterThanOrEqual(password.unicodeScalars.count, password.count, password)
        }

        // Plain short passwords are still short; 8 is enough.
        XCTAssertFalse(PasswordPolicy.isSatisfied(.length, by: "Ab1!xyz"))
        XCTAssertTrue(PasswordPolicy.isSatisfied(.length, by: "Ab1!wxyz"))
        XCTAssertEqual(PasswordRequirementsHint(password: "Ab1!xyz").text, "Still needed: 8+ characters.")
    }

    /// Every line says what to do, in plain words and without blame (spec Appendix A), and ends the way
    /// "Add your street address, city, state and ZIP to continue." does.
    func testEveryLineSaysWhatToDo() {
        let lines = [
            SignInForm.missingBoth, SignInForm.missingEmail, SignInForm.missingPassword,
            ForgotPasswordForm.missingEmail, ForgotPasswordForm.missingCode, ForgotPasswordForm.missingCodeAndPassword,
            ForgotPasswordForm.missingCodeAndRequirements, ForgotPasswordForm.missingCodeAndConfirmation,
            ForgotPasswordForm.missingCodeAndMatch,
            NewPasswordForm.missingPassword, NewPasswordForm.missingConfirmation,
            NewPasswordHints.unmetRequirements, NewPasswordHints.mismatch,
            CreateAccountForm.missingEmailAndPassword, CreateAccountForm.missingEmail, CreateAccountForm.incompleteEmail,
            CreateAccountForm.missingPassword, CreateAccountForm.missingConfirmation, CreateAccountForm.adultRequiredHint,
            CreateAccountForm.missingCode
        ]
        for line in lines {
            XCTAssertTrue(["Add ", "Use ", "Confirm ", "Make "].contains { line.hasPrefix($0) }, line)
            XCTAssertTrue(line.hasSuffix(" to continue."), line)
            for word in ["invalid", "error", "wrong", "incorrect", "failed", "must", "required", "please"] {
                XCTAssertFalse(line.lowercased().contains(word), "\(line): \(word)")
            }
        }
    }
}
