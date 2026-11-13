import SwiftUI

/// Copy of the civic profile card (spec D 2.4.2: themes, not axes). Pure, for tests.
enum CivicProfileCopy {
    static let title = "Your Civic Profile"
    static let missingThemesNote = "Some themes need more votes before they get a score."
    /// Until the first read ends (UX-39 N11), in place of the locked state's "Vote on 25 more bills".
    static let loading = "Loading your Civic Profile…"
    static let failedTitle = "Couldn't load your Civic Profile"

    /// "Based on 47 votes".
    static func basedOn(votes: Int) -> String {
        votes == 1 ? "Based on 1 vote" : "Based on \(votes) votes"
    }

    /// Whether the profile's count is capped: GET /civic-profile reads only the most recent 100 Yea or Nay votes on
    /// bills with theme scores (`votesUsed`) of all of them (`totalVotesWithProfile`), so a count under the total is
    /// the cap. Profile's "Based on your last 100 votes" and the member page's "Your chart is based on your last 100
    /// bill votes." both ask this, so the two never disagree.
    static func isCapped(_ profile: CivicProfileResponse) -> Bool {
        profile.totalVotesWithProfile > profile.votesUsed
    }

    /// The line over the chart: "Based on 47 votes", or "Based on your last 100 votes" when the count is capped
    /// (project decision of 2026-10-29), since "Based on 100 votes" would not match the user's own count of votes.
    static func basedOn(_ profile: CivicProfileResponse) -> String {
        guard isCapped(profile) else { return basedOn(votes: profile.votesUsed) }
        return "Based on your last \(profile.votesUsed) votes"
    }

    /// "Vote on 3 more bills to unlock your Civic Profile".
    static func unlockPrompt(votesRemaining: Int) -> String {
        "Vote on \(votesRemaining) more bill\(votesRemaining == 1 ? "" : "s") to unlock your Civic Profile"
    }

    /// The line under the prompt while GET /civic-profile says the themes hold the profile (UX-32, approved
    /// 2026-10-29): "It opens once 3 themes each have 8 of your votes. 2 of 3 so far." Nil for the vote lock (any
    /// `lockedBy` but "themes"), from a server before UX-32, which sends none of the numbers, or when one is missing.
    static func themeLock(_ profile: CivicProfileResponse) -> String? {
        guard profile.isLockedByThemes,
              let themesRequired = profile.minThemesRequired,
              let themeVotes = profile.minThemeVotes,
              let themesReady = profile.themesReady,
              themesReady < themesRequired else { return nil }
        return "It opens once \(themesRequired) themes each have \(themeVotes) of your votes. \(themesReady) of \(themesRequired) so far."
    }

    /// What VoiceOver reads for the prompt: the prompt alone, or with the theme line after it as one element, so
    /// the reason follows the number it explains.
    static func spokenUnlockPrompt(_ profile: CivicProfileResponse) -> String {
        let prompt = unlockPrompt(votesRemaining: profile.votesRemaining)
        guard let themeLock = themeLock(profile) else { return prompt }
        return "\(prompt). \(themeLock)"
    }

    /// "12 of 25 votes" (the docket face sets it in capitals).
    static func progress(votesUsed: Int, votesRequired: Int) -> String {
        "\(votesUsed) of \(votesRequired) vote\(votesRequired == 1 ? "" : "s")"
    }
}

/// "Your Civic Profile" on Profile (Civic Record spec 3.27, 4.64): a section on paper with the ink info
/// button at the head's trailing edge, then "Based on 47 votes" in the docket face, the radar chart in
/// ink and the AI note (UX-37). Until there are enough votes, the locked state: "Vote on 13 more bills to unlock your Civic
/// Profile", a 6 pt square-ended progress bar and "12 of 25 votes" in the docket face. While the server says the
/// themes hold it (UX-32), a caption line under the prompt says what they need. No hexagon, pie or lock symbols.
/// The user's own data only.
///
/// Before the profile has loaded (UX-39 N11), as the member page's card does: a loading line, or COULDN'T
/// LOAD with Try again when the read failed. Never the locked state, which would tell a user with hundreds
/// of votes to vote on 25 more bills.
struct CivicProfileCard: View {
    let profile: CivicProfileResponse
    let isLoading: Bool
    var phase: CivicLoadPhase = .loaded
    var onRetry: () -> Void = {}
    @State private var isShowingInfo = false

    var body: some View {
        VStack(alignment: .leading, spacing: ProfileLayout.headToContent) {
            ProfileSectionHead(CivicProfileCopy.title) {
                HStack(spacing: BillboardStyle.Space.s) {
                    // A refresh over a shown profile; before it loads the loading line has the spinner.
                    if isLoading && phase == .loaded {
                        ProgressView()
                            .tint(BillboardColors.interactive)
                            .accessibilityLabel("Loading")
                    }
                    CivicProfileInfoButton(isShowingInfo: $isShowingInfo)
                }
            }

            ZStack(alignment: .top) {
                VStack(alignment: .leading, spacing: BillboardStyle.Space.m) {
                    if phase != .loaded {
                        notLoadedView
                    } else if profile.isReady {
                        Text(CivicProfileCopy.basedOn(profile))
                            .textRole(.docket)
                            .foregroundStyle(BillboardColors.dimText)
                            .fixedSize(horizontal: false, vertical: true)

                        RadarChartView(profile: profile, scoreSubjectLabel: "You")
                            .frame(maxWidth: 430)
                            .frame(maxWidth: .infinity, alignment: .center)

                        CivicProfileAINote()

                        // The server leaves out themes without enough votes; say so instead of implying a score.
                        if !profile.axesWithoutSignal.isEmpty {
                            Text(CivicProfileCopy.missingThemesNote)
                                .textRole(.caption)
                                .foregroundStyle(BillboardColors.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        unlockView
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(isShowingInfo ? 0 : 1)
                .accessibilityHidden(isShowingInfo)

                if isShowingInfo {
                    CivicProfileInfoOverlay {
                        isShowingInfo = false
                    }
                    .transition(.opacity)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeInOut(duration: 0.2), value: isShowingInfo)
        // A container, so the controls inside keep their own ids.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("profile.civicProfile")
    }

    @ViewBuilder
    private var notLoadedView: some View {
        switch phase {
        case .failed(let message):
            RecordNotice(
                .couldNotLoad,
                title: CivicProfileCopy.failedTitle,
                message: message,
                action: .init(title: "Try again", accessibilityIdentifier: "profile.civicProfile.retry", perform: onRetry)
            )
        case .loading, .loaded:
            CongressLoadingLine(text: CivicProfileCopy.loading)
                .accessibilityIdentifier("profile.civicProfile.loading")
        }
    }

    private var unlockView: some View {
        VStack(alignment: .leading, spacing: BillboardStyle.Space.s) {
            VStack(alignment: .leading, spacing: BillboardStyle.Space.s) {
                Text(CivicProfileCopy.unlockPrompt(votesRemaining: profile.votesRemaining))
                    .textRole(.body)
                    .foregroundStyle(BillboardColors.primaryText)
                    .fixedSize(horizontal: false, vertical: true)

                if let themeLock = CivicProfileCopy.themeLock(profile) {
                    Text(themeLock)
                        .textRole(.caption)
                        .foregroundStyle(BillboardColors.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(CivicProfileCopy.spokenUnlockPrompt(profile))

            CivicProfileProgressBar(
                progress: profile.minVotesRequired > 0
                    ? Double(profile.votesUsed) / Double(profile.minVotesRequired)
                    : 0
            )
            .padding(.top, BillboardStyle.Space.xs)

            Text(CivicProfileCopy.progress(votesUsed: profile.votesUsed, votesRequired: profile.minVotesRequired))
                .textRole(.docket)
                .foregroundStyle(BillboardColors.dimText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview("Ready") {
    CivicProfileCard(
        profile: CivicProfileResponse(
            axes: [
                "individualVsCommunity": 0.65,
                "localVsFederal": 0.55,
                "freeMarketVsRegulated": 0.7,
                "traditionalVsProgressive": 0.6,
                "interventionistVsRestrained": 0.45,
                "privacyVsSecurity": 0.75,
            ],
            votesUsed: 47,
            totalVotesWithProfile: 47,
            minVotesRequired: 25,
            isReady: true
        ),
        isLoading: false
    )
    .padding()
}

#Preview("Locked by themes") {
    CivicProfileCard(
        profile: CivicProfileResponse(
            axes: [:],
            votesUsed: 30,
            totalVotesWithProfile: 30,
            minVotesRequired: 33,
            isReady: false,
            lockedBy: "themes",
            themesReady: 2,
            minThemesRequired: 3,
            minThemeVotes: 8
        ),
        isLoading: false
    )
    .padding()
}

#Preview("Locked") {
    CivicProfileCard(
        profile: CivicProfileResponse(
            axes: [:],
            votesUsed: 12,
            totalVotesWithProfile: 12,
            minVotesRequired: 25,
            isReady: false
        ),
        isLoading: false
    )
    .padding()
}
