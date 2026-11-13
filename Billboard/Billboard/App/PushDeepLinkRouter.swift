import SwiftUI

/// Routes pushes and deep links for `TabsBar`. It restores the cached bills at startup,
/// reacts to bill, alert and manifest change notifications, and opens bill links on the
/// Bills tab. Links that arrive before navigation is allowed wait in
/// `PendingAppDeepLink` or `PendingPushDeepLink` and open once it is.
struct PushDeepLinkRouter: ViewModifier {
    /// The title of a Congress action (`alert`) push that arrives without one (spec D 2.4.1).
    static let actionInCongressTitle = "Action in Congress"

    @ObservedObject var billsStore: BillsStore
    @ObservedObject var billAlertsStore: BillAlertsStore
    @ObservedObject var readState: AppReadState
    @ObservedObject var appState: AppState
    @ObservedObject var voteStore: BillVoteStore

    @Binding var billBoardPath: NavigationPath
    /// See `TabsBar.isReadyForDeepLinkNavigation`.
    let isReadyForDeepLinks: Bool
    let onCacheRestoreReady: @MainActor () -> Void

    @State private var hasRestoredCachedState = false
    /// Set when a deep link is left pending because navigation was not allowed yet.
    @State private var hasDeferredDeepLink = false

    private var canNavigateForDeepLink: Bool {
        hasRestoredCachedState && isReadyForDeepLinks
    }

    func body(content: Content) -> some View {
        content
            .task {
                HomePerfTimeline.mark("push_handler_bootstrap_started")
                await billsStore.restoreCachedStateIfNeeded()
                await MainActor.run {
                    onCacheRestoreReady()
                }
                HomePerfTimeline.mark(
                    "push_handler_cache_restore_ready",
                    detail: "activeManifestBills=\(billsStore.activeManifestBills.count)"
                )

                // Cold-start deep links: the delegate may fire before SwiftUI listeners attach.
                // They open as soon as navigation is allowed (see the onChange below).
                hasDeferredDeepLink = true
                hasRestoredCachedState = true
            }
            // Handled here rather than at the end of the task above: `isReadyForDeepLinks`
            // captured by that task is stale after its awaits, while this closure is rebuilt
            // with every update.
            .onChange(of: canNavigateForDeepLink) { _, canNavigate in
                guard canNavigate else { return }
                consumeDeferredDeepLinksIfReady()
            }
            .onReceive(NotificationCenter.default.publisher(for: .billboardBillsManifestDidChange)) { _ in
                Task { await billsStore.load(forceRefresh: true, mode: .manifestOnly) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .billboardBillDidChange)) { note in
                handleBillDidChange(note)
            }
            .onReceive(NotificationCenter.default.publisher(for: .billboardBillAlertDidChange)) { note in
                handleBillAlertDidChange(note)
            }
            .onReceive(NotificationCenter.default.publisher(for: .billboardDidReceiveBillDeepLink)) { note in
                handleAppDeepLink(note)
            }
            .onReceive(NotificationCenter.default.publisher(for: .billboardDidSavePendingPushDeepLink)) { _ in
                // A bill or weekly-brief push was tapped while the app was running. Open it
                // now, or once onboarding and the tour are done; either way it is consumed.
                hasDeferredDeepLink = true
                consumeDeferredDeepLinksIfReady()
            }
    }

    private func handleBillDidChange(_ note: Notification) {
        let guid = (note.userInfo?["guid"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let wasUserInteraction = (note.userInfo?["user_interaction"] as? Bool) ?? false
        let notificationType = (note.userInfo?["notificationType"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        let billID = guid.flatMap { $0.isEmpty ? nil : UUID.deterministic(from: $0) }
        // A companion group (APPF-23) opens on its primary when that bill is loaded; a bill that is not
        // loaded is fetched by the detail screen (APPF-26).
        let routeTarget = guid.flatMap { $0.isEmpty ? nil : billsStore.deepLinkTarget(forGUID: $0) }

        // Re-surface the bill for "updated" pushes only, and only when the vote it clears is the one
        // that counts: for a companion group, an update to the member without the counted vote is
        // information only (`revoteGUIDs(forUpdatedPushGUID:)`).
        // "new", "passed", "failed", and "alert" are informational — preserve prior vote state.
        var revoteGuids: [String] = []
        if notificationType == "updated", let guid, !guid.isEmpty {
            revoteGuids = billsStore.revoteGUIDs(forUpdatedPushGUID: guid)
            if !revoteGuids.isEmpty {
                billsStore.companionMemberBillIDs(forGUID: guid).forEach(readState.undismissBill)
                revoteGuids.forEach(voteStore.clearVote(for:))
            }
        }

        if wasUserInteraction, let routeTarget {
            if canNavigateForDeepLink {
                // Deep link straight to bill detail.
                appState.selectedTab = TabsBar.Tab.home.rawValue
                billBoardPath = NavigationPath()
                billBoardPath.append(TabsBar.AppRoute.billDetail(routeTarget))
            } else if let guid, !guid.isEmpty {
                // Not allowed to navigate yet: open the bill once onboarding and the tour are done.
                PendingAppDeepLink.saveBillGuid(guid)
                hasDeferredDeepLink = true
            }
        }

        Task {
            await billsStore.load(forceRefresh: true, mode: .manifestOnly)
            for revoteGuid in revoteGuids {
                billsStore.requireRevote(billID: UUID.deterministic(from: revoteGuid))
            }
            if let billID {
                await billsStore.ensureHydrated(billID: billID)
            }
            if let routeBillID = routeTarget?.billID, routeBillID != billID {
                await billsStore.ensureHydrated(billID: routeBillID)
            }
        }
    }

    private func handleBillAlertDidChange(_ note: Notification) {
        let wasUserInteraction = (note.userInfo?["user_interaction"] as? Bool) ?? false
        let alertIdRaw = (note.userInfo?["alertId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let billId = (note.userInfo?["billId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let category = (note.userInfo?["category"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let subCategory = (note.userInfo?["subCategory"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let updatedAt = (note.userInfo?["updatedAt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (note.userInfo?["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let subtitle = (note.userInfo?["subtitle"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = (note.userInfo?["body"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        let alertText = (note.userInfo?["alertText"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let actionDate = (note.userInfo?["actionDate"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let actionCode = (note.userInfo?["actionCode"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let actionType = (note.userInfo?["actionType"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        let resolvedBillId = billId.flatMap { $0.isEmpty ? nil : $0 }
        let resolvedCategory = category.flatMap { $0.isEmpty ? nil : $0 } ?? subtitle.flatMap { $0.isEmpty ? nil : $0 } ?? "Bills"
        let resolvedSubCategory = subCategory.flatMap { $0.isEmpty ? nil : $0 } ?? body.flatMap { $0.isEmpty ? nil : $0 }
        let resolvedAlertText = alertText.flatMap { $0.isEmpty ? nil : $0 }

        let date = FlexibleISO8601.parse(updatedAt) ?? Date()

        let alertId: UUID = {
            if let raw = alertIdRaw, !raw.isEmpty {
                return UUID(uuidString: raw) ?? UUID.deterministic(from: raw)
            }
            let key = [
                "bill_alert",
                resolvedBillId ?? "(nil)",
                updatedAt ?? "(nil)",
                resolvedCategory,
                resolvedSubCategory ?? "(nil)",
                resolvedAlertText ?? "(nil)",
                actionDate ?? "(nil)",
                actionCode ?? "(nil)",
                actionType ?? "(nil)",
                title ?? "(nil)",
                body ?? "(nil)"
            ].joined(separator: "|")
            return UUID.deterministic(from: key)
        }()
        let billUUID = resolvedBillId.map { UUID.deterministic(from: $0) }

        let alert = BillAlert(
            id: alertId,
            sponsorMemberID: nil,
            billID: billUUID,
            title: title.flatMap { $0.isEmpty ? nil : $0 } ?? PushDeepLinkRouter.actionInCongressTitle,
            category: resolvedCategory,
            summary: resolvedAlertText ?? body.flatMap { $0.isEmpty ? nil : $0 } ?? resolvedSubCategory ?? "",
            soWhat: resolvedAlertText ?? body.flatMap { $0.isEmpty ? nil : $0 } ?? resolvedSubCategory ?? "",
            lifeAreas: [],
            subCategory: resolvedSubCategory,
            alertText: resolvedAlertText,
            actionDate: actionDate.flatMap { $0.isEmpty ? nil : $0 },
            actionCode: actionCode.flatMap { $0.isEmpty ? nil : $0 },
            actionType: actionType.flatMap { $0.isEmpty ? nil : $0 },
            date: date
        )

        billAlertsStore.ingest(alert)

        if wasUserInteraction {
            guard canNavigateForDeepLink else {
                // The push delegate saved this tap as a pending deep link; it opens once
                // onboarding and the tour are done.
                hasDeferredDeepLink = true
                return
            }
            // Handled now, so it must not replay from the pending store later.
            PendingPushDeepLink.clear()

            // Deep link straight to bill detail (alerts are no longer a first-class UI).
            readState.markBillAlertRead(alert.id)
            billAlertsStore.remove(alert.id)
            guard let resolvedBillId else { return }
            let routeTarget = billsStore.deepLinkTarget(forGUID: resolvedBillId)

            appState.selectedTab = TabsBar.Tab.home.rawValue
            billBoardPath = NavigationPath()
            billBoardPath.append(TabsBar.AppRoute.billDetail(routeTarget))

            Task { await billsStore.ensureHydrated(billID: routeTarget.billID) }
        }
    }

    private func handleAppDeepLink(_ note: Notification) {
        let guid = (note.userInfo?["guid"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let guid, !guid.isEmpty else { return }
        guard canNavigateForDeepLink else {
            // The app saved the link in PendingAppDeepLink before posting; it opens once
            // onboarding and the tour are done.
            hasDeferredDeepLink = true
            return
        }
        PendingAppDeepLink.clear()
        navigateToBillDetail(guid: guid)
    }

    /// Opens deep links that were left pending (cold start, onboarding, compliance gates,
    /// the product tour) once navigation is allowed. Links that were already handled are
    /// not replayed.
    private func consumeDeferredDeepLinksIfReady() {
        guard hasDeferredDeepLink, canNavigateForDeepLink else { return }
        hasDeferredDeepLink = false
        consumePendingDeepLinkIfAny()
        consumePendingAppDeepLinkIfAny()
    }

    private func consumePendingAppDeepLinkIfAny() {
        guard let guid = PendingAppDeepLink.consumeBillGuid() else { return }
        navigateToBillDetail(guid: guid)
    }

    private func navigateToBillDetail(guid: String) {
        let cleanedGuid = guid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedGuid.isEmpty else { return }

        // A companion group (APPF-23) opens on its primary when that bill is loaded; a bill that is not
        // loaded is fetched by the detail screen (APPF-26).
        let target = billsStore.deepLinkTarget(forGUID: cleanedGuid)
        appState.selectedTab = TabsBar.Tab.home.rawValue
        billBoardPath = NavigationPath()
        billBoardPath.append(TabsBar.AppRoute.billDetail(target))

        Task {
            await billsStore.load(forceRefresh: true, mode: .manifestOnly, loadFullManifest: true)
            await billsStore.ensureHydrated(billID: target.billID)
        }
    }

    private func consumePendingDeepLinkIfAny() {
        guard let pending = PendingPushDeepLink.consume() else { return }

        switch pending {
        case .digest(let billIds, let notificationType):
            let trimmedIds = billIds.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            guard !trimmedIds.isEmpty else { return }

            // Re-surface bills for "updated" pushes only, and for a companion group (APPF-23) only
            // when the pushed bill holds the counted vote (`revoteGUIDs(forUpdatedPushGUID:)`).
            // "new", "passed", "failed", and "alert" are informational — preserve prior vote state.
            var revoteGuids: [String] = []
            if notificationType?.lowercased() == "updated" {
                for guid in trimmedIds {
                    let cleared = billsStore.revoteGUIDs(forUpdatedPushGUID: guid)
                    guard !cleared.isEmpty else { continue }
                    revoteGuids.append(contentsOf: cleared)
                    billsStore.companionMemberBillIDs(forGUID: guid).forEach(readState.undismissBill)
                    cleared.forEach(voteStore.clearVote(for:))
                }
            }

            // One bill (or the members of one companion group, APPF-23): open it.
            if let target = billsStore.pushDeepLinkTarget(forGUIDs: trimmedIds) {
                let id = target.billID
                appState.selectedTab = TabsBar.Tab.home.rawValue
                billBoardPath = NavigationPath()
                billBoardPath.append(TabsBar.AppRoute.billDetail(target))

                Task {
                    await billsStore.load(forceRefresh: true, mode: .manifestOnly, loadFullManifest: true)
                    for revoteGuid in revoteGuids {
                        billsStore.requireRevote(billID: UUID.deterministic(from: revoteGuid))
                    }
                    await billsStore.ensureHydrated(billID: id)
                    for guid in trimmedIds where UUID.deterministic(from: guid) != id {
                        await billsStore.ensureHydrated(billID: UUID.deterministic(from: guid))
                    }
                }
            } else {
                // Multiple bills: show the Bills tab so the user can see all of them
                appState.selectedTab = TabsBar.Tab.home.rawValue
                billBoardPath = NavigationPath()

                Task {
                    await billsStore.load(forceRefresh: true, mode: .manifestOnly, loadFullManifest: true)
                    for revoteGuid in revoteGuids {
                        billsStore.requireRevote(billID: UUID.deterministic(from: revoteGuid))
                    }

                    // Ensure all bills are hydrated
                    for guid in trimmedIds {
                        await billsStore.ensureHydrated(billID: UUID.deterministic(from: guid))
                    }
                }
            }

        case .weeklyDigest(_):
            appState.selectedTab = TabsBar.Tab.updates.rawValue

        case .alert(let alert):
            // Build a BillAlert instance and navigate to bill detail (alerts are not shown as a standalone UI).
            let alertIdRaw = (alert.alertId?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            let resolvedBillId = alert.billId?.trimmingCharacters(in: .whitespacesAndNewlines)
            let billId = resolvedBillId.flatMap { $0.isEmpty ? nil : $0 }

            let category = (alert.category?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            let subCategory = (alert.subCategory?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            let title = (alert.title?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            let subtitle = (alert.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            let body = (alert.body?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }

            let alertText = (alert.alertText?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            let actionDate = (alert.actionDate?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            let actionCode = (alert.actionCode?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            let actionType = (alert.actionType?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            let updatedAt = (alert.updatedAt?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }

            let resolvedCategory = category ?? subtitle ?? "Bills"
            let resolvedSubCategory = subCategory ?? (body?.isEmpty == false ? body : nil)
            let resolvedAlertText = alertText

            let date = FlexibleISO8601.parse(updatedAt) ?? Date()

            let alertId: UUID = {
                if let raw = alertIdRaw {
                    return UUID(uuidString: raw) ?? UUID.deterministic(from: raw)
                }
                let key = [
                    "bill_alert",
                    billId ?? "(nil)",
                    updatedAt ?? "(nil)",
                    resolvedCategory,
                    resolvedSubCategory ?? "(nil)",
                    resolvedAlertText ?? "(nil)",
                    actionDate ?? "(nil)",
                    actionCode ?? "(nil)",
                    actionType ?? "(nil)",
                    title ?? "(nil)",
                    body ?? "(nil)"
                ].joined(separator: "|")
                return UUID.deterministic(from: key)
            }()
            let billUUID = billId.map { UUID.deterministic(from: $0) }

            let built = BillAlert(
                id: alertId,
                sponsorMemberID: nil,
                billID: billUUID,
                title: title ?? PushDeepLinkRouter.actionInCongressTitle,
                category: resolvedCategory,
                summary: resolvedAlertText ?? (body ?? (resolvedSubCategory ?? "")),
                soWhat: resolvedAlertText ?? (body ?? (resolvedSubCategory ?? "")),
                lifeAreas: [],
                subCategory: resolvedSubCategory,
                alertText: resolvedAlertText,
                actionDate: actionDate,
                actionCode: actionCode,
                actionType: actionType,
                date: date
            )

            billAlertsStore.ingest(built)

            readState.markBillAlertRead(built.id)
            billAlertsStore.remove(built.id)

            guard let billId else {
                appState.selectedTab = TabsBar.Tab.home.rawValue
                return
            }
            let routeTarget = billsStore.deepLinkTarget(forGUID: billId)

            appState.selectedTab = TabsBar.Tab.home.rawValue
            billBoardPath = NavigationPath()
            billBoardPath.append(TabsBar.AppRoute.billDetail(routeTarget))

            Task { await billsStore.ensureHydrated(billID: routeTarget.billID) }
        }
    }
}
