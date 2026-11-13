import SwiftUI

/// What the Civic Rank sheet shows for a score (Civic Record spec 4.65). Pure, for tests.
///
/// One colour system: the rank's name carries the meaning, never a tier colour. Progress to the next rank is
/// counted within the current rank, from its minimum score to the next rank's, so the bar and its words agree:
/// at 340 points between Steward (250) and Advocate (500), "90 of 250 points to Advocate".
struct CivicRankSummary: Equatable {
    let rankTitle: String
    /// Nil at the top rank.
    let nextRankTitle: String?
    /// 0 to 1, within the current rank; 1 at the top rank.
    let progress: Double
    /// "90 of 250 points to Advocate" (the docket face sets it in capitals); "Top rank reached" at the top.
    let progressText: String
    /// "Advocate is about 80 votes." Nil at the top rank or when the server sends no estimate.
    let referenceText: String?
    /// CIVIC SCORE, BILLS VOTED, DAY STREAK, BEST STREAK.
    let figures: [Ledger.Row]
    /// VOTES, BEST STREAK, HONORS, each "+260". The streak row holds 5 points a day of the best streak, which
    /// never drops (UX-31: the score never goes down), so it is "Best streak", as in the figures above.
    let breakdown: [Ledger.Row]
    /// The honors' names, for their stamps.
    let honors: [String]
    /// "4 issue areas represented".
    let coverageText: String

    static let topRankText = "Top rank reached"

    init(score: CivicScore) {
        rankTitle = score.rank.title
        nextRankTitle = score.nextRank?.title
        if let next = score.nextRank {
            let span = max(1, next.minScore - score.rank.minScore)
            let earned = min(max(score.civicScore - score.rank.minScore, 0), span)
            progress = Double(earned) / Double(span)
            progressText = "\(earned) of \(span) points to \(next.title)"
            referenceText = next.approxVotesRequired > 0 ? "\(next.title) is about \(next.approxVotesRequired) votes." : nil
        } else {
            progress = 1
            progressText = Self.topRankText
            referenceText = nil
        }
        figures = [
            Ledger.Row("Civic Score", "\(score.civicScore)"),
            Ledger.Row("Bills voted", "\(score.totalVotes)"),
            Ledger.Row("Day streak", "\(score.currentStreak)"),
            Ledger.Row("Best streak", "\(score.longestStreak)")
        ]
        breakdown = [
            Ledger.Row("Votes", "+\(score.voteScore)"),
            Ledger.Row("Best streak", "+\(score.streakBonus)"),
            Ledger.Row("Honors", "+\(score.honorBonus)")
        ]
        honors = score.honors.map(\.title)
        coverageText = score.coverageAreaCount == 1 ? "1 issue area represented" : "\(score.coverageAreaCount) issue areas represented"
    }
}

/// The Civic Rank sheet's content (spec 4.65), opened from the masthead chips: "Current rank" in the docket
/// face and the rank's name in the `display` role, progress to the next rank as a 6 pt square-ended bar
/// (`controlOn` on `well`) with its figures, a ledger of the score, votes and streaks in the figure face,
/// the score breakdown, the honors as ink stamps, the last 30 days as tally marks, and how it works. No
/// tier colour fills, star, stat pills, hero number or rosettes.
struct CivicScoreCard: View {
    let score: CivicScore
    let isLoading: Bool

    private var summary: CivicRankSummary {
        CivicRankSummary(score: score)
    }

    var body: some View {
        let summary = summary
        VStack(alignment: .leading, spacing: BillboardStyle.Space.xxl) {
            VStack(alignment: .leading, spacing: BillboardStyle.Space.s) {
                HStack(alignment: .firstTextBaseline, spacing: BillboardStyle.Space.s) {
                    // For the eye: VoiceOver hears it with the name ("Current rank: Steward").
                    Text("Current rank")
                        .textRole(.docket)
                        .foregroundStyle(BillboardColors.dimText)
                        .accessibilityHidden(true)
                    Spacer(minLength: 0)
                    if isLoading {
                        ProgressView()
                            .tint(BillboardColors.interactive)
                            .accessibilityLabel("Loading")
                    }
                }

                Text(summary.rankTitle)
                    .textRole(.display)
                    .foregroundStyle(BillboardColors.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Current rank: \(summary.rankTitle)")
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("civicRank.rank")

                VStack(alignment: .leading, spacing: BillboardStyle.Space.s) {
                    CivicProfileProgressBar(progress: summary.progress)
                    Text(summary.progressText)
                        .textRole(.docket)
                        .foregroundStyle(BillboardColors.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    if let reference = summary.referenceText {
                        Text(reference)
                            .textRole(.caption)
                            .foregroundStyle(BillboardColors.dimText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, BillboardStyle.Space.xs)
                .accessibilityElement(children: .combine)
            }

            Ledger(rows: summary.figures, answerRole: .figureLarge)

            VStack(alignment: .leading, spacing: BillboardStyle.Space.m) {
                SectionHeader("Score breakdown")
                Ledger(rows: summary.breakdown, answerRole: .figure)
            }

            if !summary.honors.isEmpty {
                VStack(alignment: .leading, spacing: BillboardStyle.Space.m) {
                    SectionHeader("Honors")
                    FlowLayout(spacing: BillboardStyle.Space.s) {
                        ForEach(Array(summary.honors.enumerated()), id: \.offset) { _, honor in
                            StatusStamp(.notice(honor, .ink))
                        }
                    }
                    Text(summary.coverageText)
                        .textRole(.caption)
                        .foregroundStyle(BillboardColors.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
