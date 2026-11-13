import CoreGraphics
import SwiftUI
import UIKit
import XCTest
@testable import Billboard

/// Renders the first-run screens (spec D 2.5: sign in, create account, the age gate, "Where do you
/// vote?" and its success panels, the topic picker, the tour and the tab bar) in light and dark, at
/// the default text size and at AX3, and attaches each image to the result bundle for review
/// (spec D 5.3). No network: the auth manager is signed out, the members manifest is a fake.
/// Platform controls (text fields, toggles, menus) show as placeholders in `ImageRenderer` images, so
/// pixels are checked only on views without them (the success panel and the tab bar); whole screens
/// are rendered for review.
@MainActor
final class FirstRunRenderTests: XCTestCase {
    private struct Variant {
        let scheme: ColorScheme
        let size: DynamicTypeSize

        var name: String { "\(scheme == .dark ? "dark" : "light")-\(size == .large ? "default" : "AX3")" }
    }

    private static let variants: [Variant] = [
        Variant(scheme: .light, size: .large),
        Variant(scheme: .dark, size: .large),
        Variant(scheme: .light, size: .accessibility3),
        Variant(scheme: .dark, size: .accessibility3)
    ]

    private static let width: CGFloat = 390
    private static let screenHeight: CGFloat = 844

    // MARK: - Signed out

    func testSignInRendersAndFollowsTheAppearance() throws {
        let auth = AuthManager()
        auth.cancelSignIn() // signed out, so the screen's task makes no auth call
        for variant in Self.variants {
            let image = try renderHosted(LoginView().environmentObject(auth), variant: variant)
            attach(image, name: "login-\(variant.name)")
            assertScreenSized(image, variant: variant)
        }
    }

    func testCreateAccountRenders() throws {
        let auth = AuthManager()
        auth.cancelSignIn()
        for variant in Self.variants {
            let view = CreateAccountView()
                .environmentObject(auth)
                .environmentObject(UserStore(preferencesService: StaticPreferencesService(items: []), congressService: FakeCongressService()))
            let image = try renderHosted(view, variant: variant)
            attach(image, name: "create-account-\(variant.name)")
            assertScreenSized(image, variant: variant)
        }
    }

    func testAgeGateRenders() throws {
        let auth = AuthManager()
        auth.cancelSignIn()
        let store = UserStore(preferencesService: StaticPreferencesService(items: []), congressService: FakeCongressService())
        for variant in Self.variants {
            let gate = try render(AdultAttestationGateView().environmentObject(auth).environmentObject(store), variant: variant)
            attach(gate, name: "age-gate-\(variant.name)")
            assertScreenSized(gate, variant: variant)

            let ineligible = try render(AccountIneligibleView().environmentObject(auth), variant: variant)
            attach(ineligible, name: "account-ineligible-\(variant.name)")
        }
    }

    /// The age gate's two text buttons, "I'm under 18" (an answer that can't be changed) and "Sign out", each
    /// stand on a 44 pt row (spec 2.8, 3.16), so their 44 pt targets do not overlap and the two read apart.
    func testAgeGateTextButtonsStandOnTheirOwn44PointRows() throws {
        let auth = AuthManager()
        auth.cancelSignIn()
        let store = UserStore(preferencesService: StaticPreferencesService(items: []), congressService: FakeCongressService())
        for size in [DynamicTypeSize.large, .accessibility3] {
            let host = AccessibilityTreeText.Host(
                AdultAttestationGateView().environmentObject(auth).environmentObject(store).environment(\.dynamicTypeSize, size),
                size: CGSize(width: 390, height: 1400),
                settle: 0.3
            )
            defer { host.close() }
            let under18 = try XCTUnwrap(host.frame(of: "I'm under 18"), host.text())
            let signOut = try XCTUnwrap(host.frame(of: "Sign out"), host.text())
            XCTAssertGreaterThanOrEqual(signOut.midY - under18.midY, 44, "\(size): the two 44 pt targets overlap")
            XCTAssertEqual(host.identifier(of: "I'm under 18"), "ageGate.under18")
        }
    }

    // MARK: - Where do you vote?

    func testLocationSetupFormRenders() throws {
        let store = UserStore(preferencesService: StaticPreferencesService(items: []), congressService: FakeCongressService())
        for variant in Self.variants {
            let setup = LocationEditorView(context: .setup, congressService: FakeCongressService()) { _ in }
                .environmentObject(store)
            let image = try renderHosted(setup, variant: variant)
            attach(image, name: "location-setup-\(variant.name)")
            assertScreenSized(image, variant: variant)

            let profile = LocationEditorView(context: .profile, congressService: FakeCongressService()) { _ in }
                .environmentObject(store)
            attach(try renderHosted(profile, variant: variant), name: "location-profile-\(variant.name)")
        }
    }

    func testSuccessPanelsRender() throws {
        let fixtures: [(String, LocationEditorResult, LocationEditorView.Context, LocationEditorView.FollowState)] = [
            ("verified-setup", result(method: .address, verified: true), .setup, .idle),
            ("capped-setup", result(method: .address, verified: false, capped: true), .setup, .idle),
            ("chosen-setup-follow-failed", result(method: .chosenDistrict, verified: false), .setup, .failed),
            ("verified-profile", result(method: .address, verified: true), .profile, .idle),
            ("no-representatives-setup", result(method: .address, verified: true, representatives: []), .setup, .idle)
        ]
        for (name, fixture, context, followState) in fixtures {
            for variant in Self.variants {
                let panel = LocationSavedPanel(
                    result: fixture,
                    context: context,
                    followState: followState,
                    unfollowedRepresentativeCount: context == .profile ? fixture.representatives.count : 0,
                    onContinue: { _ in },
                    onFollow: {},
                    onDone: {}
                )
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(BillboardColors.background)
                let image = try render(panel, variant: variant, height: nil)
                attach(image, name: "location-success-\(name)-\(variant.name)")
                XCTAssertGreaterThan(image.height, 200, "\(name) \(variant.name)")
                // The panel's left margin is the page background of the variant's appearance.
                try assertBackground(image, variant: variant, x: 2, y: image.height / 2)
            }
        }
    }

    /// The success panel (Civic Record spec 4.16, frame 19): VERIFIED is an ink stamp (no green seal), the
    /// headline reads the district in words, and the representatives are roll-sheet rows read with the party.
    func testSuccessPanelStampsInInkAndReadsTheDistrictInWords() throws {
        let verified = result(method: .address, verified: true)
        let panel = LocationSavedPanel(
            result: verified,
            context: .setup,
            followState: .idle,
            unfollowedRepresentativeCount: 0,
            onContinue: { _ in },
            onFollow: {},
            onDone: {}
        )
        for variant in [Self.variants[0], Self.variants[1]] {
            let image = try render(panel.padding(20).background(BillboardColors.background), variant: variant, height: nil)
            XCTAssertFalse(
                try contains(image, variant.scheme == .dark ? BillboardPalette.statusPassed.dark : BillboardPalette.statusPassed.light),
                "\(variant.name): VERIFIED is ink, not green"
            )
        }
        XCTAssertEqual(LocationSavedPanel.spokenHeadline(state: "VA", district: "11"), "You're in Virginia's 11th district.")
        XCTAssertEqual(LocationSavedPanel.spokenHeadline(state: "AK", district: "At-Large"), "You're in Alaska's at-large district.")
        XCTAssertEqual(LocationSavedPanel.spokenHeadline(state: "DC", district: "At-Large"), "You're in the District of Columbia.")

        let host = AccessibilityTreeText.Host(panel.padding(20), size: CGSize(width: 390, height: 900))
        defer { host.close() }
        let text = host.text()
        XCTAssertTrue(text.contains("You're in Virginia's 11th district."), text)
        XCTAssertTrue(text.contains("Verified"), text)
        XCTAssertTrue(text.contains("Found from your address."), text)
        XCTAssertTrue(text.contains("Senator Tim Kaine, Democrat, Virginia"), text)
        XCTAssertEqual(host.identifier(of: "You're in Virginia's 11th district."), "location.success.headline")

        // Chosen by the user: NOT VERIFIED and why.
        let chosen = LocationSavedPanel(
            result: result(method: .chosenDistrict, verified: false),
            context: .profile,
            followState: .idle,
            unfollowedRepresentativeCount: 3,
            onContinue: { _ in },
            onFollow: {},
            onDone: {}
        )
        XCTAssertEqual(chosen.statusNote, "You chose this district.")
        let cappedPanel = LocationSavedPanel(
            result: result(method: .address, verified: false, capped: true),
            context: .setup,
            followState: .idle,
            unfollowedRepresentativeCount: 0,
            onContinue: { _ in },
            onFollow: {},
            onDone: {}
        )
        XCTAssertNil(cappedPanel.statusNote, "the address cap has its own notice")
    }

    /// A disabled Find my district says what is missing (spec 4.16), and VoiceOver reads it as the hint.
    func testFindMyDistrictSaysWhatIsMissing() throws {
        var form = LocationForm()
        XCTAssertEqual(form.findDistrictHint, "Add your street address, city, state and ZIP to continue.")
        form.line1 = "10 Main St"
        form.city = "Fairfax"
        form.state = "VA"
        XCTAssertEqual(form.findDistrictHint, "Add a ZIP to continue.")
        form.zip = "220"
        XCTAssertEqual(form.findDistrictHint, "Add a 5-digit ZIP to continue.")
        form.zip = "22030"
        XCTAssertNil(form.findDistrictHint)
        form.city = ""
        form.state = ""
        XCTAssertEqual(form.findDistrictHint, "Add a city and a state to continue.")
        form.line1 = ""
        XCTAssertEqual(form.findDistrictHint, "Add your street address, a city and a state to continue.")

        var choose = LocationForm()
        XCTAssertEqual(choose.chooseDistrictHint(choices: []), "Choose a state and a district to continue.")
        choose.state = "VA"
        let choices = DistrictPickerModel.districtChoices(for: "VA", manifest: [])
        XCTAssertEqual(choose.chooseDistrictHint(choices: choices), "Choose a district to continue.")
        choose.district = "11"
        XCTAssertNil(choose.chooseDistrictHint(choices: choices))

        let store = UserStore(preferencesService: StaticPreferencesService(items: []), congressService: FakeCongressService())
        let host = AccessibilityTreeText.Host(
            NavigationStack { LocationEditorView(context: .setup, congressService: FakeCongressService(), onSignOut: {}) { _ in } }
                .environmentObject(store),
            size: CGSize(width: 390, height: 1600),
            settle: 0.3
        )
        defer { host.close() }
        let text = host.text()
        XCTAssertTrue(text.contains("Add your street address, city, state and ZIP to continue."), text)
        // The address note, word for word, and the labels that differ from the placeholders.
        XCTAssertTrue(text.contains(LocationEditorView.privacyNote), text)
        for label in ["Street address", "Apt or unit (optional)", "City", "State", "ZIP"] {
            XCTAssertTrue(text.contains(label), "\(label): \(text)")
        }
        XCTAssertEqual(host.identifier(of: "Sign out"), "setup.signOut")
        XCTAssertEqual(host.identifier(of: "Street address"), "location.street")
    }

    /// Setup's Sign out ends the form (frame 18); the success panel has only Continue (frame 19, spec 4.16).
    func testSetupSuccessPanelHasContinueAndNoSignOut() throws {
        let store = UserStore(preferencesService: StaticPreferencesService(items: []), congressService: FakeCongressService())
        let host = AccessibilityTreeText.Host(
            NavigationStack {
                LocationEditorView(
                    context: .setup,
                    congressService: FakeCongressService(),
                    onSignOut: {},
                    savedResult: result(method: .address, verified: true)
                ) { _ in }
            }
            .environmentObject(store),
            size: CGSize(width: 390, height: 1600),
            settle: 0.3
        )
        defer { host.close() }
        let text = host.text()
        XCTAssertTrue(text.contains("You're in Virginia's 11th district."), text)
        XCTAssertEqual(host.identifier(of: "Continue"), "location.continue")
        XCTAssertNil(host.identifier(of: "Sign out"), text)
        XCTAssertFalse(text.contains("Sign out"), text)
    }

    /// Sign in (spec 4.10): labelled fields with example placeholders, INT-11's value line word for word, and
    /// the empty form's disabled Sign in saying what is missing (spec 3.16), read as its hint.
    func testSignInFieldsAreLabelledAboveWithExamplePlaceholders() throws {
        let auth = AuthManager()
        auth.cancelSignIn()
        let host = AccessibilityTreeText.Host(NavigationStack { LoginView() }.environmentObject(auth), size: CGSize(width: 390, height: 844), settle: 0.3)
        defer { host.close() }
        let text = host.text()
        XCTAssertTrue(text.contains(LoginView.valueLine), text)
        XCTAssertTrue(text.contains("Add your email and password to continue."), text)
        XCTAssertEqual(host.identifier(of: "Email"), "login.email")
        XCTAssertEqual(host.identifier(of: "Password"), "login.password")
        XCTAssertEqual(host.identifier(of: "Forgot password?"), "login.forgotPassword")
        XCTAssertEqual(host.identifier(of: "Create account"), "login.createAccount")
        XCTAssertEqual(host.identifier(of: "Sign in"), "login.submit")
    }

    /// Create account (spec 3.16, 4.11): the disabled button names the first thing still missing, the age line
    /// first while "I'm 18 or older" is off, so the empty form shows it from the start (project decision, 2026-10-21; the
    /// field lines once it is on, in `CreateAccountFormTests`), and VoiceOver reads it as the hint; the AI line
    /// and INT-11's line stay word for word.
    func testCreateAccountExplainsTheDisabledButton() throws {
        let auth = AuthManager()
        auth.cancelSignIn()
        let store = UserStore(preferencesService: StaticPreferencesService(items: []), congressService: FakeCongressService())
        let host = AccessibilityTreeText.Host(
            NavigationStack { CreateAccountView() }.environmentObject(auth).environmentObject(store),
            size: CGSize(width: 390, height: 1400),
            settle: 0.3
        )
        defer { host.close() }
        let text = host.text()
        XCTAssertTrue(text.contains(CreateAccountForm.adultRequiredHint), text)
        XCTAssertFalse(text.contains("Add your email and a password to continue."), "one line at a time: \(text)")
        for line in CreateAccountView.valueBullets {
            XCTAssertTrue(text.contains(line), "\(line): \(text)")
        }
        XCTAssertEqual(host.identifier(of: "Email"), "signup.email")
        XCTAssertEqual(host.identifier(of: "Confirm password"), "signup.confirmPassword")
        XCTAssertEqual(host.identifier(of: "Create account"), "signup.submit")
    }

    /// Forgot password's Send code and Set a new password's Update password say what is missing while they
    /// are disabled (spec 3.16), and VoiceOver reads it as the button's hint.
    func testPasswordScreensExplainTheDisabledButton() throws {
        let auth = AuthManager()
        auth.cancelSignIn()
        let screens: [(String, AnyView, String, String)] = [
            ("forgot-password", AnyView(NavigationStack { ForgotPasswordView() }.environmentObject(auth)), "Send code", "Add your email to continue."),
            ("new-password", AnyView(NavigationStack { NewPasswordRequiredView() }.environmentObject(auth)), "Update password", "Add a new password to continue.")
        ]
        for (name, view, button, hint) in screens {
            let host = AccessibilityTreeText.Host(view, size: CGSize(width: 390, height: 1200), settle: 0.3)
            defer { host.close() }
            let text = host.text()
            XCTAssertTrue(text.contains(button), "\(name): \(text)")
            XCTAssertEqual(text.components(separatedBy: hint).count - 1, 1, "\(name): read once, as the hint: \(text)")
        }
    }

    /// Each auth screen hosted part-filled and filled in (spec 3.16): VoiceOver finds its button not enabled
    /// exactly when the button has a hint, and that hint is the form's line for those fields. The forms' own
    /// tests cover every state; this checks that each screen feeds its button from its form.
    func testAuthButtonsAreDisabledExactlyWhileTheyHaveAHint() throws {
        let auth = AuthManager()
        auth.cancelSignIn()
        let store = UserStore(preferencesService: StaticPreferencesService(items: []), congressService: FakeCongressService())
        let email = "you@example.com"
        let met = "Placeholder-1"

        struct Case {
            let name: String
            let view: AnyView
            let button: String
            /// The form's line for the hosted fields; nil when the button should be enabled.
            let line: String?
        }
        func login(_ email: String, _ password: String) -> Case {
            Case(
                name: "sign in \(email.debugDescription) \(password.debugDescription)",
                view: AnyView(LoginView(email: email, password: password)),
                button: "Sign in",
                line: SignInForm.hint(email: email, password: password)
            )
        }
        func sendCode(_ email: String) -> Case {
            Case(
                name: "send code \(email.debugDescription)",
                view: AnyView(ForgotPasswordView(email: email)),
                button: "Send code",
                line: ForgotPasswordForm.requestHint(email: email)
            )
        }
        func enterCode(_ code: String, _ password: String, _ confirmation: String) -> Case {
            Case(
                name: "enter code \(code.debugDescription) \(password.debugDescription) \(confirmation.debugDescription)",
                view: AnyView(
                    ForgotPasswordView(
                        step: .confirm(details: nil),
                        email: email,
                        code: code,
                        newPassword: password,
                        confirmNewPassword: confirmation
                    )
                ),
                button: "Update password",
                line: ForgotPasswordForm.confirmHint(code: code, newPassword: password, confirmPassword: confirmation)
            )
        }
        func newPassword(_ password: String, _ confirmation: String) -> Case {
            Case(
                name: "new password \(password.debugDescription) \(confirmation.debugDescription)",
                view: AnyView(NewPasswordRequiredView(newPassword: password, confirmNewPassword: confirmation)),
                button: "Update password",
                line: NewPasswordForm.hint(newPassword: password, confirmPassword: confirmation)
            )
        }
        func createAccount(_ email: String, _ password: String, _ confirmation: String, adult: Bool) -> Case {
            Case(
                name: "create account \(email.debugDescription) \(password.debugDescription) \(confirmation.debugDescription) \(adult)",
                view: AnyView(
                    CreateAccountView(email: email, password: password, confirmPassword: confirmation, isAdultConfirmed: adult)
                ),
                button: "Create account",
                line: CreateAccountForm.hint(email: email, password: password, confirmPassword: confirmation, isAdultConfirmed: adult)
            )
        }
        func confirmCode(_ code: String) -> Case {
            Case(
                name: "confirm code \(code.debugDescription)",
                view: AnyView(CreateAccountView(step: .confirmCode(details: nil), email: email, code: code)),
                button: "Confirm",
                line: CreateAccountForm.codeHint(code: code)
            )
        }
        func accountReady(_ password: String) -> Case {
            Case(
                name: "account ready \(password.debugDescription)",
                view: AnyView(CreateAccountView(step: .done, email: email, password: password)),
                button: "Sign in",
                line: SignInForm.hint(email: email, password: password)
            )
        }

        let cases = [
            login("   ", "x"), login(email, ""), login(email, "x"),
            sendCode(" "), sendCode(email),
            enterCode("", met, ""), enterCode("123456", "placeholder", "placeholder"), enterCode("123456", met, met),
            newPassword("placeholder", "placeholder"), newPassword(met, "Placeholder-2"), newPassword(met, met),
            createAccount("you@example", met, met, adult: true), createAccount(email, met, "", adult: true),
            createAccount(email, met, met, adult: false), createAccount(email, met, met, adult: true),
            confirmCode(" "), confirmCode("123456"),
            accountReady(""), accountReady("x")
        ]
        // Each screen is hosted both disabled and enabled.
        for button in ["Sign in", "Send code", "Update password", "Create account", "Confirm"] {
            XCTAssertTrue(cases.contains { $0.button == button && $0.line != nil }, button)
            XCTAssertTrue(cases.contains { $0.button == button && $0.line == nil }, button)
        }
        XCTAssertEqual(enterCode("", met, "").line, "Add the code and confirm your new password to continue.")

        for testCase in cases {
            let host = AccessibilityTreeText.Host(
                NavigationStack { testCase.view }.environmentObject(auth).environmentObject(store),
                size: CGSize(width: 390, height: 1400),
                settle: 0.3
            )
            defer { host.close() }
            let traits = try XCTUnwrap(host.traits(of: testCase.button), "\(testCase.name): \(host.text())")
            XCTAssertEqual(traits.contains(.notEnabled), testCase.line != nil, "\(testCase.name): enabled exactly without a line")
            XCTAssertEqual(host.hint(of: testCase.button), testCase.line, testCase.name)
        }
    }

    // MARK: - Topics

    func testTopicPickerRenders() throws {
        let store = UserStore(preferencesService: StaticPreferencesService(items: []), congressService: FakeCongressService())
        let seed = Bill(
            title: "A bill",
            category: SubscriptionsConfig.categorySocialPolicy,
            subCategory: SubscriptionsConfig.subHousing,
            soWhat: "",
            lifeAreas: [SubscriptionsConfig.lifeTaxes],
            billStatus: .new,
            userVoted: true
        )
        for variant in Self.variants {
            let prompt = TopicPickerView(context: .firstVote(seedBill: seed)) {}
                .environmentObject(store)
            let image = try render(prompt, variant: variant)
            attach(image, name: "first-vote-topics-\(variant.name)")
            assertScreenSized(image, variant: variant)

            let profile = TopicPickerView(context: .profile) {}
                .environmentObject(store)
            attach(try render(profile, variant: variant), name: "topic-picker-profile-\(variant.name)")
        }

        // The first-vote prompt asks for topics and life areas only, never a party (UX-36).
        let text = AccessibilityTreeText.text(of: TopicPickerView(context: .firstVote(seedBill: seed)) {}.environmentObject(store))
        XCTAssertTrue(text.contains("Want more bills like this?"), text)
        for asked in ["party", "Party", "Prefer not to say", "Democrat", "Republican"] {
            XCTAssertFalse(text.contains(asked), "\(asked) in: \(text)")
        }
    }

    // MARK: - Tour and tab bar

    func testTourStepsRender() throws {
        let card = CGRect(x: 20, y: 160, width: 350, height: 170)
        for (index, step) in ProductTutorial.steps.enumerated() {
            for variant in Self.variants {
                let overlay = ProductTutorialOverlay(
                    step: step,
                    stepIndex: index,
                    totalSteps: ProductTutorial.steps.count,
                    highlightRects: [card],
                    hasFirstCard: true,
                    onBack: {},
                    onPrimary: {},
                    onSkip: {}
                )
                .background(BillboardColors.background)
                attach(try render(overlay, variant: variant), name: "tour-step\(index + 1)-\(variant.name)")
            }
        }
        // Step 3 with an empty list.
        let empty = ProductTutorialOverlay(
            step: ProductTutorial.steps[2],
            stepIndex: 2,
            totalSteps: 3,
            highlightRects: [],
            hasFirstCard: false,
            onBack: {},
            onPrimary: {},
            onSkip: {}
        )
        attach(try render(empty, variant: Self.variants[0]), name: "tour-step3-empty-light-default")
    }

    /// The tour card (spec 4.17): ink on sheet with no teal, the step's title carrying the step (no symbol),
    /// "1 of 3" read as "Step 1 of 3", and the buttons and ids kept.
    func testTourCardIsInkOnSheetWithItsProgressInWords() throws {
        let card = CGRect(x: 20, y: 160, width: 350, height: 170)
        let overlay = ProductTutorialOverlay(
            step: ProductTutorial.steps[1],
            stepIndex: 1,
            totalSteps: 3,
            highlightRects: [card],
            hasFirstCard: true,
            onBack: {},
            onPrimary: {},
            onSkip: {}
        )
        .background(BillboardColors.background)
        for variant in [Self.variants[0], Self.variants[1]] {
            let image = try render(overlay, variant: variant)
            // Below the spotlight (its stroke and the swipe hint are drawn there): the card holds no teal.
            let teal = BillboardPalette.brandTeal.light
            XCTAssertFalse(try contains(image, teal, fromY: 420), "\(variant.name): teal in the tour card")
            XCTAssertTrue(
                try contains(image, variant.scheme == .dark ? BillboardPalette.controlOn.dark : BillboardPalette.controlOn.light, fromY: 420),
                "\(variant.name): the steps reached are controlOn"
            )
        }

        let host = AccessibilityTreeText.Host(overlay, size: CGSize(width: 390, height: 844))
        defer { host.close() }
        let text = host.text()
        XCTAssertTrue(text.contains("Step 2 of 3"), text)
        XCTAssertTrue(text.contains("Skip what you don't care about"), text)
        XCTAssertEqual(host.identifier(of: "Skip tour"), "tour.skip")
        XCTAssertEqual(host.identifier(of: "Back"), "tour.back")
        XCTAssertEqual(host.identifier(of: "Next"), "tour.primary")
    }

    /// The tour's Back is the secondary capsule at its own 44 pt (spec 3.16, 4.17), centred beside the 50 pt
    /// primary: stretched to 50 pt its corners (22 pt) would be flatter than a capsule's, unlike Next beside it.
    func testTourBackIsACapsuleAtTheSecondaryHeight() throws {
        let overlay = ProductTutorialOverlay(
            step: ProductTutorial.steps[1],
            stepIndex: 1,
            totalSteps: 3,
            highlightRects: [CGRect(x: 20, y: 160, width: 350, height: 170)],
            hasFirstCard: true,
            onBack: {},
            onPrimary: {},
            onSkip: {}
        )
        let host = AccessibilityTreeText.Host(overlay, size: CGSize(width: 390, height: 844))
        defer { host.close() }
        let back = try XCTUnwrap(host.frame(of: "Back"), host.text())
        let next = try XCTUnwrap(host.frame(of: "Next"), host.text())
        XCTAssertEqual(back.height, BillboardButtonKind.secondary.capsuleHeight, accuracy: 0.5)
        XCTAssertLessThanOrEqual(back.height, 2 * BillboardButtonKind.secondary.cornerRadius + 0.5, "Back is a capsule")
        XCTAssertEqual(next.height, BillboardButtonKind.primary.capsuleHeight, accuracy: 0.5)
        XCTAssertEqual(back.midY, next.midY, accuracy: 0.5, "Back is centred beside Next")
    }

    // MARK: - Launch loading and startup failure (Civic Record spec 4.2, 4.3)

    /// The launch loading screen and its 15-second state, and the startup failure screen: navy in both
    /// appearances (they follow the navy launch screen), with the wordmark and no teal but the wordmark's.
    func testLaunchAndStartupFailureScreensAreNavyInBothAppearances() throws {
        let screens: [(String, AnyView)] = [
            ("launch-loading", AnyView(LaunchLoadingView(onRetry: {}))),
            ("launch-loading-slow", AnyView(LaunchLoadingView(showsSlowLoadingHelp: true, onRetry: {}))),
            ("startup-failure", AnyView(StartupFailureView()))
        ]
        let navy = BillboardPalette.navy.light
        for (name, screen) in screens {
            for variant in Self.variants {
                let image = try render(screen, variant: variant)
                attach(image, name: "\(name)-\(variant.name)")
                assertScreenSized(image, variant: variant)
                for (x, y) in [(8, 8), (8, Int(Self.screenHeight) - 8), (Int(Self.width) - 8, Int(Self.screenHeight) / 2)] {
                    let sample = try pixel(of: image, x: x, y: y)
                    XCTAssertEqual(sample.red, navy.red, accuracy: 0.02, "\(name) \(variant.name) at \(x), \(y)")
                    XCTAssertEqual(sample.green, navy.green, accuracy: 0.02, "\(name) \(variant.name) at \(x), \(y)")
                    XCTAssertEqual(sample.blue, navy.blue, accuracy: 0.02, "\(name) \(variant.name) at \(x), \(y)")
                }
            }
        }

        // The 15-second state says so and offers Try again; VoiceOver reads the wordmark as "Billboard".
        let host = AccessibilityTreeText.Host(LaunchLoadingView(showsSlowLoadingHelp: true, onRetry: {}), size: CGSize(width: 390, height: 844))
        defer { host.close() }
        let text = host.text()
        XCTAssertTrue(text.contains("Billboard"), text)
        XCTAssertTrue(text.contains("Still loading…"), text)
        XCTAssertTrue(text.contains("Try again"), text)
    }

    /// The tab capsule (Civic Record spec 3.22, 4.4), replacing R2's navy pill: navy-tinted glass over a
    /// white slip in light and over night paper in dark, the selected Bills tab on an opaque navy capsule
    /// with its brand-teal stroke in both appearances, 64 pt at every text size; under Reduce Transparency,
    /// solid navy.
    func testTabCapsuleIsNavyGlassWithAnOpaqueNavySelectionInBothAppearances() throws {
        let navy = BillboardPalette.navy.light
        let teal = BillboardPalette.brandTeal.light
        func capsule(over ground: Color) -> some View {
            BillboardTabBar(selectedTab: .home, homeBadgeCount: 3, updatesBadgeCount: 12, onSelect: { _ in })
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(ground)
        }
        for variant in Self.variants {
            let ground = variant.scheme == .dark ? BillboardColors.background : BillboardColors.cardBackground
            let image = try render(capsule(over: ground), variant: variant, height: nil)
            attach(image, name: "tab-capsule-\(variant.name)")
            XCTAssertEqual(image.height, 64 + 24, "fixed size: \(variant.name)")

            // Inside the selected capsule (x from 20 pt, y from 16 to 72 pt), left of the symbol.
            let selection = try pixel(of: image, x: 28, y: 44)
            XCTAssertEqual(selection.red, navy.red, accuracy: 0.02, variant.name)
            XCTAssertEqual(selection.green, navy.green, accuracy: 0.02, variant.name)
            XCTAssertEqual(selection.blue, navy.blue, accuracy: 0.02, variant.name)
            // Its 1.5 pt stroke at its leftmost point.
            let stroke = try pixel(of: image, x: 20, y: 44)
            XCTAssertEqual(stroke.green, teal.green, accuracy: 0.08, "brand-teal stroke \(variant.name): \(stroke)")
            XCTAssertLessThan(stroke.red, 0.15, "brand-teal stroke \(variant.name): \(stroke)")

            // The glass in the 4 pt band above the tabs, mid-capsule: dark navy whatever is under it.
            let glass = try pixel(of: image, x: 195, y: 14)
            XCTAssertLessThan(0.2126 * glass.red + 0.7152 * glass.green + 0.0722 * glass.blue, 0.3, "navy glass \(variant.name): \(glass)")
            XCTAssertGreaterThan(glass.blue, glass.red, "navy glass \(variant.name): \(glass)")
        }

        let reduced = try render(
            capsule(over: BillboardColors.cardBackground).environment(\._accessibilityReduceTransparency, true),
            variant: Self.variants[0],
            height: nil
        )
        attach(reduced, name: "tab-capsule-light-reduce-transparency")
        let solid = try pixel(of: reduced, x: 195, y: 14)
        XCTAssertEqual(solid.red, navy.red, accuracy: 0.01, "solid navy")
        XCTAssertEqual(solid.green, navy.green, accuracy: 0.01, "solid navy")
        XCTAssertEqual(solid.blue, navy.blue, accuracy: 0.01, "solid navy")
    }

    // MARK: - Fixtures

    private func result(
        method: LocationEditorResult.Method,
        verified: Bool,
        capped: Bool = false,
        representatives: [CongressMemberManifestItem]? = nil
    ) -> LocationEditorResult {
        LocationEditorResult(
            state: "VA",
            district: "11",
            method: method,
            verification: DistrictVerificationStatus(
                verified: verified,
                status: verified ? "verified" : "self_attested",
                method: capped ? DistrictVerificationStatus.methodAddressCapped
                    : (method == .address ? DistrictVerificationStatus.methodAddressGeocode : DistrictVerificationStatus.methodManualStateDistrict),
                verifiedAt: nil,
                resolved: DistrictVerificationResolved(state: "VA", districtId: "11"),
                signals: nil,
                repsSignalEligible: nil,
                nextStep: nil,
                limitReason: capped ? DistrictVerificationStatus.limitReasonAddressLimit : nil
            ),
            representatives: representatives ?? [
                member("S1", name: "Tim Kaine", chamber: "Senate", district: nil, party: "Democratic"),
                member("S2", name: "Mark Warner", chamber: "Senate", district: nil, party: "Democratic"),
                member("H11", name: "Jane Doe Representative With A Long Name", chamber: "House", district: "11", party: "Republican")
            ],
            followedRepresentatives: false
        )
    }

    private func member(_ id: String, name: String, chamber: String, district: String?, party: String) -> CongressMemberManifestItem {
        CongressMemberManifestItem(dto: UserAPIContractsV1.CongressMemberManifestItem(
            bioguideId: id,
            name: name,
            chamber: chamber,
            state: "VA",
            party: party,
            district: district,
            depictionImageUrl: nil,
            updatedAt: nil,
            currentCongressBillsSupportedCount: nil,
            trackedSponsoredCount: nil,
            trackedSupportedCount: nil
        ))
    }

    // MARK: - Helpers

    /// Renders `view` at the phone width, on a phone-height screen; `height` nil lets the view size
    /// itself.
    private func render<Content: View>(_ view: Content, variant: Variant, height: CGFloat? = 844) throws -> CGImage {
        let renderer = ImageRenderer(
            content: view
                .environment(\.colorScheme, variant.scheme)
                .environment(\.dynamicTypeSize, variant.size)
        )
        renderer.scale = 1
        renderer.proposedSize = ProposedViewSize(width: Self.width, height: height)
        return try XCTUnwrap(renderer.cgImage, "render failed for \(variant.name)")
    }

    /// `render`, for a screen with text fields: drawn in a window, which gives `@FocusState` a focus system
    /// (`HostedRender`).
    private func renderHosted<Content: View>(_ view: Content, variant: Variant, height: CGFloat? = 844) throws -> CGImage {
        try HostedRender.image(
            view
                .environment(\.colorScheme, variant.scheme)
                .environment(\.dynamicTypeSize, variant.size),
            width: Self.width,
            height: height,
            style: variant.scheme == .dark ? .dark : .light
        )
    }

    /// A whole screen rendered at the phone size.
    private func assertScreenSized(_ image: CGImage, variant: Variant, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(image.width, Int(Self.width), variant.name, file: file, line: line)
        XCTAssertEqual(image.height, Int(Self.screenHeight), variant.name, file: file, line: line)
    }

    /// The pixel at `x`, `y` is the `background` token for the variant's appearance: the view
    /// follows dark mode instead of forcing light.
    private func assertBackground(_ image: CGImage, variant: Variant, x: Int, y: Int, file: StaticString = #filePath, line: UInt = #line) throws {
        let sample = try pixel(of: image, x: x, y: y)
        let expected = variant.scheme == .dark ? BillboardPalette.background.dark : BillboardPalette.background.light
        XCTAssertEqual(sample.red, expected.red, accuracy: 0.03, variant.name, file: file, line: line)
        XCTAssertEqual(sample.green, expected.green, accuracy: 0.03, variant.name, file: file, line: line)
        XCTAssertEqual(sample.blue, expected.blue, accuracy: 0.03, variant.name, file: file, line: line)
    }

    private func attach(_ image: CGImage, name: String) {
        let attachment = XCTAttachment(image: UIImage(cgImage: image))
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Whether any opaque pixel at or below row `fromY` is within 0.03 of `color` on every channel.
    private func contains(_ image: CGImage, _ color: BillboardColorToken.RGBA, fromY: Int = 0) throws -> Bool {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        XCTAssertTrue(drawn, "bitmap context")
        let limit = 8
        let target = [color.red, color.green, color.blue].map { Int(($0 * 255).rounded()) }
        for row in max(0, fromY)..<height {
            for column in 0..<width {
                let index = (row * width + column) * 4
                guard bytes[index + 3] == 255 else { continue }
                if abs(Int(bytes[index]) - target[0]) <= limit,
                   abs(Int(bytes[index + 1]) - target[1]) <= limit,
                   abs(Int(bytes[index + 2]) - target[2]) <= limit {
                    return true
                }
            }
        }
        return false
    }

    /// The sRGB colour of one pixel, `x` and `y` from the top left.
    private func pixel(of image: CGImage, x: Int, y: Int) throws -> (red: Double, green: Double, blue: Double) {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        var bytes = [UInt8](repeating: 0, count: 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(
                image,
                in: CGRect(
                    x: -CGFloat(x),
                    y: -CGFloat(image.height - 1 - y),
                    width: CGFloat(image.width),
                    height: CGFloat(image.height)
                )
            )
            return true
        }
        XCTAssertTrue(drawn, "bitmap context")
        XCTAssertEqual(bytes[3], 255, "sampled an opaque pixel")
        return (Double(bytes[0]) / 255, Double(bytes[1]) / 255, Double(bytes[2]) / 255)
    }
}
