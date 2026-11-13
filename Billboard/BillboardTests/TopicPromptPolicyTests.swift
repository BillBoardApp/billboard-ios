import UIKit
import XCTest
@testable import Billboard

/// "Want more bills like this?" (spec D 2.5.6) is asked once per account, after a saved vote, only
/// while the profile follows no topics and no life areas. Followed members do not count. It is asked on an
/// event, not after a timer (Civic Record spec 4.39): the bill page's vote saved, then Done or leaving the
/// page. Storage uses a throwaway `UserDefaults` suite.
@MainActor
final class TopicPromptPolicyTests: XCTestCase {
    private func profile(
        id: String = "user-a",
        topics: [String] = [],
        lifeAreas: [String] = [],
        members: [UUID] = []
    ) -> UserProfile {
        UserProfile.placeholder().updating(
            id: id,
            state: "VA",
            district: "11",
            subscribedSubCategories: topics,
            subscribedLifeAreas: lifeAreas,
            subscribedMemberIDs: members
        )
    }

    func testAskedWhenNothingIsFollowedAndNotAskedBefore() {
        XCTAssertTrue(TopicPromptPolicy.shouldPrompt(profile: profile(), promptShown: false))
        XCTAssertTrue(
            TopicPromptPolicy.shouldPrompt(profile: profile(members: [UUID(), UUID()]), promptShown: false),
            "followed members (your representatives) do not count"
        )
    }

    func testNeverAskedWhenTopicsOrLifeAreasAreFollowed() {
        XCTAssertFalse(TopicPromptPolicy.shouldPrompt(profile: profile(topics: [SubscriptionsConfig.subHousing]), promptShown: false))
        XCTAssertFalse(TopicPromptPolicy.shouldPrompt(profile: profile(lifeAreas: [SubscriptionsConfig.lifeTaxes]), promptShown: false))
    }

    func testNeverAskedTwiceOrWithoutAnAccount() {
        XCTAssertFalse(TopicPromptPolicy.shouldPrompt(profile: profile(), promptShown: true))
        XCTAssertFalse(TopicPromptPolicy.shouldPrompt(profile: profile(id: ""), promptShown: false))
        XCTAssertFalse(TopicPromptPolicy.shouldPrompt(profile: profile(id: "  "), promptShown: false))
    }

    func testShownFlagIsPerAccount() throws {
        let suiteName = "TopicPromptPolicyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = profile(id: "user-a")
        let second = profile(id: "user-b")
        func shouldPrompt(_ profile: UserProfile) -> Bool {
            TopicPromptPolicy.shouldPrompt(
                profile: profile,
                promptShown: FirstRunStorage.topicPromptShown(userID: profile.id, defaults: defaults)
            )
        }

        XCTAssertTrue(shouldPrompt(first))
        FirstRunStorage.markTopicPromptShown(userID: first.id, defaults: defaults)
        XCTAssertFalse(shouldPrompt(first), "shown once")
        XCTAssertTrue(shouldPrompt(second), "another account on the same device is still asked")
    }

    // MARK: - The trigger (Civic Record spec 4.39): an event, not a timer

    private let request = FirstVoteTopicPromptTrigger.Request(userID: "user-a", votedGUID: "BILLS-119hr900")

    /// Done after a saved vote asks; so does leaving the page (Back or a swipe), whichever comes second.
    func testASavedVoteThenDoneOrLeavingThePageAsks() {
        for ending in [FirstVoteTopicPromptTrigger.Ending.done, .left] {
            var trigger = FirstVoteTopicPromptTrigger()
            XCTAssertNil(trigger.voteSaved(request), "\(ending): not while the page is up (Results just opened)")
            XCTAssertEqual(trigger.pageEnded(ending), request, "\(ending)")
        }
    }

    /// A vote whose write ends after the page was left asks when it is saved.
    func testAVoteSavedAfterThePageWasLeftAsksThen() {
        var trigger = FirstVoteTopicPromptTrigger()
        XCTAssertNil(trigger.pageEnded(.left), "no vote saved yet")
        XCTAssertEqual(trigger.voteSaved(request), request)
    }

    /// No saved vote (none made, or refused): leaving the page asks nothing. A page asks once.
    func testNothingIsAskedWithoutASavedVoteAndAPageAsksOnce() {
        var unvoted = FirstVoteTopicPromptTrigger()
        XCTAssertNil(unvoted.pageEnded(.done))
        XCTAssertNil(unvoted.pageEnded(.left))

        var trigger = FirstVoteTopicPromptTrigger()
        _ = trigger.voteSaved(request)
        XCTAssertEqual(trigger.pageEnded(.done), request)
        XCTAssertNil(trigger.pageEnded(.left), "Done then the pop asks once")
        let change = FirstVoteTopicPromptTrigger.Request(userID: "user-a", votedGUID: "BILLS-119hr900")
        XCTAssertNil(trigger.voteSaved(change), "a later vote on the same page does not ask again")
    }

    /// What the page posts is what `TabsBar` reads back.
    func testTheRequestTravelsInTheNotification() {
        XCTAssertEqual(FirstVoteTopicPromptTrigger.Request(userInfo: request.userInfo), request)
        let noGuid = FirstVoteTopicPromptTrigger.Request(userID: "user-a", votedGUID: nil)
        XCTAssertEqual(FirstVoteTopicPromptTrigger.Request(userInfo: noGuid.userInfo), noGuid)
        XCTAssertNil(FirstVoteTopicPromptTrigger.Request(userInfo: ["guid": "BILLS-119hr900"]), "no account, no request")
        XCTAssertNil(FirstVoteTopicPromptTrigger.Request(userInfo: nil))
        XCTAssertEqual(Notification.Name.billboardFirstVoteTopicPromptTrigger.rawValue, "BillBoard.firstVoteTopicPrompt.trigger")
    }

    /// The bill page's probe calls "left" when the page is taken off its navigation stack, not when a page is
    /// pushed over it (a sponsor's page), so the prompt never covers a page the person went on to.
    func testThePageLeaveProbeFiresOnPopNotOnPush() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.windowLevel = .normal + 1
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        let root = UIViewController()
        let navigation = UINavigationController(rootViewController: root)
        window.rootViewController = navigation
        window.makeKeyAndVisible()

        var leaves = 0
        let page = UIViewController()
        let probe = PageLeaveProbe.Controller()
        probe.onLeft = { leaves += 1 }
        page.addChild(probe)
        page.view.addSubview(probe.view)
        probe.didMove(toParent: page)

        navigation.pushViewController(page, animated: false)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        navigation.pushViewController(UIViewController(), animated: false)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(leaves, 0, "a page pushed over it")
        navigation.popViewController(animated: false)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(leaves, 0, "back on top")
        navigation.popViewController(animated: false)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(leaves, 1, "popped: left")
    }

    /// Every guard `TabsBar` kept from the timer: `shouldPrompt`, the same account, the tabs taking input, no
    /// tour, no other sheet.
    func testTheTriggerKeepsEveryGuard() {
        func presents(
            _ profile: UserProfile? = nil,
            shown: Bool = false,
            votedBy: String = "user-a",
            interactive: Bool = true,
            tour: Bool = false,
            sheet: Bool = false
        ) -> Bool {
            TopicPromptPolicy.presents(
                profile: profile ?? self.profile(),
                promptShown: shown,
                votedByUserID: votedBy,
                isInteractive: interactive,
                isShowingTour: tour,
                isSheetUp: sheet
            )
        }
        XCTAssertTrue(presents())
        XCTAssertFalse(presents(shown: true), "asked before")
        XCTAssertFalse(presents(self.profile(topics: [SubscriptionsConfig.subHousing])), "follows a topic")
        XCTAssertFalse(presents(votedBy: "user-b"), "another account voted")
        XCTAssertFalse(presents(interactive: false), "the tabs are not taking input")
        XCTAssertFalse(presents(tour: true), "the tour is showing")
        XCTAssertFalse(presents(sheet: true), "another sheet is up")
    }
}
