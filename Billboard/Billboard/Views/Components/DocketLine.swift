import SwiftUI

/// The first line of every bill slip and of the bill page (Civic Record spec 3.1): what the clerk
/// writes at the top of the record. On one baseline: the bill number(s) in `ink2` semibold, a "·" and
/// the chamber in `ink3` (both in the `docket` role), then at the trailing edge an optional watched
/// mark and the `StatusStamp`. A companion pair shows both numbers ("H.R. 10 · S. 10") and no chamber.
/// An optional second docket line names the bill's companions: "Identical to H.R. 900".
///
/// The line is one VoiceOver element: "House bill 1234. New.", with "Watching." when the mark shows. A
/// vetoed bill's stamp reads VETOED (project decision 2026-11-19): "House bill 131. Vetoed." A New or Updated
/// bill whose Congress ended reads ENDED WITH THE 119TH CONGRESS (REL-46). A bill of an earlier Congress than the one
/// in office prints its Congress after the chamber, "H.R. 1 · HOUSE · 119TH", read "House bill 1, 119th Congress".
/// Every bill number in it is read in its spoken form, the companions' too ("Identical to House bill
/// 900", spec 1.7).
/// When the line does not fit, and at every accessibility text size, the stamp moves onto its own
/// line under the numbers.
struct DocketLine: View {
    /// The bill number, or a companion group's numbers, as printed: "H.R. 1234", ["H.R. 10", "S. 10"].
    let numbers: [String]
    /// HOUSE or SENATE; nil for a companion pair (the numbers say it) or an unknown bill type.
    let chamber: CongressChamber?
    let status: BillStatus?
    /// An older bill's Congress, "119th" (`BillDisplayFormatting.olderCongressTag`, REL-46): printed after the chamber
    /// in `ink3` (the docket role sets it in capitals) and read after the numbers. Nil for a current bill. A group's
    /// members share a Congress, so a line has one.
    var congressTag: String?
    /// The bill (or the group's status lead) is vetoed: the stamp reads VETOED unless the status is
    /// Finalized (`StatusStamp.Kind(status:vetoed:)`).
    var vetoed = false
    /// The bill's Congress has ended and it has no outcome (`Bill.endedCongress(at:)`, REL-46): the stamp reads
    /// ENDED WITH THE 119TH CONGRESS (`StatusStamp.Kind.docket`).
    var endedCongress: Int?
    /// The number of the companion whose status the group shows, when it is not the first: the stamp
    /// then reads "S. 456 PASSED".
    var companionLead: String? = nil
    /// The binoculars mark, shown only on a watched bill whose status is Updated (it replaces R2's
    /// pulsing glow).
    var isWatched = false
    /// The bill's companions, named on a second docket line ("Identical to H.R. 900" on member pages).
    var companions: Companions? = nil

    /// The other bills of a companion group, by their printed numbers.
    struct Companions: Equatable {
        let numbers: [String]
        /// "Identical to"; otherwise "Companion to".
        var isIdentical = true

        init(_ numbers: [String], isIdentical: Bool = true) {
            self.numbers = numbers
            self.isIdentical = isIdentical
        }

        /// "Identical to H.R. 900".
        var printed: String? {
            BillDisplayFormatting.companionSubtitle(numbers: numbers, isIdentical: isIdentical)
        }

        /// "Identical to House bill 900".
        var spoken: String? {
            BillDisplayFormatting.companionSubtitle(numbers: numbers.map(SpokenForm.billNumber), isIdentical: isIdentical)
        }
    }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .caption) private var watchedMarkSize: CGFloat = 12

    init(
        numbers: [String],
        chamber: CongressChamber?,
        status: BillStatus?,
        vetoed: Bool = false,
        endedCongress: Int? = nil,
        congressTag: String? = nil,
        companionLead: String? = nil,
        isWatched: Bool = false,
        companions: Companions? = nil
    ) {
        self.numbers = numbers
        self.chamber = chamber
        self.status = status
        self.congressTag = congressTag
        self.vetoed = vetoed
        self.endedCongress = endedCongress
        self.companionLead = companionLead
        self.isWatched = isWatched
        self.companions = companions
    }

    /// One bill: its number, with the chamber taken from the bill type.
    init(
        number: String,
        status: BillStatus?,
        vetoed: Bool = false,
        endedCongress: Int? = nil,
        congressTag: String? = nil,
        isWatched: Bool = false,
        companions: Companions? = nil
    ) {
        self.init(
            numbers: [number],
            chamber: Self.chamber(forBillNumber: number),
            status: status,
            vetoed: vetoed,
            endedCongress: endedCongress,
            congressTag: congressTag,
            isWatched: isWatched,
            companions: companions
        )
    }

    /// House for H.R., H.Res., H.J.Res. and H.Con.Res.; Senate for S., S.Res., S.J.Res. and
    /// S.Con.Res. (spec 3.1). Nil when the text is not a bill number.
    static func chamber(forBillNumber number: String) -> CongressChamber? {
        guard let key = BillDisplayFormatting.billNumberQueryKey(number) else { return nil }
        switch key.first {
        case "h": return .house
        case "s": return .senate
        default: return nil
        }
    }

    private static let noBreakSpace = "\u{00A0}"

    private var showsWatchedMark: Bool {
        isWatched && status == .updated
    }

    private var stampKind: StatusStamp.Kind? {
        guard let status else { return nil }
        return .docket(status: status, vetoed: vetoed, endedCongress: endedCongress, companionLead: companionLead)
    }

    /// The tag to print and read: only with a number to follow.
    private var shownCongressTag: String? {
        numbers.isEmpty ? nil : congressTag?.trimmedNonEmpty
    }

    /// What VoiceOver reads for the line: "House bill 1234. New.", "House bill 10 and Senate bill 10.
    /// Senate bill 10 passed.", "House bill 1234. Updated. Watching. Identical to House bill 900.", and for an older
    /// bill "House bill 1, 119th Congress. Ended with the 119th Congress."
    var accessibilityText: String {
        let spokenNumbers = BillDisplayFormatting.naturalList(numbers.map(SpokenForm.billNumber))
        var sentences = [SpokenForm.withCongress(spokenNumbers, congressTag: shownCongressTag)]
        if let stampKind { sentences.append(stampKind.spokenWord) }
        if showsWatchedMark { sentences.append("Watching") }
        if let spoken = companions?.spoken { sentences.append(spoken) }
        return SpokenSentences.join(sentences)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if dynamicTypeSize.isAccessibilitySize {
                stacked
            } else {
                ViewThatFits(in: .horizontal) {
                    oneLine
                    stacked
                }
            }
            if let printed = companions?.printed {
                Text(printed)
                    .textRole(.docket)
                    .foregroundStyle(BillboardColors.dimText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var oneLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            numbersText
                .fixedSize()
            Spacer(minLength: 8)
            marks
        }
    }

    private var stacked: some View {
        VStack(alignment: .leading, spacing: 6) {
            numbersText
                .fixedSize(horizontal: false, vertical: true)
            if showsWatchedMark || stampKind != nil {
                HStack(alignment: .center, spacing: 8) {
                    marks
                }
            }
        }
    }

    /// "H.R. 1234 · HOUSE", or "H.R. 1 · HOUSE · 119TH" for an older bill, as one text, so it keeps one baseline and
    /// wraps as a line of type. A bill number never breaks inside, and a "·" stays at the end of its line, not the
    /// start of the next.
    private var numbersText: some View {
        let unbroken = numbers.map { $0.replacingOccurrences(of: " ", with: Self.noBreakSpace) }
        let numberRun = Text(unbroken.joined(separator: "\(Self.noBreakSpace)· "))
            .fontWeight(.semibold)
            .foregroundStyle(BillboardColors.secondaryText)
        var trailing: [String] = []
        if let chamber, numbers.count == 1 {
            trailing.append(CongressMemberLabel.chamberWord(chamber))
        }
        if let shownCongressTag {
            trailing.append(shownCongressTag)
        }
        let text: Text
        if trailing.isEmpty {
            text = numberRun
        } else {
            let trailingRun = Text(trailing.map { "\(Self.noBreakSpace)· \($0)" }.joined())
                .foregroundStyle(BillboardColors.dimText)
            text = Text("\(numberRun)\(trailingRun)")
        }
        return text.textRole(.docket)
    }

    @ViewBuilder
    private var marks: some View {
        if showsWatchedMark {
            Image(systemName: "binoculars.fill")
                .font(TextRole.Face.text.font(size: watchedMarkSize, weight: .semibold))
                .foregroundStyle(BillboardColors.dimText)
        }
        if let stampKind {
            StatusStamp(stampKind)
        }
    }
}

#Preview("Docket lines") {
    VStack(alignment: .leading, spacing: 16) {
        DocketLine(number: "H.R. 1234", status: .new)
        DocketLine(number: "S. 88", status: .updated, isWatched: true)
        DocketLine(numbers: ["H.R. 10", "S. 10"], chamber: nil, status: .passed, companionLead: "S. 10")
        DocketLine(number: "H.R. 77", status: .finalized, companions: .init(["H.R. 900"]))
        DocketLine(number: "H.R. 131", status: .failed, vetoed: true)
        DocketLine(number: "H.R. 4521", status: .updated, endedCongress: 119, congressTag: "119th")
    }
    .padding()
    .background(BillboardColors.cardBackground)
}
