import XCTest
@testable import Billboard

/// `PushNotificationPayload` parses APNs `userInfo` from the notifier (new schema) and
/// older payloads (legacy `event` / `guid` / `alert_id` keys).
final class PushNotificationPayloadTests: XCTestCase {
    // MARK: - Domain

    @MainActor
    func testDomainParsingIsTrimmedAndCaseInsensitive() {
        let expectations: [(raw: String?, domain: PushNotificationPayload.Domain)] = [
            ("bill", .bill),
            (" BILL ", .bill),
            ("bill_alert", .billAlert),
            ("billAlert", .billAlert),
            ("alerts", .billAlert),
            ("Bill-Alert", .billAlert),
            ("weekly_digest", .weeklyDigest),
            ("weekly-digest", .weeklyDigest),
            ("member", .unknown),
            ("", .unknown),
            (nil, .unknown)
        ]

        for (raw, domain) in expectations {
            let userInfo: [AnyHashable: Any] = raw.map { ["domain": $0] } ?? [:]
            XCTAssertEqual(PushNotificationPayload(userInfo: userInfo).domain, domain, String(describing: raw))
        }
    }

    // MARK: - Bill payloads (shape sent by userNotifier)

    @MainActor
    func testSingleBillPayload() {
        let payload = PushNotificationPayload(userInfo: [
            "aps": ["alert": ["title": "A bill you follow changed", "body": "Open BillBoard"]],
            "domain": "bill",
            "billId": "BILLS-119hr1234ih",
            "billIds": ["BILLS-119hr1234ih"],
            "notificationType": "Updated"
        ])

        XCTAssertEqual(payload.domain, .bill)
        XCTAssertEqual(payload.notificationType, .updated)
        XCTAssertEqual(payload.normalizedBillGuid, "BILLS-119hr1234ih")
        XCTAssertEqual(payload.allBillIds, ["BILLS-119hr1234ih"])
        XCTAssertTrue(payload.isBillsManifestRelevant)
        XCTAssertFalse(payload.isBillAlertRelevant)
        XCTAssertFalse(payload.isWeeklyDigestRelevant)
        XCTAssertEqual(payload.apsTitle, "A bill you follow changed")
        XCTAssertEqual(payload.apsBody, "Open BillBoard")
        XCTAssertNil(payload.apsSubtitle)
    }

    @MainActor
    func testMultiBillPayloadTrimsAndDropsBlankIds() {
        let payload = PushNotificationPayload(userInfo: [
            "domain": "bill",
            "billIds": [" BILLS-119hr1234ih ", "", "BILLS-119s567is"],
            "notificationType": "new"
        ])

        XCTAssertEqual(payload.allBillIds, ["BILLS-119hr1234ih", "BILLS-119s567is"])
        XCTAssertEqual(payload.normalizedBillGuid, "BILLS-119hr1234ih")
        XCTAssertTrue(payload.isBillsManifestRelevant)
        XCTAssertFalse(payload.isWeeklyDigestRelevant)
    }

    @MainActor
    func testBillAlertViaNotificationType() {
        let payload = PushNotificationPayload(userInfo: [
            "domain": "bill",
            "billIds": ["BILLS-119hr2312rh"],
            "notificationType": "alert",
            "alertId": "da0cdd34-4324-4331-b0e0-fa6ee08bf118",
            "alert": [
                "text": "On Passage (Passed)",
                "actionDate": "2025-01-03",
                "actionCode": "pass",
                "actionType": "vote"
            ]
        ])

        XCTAssertTrue(payload.isBillAlertRelevant)
        XCTAssertEqual(payload.normalizedAlertId, "da0cdd34-4324-4331-b0e0-fa6ee08bf118")
        XCTAssertEqual(payload.alertText, "On Passage (Passed)")
        XCTAssertEqual(payload.alertActionDate, "2025-01-03")
        XCTAssertEqual(payload.alertActionCode, "pass")
        XCTAssertEqual(payload.alertActionType, "vote")
    }

    @MainActor
    func testBillAlertViaDomain() {
        let payload = PushNotificationPayload(userInfo: ["domain": "bill_alert"])

        XCTAssertTrue(payload.isBillAlertRelevant)
        XCTAssertFalse(payload.isBillsManifestRelevant)
    }

    // MARK: - Alert id precedence

    @MainActor
    func testNestedAlertIdWinsOverTopLevel() {
        let payload = PushNotificationPayload(userInfo: [
            "alert": ["id": "nested"],
            "alertId": "top"
        ])

        XCTAssertEqual(payload.normalizedAlertId, "nested")
    }

    @MainActor
    func testBlankNestedAlertIdFallsBackToTopLevelKeys() {
        let camel = PushNotificationPayload(userInfo: ["alert": ["id": "  "], "alertId": "top"])
        XCTAssertEqual(camel.normalizedAlertId, "top")

        let legacy = PushNotificationPayload(userInfo: ["alert_id": " legacy "])
        XCTAssertEqual(legacy.normalizedAlertId, "legacy")
    }

    @MainActor
    func testBlankAlertIdIsNil() {
        let payload = PushNotificationPayload(userInfo: ["alertId": "   "])
        XCTAssertNil(payload.normalizedAlertId)
    }

    // MARK: - Legacy events

    @MainActor
    func testLegacyBillEventsAreManifestRelevant() {
        for event in ["bill.new", "bill.updated"] {
            let payload = PushNotificationPayload(userInfo: ["event": event, "guid": " BILLS-118s5is "])

            XCTAssertEqual(payload.domain, .unknown, event)
            XCTAssertTrue(payload.isBillsManifestRelevant, event)
            XCTAssertEqual(payload.normalizedBillGuid, "BILLS-118s5is", event)
        }
    }

    @MainActor
    func testLegacyAlertEventIsAlertRelevant() {
        let payload = PushNotificationPayload(userInfo: ["event": "bill_alert.new", "alert_id": "a-1"])

        XCTAssertTrue(payload.isBillAlertRelevant)
        XCTAssertFalse(payload.isBillsManifestRelevant)
        XCTAssertEqual(payload.normalizedAlertId, "a-1")
    }

    @MainActor
    func testMalformedBillGuidsAreSkipped() {
        let payload = PushNotificationPayload(userInfo: [
            "domain": "bill",
            "billIds": ["../../etc/passwd", "BILLS-119hr1234ih"],
            "guid": "not-a-guid"
        ])

        XCTAssertEqual(payload.allBillIds, ["BILLS-119hr1234ih"])
        XCTAssertEqual(payload.normalizedBillGuid, "BILLS-119hr1234ih")

        let legacyOnly = PushNotificationPayload(userInfo: ["event": "bill.new", "guid": "not-a-guid"])
        XCTAssertNil(legacyOnly.normalizedBillGuid)
    }

    @MainActor
    func testEmptyBillIdsFallBackToLegacyGuid() {
        let payload = PushNotificationPayload(userInfo: ["billIds": [String](), "guid": "BILLS-118s5is"])

        XCTAssertEqual(payload.normalizedBillGuid, "BILLS-118s5is")
        XCTAssertEqual(payload.allBillIds, [])
    }

    // MARK: - Renamed topics (LLM-10)

    @MainActor
    func testLegacyTopicNamesAreReadUnderTheirNewNames() {
        let payload = PushNotificationPayload(userInfo: [
            "domain": "bill",
            "billIds": ["BILLS-119hr1234ih"],
            "notificationType": "alert",
            "category": "Social Policy",
            "subCategory": "Social Justice"
        ])

        XCTAssertEqual(payload.subCategory, "Civil Rights and Liberties")
        XCTAssertEqual(payload.category, "Social Policy")

        let other = PushNotificationPayload(userInfo: ["subCategory": "Identity Politics", "category": "Identity Politics"])
        XCTAssertEqual(other.subCategory, "Heritage and Identity")
        XCTAssertEqual(other.category, "Heritage and Identity")
    }

    @MainActor
    func testCurrentAndNotifierTopicValuesAreKeptAsSent() {
        let expectations: [(category: String, subCategory: String)] = [
            ("Cultural and Ethical Issues", "Heritage and Identity"),
            ("Priority Bill", "Priority Bill"),
            ("Bill Alert", " Energy ")
        ]

        for (category, subCategory) in expectations {
            let payload = PushNotificationPayload(userInfo: ["category": category, "subCategory": subCategory])
            XCTAssertEqual(payload.category, category)
            XCTAssertEqual(payload.subCategory, subCategory)
        }
        XCTAssertNil(PushNotificationPayload(userInfo: [:]).subCategory)
        XCTAssertNil(PushNotificationPayload(userInfo: ["subCategory": 42]).subCategory)
    }

    // MARK: - Weekly digest

    @MainActor
    func testWeeklyDigestNeedsDigestIdAndNoBills() {
        let digest = PushNotificationPayload(userInfo: ["domain": "weekly_digest", "digestId": " 2026-W39 "])
        XCTAssertTrue(digest.isWeeklyDigestRelevant)
        XCTAssertEqual(digest.normalizedDigestID, "2026-W39")

        let snakeCase = PushNotificationPayload(userInfo: ["domain": "weekly_digest", "digest_id": "2026-W39"])
        XCTAssertTrue(snakeCase.isWeeklyDigestRelevant)

        let byType = PushNotificationPayload(userInfo: ["notificationType": "digest", "digestId": "2026-W39"])
        XCTAssertTrue(byType.isWeeklyDigestRelevant)

        let missingId = PushNotificationPayload(userInfo: ["domain": "weekly_digest", "digestId": "  "])
        XCTAssertFalse(missingId.isWeeklyDigestRelevant)
        XCTAssertNil(missingId.normalizedDigestID)

        let withBills = PushNotificationPayload(userInfo: [
            "domain": "weekly_digest",
            "digestId": "2026-W39",
            "billIds": ["BILLS-119hr1234ih"]
        ])
        XCTAssertFalse(withBills.isWeeklyDigestRelevant)
    }

    // MARK: - Malformed input

    @MainActor
    func testEmptyPayloadHasNoTargets() {
        let payload = PushNotificationPayload(userInfo: [:])

        XCTAssertEqual(payload.domain, .unknown)
        XCTAssertEqual(payload.notificationType, .unknown)
        XCTAssertNil(payload.normalizedBillGuid)
        XCTAssertNil(payload.normalizedAlertId)
        XCTAssertNil(payload.normalizedDigestID)
        XCTAssertEqual(payload.allBillIds, [])
        XCTAssertFalse(payload.isBillsManifestRelevant)
        XCTAssertFalse(payload.isBillAlertRelevant)
        XCTAssertFalse(payload.isWeeklyDigestRelevant)
    }

    @MainActor
    func testWrongValueTypesAreIgnored() {
        let payload = PushNotificationPayload(userInfo: [
            "domain": 1,
            "billIds": [1, 2],
            "guid": 42,
            "notificationType": 5,
            "aps": ["alert": "plain string alert"]
        ])

        XCTAssertEqual(payload.domain, .unknown)
        XCTAssertEqual(payload.allBillIds, [])
        XCTAssertNil(payload.normalizedBillGuid)
        XCTAssertEqual(payload.notificationType, .unknown)
        XCTAssertNil(payload.apsTitle)
    }

    @MainActor
    func testNotificationTypeIsTrimmedAndCaseInsensitive() {
        let payload = PushNotificationPayload(userInfo: ["notificationType": " PASSED "])

        XCTAssertEqual(payload.notificationType, .passed)
    }

    // MARK: - Foreground presentation settings

    /// The local toggles snapshot never stores the device id (it lives in the Keychain),
    /// and a snapshot from an earlier build that did is rewritten without it.
    @MainActor
    func testPresentationSnapshotOmitsDeviceID() throws {
        let suiteName = "PushPresentationSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var settings = DeviceNotificationSettings.allEnabled
        settings.deviceID = "device-123"
        settings.notifyPassed = false
        PushPresentationSettings.save(settings, defaults: defaults)

        let saved = try XCTUnwrap(defaults.data(forKey: PushPresentationSettings.snapshotKey))
        XCTAssertFalse(String(decoding: saved, as: UTF8.self).contains("device-123"))
        XCTAssertEqual(PushPresentationSettings.load(defaults: defaults)?.notifyPassed, false)
        XCTAssertFalse(PushPresentationSettings.allowsForegroundPresentation(
            of: PushNotificationPayload(userInfo: ["notificationType": "passed"]),
            defaults: defaults
        ))

        // Legacy snapshot that encoded the whole settings struct, device id included.
        defaults.set(try JSONEncoder().encode(settings), forKey: PushPresentationSettings.snapshotKey)
        XCTAssertEqual(PushPresentationSettings.load(defaults: defaults)?.notifyPassed, false)
        let rewritten = try XCTUnwrap(defaults.data(forKey: PushPresentationSettings.snapshotKey))
        XCTAssertFalse(String(decoding: rewritten, as: UTF8.self).contains("device"))
    }

    // MARK: - "Updated" pushes for companion groups (APPF-23)

    /// An "updated" push clears the vote and asks for a new one only when the pushed bill holds the
    /// vote that counts; an update to the other member of a group is information only.
    @MainActor
    func testUpdatedPushForTheMemberWithoutTheCountedVoteKeepsTheVote() async {
        let house = "BILLS-119hr900"
        let senate = "BILLS-119s456"
        let group = BillCompanionGroup(primaryGuid: house, memberGuids: [house, senate], relationship: "identical")
        let payload = PushNotificationPayload(userInfo: ["domain": "bill", "billIds": [senate], "notificationType": "updated"])
        XCTAssertEqual(payload.notificationType, .updated)
        XCTAssertEqual(payload.normalizedBillGuid, senate)
        let pushedGuid = senate

        let (store, voteStore, scope) = await makeCompanionStore(
            bills: [companionTestBill(house), companionTestBill(senate)],
            groups: [group]
        )
        XCTAssertEqual(store.revoteGUIDs(forUpdatedPushGUID: pushedGuid), [], "no vote held: information only")

        await voteStore.setVote(billId: house, vote: .yea)
        XCTAssertEqual(store.revoteGUIDs(forUpdatedPushGUID: pushedGuid), [], "the vote is on the House bill")
        XCTAssertEqual(store.revoteGUIDs(forUpdatedPushGUID: house), [house])

        await voteStore.setVote(billId: senate, vote: .nay)
        XCTAssertEqual(store.revoteGUIDs(forUpdatedPushGUID: pushedGuid), [], "the Senate row does not count while the House row exists")
        XCTAssertEqual(
            store.revoteGUIDs(forUpdatedPushGUID: house),
            [house, senate],
            "a revote clears every member's row, so the Senate row does not become the counted one"
        )

        let (ungrouped, _, ungroupedScope) = await makeCompanionStore(bills: [companionTestBill(senate)], groups: [])
        XCTAssertEqual(ungrouped.revoteGUIDs(forUpdatedPushGUID: pushedGuid), [senate], "no groups: every update asks again")

        // Votes set on the vote store alone do not write the bills cache.
        _ = (scope, ungroupedScope)
    }

    @MainActor
    func testUpdatedPushForTheMemberHoldingTheOnlyVoteAsksAgain() async {
        let house = "BILLS-119hr900"
        let senate = "BILLS-119s456"
        let group = BillCompanionGroup(primaryGuid: house, memberGuids: [house, senate], relationship: "identical")
        let (store, voteStore, scope) = await makeCompanionStore(
            bills: [companionTestBill(house), companionTestBill(senate)],
            groups: [group]
        )
        await voteStore.setVote(billId: senate, vote: .nay)

        XCTAssertEqual(store.revoteGUIDs(forUpdatedPushGUID: senate), [senate])
        XCTAssertEqual(store.revoteGUIDs(forUpdatedPushGUID: house), [])
        XCTAssertEqual(store.companionMemberBillIDs(forGUID: senate), [UUID.deterministic(from: senate), UUID.deterministic(from: house)])
        _ = scope
    }
}
