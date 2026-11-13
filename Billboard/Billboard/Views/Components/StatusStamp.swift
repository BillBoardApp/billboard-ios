import SwiftUI

/// A word inside a ruled rectangle, like a clerk's rubber stamp (Civic Record spec 3.2): NEW,
/// UPDATED, PASSED, FAILED, BECAME LAW and the rest of the stamp family. Never a dot, never a seal.
///
/// The word is in the `stamp` role (11 pt SF Mono semibold, +0.08 em, capitals) and its colour is
/// also the rule's. The fill is transparent, so the stamp shows the sheet beneath; nothing animates.
/// Became law and Sealed are double-ruled: a 1 pt outer rule, a 1.5 pt gap and a 1 pt inner rule.
/// Under Increase Contrast each colour is its token's stronger value (spec 2.1).
///
/// This is the only view that draws the status colours (`statusUpdated`, `statusPassed`): a status is
/// always a stamped word (spec 1.2; the UI rules check warns anywhere else).
struct StatusStamp: View {
    /// The colour of a notice stamp (the empty, error and caught-up states).
    enum Tone: Equatable {
        /// `ink`: ALL CAUGHT UP.
        case ink
        /// `ink3`: NOTHING YET, NOT FOUND.
        case dim
        /// `danger`: COULDN'T LOAD.
        case danger
    }

    enum Kind: Equatable {
        case new
        case updated
        case passed
        case failed
        case becameLaw
        /// A companion group whose status comes from one member: "S. 456 PASSED".
        case companionLead(number: String, status: BillStatus)
        case verified
        case notVerified
        case sealed
        case unread
        /// NOTHING YET, NOT FOUND, ALL CAUGHT UP, COULDN'T LOAD: the word in sentence case.
        case notice(String, Tone)

        /// The stamp for a bill status. Replaces R2's status dot, arrows and seals.
        init(status: BillStatus) {
            switch status {
            case .new: self = .new
            case .updated: self = .updated
            case .passed: self = .passed
            case .failed: self = .failed
            case .finalized: self = .becameLaw
            }
        }

        static let nothingYet = Kind.notice("Nothing yet", .dim)
        static let notFound = Kind.notice("Not found", .dim)
        static let allCaughtUp = Kind.notice("All caught up", .ink)
        static let couldNotLoad = Kind.notice("Couldn't load", .danger)

        /// The word in sentence case: what the stamp shows (in capitals) and what VoiceOver reads.
        var word: String {
            switch self {
            case .new: return "New"
            case .updated: return "Updated"
            case .passed: return "Passed"
            case .failed: return "Failed"
            case .becameLaw: return "Became law"
            case let .companionLead(number, status): return "\(number) \(Kind(status: status).word)"
            case .verified: return "Verified"
            case .notVerified: return "Not verified"
            case .sealed: return "Sealed"
            case .unread: return "Unread"
            case let .notice(word, _): return word
            }
        }

        /// What VoiceOver reads: the word, with a companion lead's bill number spoken ("Senate bill
        /// 456 passed").
        var spokenWord: String {
            if case let .companionLead(number, status) = self {
                return "\(SpokenForm.billNumber(number)) \(Kind(status: status).word.lowercased())"
            }
            return word
        }

        /// Became law and Sealed carry the double rule.
        var isDoubleRuled: Bool {
            switch self {
            case .becameLaw, .sealed: return true
            case let .companionLead(_, status): return status == .finalized
            default: return false
            }
        }

        /// The colour of the word and the rule.
        var color: Color {
            switch self {
            case .new, .verified, .sealed, .unread: return BillboardColors.primaryText
            case .notVerified: return BillboardColors.dimText
            case .updated: return BillboardColors.statusUpdated
            case .passed, .becameLaw: return BillboardColors.statusPassed
            case .failed: return BillboardColors.statusFailed
            case let .companionLead(_, status): return Kind(status: status).color
            case let .notice(_, tone):
                switch tone {
                case .ink: return BillboardColors.primaryText
                case .dim: return BillboardColors.dimText
                case .danger: return BillboardColors.danger
                }
            }
        }

        /// The palette token behind `color`, for the render tests.
        var paletteToken: BillboardColorToken {
            switch self {
            case .new, .verified, .sealed, .unread: return BillboardPalette.primaryText
            case .notVerified: return BillboardPalette.dimText
            case .updated: return BillboardPalette.statusUpdated
            case .passed, .becameLaw: return BillboardPalette.statusPassed
            case .failed: return BillboardPalette.statusFailed
            case let .companionLead(_, status): return Kind(status: status).paletteToken
            case let .notice(_, tone):
                switch tone {
                case .ink: return BillboardPalette.primaryText
                case .dim: return BillboardPalette.dimText
                case .danger: return BillboardPalette.danger
                }
            }
        }
    }

    /// The single rule's width.
    static let ruleWidth: CGFloat = 1.25
    /// The double rule: outer rule, gap, inner rule.
    static let doubleRuleWidth: CGFloat = 1
    static let doubleRuleGap: CGFloat = 1.5

    /// How big the stamp is.
    enum Size: Equatable {
        /// 11 pt, the `stamp` role: every stamp but one.
        case regular
        /// 12.5 pt with more room inside: the SEALED stamp over the sealed tally sheet (spec 3.8.2).
        case seal

        /// The word's size as a multiple of the `stamp` role's.
        var scale: CGFloat {
            switch self {
            case .regular: return 1
            case .seal: return 12.5 / TextRole.stamp.size
            }
        }
    }

    let kind: Kind
    var size: Size = .regular

    init(_ kind: Kind, size: Size = .regular) {
        self.kind = kind
        self.size = size
    }

    init(status: BillStatus) {
        self.kind = Kind(status: status)
    }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .caption2) private var singleMinHeight: CGFloat = 20
    @ScaledMetric(relativeTo: .caption2) private var doubleMinHeight: CGFloat = 22
    @ScaledMetric(relativeTo: .caption2) private var sealMinHeight: CGFloat = 28

    private var minHeight: CGFloat {
        if size == .seal {
            // 28 pt around the 12.5 pt word (spec 3.8.2). At the accessibility sizes the box fits the word
            // (frame 26): a scaled 28 pt would stand far taller than it (75 pt around 25 pt capitals at AX3).
            return dynamicTypeSize.isAccessibilitySize ? 0 : sealMinHeight
        }
        return kind.isDoubleRuled ? doubleMinHeight : singleMinHeight
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: BillboardStyle.Radius.mark, style: .continuous)
        let double = kind.isDoubleRuled
        // The double rule takes 3.5 pt of the edge, so the word moves in by the extra 2.25 pt to keep
        // the same clearance from the innermost rule as a single-ruled stamp. The seal has more room.
        let horizontalPadding: CGFloat = size == .seal ? 10 : (double ? 8.25 : 6)

        Text(kind.word)
            .textRole(.stamp, scale: size.scale)
            .foregroundStyle(kind.color)
            .multilineTextAlignment(.center)
            // Never truncated (spec 2.5): a long companion lead wraps at the largest text sizes.
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, 2)
            .frame(minHeight: minHeight)
            // The box grows with the word when it wraps (project decision of 2026-10-29). A `minHeight` frame
            // alone takes the smaller of the word's height and the height a stack offers, so in a notice with an
            // action COULDN'T LOAD wrapped to two lines at AX5 in a one-line box, its words over the rules. Asked
            // for its own height the box is the minimum or the word, whichever is taller: a one-line word is
            // shorter than the minimum, so at the default sizes nothing moves.
            .fixedSize(horizontal: false, vertical: true)
            .overlay {
                if double {
                    ZStack {
                        shape.strokeBorder(kind.color, lineWidth: Self.doubleRuleWidth)
                        shape
                            .inset(by: Self.doubleRuleWidth + Self.doubleRuleGap)
                            .strokeBorder(kind.color, lineWidth: Self.doubleRuleWidth)
                    }
                } else {
                    shape.strokeBorder(kind.color, lineWidth: Self.ruleWidth)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(kind.spokenWord)
    }
}

#Preview("Stamps") {
    let kinds: [StatusStamp.Kind] = [
        .new, .updated, .passed, .failed, .becameLaw, .verified, .notVerified, .sealed, .unread,
        .allCaughtUp, .nothingYet, .couldNotLoad, .companionLead(number: "S. 456", status: .passed)
    ]
    FlowLayout(spacing: 12) {
        ForEach(Array(kinds.enumerated()), id: \.offset) { _, kind in
            StatusStamp(kind)
        }
    }
    .padding()
    .background(BillboardColors.cardBackground)
}
