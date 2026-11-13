import SwiftUI

/// When "Want more bills like this?" is asked (spec D 2.5.6; Civic Record spec 4.39). Pure, for
/// `TopicPromptPolicyTests`.
enum TopicPromptPolicy {
    /// True after a saved vote (Yea, Nay or Abstain) when the signed-in profile follows no topics and
    /// no life areas (followed members do not count) and this account has not been asked before.
    static func shouldPrompt(profile: UserProfile, promptShown: Bool) -> Bool {
        guard profile.id.trimmedNonEmpty != nil, !promptShown else { return false }
        return profile.subscribedSubCategories.isEmpty && profile.subscribedLifeAreas.isEmpty
    }

    /// Whether `TabsBar` presents the prompt when a bill page's `FirstVoteTopicPromptTrigger` fires: every guard
    /// of `shouldPrompt`, the account that voted is still the one signed in, the tabs take input, the tour is
    /// not showing and no other sheet is up. There is no timer: the trigger is the event.
    static func presents(
        profile: UserProfile,
        promptShown: Bool,
        votedByUserID: String,
        isInteractive: Bool,
        isShowingTour: Bool,
        isSheetUp: Bool
    ) -> Bool {
        guard votedByUserID == profile.id, isInteractive, !isShowingTour, !isSheetUp else { return false }
        return shouldPrompt(profile: profile, promptShown: promptShown)
    }
}

/// When a bill page asks for the first-vote topic prompt (Civic Record spec 4.39, 5.1): after a vote saved on
/// the page, once Done is tapped or the page is left, whichever comes second (a vote whose write ends after
/// the page was left asks then). Once per page. On a timer it would cover the reasons the person is about to
/// tap and the Results that just opened. `BillDetail` posts what `fire` returns as
/// `.billboardFirstVoteTopicPromptTrigger`; `TabsBar` decides with `TopicPromptPolicy.presents`.
struct FirstVoteTopicPromptTrigger: Equatable {
    /// What the bill page passes up: the account that voted and the guid the vote went to (the prompt's seed).
    struct Request: Equatable {
        let userID: String
        let votedGUID: String?

        var userInfo: [AnyHashable: Any] {
            var info: [AnyHashable: Any] = ["userID": userID]
            if let votedGUID { info["guid"] = votedGUID }
            return info
        }

        init(userID: String, votedGUID: String?) {
            self.userID = userID
            self.votedGUID = votedGUID
        }

        init?(userInfo: [AnyHashable: Any]?) {
            guard let userID = userInfo?["userID"] as? String else { return nil }
            self.init(userID: userID, votedGUID: userInfo?["guid"] as? String)
        }
    }

    /// How the page ended.
    enum Ending: Equatable {
        /// Done, after the post-vote block.
        case done
        /// Back, a swipe back, or anything else that took the page off its navigation stack.
        case left
    }

    private(set) var saved: Request?
    private(set) var hasEnded = false
    private(set) var hasFired = false

    /// A vote made on the page was stored. Returns the request to post if the page has already ended.
    mutating func voteSaved(_ request: Request) -> Request? {
        saved = request
        return fireIfReady()
    }

    /// Done was tapped or the page was left. Returns the request to post if a vote here was saved.
    mutating func pageEnded(_ ending: Ending) -> Request? {
        hasEnded = true
        return fireIfReady()
    }

    private mutating func fireIfReady() -> Request? {
        guard let saved, hasEnded, !hasFired else { return nil }
        hasFired = true
        return saved
    }
}

extension Notification.Name {
    /// Posted by a bill page when the first-vote topic prompt may show (`FirstVoteTopicPromptTrigger`);
    /// `userInfo` is `FirstVoteTopicPromptTrigger.Request.userInfo`.
    static let billboardFirstVoteTopicPromptTrigger = Notification.Name("BillBoard.firstVoteTopicPrompt.trigger")
}

/// The first-vote topic prompt (spec D 2.5.6): the topic picker seeded from the bill just voted on.
/// `TabsBar` presents it as a sheet once per account (`FirstRunStorage.markTopicPromptShown`); Save
/// and Not now both end it. The starter-feed banner offers the same picker later.
struct FirstVoteTopicPrompt: View {
    let seedBill: Bill?
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            TopicPickerView(context: .firstVote(seedBill: seedBill), onDone: onDone)
        }
        .presentationDragIndicator(.visible)
        // Paper behind the picker (spec 4.7); this context has no bar.
        .presentationBackground(BillboardColors.background)
        .accessibilityIdentifier("firstVoteTopicPrompt")
    }
}
