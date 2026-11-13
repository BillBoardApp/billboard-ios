import Foundation

/// Shared policy for how long server manifests are considered fresh.
///
/// Manifests are also cached on disk for offline/placeholder use (the bills manifest in
/// `BillsManifestCache`), but the app should only skip network refreshes when the cached copy is
/// within this freshness window.
enum ManifestCachePolicy {
    /// 10 minutes
    static let ttl: TimeInterval = 10 * 60
}
