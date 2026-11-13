import Foundation
import os

// MARK: - Manifest delivery (CAP-01)

extension BillsService {
    nonisolated private enum ManifestPath {
        static let manifest = "bills-manifest"
    }

    nonisolated private enum ManifestQuery {
        static let updatedAfter = "updatedAfter"
        static let delivery = "delivery"
        static let snapshotDelivery = "snapshot"
    }

    nonisolated private enum ManifestLabel {
        static let request = "BillsService bills-manifest"
        static let snapshot = "BillsService bills-manifest snapshot"
        static let delta = "BillsService bills-manifest delta"
    }

    /// The delta after a snapshot starts this long before the snapshot's `generatedAt`, so a bill
    /// written while the snapshot was being built is not missed.
    nonisolated static let snapshotDeltaOverlap: TimeInterval = 15 * 60

    /// A snapshot pointer is a few hundred bytes, so a larger payload can only be an inline manifest.
    nonisolated private static let maxSnapshotPointerBytes = 16 * 1024

    /// Pointer requests per full fetch: the first, and one more after S3 rejects the first pointer's URL.
    nonisolated private static let maxPointerRequests = 2

    nonisolated private struct DecodedManifest: Sendable {
        /// The manifest's own `generatedAt`.
        let generatedAt: String
        let items: [BillsManifestItem]
        /// The manifest's `companionGroups`; nil when the field is absent.
        let companionGroups: [BillCompanionGroup]?
    }

    /// A manifest as fetched, before it is cached.
    nonisolated struct FetchedManifest: Sendable {
        let items: [BillsManifestItem]
        /// How it was delivered, for the Home timeline: windowed, full, snapshot or snapshot_retry.
        let source: String
        /// Every companion group (APPF-23); `[]` for none. Nil when no response carried the field (a
        /// server that predates companion groups), which keeps the cached list.
        var companionGroups: [BillCompanionGroup]?
    }

    /// Fetches the manifest without touching the cache. Nil when the API returned an empty payload,
    /// which leaves the cache as it is.
    ///
    /// A windowed fetch (`updatedAfter` set) is one `GET /bills-manifest?updatedAfter=`. A full fetch
    /// asks for `delivery=snapshot` (CAP-01): the API answers with a `BillsManifestSnapshotPointer`, or
    /// with the whole manifest inline while no snapshot exists. For a pointer the snapshot is downloaded
    /// without the API's auth (`BillsManifestSnapshotClient`) and the bills updated since shortly before
    /// it was generated are merged over it.
    ///
    /// There is no fallback to the plain full request: at production size its response is over the
    /// 6 MB Lambda response limit, and `APIRequest` retries a GET that fails with a 5xx, so every
    /// snapshot failure cost two failing full builds. When S3 rejects the presigned URL with 403 or 400
    /// (expired or invalid), the pointer is requested once more and that snapshot downloaded once.
    /// Any other snapshot failure, or a second rejection, is thrown, so the store reports a failed
    /// load and keeps the bills it has. A cancelled request or download is thrown as `CancellationError`.
    ///
    /// Runs off the main actor, like `getBillsManifest(updatedAfter:)`.
    @concurrent
    nonisolated static func fetchBillsManifest(updatedAfter: Date?) async throws -> FetchedManifest? {
        guard let updatedAfter else { return try await fetchFullBillsManifest() }

        let source = "windowed"
        let data = try await requestManifestPayload(
            query: [ManifestQuery.updatedAfter: manifestQueryDate(updatedAfter)],
            label: ManifestLabel.request,
            source: source
        )
        guard !data.isEmpty else { return nil }
        let manifest = try decodeManifest(from: data, label: ManifestLabel.request, source: source)
        return FetchedManifest(items: manifest.items, source: source, companionGroups: manifest.companionGroups)
    }

    /// One `GET /bills-manifest` through the API client (Cognito ID token when signed in). A cancelled
    /// request is thrown as `CancellationError`: Amplify reports it as an `APIError` wrapping
    /// `URLError.cancelled`, which callers would report as a failed load.
    nonisolated private static func requestManifestPayload(
        query: [String: String]?,
        label: String,
        source: String
    ) async throws -> Data {
        let client = await APIClient.current
        let data: Data
        do {
            data = try await client.payload(
                .get,
                ManifestPath.manifest,
                query: query,
                label: label,
                authMode: .autoFetch,
                traceTimeline: true
            )
        } catch {
            if APIErrorResponse.isCancellation(error) { throw CancellationError() }
            throw error
        }
        HomePerfTimeline.mark(
            "manifest_service_data_ready",
            detail: "source=\(source) bytes=\(data.count)"
        )
        return data
    }

    /// Decodes a `BillsManifest`, whether the API returned it inline or it came from a snapshot.
    /// A decode failure is logged by `APIDecoding` and thrown as `invalidPayload("bills-manifest")`.
    nonisolated private static func decodeManifest(from data: Data, label: String, source: String) throws -> DecodedManifest {
        let manifest: UserAPIContractsV1.BillsManifest
        do {
            manifest = try APIDecoding.decode(
                UserAPIContractsV1.BillsManifest.self,
                from: data,
                decoder: .convertingFromSnakeCase(),
                label: label
            )
        } catch {
            throw APIServiceError.invalidPayload(ManifestPath.manifest)
        }
        HomePerfTimeline.mark(
            "manifest_json_decoded",
            detail: "source=\(source) count=\(manifest.bills.count)"
        )
        let mapped = manifest.bills.map { BillsManifestItem(dto: $0) }
        // An unusable group (fewer than two members) is dropped rather than failing the manifest.
        let groups = manifest.companionGroups.map { $0.compactMap(BillCompanionGroup.init(dto:)) }
        HomePerfTimeline.mark(
            "manifest_items_mapped",
            detail: "source=\(source) count=\(mapped.count) companionGroups=\(groups.map { String($0.count) } ?? "absent")"
        )
        return DecodedManifest(generatedAt: manifest.generatedAt, items: mapped, companionGroups: groups)
    }

    nonisolated private static func manifestQueryDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    nonisolated private static func fetchFullBillsManifest() async throws -> FetchedManifest? {
        for attempt in 1...maxPointerRequests {
            let isRetry = attempt > 1
            let data = try await requestManifestPayload(
                query: [ManifestQuery.delivery: ManifestQuery.snapshotDelivery],
                label: ManifestLabel.request,
                source: isRetry ? "full_retry" : "full"
            )
            guard !data.isEmpty else { return nil }

            guard isSnapshotPointer(data) else {
                let manifest = try decodeManifest(from: data, label: ManifestLabel.request, source: "full")
                AppLog.api.info("[\(ManifestLabel.request, privacy: .public)] full manifest delivered inline count=\(manifest.items.count)")
                return FetchedManifest(items: manifest.items, source: "full", companionGroups: manifest.companionGroups)
            }

            let snapshot: DecodedManifest
            do {
                snapshot = try await downloadSnapshot(pointerData: data)
            } catch {
                let failure = snapshotFailure(error)
                if failure is CancellationError { throw failure }
                let reason = ManifestSnapshotError.logReason(for: failure)
                guard attempt < maxPointerRequests, (failure as? ManifestSnapshotError)?.isRejectedURL == true else {
                    AppLog.api.error("[\(ManifestLabel.snapshot, privacy: .public)] snapshot unavailable (\(reason, privacy: .public)) attempt=\(attempt)")
                    throw failure
                }
                AppLog.api.error("[\(ManifestLabel.snapshot, privacy: .public)] snapshot URL rejected (\(reason, privacy: .public)); requesting a new pointer")
                continue
            }

            // The delta cursor comes from the downloaded manifest, not the pointer: a publish can land
            // between the two, and the object at the URL is what was actually read.
            let merged = try await mergingSnapshotDelta(into: snapshot)
            return FetchedManifest(
                items: merged.items,
                source: isRetry ? "snapshot_retry" : "snapshot",
                companionGroups: merged.companionGroups
            )
        }
        // Not reached: the last attempt returns or throws.
        throw APIServiceError.invalidPayload(ManifestPath.manifest)
    }

    /// The error to throw for a failed snapshot download or delta. A cancelled request becomes
    /// `CancellationError`: URLSession throws `URLError.cancelled`, which the store would report as a
    /// failed load. Any other `URLError` is rebuilt from its code alone, because URLSession puts the
    /// request URL in its userInfo (`NSErrorFailingURLKey`), and for the snapshot that URL is a
    /// presigned credential that must not reach a log.
    nonisolated static func snapshotFailure(_ error: Error) -> Error {
        if Task.isCancelled || APIErrorResponse.isCancellation(error) { return CancellationError() }
        if let urlError = error as? URLError { return URLError(urlError.code) }
        return error
    }

    /// True for a `BillsManifestSnapshotPointer`; false for an inline `BillsManifest` (or anything else,
    /// which then fails to decode as a manifest).
    nonisolated private static func isSnapshotPointer(_ data: Data) -> Bool {
        guard data.count <= maxSnapshotPointerBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return object["snapshotUrl"] != nil
    }

    /// Decodes the pointer, checks its URL, downloads the snapshot and decodes it like an inline manifest.
    ///
    /// The pointer's `expiresAt` is not compared with the device clock: S3 enforces it, and a device
    /// clock running fast rejected every pointer. An expired URL is answered with 403, which
    /// `fetchFullBillsManifest` handles by requesting a new pointer.
    nonisolated private static func downloadSnapshot(pointerData: Data) async throws -> DecodedManifest {
        let label = ManifestLabel.snapshot
        let pointer = try APIDecoding.decode(
            UserAPIContractsV1.BillsManifestSnapshotPointer.self,
            from: pointerData,
            decoder: .convertingFromSnakeCase(),
            label: label
        )
        AppLog.api.info("[\(label, privacy: .public)] pointer generatedAt=\(pointer.generatedAt, privacy: .public) count=\(pointer.count) expiresAt=\(pointer.expiresAt, privacy: .public)")

        // The presigned URL is a credential for the object, so it is never logged.
        guard let url = URL(string: pointer.snapshotUrl), url.scheme?.lowercased() == "https", url.host != nil else {
            throw ManifestSnapshotError.invalidURL
        }

        HomePerfTimeline.mark("manifest_snapshot_download_started", detail: "count=\(pointer.count)")
        let body = try await BillsManifestSnapshotClient.current.download(url)
        HomePerfTimeline.mark("manifest_snapshot_download_completed", detail: "bytes=\(body.count)")
        let manifest = try decodeManifest(from: body, label: label, source: "snapshot")
        AppLog.api.info("[\(label, privacy: .public)] downloaded bytes=\(body.count) count=\(manifest.items.count) generatedAt=\(manifest.generatedAt, privacy: .public)")
        return manifest
    }

    /// The snapshot with the bills updated since `snapshotDeltaOverlap` before it was generated merged
    /// over it. The snapshot's `generatedAt` is the downloaded manifest's own. When the delta cannot be
    /// fetched the snapshot is used as it is; a cancelled delta throws `CancellationError`.
    ///
    /// Companion groups: each response carries the complete list, so the delta's list (newer) wins; a
    /// delta without the field keeps the snapshot's list, and a delta's `[]` clears it.
    nonisolated private static func mergingSnapshotDelta(
        into snapshot: DecodedManifest
    ) async throws -> (items: [BillsManifestItem], companionGroups: [BillCompanionGroup]?) {
        let label = ManifestLabel.delta
        guard let generated = FlexibleISO8601.parse(snapshot.generatedAt) else {
            AppLog.api.error("[\(label, privacy: .public)] snapshot generatedAt is not a date; using the snapshot without a delta")
            return (snapshot.items, snapshot.companionGroups)
        }

        let delta: DecodedManifest?
        do {
            let data = try await requestManifestPayload(
                query: [ManifestQuery.updatedAfter: manifestQueryDate(generated.addingTimeInterval(-snapshotDeltaOverlap))],
                label: label,
                source: "snapshot_delta"
            )
            delta = data.isEmpty ? nil : try decodeManifest(from: data, label: label, source: "snapshot_delta")
        } catch {
            let failure = snapshotFailure(error)
            if failure is CancellationError { throw failure }
            let detail = String(describing: failure)
            AppLog.api.error("[\(label, privacy: .public)] delta failed; using the snapshot without it: \(detail, privacy: .private)")
            return (snapshot.items, snapshot.companionGroups)
        }

        let deltaItems = delta?.items ?? []
        let merged = mergingManifestDelta(deltaItems, into: snapshot.items)
        let groups = mergingCompanionGroups(delta: delta?.companionGroups, snapshot: snapshot.companionGroups)
        AppLog.api.info("[\(label, privacy: .public)] merged delta=\(deltaItems.count) snapshot=\(snapshot.items.count) total=\(merged.count)")
        return (merged, groups)
    }

    /// The companion groups of a snapshot and its delta: the delta's list when it has the field
    /// (`[]` included), else the snapshot's.
    nonisolated static func mergingCompanionGroups(
        delta: [BillCompanionGroup]?,
        snapshot: [BillCompanionGroup]?
    ) -> [BillCompanionGroup]? {
        delta ?? snapshot
    }

    /// `snapshot` with each item replaced by the `delta` item with the same guid (the delta wins), then
    /// the delta items the snapshot does not have, in delta order. Within `delta` the last item of a
    /// guid wins.
    nonisolated static func mergingManifestDelta(
        _ delta: [BillsManifestItem],
        into snapshot: [BillsManifestItem]
    ) -> [BillsManifestItem] {
        guard !delta.isEmpty else { return snapshot }

        var deltaByGuid: [String: BillsManifestItem] = [:]
        var deltaGuids: [String] = []
        var seenGuids = Set<String>()
        for item in delta {
            deltaByGuid[item.guid] = item
            if seenGuids.insert(item.guid).inserted { deltaGuids.append(item.guid) }
        }

        let snapshotGuids = Set(snapshot.map(\.guid))
        let added = deltaGuids.filter { !snapshotGuids.contains($0) }.compactMap { deltaByGuid[$0] }
        return snapshot.map { deltaByGuid[$0.guid] ?? $0 } + added
    }
}
