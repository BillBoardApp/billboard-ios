import XCTest
@testable import Billboard

/// Create account asks the age question once, as a required "I'm 18 or older" toggle (spec D 2.5.2):
/// the button stays disabled until the toggle is on, whatever else is filled in. While it is disabled, the
/// line under it names the first thing still missing, top to bottom (spec 3.16, 4.11), and the button is
/// enabled exactly when there is no such line.
@MainActor
final class CreateAccountFormTests: XCTestCase {
    private func canSubmit(
        email: String = "you@example.com",
        password: String = "Placeholder-1",
        confirmPassword: String = "Placeholder-1",
        isAdultConfirmed: Bool = true,
        isBusy: Bool = false
    ) -> Bool {
        CreateAccountForm.createAccountButton(
            email: email,
            password: password,
            confirmPassword: confirmPassword,
            isAdultConfirmed: isAdultConfirmed,
            isBusy: isBusy
        ).isEnabled
    }

    private func hint(
        email: String = "you@example.com",
        password: String = "Placeholder-1",
        confirmPassword: String = "Placeholder-1",
        isAdultConfirmed: Bool = true
    ) -> String? {
        CreateAccountForm.hint(
            email: email,
            password: password,
            confirmPassword: confirmPassword,
            isAdultConfirmed: isAdultConfirmed
        )
    }

    func testEnabledOnlyWithTheAgeToggleOn() {
        XCTAssertTrue(canSubmit())
        XCTAssertFalse(canSubmit(isAdultConfirmed: false), "a complete form still needs the age toggle")
    }

    func testEveryOtherFieldStillGates() {
        XCTAssertFalse(canSubmit(email: ""))
        XCTAssertFalse(canSubmit(email: "you@example"))
        XCTAssertFalse(canSubmit(password: "", confirmPassword: ""))
        XCTAssertFalse(canSubmit(password: "placeholder", confirmPassword: "placeholder"), "the requirements gate too")
        XCTAssertFalse(canSubmit(confirmPassword: "Placeholder-2"))
        XCTAssertFalse(canSubmit(isBusy: true))
    }

    func testTheToggleAloneIsNotEnough() {
        XCTAssertFalse(canSubmit(email: "", password: "", confirmPassword: "", isAdultConfirmed: true))
    }

    func testHintNamesTheMissingStep() {
        XCTAssertEqual(CreateAccountForm.adultRequiredHint, "Confirm you're 18 or older to continue.")
        XCTAssertEqual(hint(isAdultConfirmed: false), CreateAccountForm.adultRequiredHint)
        XCTAssertNil(hint())
    }

    /// The age line first, from the empty form on, whatever else is missing (project decision, 2026-10-21; spec 4.11).
    func testTheAgeLineComesFirstWhileTheSwitchIsOff() {
        let age = "Confirm you're 18 or older to continue."
        XCTAssertEqual(hint(email: "", password: "", confirmPassword: "", isAdultConfirmed: false), age)
        XCTAssertEqual(hint(email: "you", password: "", isAdultConfirmed: false), age)
        XCTAssertEqual(hint(password: "placeholder", confirmPassword: "placeholder", isAdultConfirmed: false), age)
        XCTAssertEqual(hint(confirmPassword: "Placeholder-2", isAdultConfirmed: false), age)
        XCTAssertEqual(hint(isAdultConfirmed: false), age)
    }

    /// With the switch on, the lines word for word, in the order the form asks for them.
    func testHintsWalkTheFormTopToBottom() {
        XCTAssertEqual(hint(email: "", password: "", confirmPassword: ""), "Add your email and a password to continue.")
        XCTAssertEqual(hint(email: " "), "Add your email to continue.")
        XCTAssertEqual(hint(email: "you", password: ""), "Add your full email, like you@example.com, to continue.")
        XCTAssertEqual(hint(password: "", confirmPassword: ""), "Add a password to continue.")
        XCTAssertEqual(
            hint(password: "placeholder", confirmPassword: "placeholder"),
            "Use a password that meets the requirements above to continue."
        )
        XCTAssertEqual(hint(confirmPassword: ""), "Confirm your password to continue.")
        XCTAssertEqual(hint(confirmPassword: "Placeholder-2"), "Make both passwords match to continue.")
        XCTAssertNil(hint())
    }

    /// Every combination of the form's states: each one that disables the button has the right line, each one
    /// that enables it has none, and busy (loading, no hint shown) is never enabled.
    func testEveryStateHasTheRightHintAndHintIsNilExactlyWhenEnabled() {
        enum Email { case missing, incomplete, complete }
        enum Password { case missing, unmet, met }
        let emails: [(String, Email)] = [
            ("", .missing), ("   ", .missing), ("\n", .missing),
            ("you", .incomplete), ("you@example", .incomplete), ("you@", .incomplete), ("@example", .incomplete),
            ("you@example.com", .complete), ("  you@example.com  ", .complete), ("a@b.co", .complete)
        ]
        let passwords: [(String, Password)] = [
            ("", .missing),
            ("Pl-1", .unmet), ("placeholder-1", .unmet), ("PLACEHOLDER-1", .unmet), ("Placeholder-x", .unmet),
            ("Placeholder1", .unmet), ("placeholder", .unmet),
            ("Placeholder-1", .met), ("Another#Pass2", .met), ("Long enough 9", .met)
        ]

        var seen: Set<String?> = []
        var count = 0
        for (email, emailState) in emails {
            for (password, passwordState) in passwords {
                for confirmation in ["", password, password + "x", "Placeholder-1"] {
                    for isAdultConfirmed in [false, true] {
                        let expected: String?
                        if !isAdultConfirmed {
                            expected = "Confirm you're 18 or older to continue."
                        } else if emailState == .missing, passwordState == .missing {
                            expected = "Add your email and a password to continue."
                        } else if emailState == .missing {
                            expected = "Add your email to continue."
                        } else if emailState == .incomplete {
                            expected = "Add your full email, like you@example.com, to continue."
                        } else if passwordState == .missing {
                            expected = "Add a password to continue."
                        } else if passwordState == .unmet {
                            expected = "Use a password that meets the requirements above to continue."
                        } else if confirmation.isEmpty {
                            expected = "Confirm your password to continue."
                        } else if confirmation != password {
                            expected = "Make both passwords match to continue."
                        } else {
                            expected = nil
                        }

                        let state = "email \(email.debugDescription), password \(password.debugDescription), "
                            + "confirmation \(confirmation.debugDescription), adult \(isAdultConfirmed)"
                        let actual = hint(
                            email: email,
                            password: password,
                            confirmPassword: confirmation,
                            isAdultConfirmed: isAdultConfirmed
                        )
                        let enabled = canSubmit(
                            email: email,
                            password: password,
                            confirmPassword: confirmation,
                            isAdultConfirmed: isAdultConfirmed
                        )
                        let button = CreateAccountForm.createAccountButton(
                            email: email,
                            password: password,
                            confirmPassword: confirmation,
                            isAdultConfirmed: isAdultConfirmed,
                            isBusy: false
                        )
                        XCTAssertEqual(actual, expected, state)
                        XCTAssertEqual(button.missing, actual, state)
                        XCTAssertEqual(actual == nil, enabled, "hint nil <=> enabled: \(state)")
                        XCTAssertFalse(
                            canSubmit(
                                email: email,
                                password: password,
                                confirmPassword: confirmation,
                                isAdultConfirmed: isAdultConfirmed,
                                isBusy: true
                            ),
                            "busy: \(state)"
                        )
                        seen.insert(actual)
                        count += 1
                    }
                }
            }
        }
        XCTAssertEqual(count, emails.count * passwords.count * 4 * 2)
        XCTAssertEqual(seen.count, 9, "every line and the enabled state are reached: \(seen)")
    }

    /// The code step's Confirm says the code is missing until one is typed.
    func testCodeStepHint() {
        for code in ["", " ", "\n"] {
            XCTAssertEqual(CreateAccountForm.codeHint(code: code), "Add the code to continue.")
            XCTAssertEqual(
                CreateAccountForm.confirmButton(code: code, isBusy: false),
                FormButtonState(missing: "Add the code to continue.", isBusy: false)
            )
            XCTAssertFalse(CreateAccountForm.confirmButton(code: code, isBusy: false).isEnabled)
        }
        for code in ["123456", " 1 "] {
            XCTAssertNil(CreateAccountForm.codeHint(code: code))
            XCTAssertTrue(CreateAccountForm.confirmButton(code: code, isBusy: false).isEnabled)
            XCTAssertFalse(CreateAccountForm.confirmButton(code: code, isBusy: true).isEnabled)
        }
    }

    func testEmailNeedsAnAtAndADotAfterIt() {
        for valid in ["you@example.com", " you@example.com\n", "a@b.c", "you@mail.example.org"] {
            XCTAssertTrue(CreateAccountForm.isValidEmail(valid), valid)
        }
        for invalid in ["", " ", "you", "you@", "you@example", "you.name@example", "@"] {
            XCTAssertFalse(CreateAccountForm.isValidEmail(invalid), invalid)
        }
    }
}
