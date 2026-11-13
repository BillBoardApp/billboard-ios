import Foundation

/// Whether a civic store has anything true to show (UX-39, feature review N11). Until the first read of
/// the user's Civic Score or Civic Profile ends, the store holds `.empty`, whose zeros, "Citizen" and
/// "Vote on 25 more bills" are not the user's; views show `loading` or `failed` instead of reading it.
enum CivicLoadPhase: Equatable {
    /// The first read has not ended (or was cancelled): a loading line, never the empty figures.
    case loading
    /// The first read failed and there is nothing to fall back on: "Couldn't load" with Try again. The
    /// message is R2's (`UserFacingLoadError`).
    case failed(String)
    /// The server's figures, fresh or cached. A later failed refresh keeps them on screen.
    case loaded

    static func of(hasLoaded: Bool, lastError: String?) -> CivicLoadPhase {
        if hasLoaded { return .loaded }
        if let lastError { return .failed(lastError) }
        return .loading
    }
}
