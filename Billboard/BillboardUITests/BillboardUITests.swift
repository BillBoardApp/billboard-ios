import XCTest

/// End-to-end journeys through the app.
///
/// The signed-in journeys run against the project's backend with a login that only the project's
/// maintainers hold, so the project runs them. They write that account's votes and follows as R1's
/// journeys did. Without credentials they are skipped.
///
/// The signed-out tests need no account and never submit a form. They are skipped when the
/// simulator already holds a signed-in session.
final class BillboardUITests: XCTestCase {
    private struct Credentials {
        let email: String
        let password: String
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Signed in

    func testSignedInLegislativeJourney() throws {
        let credentials = try requireCredentials()
        let app = makeApp()
        app.launch()

        signInIfNeeded(app, credentials: credentials)
        waitForMainTabs(in: app)
        openTab(.bills, in: app)

        openFirstVotableBill(in: app)
        castYeaIfNotVoted(in: app)
        provideOptionalFeedback(in: app)
        closeBillDetail(in: app)
        // The first-vote topic prompt asks once the page is left (Civic Record spec 4.39), not on the page.
        dismissFirstVoteTopicPromptIfShown(in: app)

        openTab(.updates, in: app)
        XCTAssertTrue(app.staticTexts["Recent actions"].waitForExistence(timeout: 20))
        openWeeklyBriefIfAvailable(in: app)

        openTab(.congress, in: app)
        let house = app.buttons["congress.nav.house"]
        scrollIntoView(house, in: app)
        tap(house)
        XCTAssertTrue(app.buttons["congress.house.member.0"].waitForExistence(timeout: 20))
        let firstHouseMember = app.buttons["congress.house.member.0"]
        scrollIntoView(firstHouseMember, in: app)
        tap(firstHouseMember)
        assertMemberDetailsLoaded(in: app)
        tapBack(in: app)
        tapBack(in: app)

        let senate = app.buttons["congress.nav.senate"]
        scrollIntoView(senate, in: app)
        tap(senate)
        XCTAssertTrue(app.buttons["congress.senate.member.0"].waitForExistence(timeout: 20))
        openFirstUnfollowedSenateMember(in: app)
        assertMemberDetailsLoaded(in: app)
        toggleMemberFollow(in: app, expectedLabel: "Follow")
        toggleMemberFollow(in: app, expectedLabel: "Unfollow")
    }

    /// Civic Record spec 10.3 (a): an unvoted bill shows Results sealed (`bill.results.locked`, no
    /// `bill.results.everyone`). Yea becomes the ballot stamp, read "You voted Yea on …", and Results open
    /// once the stats for the stored vote arrive (after "Opening results…"): the sealed sheet is gone. Open
    /// Results are the tally (`bill.results.everyone`) or, under 5 Yea or Nay votes, the floor line (UX-34).
    func testVoteYeaStampsTheBallotAndOpensResults() throws {
        let credentials = try requireCredentials()
        let app = makeApp()
        app.launch()

        signInIfNeeded(app, credentials: credentials)
        waitForMainTabs(in: app)
        openTab(.bills, in: app)
        openFirstUnvotedBill(in: app)

        let locked = app.descendants(matching: .any)["bill.results.locked"]
        let everyone = app.descendants(matching: .any)["bill.results.everyone"]
        XCTAssertTrue(locked.waitForExistence(timeout: 20), "Results are sealed before a vote")
        XCTAssertFalse(everyone.exists, "no one's votes before a vote")

        tap(app.buttons["bill.vote.yea"])
        waitForVoteSummary("You voted Yea", in: app)
        attachScreenshot(named: "vote-yea-ballot-stamp", in: app)
        XCTAssertTrue(openResults(in: app).waitForExistence(timeout: 30), "Results open on the stats for the stored vote")
        XCTAssertFalse(locked.exists, "the sealed sheet is gone")
        closeBillDetail(in: app)
        dismissFirstVoteTopicPromptIfShown(in: app)
    }

    /// Civic Record spec 10.3 (b): vote Yea from the panel, then Change and Nay; the stamp says Nay.
    func testVoteBarYeaThenChange() throws {
        let credentials = try requireCredentials()
        let app = makeApp()
        app.launch()

        signInIfNeeded(app, credentials: credentials)
        waitForMainTabs(in: app)
        openTab(.bills, in: app)
        openFirstVotableBill(in: app)

        let change = app.buttons["bill.vote.change"]
        if change.waitForExistence(timeout: 5) {
            tap(change)
        }
        tap(app.buttons["bill.vote.yea"])
        waitForVoteSummary("You voted Yea", in: app)

        tap(app.buttons["bill.vote.change"])
        XCTAssertTrue(app.buttons["bill.vote.cancel"].waitForExistence(timeout: 5), "\"Change your vote\" with Cancel")
        tap(app.buttons["bill.vote.nay"])
        waitForVoteSummary("You voted Nay", in: app)
        closeBillDetail(in: app)
        dismissFirstVoteTopicPromptIfShown(in: app)
    }

    /// Civic Record spec 10.3 (c): Abstain on a fresh bill is a vote: the stamp says "You abstained" and Results
    /// open, as after a Yea or Nay (INT-11).
    func testAbstainOnAFreshBillOpensResults() throws {
        let credentials = try requireCredentials()
        let app = makeApp()
        app.launch()

        signInIfNeeded(app, credentials: credentials)
        waitForMainTabs(in: app)
        openTab(.bills, in: app)
        openFirstUnvotedBill(in: app)

        let locked = app.descendants(matching: .any)["bill.results.locked"]
        XCTAssertTrue(locked.waitForExistence(timeout: 20))
        tap(app.buttons["bill.vote.abstain"])
        waitForVoteSummary("You abstained", in: app)
        XCTAssertTrue(openResults(in: app).waitForExistence(timeout: 30), "Results open after Abstain")
        XCTAssertFalse(locked.exists)
        closeBillDetail(in: app)
        dismissFirstVoteTopicPromptIfShown(in: app)
    }

    /// Open Results: Everyone's tally row, or under 5 Yea or Nay votes the floor line that takes the tally's
    /// place (UX-34).
    private func openResults(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier IN %@", ["bill.results.everyone", "bill.results.belowFloor"]))
            .firstMatch
    }

    /// Civic Record spec 10.3 (d): at an accessibility text size (AX3) the panel holds one button. `bill.vote.open`
    /// opens the "Your vote" dialog; choosing Yea puts the full stamp in Your vote (`bill.vote.summary`) and the
    /// voted button (`bill.vote.change`, "Yea · Change") in the panel.
    func testAtAnAccessibilitySizeTheVoteButtonOpensTheDialog() throws {
        let credentials = try requireCredentials()
        let app = makeApp()
        app.launchArguments += Self.accessibilitySizeArguments
        app.launch()

        signInIfNeeded(app, credentials: credentials, keeping: Self.accessibilitySizeArguments)
        waitForMainTabs(in: app)
        openTab(.bills, in: app)
        openFirstUnvotedBill(in: app)

        XCTAssertFalse(app.buttons["bill.vote.nay"].exists, "one button, not three")
        tap(app.buttons["bill.vote.open"])
        // At this size the dialog is a popover, and Yea's id is on more than one element in it.
        tap(app.buttons.matching(identifier: "bill.vote.yea").firstMatch)
        waitForVoteSummary("You voted Yea", in: app)
        let voted = app.buttons["bill.vote.change"]
        XCTAssertTrue(voted.waitForExistence(timeout: 10), "the voted button in the panel")
        XCTAssertTrue(voted.label.hasPrefix("You voted Yea"), voted.label)
        attachScreenshot(named: "vote-ax3-voted", in: app)
        closeBillDetail(in: app)
        dismissFirstVoteTopicPromptIfShown(in: app)
    }

    /// AX3, for one launch only: no simulator setting changes.
    private static let accessibilitySizeArguments = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"]

    /// Spec D 2.1.1 and 2.1.2: a swipe skips the card (never a vote) and Undo puts it back.
    func testSwipeSkipsAndUndo() throws {
        let credentials = try requireCredentials()
        let app = makeApp()
        app.launch()

        signInIfNeeded(app, credentials: credentials)
        waitForMainTabs(in: app)
        openTab(.bills, in: app)

        // Skip a bill not voted on: one an earlier test voted on leaves the queue once the app knows, so Undo
        // can't bring it back (a run on 2026-11-02).
        guard let index = openFirstUnvotedBill(in: app) else { return }
        tapBack(in: app)
        let card = queueCard(index, in: app)
        scrollIntoView(card, in: app)
        let skippedLabel = card.label
        XCTAssertFalse(skippedLabel.isEmpty)

        let start = card.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
        let end = card.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end)

        // The toast lasts 4 seconds, so tap Undo as soon as it shows.
        let undo = app.buttons["undo.toast.undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 3), "Expected the Undo toast after a skip.")
        let skippedMessage = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Skipped")).firstMatch
        XCTAssertTrue(skippedMessage.exists, "Expected the toast to say what was skipped.")
        undo.tap()

        // The bill comes back to the queue.
        let restoredCard = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "home.queue.card.", skippedLabel)
        ).firstMatch
        XCTAssertTrue(
            restoredCard.waitForExistence(timeout: 10),
            "The skipped bill is back after Undo. First card now: \(firstQueueCard(in: app).label)"
        )
        XCTAssertFalse(undo.exists)
    }

    /// Spec D 2.5.7: Profile edits the followed topics in place. Turns one topic on (or off), checks
    /// Profile shows the change, then puts it back.
    func testProfileEditTopics() throws {
        let credentials = try requireCredentials()
        let app = makeApp()
        app.launch()

        signInIfNeeded(app, credentials: credentials)
        waitForMainTabs(in: app)
        openTab(.profile, in: app)
        XCTAssertTrue(app.descendants(matching: .any)["profile.screen"].waitForExistence(timeout: 20))

        let topic = "Fiscal Policy"
        let group = "Economic Policy"

        let wasFollowing = setTopic(topic, inGroup: group, following: nil, in: app)
        XCTAssertEqual(profileShowsTopic(topic, in: app), !wasFollowing)

        _ = setTopic(topic, inGroup: group, following: wasFollowing, in: app)
        XCTAssertEqual(profileShowsTopic(topic, in: app), wasFollowing)
    }

    // MARK: - Signed out (no account, nothing sent)

    /// Spec D 2.5.2: Create account stays disabled until "I'm 18 or older" is on. Types placeholder
    /// values into the local form and never taps Create account while it is enabled.
    func testSignedOutCreateAccountNeedsAdultToggle() throws {
        let app = makeApp()
        app.launch()
        try requireSignedOut(app)

        tap(app.buttons["login.createAccount"])

        let email = app.textFields["signup.email"]
        XCTAssertTrue(email.waitForExistence(timeout: 10))
        email.tap()
        email.typeText("signed-out-ui-test@example.invalid")

        typeNewPassword("Placeholder-Only-1", into: app.secureTextFields["signup.password"], in: app)
        typeNewPassword("Placeholder-Only-1", into: app.secureTextFields["signup.confirmPassword"], in: app)
        dismissKeyboardIfPresent(in: app)

        let submit = app.buttons["signup.submit"]
        let adult = app.switches["signup.adult"]
        scrollIntoView(adult, in: app)
        XCTAssertEqual(adult.value as? String, "0", "The age toggle starts off.")
        XCTAssertFalse(submit.isEnabled, "Create account is disabled until the age toggle is on.")

        flip(adult)
        XCTAssertEqual(adult.value as? String, "1")
        XCTAssertTrue(submit.isEnabled)

        flip(adult)
        XCTAssertFalse(submit.isEnabled)
    }

    /// Spec D 5.3: walks the signed-out screens (Login, Create account, Forgot password) and attaches
    /// a screenshot of each. Run it once per appearance and text size (`xcrun simctl ui`). Taps only
    /// navigation links; types nothing.
    func testSignedOutScreensForReview() throws {
        let app = makeApp()
        app.launch()
        try requireSignedOut(app)
        // The field exists before the launch animation ends (slower at large text sizes).
        RunLoop.current.run(until: Date().addingTimeInterval(2))

        attachScreenshot(named: "login", in: app)
        app.swipeUp()
        attachScreenshot(named: "login-scrolled", in: app)

        let createAccount = app.buttons["login.createAccount"]
        scrollIntoView(createAccount, in: app)
        tap(createAccount)
        XCTAssertTrue(app.textFields["signup.email"].waitForExistence(timeout: 10))
        attachScreenshot(named: "create-account", in: app)
        app.swipeUp()
        app.swipeUp()
        attachScreenshot(named: "create-account-scrolled", in: app)
        tapBack(in: app)

        let forgotPassword = app.buttons["login.forgotPassword"]
        scrollIntoView(forgotPassword, in: app)
        tap(forgotPassword)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        attachScreenshot(named: "forgot-password", in: app)
    }

    /// Civic Record spec 3.21 and 4.6: pushed screens use the system back button, so swipe-back works
    /// with no gesture delegate (R2's InteractivePopGesture is gone). From sign in, pushes Create account,
    /// drags from the left edge a third of the way and holds there, lets go so the screen snaps back, then
    /// swipes back all the way. Animations stay on: the half swipe is an interactive transition. Taps
    /// only a navigation link; types nothing.
    func testSignedOutSwipeBack() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-bbUITesting", "-bbResetState"]
        app.launch()
        try requireSignedOut(app)

        let createAccount = app.buttons["login.createAccount"]
        scrollIntoView(createAccount, in: app)
        tap(createAccount)
        let signupEmail = app.textFields["signup.email"]
        XCTAssertTrue(signupEmail.waitForExistence(timeout: 10))
        RunLoop.current.run(until: Date().addingTimeInterval(1))

        let window = app.windows.firstMatch
        let edge = window.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
        // A third of the way: well short of the halfway point where iOS completes the pop (at 42% it completed
        // once on Xcode Cloud's virtual Mac, 2026-11-02).
        let partWay = window.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
        let far = window.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5))

        // Part way, held, then let go: the swipe is cancelled and Create account stays.
        edge.press(forDuration: 0.05, thenDragTo: partWay, withVelocity: XCUIGestureVelocity(300), thenHoldForDuration: 1.5)
        // The cancel animates back; on a slow machine give it up to 5 s.
        for _ in 0..<10 where !signupEmail.isHittable {
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        XCTAssertTrue(signupEmail.isHittable, "A cancelled half swipe stays on Create account.")
        attachScreenshot(named: "swipe-back-cancelled", in: app)

        // All the way: back to sign in.
        edge.press(forDuration: 0.05, thenDragTo: far, withVelocity: .fast, thenHoldForDuration: 0)
        let loginEmail = app.textFields["login.email"]
        XCTAssertTrue(loginEmail.waitForExistence(timeout: 10))
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertTrue(loginEmail.isHittable, "A full swipe goes back to sign in.")
        XCTAssertFalse(signupEmail.exists, "Create account was popped.")
        attachScreenshot(named: "swipe-back-done", in: app)
    }

    // MARK: - Launch and sign-in

    private func makeApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-bbUITesting",
            "-bbResetState",
            "-bbDisableAnimations"
        ]
        return app
    }

    /// Reads the smoke-test account from the test runner's environment.
    /// xcodebuild forwards variables prefixed with `TEST_RUNNER_` to the test process with the
    /// prefix removed, so `TEST_RUNNER_BB_UI_TEST_EMAIL` arrives here as `BB_UI_TEST_EMAIL`.
    /// Nothing is written to disk; without credentials the signed-in journeys are skipped.
    private func requireCredentials(
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Credentials {
        let environment = ProcessInfo.processInfo.environment
        let email = environment["BB_UI_TEST_EMAIL"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let password = environment["BB_UI_TEST_PASSWORD"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !email.isEmpty, !password.isEmpty else {
            throw XCTSkip(
                "Signed-in UI tests need TEST_RUNNER_BB_UI_TEST_EMAIL and TEST_RUNNER_BB_UI_TEST_PASSWORD in the xcodebuild environment.",
                file: file,
                line: line
            )
        }

        return Credentials(email: email, password: password)
    }

    /// Skips the test unless the login screen shows (a signed-in session survives `-bbResetState`).
    private func requireSignedOut(_ app: XCUIApplication) throws {
        let email = app.textFields["login.email"]
        if email.waitForExistence(timeout: 20) { return }
        if tabButton(.bills, in: app).exists {
            throw XCTSkip("The simulator holds a signed-in session; signed-out tests need the login screen.")
        }
        XCTFail("Neither the login screen nor the tabs appeared.")
    }

    /// `keeping` are launch arguments the relaunch keeps (a text size for one launch).
    private func signInIfNeeded(_ app: XCUIApplication, credentials: Credentials, keeping: [String] = []) {
        if tabButton(.bills, in: app).waitForExistence(timeout: 10) {
            relaunchSignedInApp(app, keeping: keeping)
            return
        }

        let emailField = app.textFields["login.email"]
        XCTAssertTrue(emailField.waitForExistence(timeout: 15))
        emailField.tap()
        emailField.typeText(credentials.email)

        let passwordField = app.secureTextFields["login.password"]
        XCTAssertTrue(passwordField.waitForExistence(timeout: 10))
        passwordField.tap()
        passwordField.typeText(credentials.password)

        dismissKeyboardIfPresent(in: app)

        // The keyboard's Go usually signs in already, and the button goes as the tabs come in. Tap Sign in only
        // while the form is still up with it enabled.
        let submitButton = app.buttons["login.submit"]
        if !tabButton(.bills, in: app).waitForExistence(timeout: 5),
           submitButton.exists, submitButton.isEnabled, submitButton.isHittable {
            submitButton.tap()
        }

        relaunchSignedInApp(app, keeping: keeping)
    }

    private func relaunchSignedInApp(_ app: XCUIApplication, keeping: [String] = []) {
        XCTAssertTrue(tabButton(.bills, in: app).waitForExistence(timeout: 30))
        app.terminate()
        app.launchArguments = [
            "-bbUITesting",
            "-bbDisableAnimations"
        ] + keeping
        app.launch()
        dismissSavePasswordSheetIfShown(in: app, timeout: 8)
    }

    /// After a sign-in, iOS offers "Save Password?" in a sheet over the app, and shows it again after the
    /// relaunch. Nothing under it is hittable, so every scroll-and-tap fails while it is up. Screen
    /// recordings leave password sheets out, so it shows only in the accessibility hierarchy. Taps Not Now.
    private func dismissSavePasswordSheetIfShown(in app: XCUIApplication, timeout: TimeInterval = 0) {
        let sheet = app.sheets["Save Password?"]
        let shown = timeout > 0 ? sheet.waitForExistence(timeout: timeout) : sheet.exists
        guard shown else { return }
        let notNow = sheet.buttons["Not Now"]
        if notNow.exists {
            notNow.tap()
        } else {
            app.buttons["Not Now"].firstMatch.tap()
        }
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5), "The Save Password? sheet stays up.")
    }

    /// Types into a new-password field. iOS offers "Use Strong Password?" in a panel over the keyboard once the
    /// field has focus, and the panel takes the keystrokes typed after it shows (screen recordings leave it out).
    /// Closes the panel, then checks every character landed, and clears and types again once if not.
    private func typeNewPassword(
        _ text: String,
        into field: XCUIElement,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(field.waitForExistence(timeout: 10), file: file, line: line)
        field.tap()
        for attempt in 0..<2 {
            closeStrongPasswordPanelIfShown(in: app, timeout: attempt == 0 ? 2 : 1)
            field.typeText(text)
            closeStrongPasswordPanelIfShown(in: app, timeout: 1)
            let typed = secureCharacterCount(field)
            if typed == text.count { return }
            field.tap()
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: typed))
        }
        XCTFail("Use Strong Password? kept taking the keystrokes.", file: file, line: line)
    }

    private func closeStrongPasswordPanelIfShown(in app: XCUIApplication, timeout: TimeInterval) {
        let title = NSPredicate(format: "label == %@", "Use Strong Password?")
        let panel = app.windows.containing(title).firstMatch
        guard panel.waitForExistence(timeout: timeout) else { return }
        let close = panel.buttons["Close"]
        if close.exists { close.tap() }
        _ = app.staticTexts.matching(title).firstMatch.waitForNonExistence(timeout: 3)
    }

    /// A secure field's value is one bullet per character.
    private func secureCharacterCount(_ field: XCUIElement) -> Int {
        ((field.value as? String) ?? "").filter { $0 == "•" }.count
    }

    private func dismissKeyboardIfPresent(in app: XCUIApplication) {
        let keyboard = app.keyboards.element
        guard keyboard.waitForExistence(timeout: 1) else { return }
        // With the Mac's keyboard connected (Simulator > I/O > Keyboard, which Simulator can turn on by itself),
        // the on-screen keyboard stays below the screen: its keys can't be tapped and nothing covers the form.
        guard keyboard.frame.minY < app.windows.firstMatch.frame.maxY - 1 else { return }

        let dismissalButtons = ["Done", "Return", "Go"]
        for label in dismissalButtons {
            let button = app.keyboards.buttons[label]
            if button.exists && button.isHittable {
                button.tap()
                return
            }
        }

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
    }

    // MARK: - Tabs

    private enum Tab {
        case bills, updates, congress, profile

        /// The tab's identifier. The Bills tab keeps R1's internal id `tab.billboard`.
        var identifier: String {
            switch self {
            case .bills: return "tab.billboard"
            case .updates: return "tab.updates"
            case .congress: return "tab.congress"
            case .profile: return "tab.profile"
            }
        }
    }

    private func waitForMainTabs(in app: XCUIApplication) {
        XCTAssertTrue(tabButton(.bills, in: app).waitForExistence(timeout: 30))
        XCTAssertTrue(tabButton(.updates, in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(tabButton(.congress, in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(tabButton(.profile, in: app).waitForExistence(timeout: 5))
    }

    private func openTab(_ tab: Tab, in app: XCUIApplication) {
        let button = tabButton(tab, in: app)
        XCTAssertTrue(button.waitForExistence(timeout: 20))
        tap(button)
    }

    private func tabButton(_ tab: Tab, in app: XCUIApplication) -> XCUIElement {
        app.buttons[tab.identifier]
    }

    // MARK: - Bills

    private func firstQueueCard(in app: XCUIApplication) -> XCUIElement {
        queueCard(0, in: app)
    }

    private func queueCard(_ index: Int, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["home.queue.card.\(index)"]
    }

    /// The queue states by id (Civic Record slice 6): each is a record notice or a combined element, so
    /// no element is labelled with its title alone ("You're all caught up", "Updating your bills…").
    private func queueCaughtUp(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["home.queue.caughtUp"]
    }

    /// The first sync's placeholder, shown in place of the list.
    private func queueSyncPlaceholder(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["home.queue.syncing"]
    }

    /// The sync capsule over the list ("Updating your bills…" or "Refreshing your bills…").
    private func queueSyncCapsule(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["home.queue.syncCapsule"]
    }

    private func waitForHomeQueueCard(
        in app: XCUIApplication,
        timeout: TimeInterval = 90,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let firstQueueCard = firstQueueCard(in: app)
        let syncPlaceholder = queueSyncPlaceholder(in: app)
        let syncCapsule = queueSyncCapsule(in: app)
        let allCaughtUp = queueCaughtUp(in: app)
        let expandHistoryButton = app.buttons["home.queue.expandHistory"]
        var scanDirectionIsDown = true
        var scanPasses = 0

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if firstQueueCard.exists {
                return firstQueueCard
            }

            if allCaughtUp.exists {
                app.swipeUp()

                if expandHistoryButton.waitForExistence(timeout: 2) {
                    scrollToElement(expandHistoryButton, in: app, maxSwipes: 4)
                    tap(expandHistoryButton)
                    waitForHomeQueueRefresh(in: app, timeout: 20)
                    continue
                }

                app.swipeDown()
                RunLoop.current.run(until: Date().addingTimeInterval(2))
                continue
            }

            if !syncPlaceholder.exists && !syncCapsule.exists {
                if scanDirectionIsDown {
                    app.swipeUp()
                } else {
                    app.swipeDown()
                }

                scanPasses += 1
                if scanPasses >= 3 {
                    scanDirectionIsDown.toggle()
                    scanPasses = 0
                    openTab(.bills, in: app)
                }
            }

            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }

        XCTFail("Timed out waiting for the signed-in Bills list to load.", file: file, line: line)
        return firstQueueCard
    }

    private func waitForHomeQueueRefresh(in app: XCUIApplication, timeout: TimeInterval) {
        let firstQueueCard = firstQueueCard(in: app)
        let allCaughtUp = queueCaughtUp(in: app)

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if firstQueueCard.exists || allCaughtUp.exists {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }
    }

    /// Opens the first card whose bill detail shows the vote bar. Every bill page has the bar, a
    /// decided bill's too (Civic Record project decision 1); a card whose page does not show it in time
    /// (a bill that did not load) is skipped by going back and trying the next card.
    private func openFirstVotableBill(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        _ = waitForHomeQueueCard(in: app, file: file, line: line)

        for index in 0..<6 {
            let card = queueCard(index, in: app)
            guard card.waitForExistence(timeout: 5) else { break }
            scrollIntoView(card, in: app)
            tap(card)
            waitForBillDetailPresentation(in: app)

            if voteBarControl(in: app).waitForExistence(timeout: 15) {
                return
            }
            tapBack(in: app)
        }

        XCTFail("No bill with a vote bar among the first cards.", file: file, line: line)
    }

    /// Any control of the vote panel: the three buttons, the one Vote button, or the voted panel. The panel's
    /// own `bill.vote.bar` id is overridden by the page's `bill.detail` in the accessibility tree.
    private func voteBarControl(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier IN %@", ["bill.vote.yea", "bill.vote.open", "bill.vote.change", "bill.vote.summary"])
        ).firstMatch
    }

    /// Opens the first card whose bill page shows no vote: the three buttons (or the one Vote button at the
    /// accessibility sizes) and no ballot stamp. A card already voted on (on another device) is skipped.
    @discardableResult
    private func openFirstUnvotedBill(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Int? {
        _ = waitForHomeQueueCard(in: app, file: file, line: line)

        var index = 0
        var weeksAdded = 0
        while index < 16 {
            let card = queueCard(index, in: app)
            guard card.waitForExistence(timeout: 5) else {
                // Out of cards: earlier runs voted on this week's bills. Show one more week and go on.
                if weeksAdded < 3, showOneMoreWeek(in: app) {
                    weeksAdded += 1
                    continue
                }
                break
            }
            scrollIntoView(card, in: app)
            tap(card)
            waitForBillDetailPresentation(in: app)

            let unvoted = app.buttons["bill.vote.yea"].waitForExistence(timeout: 15)
                || app.buttons["bill.vote.open"].waitForExistence(timeout: 2)
            if unvoted, !voteSummary(in: app).exists, !app.buttons["bill.vote.change"].exists {
                return index
            }
            tapBack(in: app)
            index += 1
        }

        XCTFail("No unvoted bill among the first cards.", file: file, line: line)
        return nil
    }

    /// Taps "Show one more week" under the queue, if it is there, and waits for the older bills.
    private func showOneMoreWeek(in app: XCUIApplication) -> Bool {
        let button = app.buttons["home.queue.expandHistory"]
        for _ in 0..<8 {
            if isReachable(button, in: app) { break }
            app.swipeUp()
        }
        guard isReachable(button, in: app) else { return false }
        tap(button)
        waitForHomeQueueRefresh(in: app, timeout: 20)
        return true
    }

    private func tap(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: 20), file: file, line: line)

        // Tap the centre, as a finger would, whenever it is on screen. XCUITest's own tap aims at the part of
        // the element it sees uncovered, and on the tab screens a full-screen layer (see `isReachable`) leaves
        // only a strip along the bottom edge uncovered: there the tap lands under the tab capsule or in the
        // home indicator's zone and does nothing (the Weekly Brief, the one Vote button; 2026-11-02).
        let frame = element.frame
        let window = XCUIApplication().windows.firstMatch.frame
        if !frame.isEmpty, window.contains(CGPoint(x: frame.midX, y: frame.midY)) {
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        } else {
            element.tap()
        }
    }

    // MARK: - Bill detail

    private func voteSummary(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["bill.vote.summary"]
    }

    /// Votes Yea from the bar unless the bill already has a vote (the bar then shows the summary).
    private func castYeaIfNotVoted(in app: XCUIApplication) {
        if voteSummary(in: app).waitForExistence(timeout: 5) {
            return
        }
        tap(app.buttons["bill.vote.yea"])
        waitForVoteSummary("You voted Yea", in: app)
    }

    private func waitForVoteSummary(
        _ text: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let summary = voteSummary(in: app)
        XCTAssertTrue(summary.waitForExistence(timeout: 20), file: file, line: line)
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: summary)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 10), .completed, "Expected \"\(text)\", got \"\(summary.label)\"", file: file, line: line)
    }

    private func waitForBillDetailPresentation(in app: XCUIApplication) {
        let detailRoot = app.descendants(matching: .any)["bill.detail"]
        let billTitle = app.navigationBars.staticTexts["Bill"]
        let loadingState = app.staticTexts["Loading bill details…"]
        let errorState = app.staticTexts["Couldn't load this bill."]

        XCTAssertTrue(
            detailRoot.waitForExistence(timeout: 20)
                || billTitle.waitForExistence(timeout: 20)
                || loadingState.waitForExistence(timeout: 20)
                || errorState.waitForExistence(timeout: 20)
        )
    }

    /// Picks the first reason the picker shows: the reasons come in each person's own order (feature review N13),
    /// so no one reason is sure to show before More reasons.
    private func provideOptionalFeedback(in app: XCUIApplication) {
        let feedbackButton = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@ AND identifier != %@", "bill.feedback.", "bill.feedback.more")
        ).firstMatch
        if feedbackButton.waitForExistence(timeout: 10) {
            tap(feedbackButton)
        }
    }

    /// After the first saved vote, an account that follows no topics gets the "Want more bills like
    /// this?" sheet (spec D 2.5.6) once the bill page is left (Done or Back; Civic Record spec 4.39). Not now
    /// closes it without saving anything.
    private func dismissFirstVoteTopicPromptIfShown(in app: XCUIApplication) {
        let notNow = app.buttons["topicPicker.notNow"]
        if notNow.waitForExistence(timeout: 3) {
            tap(notNow)
        }
    }

    private func closeBillDetail(in app: XCUIApplication) {
        let doneButton = app.buttons["Done"]
        if doneButton.waitForExistence(timeout: 10) {
            tap(doneButton)
            return
        }

        tapBack(in: app)
    }

    // MARK: - Updates

    private func openWeeklyBriefIfAvailable(in app: XCUIApplication) {
        let weeklyBrief = app.buttons["updates.weeklyBrief.open"]
        XCTAssertTrue(weeklyBrief.waitForExistence(timeout: 20))
        scrollIntoView(weeklyBrief, in: app)
        tap(weeklyBrief)

        let detailRoot = app.descendants(matching: .any)["weeklyBrief.detail"]
        let title = app.navigationBars.staticTexts["Weekly Brief"]
        XCTAssertTrue(
            detailRoot.waitForExistence(timeout: 20)
                || title.waitForExistence(timeout: 20)
        )
        tapBack(in: app)
    }

    // MARK: - Congress

    private func assertMemberDetailsLoaded(in app: XCUIApplication) {
        XCTAssertTrue(app.buttons["member.subscription"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Civic Profile"].waitForExistence(timeout: 20))
    }

    private func openFirstUnfollowedSenateMember(in app: XCUIApplication) {
        for index in 0..<8 {
            let row = app.buttons["congress.senate.member.\(index)"]
            guard row.waitForExistence(timeout: 5) else { continue }
            scrollIntoView(row, in: app)
            tap(row)

            let followButton = app.buttons["member.subscription"]
            XCTAssertTrue(followButton.waitForExistence(timeout: 20))
            // VoiceOver label: the action the button performs.
            if followButton.label == "Follow" {
                return
            }

            tapBack(in: app)
        }

        XCTFail("Could not find a Senate member you don't follow in the first visible results.")
    }

    private func toggleMemberFollow(in app: XCUIApplication, expectedLabel: String) {
        let button = app.buttons["member.subscription"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        XCTAssertEqual(button.label, expectedLabel)
        scrollIntoView(button, in: app)
        tap(button)

        let nextLabel = expectedLabel == "Follow" ? "Unfollow" : "Follow"
        let predicate = NSPredicate(format: "label == %@", nextLabel)
        expectation(for: predicate, evaluatedWith: button)
        waitForExpectations(timeout: 20)
    }

    // MARK: - Profile

    /// Opens the topic picker from Profile, sets `topic` (toggles it when `following` is nil), saves,
    /// and returns whether the topic was followed before.
    @discardableResult
    private func setTopic(
        _ topic: String,
        inGroup group: String,
        following: Bool?,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        let edit = app.buttons["profile.topics.edit"]
        scrollIntoView(edit, in: app, file: file, line: line)
        tap(edit, file: file, line: line)

        let groupHeader = app.buttons["topicPicker.group.\(group)"]
        XCTAssertTrue(groupHeader.waitForExistence(timeout: 15), file: file, line: line)
        let chip = app.buttons["topicPicker.topic.\(topic)"]
        if !chip.waitForExistence(timeout: 2) {
            tap(groupHeader, file: file, line: line)
        }
        scrollIntoView(chip, in: app, file: file, line: line)

        let wasSelected = chip.isSelected
        let target = following ?? !wasSelected
        if target != wasSelected {
            tap(chip, file: file, line: line)
            let selected = NSPredicate(format: "isSelected == %@", NSNumber(value: target))
            let expectation = XCTNSPredicateExpectation(predicate: selected, object: chip)
            XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed, file: file, line: line)
            tap(app.buttons["topicPicker.save"], file: file, line: line)
        } else {
            tap(app.buttons["topicPicker.cancel"], file: file, line: line)
        }

        let closed = NSPredicate(format: "exists == false")
        let sheetClosed = XCTNSPredicateExpectation(predicate: closed, object: groupHeader)
        XCTAssertEqual(XCTWaiter.wait(for: [sheetClosed], timeout: 20), .completed, "The topic picker should close after saving.", file: file, line: line)
        return wasSelected
    }

    /// Whether Profile's "Topics you follow" lists `topic`.
    private func profileShowsTopic(_ topic: String, in app: XCUIApplication) -> Bool {
        let topics = app.descendants(matching: .any).matching(identifier: "profile.topics").firstMatch
        let empty = app.descendants(matching: .any)["profile.topics.empty"]
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if topics.exists { return topics.label.contains(topic) }
            if empty.exists { return false }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        return false
    }

    // MARK: - Shared

    private func scrollToElement(
        _ element: XCUIElement,
        in app: XCUIApplication,
        maxSwipes: Int = 6,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(element.waitForExistence(timeout: 20), file: file, line: line)

        var attempts = 0
        while !isReachable(element, in: app) && attempts < maxSwipes {
            app.swipeUp()
            attempts += 1
        }

        XCTAssertTrue(isReachable(element, in: app), file: file, line: line)
    }

    /// Whether a finger could tap `element` where it is now. `isHittable` says no for everything on the tab
    /// screens: a full-screen toolbar layer and the tab capsule's container sit over the content in the
    /// accessibility tree, though touches go through them. So this also takes an element whose centre is on
    /// screen between the top bar and the tab capsule; `tap(_:)` taps the centre.
    private func isReachable(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        guard element.exists else { return false }
        if element.isHittable { return true }
        let frame = element.frame
        guard !frame.isEmpty else { return false }
        let window = app.windows.firstMatch.frame
        var top = window.minY
        let navigationBar = app.navigationBars.firstMatch
        if navigationBar.exists {
            let bar = navigationBar.frame
            // A button in the bar itself (a member's Follow) sits over everything.
            if bar.contains(CGPoint(x: frame.midX, y: frame.midY)) { return true }
            top = max(top, bar.maxY)
        }
        var bottom = window.maxY
        let tabCapsule = tabButton(.bills, in: app)
        if tabCapsule.exists { bottom = min(bottom, tabCapsule.frame.minY) }
        return frame.midY > top && frame.midY < bottom && frame.midX > window.minX && frame.midX < window.maxX
    }

    /// Scrolls down (then back up) until `element` can be tapped. Unlike `scrollToElement`, it also
    /// works for an element that is not created until it scrolls on screen (lazy lists).
    private func scrollIntoView(
        _ element: XCUIElement,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        dismissSavePasswordSheetIfShown(in: app)
        for _ in 0..<8 {
            if isReachable(element, in: app) { return }
            app.swipeUp()
        }
        for _ in 0..<8 {
            if isReachable(element, in: app) { return }
            app.swipeDown()
        }
        XCTAssertTrue(isReachable(element, in: app), "Could not scroll \(element) into view.", file: file, line: line)
    }

    /// Flips a SwiftUI Toggle: its inner switch when exposed, else the trailing edge of the row.
    private func flip(_ toggle: XCUIElement) {
        let inner = toggle.switches.firstMatch
        if inner.exists {
            inner.tap()
        } else {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        }
    }

    private func attachScreenshot(named name: String, in app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Taps the system back button: by its "Back" label, else the first button in the navigation bar (the
    /// label can be the previous screen's title).
    private func tapBack(in app: XCUIApplication) {
        let backButton = app.buttons["Back"]
        if backButton.waitForExistence(timeout: 10) {
            backButton.tap()
            return
        }
        let systemBack = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(systemBack.exists, "No back button.")
        systemBack.tap()
    }
}
