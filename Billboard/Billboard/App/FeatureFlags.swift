import Foundation

/// Compile-time switches for R2's riskier client features (spec D 6). The app has no remote
/// configuration: a hotfix build turns one off by changing its value here, without code surgery.
/// Each feature checks its flag at its single entry point.
nonisolated enum FeatureFlags {
    /// App Attest on this install: key generation, attestation, assertions on `POST /feedback` and
    /// sign-up metadata (spec D 2.8, C3). Off: requests carry no attestation header and sign-up
    /// sends no attestation metadata. The server kill switch (`APP_ATTEST_CLIENT_MODE=off`) needs
    /// no app release.
    static let appAttestClient = true

    /// The starter feed for profiles that follow no topics and no life areas (spec D 2.5.4).
    /// Off: such a profile sees the R1 Bills list (topic-matched bills only).
    static let starterFeed = true

    /// The coach mark above the vote bar after the tour opens the first bill (spec D 2.5.5).
    static let voteBarCoachMark = true

    /// Civic Record's custom Liquid Glass (spec 2.9): the tab capsule, the vote panel, the Undo
    /// toast, the sync capsule, Jump to top and the tour swipe hint. Off: those six views draw their
    /// Reduce Transparency fallback (solid fills) for everyone, so a hotfix build can turn custom
    /// glass off if a device problem shows up after release. System bars are not affected.
    static let glassChrome = true
}
