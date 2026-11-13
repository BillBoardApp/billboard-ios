import Combine
import Foundation

@MainActor
final class CongressMembersManifestStore: ObservableObject {
    /// Kept in roster order (last name, then first name), so filtered lists need no re-sort.
    @Published private(set) var items: [CongressMemberManifestItem] = []
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var hasLoadedOnce: Bool = false
    @Published private(set) var errorMessage: String?

    private let service: any CongressServicing

    init(service: any CongressServicing = CongressService.Live()) {
        self.service = service
        if let cachedAny = service.cachedCongressMembersManifest(),
           !cachedAny.isEmpty {
            items = Self.sortedItems(cachedAny)

            if let cachedFresh = service.cachedCongressMembersManifest(maxAge: ManifestCachePolicy.ttl),
               !cachedFresh.isEmpty {
                hasLoadedOnce = true
            }
        }
    }

    func load(forceRefresh: Bool = false) async {
        if isLoading { return }

        if !forceRefresh,
           !items.isEmpty,
           let cachedFresh = service.cachedCongressMembersManifest(maxAge: ManifestCachePolicy.ttl),
           !cachedFresh.isEmpty {
            hasLoadedOnce = true
            return
        }

        if !forceRefresh,
           items.isEmpty,
           let cachedAny = service.cachedCongressMembersManifest(),
           !cachedAny.isEmpty {
            items = sorted(cachedAny)

            if let cachedFresh = service.cachedCongressMembersManifest(maxAge: ManifestCachePolicy.ttl),
               !cachedFresh.isEmpty {
                hasLoadedOnce = true
                return
            }
        }

        isLoading = true
        errorMessage = nil
        defer {
            isLoading = false
            hasLoadedOnce = true
        }

        do {
            let fresh = try await service.getCongressMembersManifest()
            items = sorted(fresh)
        } catch {
            // Leaving the screen mid-load is not a failure (APPF-22).
            if APIErrorResponse.isCancellation(error) { return }
            errorMessage = "Could not load members right now."
            #if DEBUG
            print("[CongressMembersManifestStore] load failed: \(CongressService.debugString(for: error))")
            #endif
        }
    }

    private func sorted(_ items: [CongressMemberManifestItem]) -> [CongressMemberManifestItem] {
        Self.sortedItems(items)
    }

    private static func sortedItems(_ items: [CongressMemberManifestItem]) -> [CongressMemberManifestItem] {
        CongressMemberManifestItem.rosterSorted(items)
    }
}
