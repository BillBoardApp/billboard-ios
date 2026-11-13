import Foundation

extension Notification.Name {
    /// Posted when the app receives a push that implies the bills manifest changed.
    static let billboardBillsManifestDidChange = Notification.Name("BillBoard.billsManifest.didChange")

    /// Posted when the app receives a push about a specific bill guid.
    /// userInfo: ["guid": String, "notificationType": String?, "user_interaction": Bool]
    static let billboardBillDidChange = Notification.Name("BillBoard.bill.didChange")

    /// Posted when the app receives a push about bill alerts.
    static let billboardBillAlertDidChange = Notification.Name("BillBoard.billAlert.didChange")

    /// Posted when a new APNs device token is available.
    /// userInfo: ["token": String]
    static let billboardDidRegisterPushToken = Notification.Name("BillBoard.pushToken.didRegister")

    /// Posted after a tapped bill, multi-bill or weekly-brief push was saved to
    /// `PendingPushDeepLink`, so a running app opens it now (or once navigation is allowed)
    /// instead of leaving it to replay on a later launch.
    static let billboardDidSavePendingPushDeepLink = Notification.Name("BillBoard.pushDeepLink.didSavePending")

    /// Posted when the app receives a bill deep link URL.
    /// userInfo: ["guid": String]
    static let billboardDidReceiveBillDeepLink = Notification.Name("BillBoard.deepLink.bill.didReceive")

    /// Posted when a foreground surface asks to request push permission contextually.
    static let billboardShouldPromptPushPermission = Notification.Name("BillBoard.pushPermission.shouldPrompt")

    /// Posted when the app should refresh APNs registration without prompting.
    static let billboardShouldSyncPushRegistration = Notification.Name("BillBoard.pushRegistration.shouldSync")

    /// Posted when the signed-in session can no longer produce usable Cognito tokens.
    /// userInfo: ["message": String]
    static let billboardAuthSessionInvalidated = Notification.Name("BillBoard.auth.sessionInvalidated")

    /// Posted on the main actor after an explicit vote (Yea, Nay or Abstain) is saved on bill
    /// detail. The first-vote topic prompt listens for it (spec D 2.5.6).
    /// userInfo: ["guid": String, "vote": String (`VoteType.rawValue`, optional)]
    static let billboardVoteSaved = Notification.Name("BillBoard.vote.saved")

    /// Asks the tab shell to present the topic picker over the current tab (spec D 2.5.9).
    static let billboardRequestTopicPicker = Notification.Name("BillBoard.request.topicPicker")

    /// Asks the tab shell to present the location editor over the current tab (spec D 2.5.9).
    static let billboardRequestLocationEditor = Notification.Name("BillBoard.request.locationEditor")

    /// Asks the tab shell to open the Congress tab at its root, where Members you follow and its
    /// Unfollow buttons are, not on a screen left open there (Profile's Manage in Congress).
    static let billboardRequestCongressFollows = Notification.Name("BillBoard.request.congressFollows")
}
