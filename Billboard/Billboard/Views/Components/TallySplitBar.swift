import SwiftUI

/// The Yea / Nay split every tally draws (spec 3.7, 4.40): 8 pt tall with square ends, Yea from the
/// leading edge, a 2 pt gap, then Nay, the widths in proportion to Yea and Nay only. One view for all of
/// them: Results' rows (`VoteSplitBar`), How Congress voted and Compare with Congress (`CongressSplitBar`).
///
/// `progress` grows the segments from the centre gap: Yea is anchored at its trailing end and Nay at its
/// leading end (spec 5.1). `tick` stands the 2 pt 50% `MajorityTick` over the bar, which then sits in the
/// 16 pt block the tick needs. `empty` is what a split with no Yea or Nay draws. A part: the rows that draw it
/// show the vote symbols, words and figures. Hidden from VoiceOver.
struct TallySplitBar: View {
    enum Tick {
        /// No tick and no room for one.
        case none
        /// The tick, always (an official roll call).
        case always
        /// The tick when there are Yea or Nay votes; the room for it either way (Results).
        case whenVotes
    }

    enum Empty {
        /// Nothing.
        case nothing
        /// A `well` fill (an official roll call with no Yea or Nay).
        case well
        /// A 1 pt `rule2` border, as `TallyBlankBar` (Results with no Yea or Nay votes).
        case outline
    }

    let yea: Double
    let nay: Double
    var progress: CGFloat = 1
    var tick: Tick = .none
    var empty: Empty = .nothing

    static let height: CGFloat = 8
    static let gap: CGFloat = 2

    private var hasVotes: Bool { yea + nay > 0 }

    var body: some View {
        GeometryReader { geometry in
            if hasVotes {
                let gap = yea > 0 && nay > 0 ? Self.gap : 0
                let available = max(0, geometry.size.width - gap)
                let yeaWidth = available * CGFloat(yea / (yea + nay))
                let nayWidth = available - yeaWidth
                HStack(spacing: gap) {
                    if yea > 0 {
                        Rectangle()
                            .fill(BillboardColors.voteYea)
                            .frame(width: yeaWidth * progress)
                            .frame(width: yeaWidth, alignment: .trailing)
                    }
                    if nay > 0 {
                        Rectangle()
                            .fill(BillboardColors.voteNay)
                            .frame(width: nayWidth * progress)
                            .frame(width: nayWidth, alignment: .leading)
                    }
                }
            } else {
                switch empty {
                case .nothing:
                    Color.clear
                case .well:
                    Rectangle().fill(BillboardColors.secondaryBackground)
                case .outline:
                    Rectangle().strokeBorder(BillboardColors.rule2, lineWidth: 1)
                }
            }
        }
        .frame(height: Self.height)
        .overlay {
            if tick == .always || (tick == .whenVotes && hasVotes) {
                MajorityTick(barHeight: Self.height)
            }
        }
        .padding(.vertical, tick == .none ? 0 : MajorityTick.overhang)
        .accessibilityHidden(true)
    }
}

/// A vote side's head with its total (spec 4.46, 4.64): the symbol and "Yea (23)" in the `label` role and the
/// vote colour, read "Yea, 23 votes". The heads of Why people voted.
struct VoteCountHead: View {
    let choice: VoteChoice
    let count: Int

    /// "Yea, 23 votes", "Nay, 1 vote".
    static func spoken(_ choice: VoteChoice, count: Int) -> String {
        "\(choice.title), \(count == 1 ? "1 vote" : "\(count) votes")"
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: choice.symbolName)
                .accessibilityHidden(true)
            Text("\(choice.title) (\(count))")
        }
        .textRole(.label)
        .foregroundStyle(choice.color)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spoken(choice, count: count))
    }
}
