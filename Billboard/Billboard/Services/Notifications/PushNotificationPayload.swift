import Foundation

/// Limits applied to push payload values before they are routed or persisted.
/// Push payloads are untrusted input: ids are validated against their expected
/// shape and free text is capped so a malformed payload cannot bloat storage.
enum PushPayloadLimits {
    nonisolated static let maxBillIds = 50
    nonisolated static let maxTextLength = 512
    nonisolated static let maxFieldLength = 128

    nonisolated private static let identifierCharacters = CharacterSet.alphanumerics
        .union(CharacterSet(charactersIn: "._:+-"))

    /// Free text (titles, bodies, categories, dates): kept as sent, capped in length.
    nonisolated static func text(_ raw: String?, limit: Int = maxTextLength) -> String? {
        guard let raw else { return nil }
        return raw.count > limit ? String(raw.prefix(limit)) : raw
    }

    /// Alert and digest ids: trimmed, ASCII id characters only, bounded length.
    nonisolated static func identifier(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              trimmed.count <= maxFieldLength,
              trimmed.unicodeScalars.allSatisfy({ $0.isASCII && identifierCharacters.contains($0) }) else {
            return nil
        }
        return trimmed
    }

    /// Well-formed bill guids only, in order, at most `maxBillIds`.
    nonisolated static func billGuids(_ raw: [String]) -> [String] {
        Array(raw.compactMap { BillGuid.validated($0) }.prefix(maxBillIds))
    }
}

struct PushNotificationPayload {
    enum Domain: String {
        case bill
        case billAlert
        case weeklyDigest
        case unknown

        init(raw: String?) {
            let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            switch value {
            case "bill":
                self = .bill
            case "bill_alert", "billalert", "alert", "alerts", "bill-alert":
                self = .billAlert
            case "weekly_digest", "weekly-digest":
                self = .weeklyDigest
            default:
                self = .unknown
            }
        }
    }

    enum NotificationType: String {
        case new
        case updated
        case passed
        case failed
        case alert
        case digest
        case unknown
    }

    enum ChangeType: String {
        case added
        case updated
        case unknown
    }

    /// Legacy (pre-2026) event schema.
    enum LegacyEvent: String {
        case billNew = "bill.new"
        case billUpdated = "bill.updated"
        case billAlertNew = "bill_alert.new"
    }

    // MARK: - Raw/legacy fields

    let legacyEvent: String
    let guid: String?
    let alertID: String?

    /// New schema alert identifier (if provided).
    let alertId: String?

    // MARK: - New schema fields

    let domain: Domain
    let billIds: [String]?
    let digestId: String?
    /// Topic group (or a notifier label such as "Bill Alert"); a legacy topic name is read under its
    /// current name (LLM-10).
    let category: String?
    /// Topic, under its current name: a push queued before the label switch may carry a legacy name
    /// (LLM-10, `SubscriptionsConfig.canonicalTopic`).
    let subCategory: String?
    let notificationType: NotificationType
    let changeType: ChangeType
    let updatedAt: String?

    // MARK: - Bill alert fields (nested `alert` object)

    let alertText: String?
    let alertActionDate: String?
    let alertActionCode: String?
    let alertActionType: String?

    /// Convenience title extracted from APS.alert.title (if present).
    let apsTitle: String?
    /// Convenience subtitle extracted from APS.alert.subtitle (if present).
    let apsSubtitle: String?
    /// Convenience body extracted from APS.alert.body (if present).
    let apsBody: String?

    init(userInfo: [AnyHashable: Any]) {
        // Legacy fields
        self.legacyEvent = PushPayloadLimits.text(userInfo["event"] as? String, limit: PushPayloadLimits.maxFieldLength) ?? ""
        self.guid = userInfo["guid"] as? String
        self.alertID = userInfo["alert_id"] as? String

        // New schema fields
        let rawDomain = userInfo["domain"] as? String
        self.domain = Domain(raw: rawDomain)

        self.billIds = userInfo["billIds"] as? [String]
        self.digestId = (userInfo["digestId"] as? String) ?? (userInfo["digest_id"] as? String)
        self.category = PushPayloadLimits.text(userInfo["category"] as? String, limit: PushPayloadLimits.maxFieldLength)
            .map(SubscriptionsConfig.canonicalTopic)
        self.subCategory = PushPayloadLimits.text(userInfo["subCategory"] as? String, limit: PushPayloadLimits.maxFieldLength)
            .map(SubscriptionsConfig.canonicalTopic)

        let rawNotif = (userInfo["notificationType"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.notificationType = NotificationType(rawValue: rawNotif ?? "") ?? .unknown

        let rawChange = (userInfo["changeType"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.changeType = ChangeType(rawValue: rawChange ?? "") ?? .unknown

        self.updatedAt = PushPayloadLimits.text(userInfo["updatedAt"] as? String, limit: PushPayloadLimits.maxFieldLength)

        var computedAlertId: String?

        // Nested alert object extraction (best-effort)
        if let alertObject = userInfo["alert"] as? [String: Any] {
            computedAlertId = (alertObject["id"] as? String) ?? (alertObject["alertId"] as? String)
            self.alertText = PushPayloadLimits.text(alertObject["text"] as? String)
            self.alertActionDate = PushPayloadLimits.text(alertObject["actionDate"] as? String, limit: PushPayloadLimits.maxFieldLength)
            self.alertActionCode = PushPayloadLimits.text(alertObject["actionCode"] as? String, limit: PushPayloadLimits.maxFieldLength)
            self.alertActionType = PushPayloadLimits.text(alertObject["actionType"] as? String, limit: PushPayloadLimits.maxFieldLength)
        } else {
            computedAlertId = nil
            self.alertText = nil
            self.alertActionDate = nil
            self.alertActionCode = nil
            self.alertActionType = nil
        }

        // Top-level alert id fallback (best-effort)
        // Prefer explicit new-schema keys, then legacy `alert_id`.
        let topAlertId = (userInfo["alertId"] as? String) ?? (userInfo["alertID"] as? String) ?? (userInfo["alert_id"] as? String)
        if (computedAlertId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
            computedAlertId = topAlertId
        }
        self.alertId = computedAlertId

        // APS convenience extraction (best-effort)
        if let aps = userInfo["aps"] as? [String: Any],
           let alert = aps["alert"] as? [String: Any] {
            self.apsTitle = PushPayloadLimits.text(alert["title"] as? String)
            self.apsSubtitle = PushPayloadLimits.text(alert["subtitle"] as? String)
            self.apsBody = PushPayloadLimits.text(alert["body"] as? String)
        } else {
            self.apsTitle = nil
            self.apsSubtitle = nil
            self.apsBody = nil
        }
    }

    var isBillsManifestRelevant: Bool {
        if domain == .bill { return true }
        // Legacy support
        return legacyEvent == LegacyEvent.billNew.rawValue || legacyEvent == LegacyEvent.billUpdated.rawValue
    }

    var isBillAlertRelevant: Bool {
        // New: either explicit alerts domain OR bill + notificationType=alert
        if domain == .billAlert { return true }
        if domain == .bill, notificationType == .alert { return true }
        // Legacy: bill_alert.new
        return legacyEvent == LegacyEvent.billAlertNew.rawValue
    }

    /// First well-formed bill guid from `billIds`, falling back to the legacy `guid`
    /// field for old alert notifications. Malformed guids are ignored.
    var normalizedBillGuid: String? {
        // Try billIds first (new format)
        if let first = allBillIds.first {
            return first
        }

        // Fallback to legacy guid for old alert notifications
        return BillGuid.validated(guid)
    }

    /// Alert id, if present and well formed.
    var normalizedAlertId: String? {
        PushPayloadLimits.identifier(alertId ?? alertID)
    }

    /// Digest id, if present and well formed.
    var normalizedDigestID: String? {
        PushPayloadLimits.identifier(digestId)
    }

    /// Well-formed bill guids from the notification (trimmed, capped in count).
    var allBillIds: [String] {
        guard let billIds = billIds else { return [] }
        return PushPayloadLimits.billGuids(billIds)
    }

    var isWeeklyDigestRelevant: Bool {
        let hasDigestID = normalizedDigestID != nil
        if domain == .weeklyDigest, hasDigestID, allBillIds.isEmpty { return true }
        return notificationType == .digest && hasDigestID && allBillIds.isEmpty
    }

    /// True if this notification contains multiple bills or is explicitly marked as digest.
    var isDigest: Bool {
        return notificationType == .digest || allBillIds.count > 1
    }
}
