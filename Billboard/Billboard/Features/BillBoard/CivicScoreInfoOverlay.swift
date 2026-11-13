import SwiftUI

/// The Civic Rank sheet opened from the masthead chips (Civic Record spec 4.65): paper under the system glass
/// bar with "Civic Rank" inline and a system Done. It watches the store, so a read that ends while it is open
/// shows at once; opened before the score has loaded (a new device, offline at launch), it reads it.
struct CivicScoreInfoOverlay: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: CivicScoreStore

    var body: some View {
        NavigationStack {
            ScrollView {
                CivicRankSheetContent(score: store.score, isLoading: store.isLoading, phase: store.phase) {
                    Task { await store.refresh() }
                }
                .padding(.horizontal, BillboardStyle.Space.xl)
                .padding(.top, BillboardStyle.Space.l)
                .padding(.bottom, BillboardStyle.Space.xxl)
            }
            .billboardBackground()
            .navigationTitle("Civic Rank")
            .navigationBarTitleDisplayMode(.inline)
            .glassNavigationBar()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    // A system bar button (Civic Record spec 3.21): sheet Done is never a custom capsule.
                    // The bar keeps it at a fixed size and offers the Large Content Viewer.
                    Button("Done") { dismiss() }
                }
            }
        }
        // Paper under the sheet's glass bar (spec 4.7).
        .presentationBackground(BillboardColors.background)
        .task {
            guard store.phase != .loaded, !store.isLoading, !AppLaunchOptions.shouldStreamlineStartupForUITests else { return }
            await store.refresh()
        }
    }
}

/// What the Civic Rank sheet holds, top to bottom (spec 4.65): the rank and the score
/// (`CivicScoreCard`), the last 30 days as tally marks, and how it works in `body` paragraphs.
///
/// Until the score has loaded (UX-39 N11), a loading line in place of the rank, the figures and the days,
/// or "Couldn't load your Civic Rank" with Try again when the read failed: never `CivicScore.empty`'s
/// "Citizen" with a full bar and "Top rank reached".
struct CivicRankSheetContent: View {
    let score: CivicScore
    let isLoading: Bool
    var phase: CivicLoadPhase = .loaded
    var onRetry: () -> Void = {}

    static let howItWorks = [
        "Your Civic Score grows through voting, your best streak, and one-time Honors earned along the way. It never goes down.",
        "Your Civic Rank is based on Civic Score milestones, with approximate vote counts shown as a reference point.",
        "Some features unlock only when there is enough voting history to make them accurate, like the Civic Profile."
    ]

    static let loadingText = "Loading your Civic Rank…"
    static let failedTitle = "Couldn't load your Civic Rank"

    var body: some View {
        VStack(alignment: .leading, spacing: BillboardStyle.Space.xxl) {
            switch phase {
            case .loaded:
                CivicScoreCard(score: score, isLoading: isLoading)

                if let days = score.recentVoteDays, !days.isEmpty {
                    VotingStreakView(recentVoteDays: days)
                }
            case .loading:
                CongressLoadingLine(text: Self.loadingText)
                    .accessibilityIdentifier("civicRank.loading")
            case .failed(let message):
                RecordNotice(
                    .couldNotLoad,
                    title: Self.failedTitle,
                    message: message,
                    action: .init(title: "Try again", accessibilityIdentifier: "civicRank.retry", perform: onRetry)
                )
            }

            VStack(alignment: .leading, spacing: BillboardStyle.Space.m) {
                SectionHeader("How it works")
                ForEach(Self.howItWorks, id: \.self) { paragraph in
                    Text(paragraph)
                        .textRole(.body)
                        .foregroundStyle(BillboardColors.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
