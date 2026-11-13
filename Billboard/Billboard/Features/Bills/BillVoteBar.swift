import SwiftUI

/// The vote panel at the bottom of every bill page (Civic Record spec 3.10, 3.11, 5.1; frames 4 to 8, 21 to
/// 24): a Liquid Glass panel with 30 pt corners and 10 pt padding, and everything inside it opaque. A decided
/// bill gets the same panel (project decision 1). `BillDetail` attaches it with `.safeAreaBar`.
///
/// - Before a vote: Yea, Nay and Abstain as ballot buttons (`BallotButtonStyle`), equal in width and height,
///   with the ballot box beside the word, or above it where that does not fit (from xLarge up on a 375 pt
///   phone, and always at xxxLarge).
/// - The tapped button inks (`inked`, set by `BillDetail` for 180 ms), then becomes the ballot stamp in place:
///   the two share a `matchedGeometryEffect` id, so its frame moves and grows into the stamp's as they
///   cross-fade (`morphID`).
/// - After a vote: the `BallotStamp` beside Change, dated if it fits, else the no-date form, else the stamp and
///   Change stacked full width (always at xxxLarge; `BallotVotedRow`). Change is an opaque capsule, never glass
///   on glass.
/// - Change opens the three buttons again under "Change your vote" and Cancel, the current vote ringed and
///   marked "Your vote"; tapping it, or Cancel, goes back to the stamp and writes nothing.
/// - At the accessibility sizes the panel holds one full-width button: "Vote" (opens the "Your vote" dialog),
///   "Checking…", or the voted capsule "Yea · Change" (or "Change"), which opens the same dialog.
/// - One opaque strip at most over the controls, up to xxLarge (`BillVoteBarModel.panelStrip`), first of: the
///   refused vote's reason, "Change your vote", the `.updatedOnly` and checking captions, the coach mark. From
///   xxxLarge up they are rows of Your vote (`BillYourVoteSection`), except "Change your vote".
///
/// The panel is an accessibility container labelled "Vote". Tapping a button never changes watch;
/// `BillDetail` records the vote with `watch: nil` (leave it as it is).
struct BillVoteBar: View {
    let model: BillVoteBarModel
    /// The first-vote coach mark (spec 3.10.1).
    var showsCoachMark: Bool = false
    /// The refused vote's reason (APPF-27, spec 3.10.2), until the next vote tap or leaving the page.
    var refusal: String? = nil
    /// When the shown vote was cast, for the stamp's date; nil draws the no-date form.
    var votedAt: Date? = nil
    /// The vote just tapped, drawn inked over the buttons until `BillDetail` clears it (spec 5.1).
    var inked: VoteChoice? = nil
    /// Draws the inked button's inner rule in rather than drawn already (a live tap, not a render).
    var animatesInk = false
    /// The stamp's label for its first VoiceOver focus after a vote here (spec 3.10.3).
    var stampFocusLabel: String? = nil
    /// The bill page's VoiceOver focus: the first button (Yea, or Vote) is `.voteButtons`, the stamp
    /// `.stamp` and the refusal strip `.refusal`. Nil attaches none; `ImageRenderer` drops a view that
    /// carries `.accessibilityFocused`, so the render tests pass none.
    var focus: AccessibilityFocusState<VoteFocusTarget?>.Binding? = nil
    let onVote: (VoteChoice) -> Void
    /// Change was tapped: open the buttons over the vote.
    let onChange: () -> Void
    /// The current vote (or Cancel) was tapped while changing: close the buttons, nothing is written.
    let onCollapse: () -> Void
    var onDismissCoachMark: () -> Void = {}
    /// The stamp's VoiceOver action "Go to Results".
    var onGoToResults: () -> Void = {}

    /// The panel's padding: its inner shapes are concentric at 30 - 10 = 20 pt.
    static let panelPadding: CGFloat = 10
    static let spacing: CGFloat = 8
    /// From the screen's sides.
    static let sideMargin: CGFloat = 12
    static let innerCornerRadius: CGFloat = BillboardStyle.Radius.panel - panelPadding

    /// The id the inked button and the stamp share (spec 3.10 step 2, 5.1). When `BillDetail` clears `inked`
    /// (`BallotMoment.morph`, `.smooth` over 0.28 s) the button row gives way to the stamp, and the inked button's
    /// frame moves and grows into the stamp's while the two cross-fade: the tapped button becomes the stamp in
    /// place; the other two buttons and Change only fade. Every other button has an id of its own, so Change,
    /// Cancel and a refusal stay plain cross-fades. With Reduce Motion nothing is matched: a 0.2 s cross-fade.
    static let morphID = "bill.vote.morph"

    @State private var showsVoteDialog = false
    @Namespace private var ballotMorph
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone

    private var sizeClass: BillVoteBarModel.TextSizeClass {
        BillVoteBarModel.TextSizeClass(dynamicTypeSize)
    }

    private var controlHeight: CGFloat {
        BillVoteBarModel.controlHeight(for: dynamicTypeSize)
    }

    /// `morphID` for the inked button (not with Reduce Motion), else the button's own.
    private func morphID(for choice: VoteChoice, isInked: Bool) -> String {
        isInked && !reduceMotion ? Self.morphID : "\(Self.morphID).\(choice.rawValue)"
    }

    /// `morphID` for the stamp (not with Reduce Motion).
    private var stampMorphID: String {
        reduceMotion ? "\(Self.morphID).stamp" : Self.morphID
    }

    /// The buttons show (before a vote, while changing, or inked for the moment after a tap): the current
    /// vote and the inked one, if any.
    private var ballotRow: (selected: VoteChoice?, inked: VoteChoice?)? {
        switch model.layout {
        case .choose(_, let selected):
            return (selected, nil)
        case .collapsed(let choice):
            return inked == choice ? (nil, choice) : nil
        }
    }

    var body: some View {
        let strip = model.panelStrip(in: sizeClass, refusal: refusal, showsCoachMark: showsCoachMark)
        VStack(alignment: .leading, spacing: Self.spacing) {
            if let strip {
                stripView(strip)
                    .transition(.opacity)
            }
            controls
        }
        .padding(Self.panelPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(VotePanelChrome())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(BillVoteBarModel.accessibilityLabel)
        .accessibilityIdentifier(BillVoteBarModel.barIdentifier)
        .tutorialTarget(.voteBar)
        .confirmationDialog(
            BillVoteBarModel.dialogTitle,
            isPresented: $showsVoteDialog,
            titleVisibility: .visible
        ) {
            ForEach(VoteChoice.allCases) { choice in
                Button(dialogTitle(for: choice)) {
                    handleDialogTap(choice)
                }
                .accessibilityIdentifier(BillVoteBarModel.identifier(for: choice))
            }
            Button(BillVoteBarModel.cancelTitle, role: .cancel) {}
        }
    }

    // MARK: Controls

    @ViewBuilder
    private var controls: some View {
        if sizeClass == .accessibility {
            accessibilityButton
        } else if let row = ballotRow {
            ballotButtons(selected: row.selected, inked: row.inked)
                .transition(.opacity)
        } else if case .collapsed(let choice) = model.layout {
            votedRow(stampCopy(choice))
                .transition(.opacity)
        }
    }

    /// The three buttons, box beside the word, else box above it (always at xxxLarge), else one Vote
    /// button where even that does not fit.
    @ViewBuilder
    private func ballotButtons(selected: VoteChoice?, inked: VoteChoice?) -> some View {
        if sizeClass == .extraLarge {
            ViewThatFits(in: .horizontal) {
                buttonRow(stacked: true, selected: selected, inked: inked)
                compactVoteButton
            }
        } else {
            ViewThatFits(in: .horizontal) {
                buttonRow(stacked: false, selected: selected, inked: inked)
                buttonRow(stacked: true, selected: selected, inked: inked)
                compactVoteButton
            }
        }
    }

    /// Yea, Nay and Abstain, left to right, equal in width and height.
    private func buttonRow(stacked: Bool, selected: VoteChoice?, inked: VoteChoice?) -> some View {
        EqualWidthRow(spacing: Self.spacing) {
            ForEach(VoteChoice.allCases) { choice in
                let isCurrent = choice == selected
                let isInked = choice == inked
                Button {
                    handleTap(choice)
                } label: {
                    BallotButtonLabel(choice: choice, stacked: stacked, isCurrent: isCurrent, isInked: isInked)
                }
                .buttonStyle(BallotButtonStyle(
                    choice: choice,
                    state: isInked ? .inked : (isCurrent ? .current : .ready),
                    height: controlHeight,
                    animatesInk: animatesInk
                ))
                .disabled(model.isAwaitingVoteCheck)
                .matchedGeometryEffect(id: morphID(for: choice, isInked: isInked), in: ballotMorph)
                // The other two fade to 45% while the tapped one inks; the moment takes no second tap.
                .opacity(inked != nil && !isInked ? BallotButtonStyle.disabledOpacity : 1)
                .allowsHitTesting(inked == nil)
                .accessibilityLabel(isCurrent ? BillVoteBarModel.currentVoteAccessibilityLabel(choice) : choice.accessibilityLabel)
                .accessibilityInputLabels(BillVoteBarModel.inputLabels(for: choice))
                .accessibilityAddTraits(isCurrent ? .isSelected : [])
                .accessibilityIdentifier(BillVoteBarModel.identifier(for: choice))
                .accessibilityFocusTarget(choice == .yea ? focus : nil, equals: .voteButtons)
            }
        }
    }

    /// One full-width Vote button where the three do not fit (a very narrow panel).
    private var compactVoteButton: some View {
        voteButton(title: BillVoteBarModel.compactTitle, isChecking: false)
    }

    /// The primary ink capsule "Vote" (or "Checking…", disabled): opens the "Your vote" dialog.
    private func voteButton(title: String, isChecking: Bool) -> some View {
        Button {
            showsVoteDialog = true
        } label: {
            Text(title)
        }
        .buttonStyle(BillboardButtonStyle(kind: .primary, fullWidth: true, minHeight: controlHeight))
        .disabled(isChecking)
        .accessibilityHint(isChecking ? "" : BillVoteBarModel.compactHint)
        .accessibilityIdentifier(BillVoteBarModel.compactIdentifier)
        .accessibilityFocusTarget(focus, equals: .voteButtons)
    }

    private func stampCopy(_ choice: VoteChoice) -> BallotStampCopy {
        BallotStampCopy(choice: choice, votedAt: votedAt, locale: locale, timeZone: timeZone)
    }

    /// "Yea", or "Yea (your vote)" for the current vote.
    private func dialogTitle(for choice: VoteChoice) -> String {
        choice == model.choice ? "\(choice.title) (your vote)" : choice.title
    }

    private func handleTap(_ choice: VoteChoice) {
        switch model.result(ofTapping: choice) {
        case .vote(let vote):
            onVote(vote)
        case .collapse:
            onCollapse()
        }
    }

    /// In the dialog the current vote ("Yea (your vote)") writes nothing, as tapping it while changing.
    private func handleDialogTap(_ choice: VoteChoice) {
        switch model.dialogResult(ofTapping: choice) {
        case .vote(let vote):
            onVote(vote)
        case .collapse:
            onCollapse()
        }
    }

    // MARK: Voted

    /// The stamp beside Change: dated, else the no-date form, else the stamp on its own row with Change under it,
    /// both full width (always at xxxLarge), the stamp there dated where it fits. One stamp view in every form
    /// (`BallotVotedRow` places it; the stamp drops its date to fit the width it gets), so it can take part in
    /// the morph, which a view inside a `ViewThatFits` cannot.
    private func votedRow(_ copy: BallotStampCopy) -> some View {
        BallotVotedRow(spacing: Self.spacing, alwaysStacked: sizeClass == .extraLarge) {
            BallotStamp(
                copy: copy,
                minHeight: controlHeight,
                dropsDateToFit: true,
                accessibilityLabel: stampFocusLabel
            )
            .matchedGeometryEffect(id: stampMorphID, in: ballotMorph)
            .ballotStampAccessibility(focus: focus, onGoToResults: onGoToResults)
            changeButton
            // Only measures: the stamp goes beside Change where its no-date form fits there.
            BallotStamp(copy: copy, minHeight: controlHeight, showsDate: false)
                .hidden()
                .accessibilityHidden(true)
        }
    }

    /// Change (spec 3.11): an opaque `sheet` capsule with a 1 pt `controlRule` and an ink label, as tall as the
    /// other controls; as wide as its label beside the stamp, full width under it (`BallotVotedRow`).
    private var changeButton: some View {
        Button {
            onChange()
        } label: {
            Text(BillVoteBarModel.changeTitle)
        }
        .buttonStyle(PanelCapsuleButtonStyle(height: controlHeight, fullWidth: true))
        .accessibilityLabel(BillVoteBarModel.changeHint)
        .accessibilityInputLabels(BillVoteBarModel.changeInputLabels)
        .accessibilityIdentifier(BillVoteBarModel.changeIdentifier)
    }

    // MARK: Accessibility sizes

    @ViewBuilder
    private var accessibilityButton: some View {
        switch model.accessibilityButton {
        case .vote:
            voteButton(title: BillVoteBarModel.compactTitle, isChecking: false)
        case .checking:
            voteButton(title: BillVoteBarModel.checkingTitle, isChecking: true)
        case .voted(let choice):
            let copy = stampCopy(choice)
            Button {
                showsVoteDialog = true
            } label: {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: BillboardStyle.Space.s) {
                        BallotBox(choice: choice, fill: .filled)
                        Text("\(Text(choice.title).foregroundStyle(choice.color)) · \(BillVoteBarModel.changeTitle)")
                            .foregroundStyle(BillboardColors.interactive)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    Text(BillVoteBarModel.changeTitle)
                }
            }
            .buttonStyle(PanelCapsuleButtonStyle(height: controlHeight, fullWidth: true))
            .accessibilityLabel(copy.accessibilityLabel)
            .accessibilityHint(BillVoteBarModel.changeHint)
            .accessibilityInputLabels(BillVoteBarModel.changeInputLabels)
            .accessibilityIdentifier(BillVoteBarModel.changeIdentifier)
            .accessibilityFocusTarget(focus, equals: .voteButtons)
        }
    }

    // MARK: Strips

    @ViewBuilder
    private func stripView(_ strip: BillVoteBarModel.Strip) -> some View {
        switch strip {
        case .refusal(let text):
            VoteStrip(kind: .refusal(text), focus: focus)
        case .changing:
            VoteStrip(kind: .changing, onCancel: onCollapse)
        case .coachMark:
            VoteStrip(kind: .coachMark(BillVoteBarModel.coachMarkText), onDismissCoachMark: onDismissCoachMark)
        case .caption(let text):
            VoteStrip(kind: .caption(text))
        }
    }
}

// MARK: - Panel chrome

/// The panel's material (spec 2.9): `.regular` Liquid Glass with 30 pt corners and no hairline or shadow;
/// with Reduce Transparency (or `FeatureFlags.glassChrome` off) an opaque `sheet` with a 1 pt `rule`; with
/// Increase Contrast the same with a 1 pt `controlRule`. Everything inside is opaque, so there is no
/// `GlassEffectContainer`.
struct VotePanelChrome: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var treatment: GlassChrome.Treatment {
        GlassChrome.treatment(
            glassChrome: FeatureFlags.glassChrome,
            reduceTransparency: reduceTransparency,
            increaseContrast: contrast == .increased
        )
    }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: BillboardStyle.Radius.panel, style: .continuous)
        switch treatment {
        case .glass:
            content
                .glassEffect(.regular, in: shape)
                .containerShape(shape)
        case .solid:
            content
                .background(shape.fill(BillboardColors.cardBackground))
                .overlay(shape.strokeBorder(BillboardColors.separator, lineWidth: 1))
                .containerShape(shape)
        case .solidHighContrast:
            content
                .background(shape.fill(BillboardColors.cardBackground))
                .overlay(shape.strokeBorder(BillboardColors.controlRule, lineWidth: 1))
                .containerShape(shape)
        }
    }
}

// MARK: - Ballot button label

/// A ballot button's label (spec 3.10): the ballot box and the word, in the `button` role at 15.5 pt, the box
/// beside the word or above it; while changing, the current vote adds "Your vote" under its word.
struct BallotButtonLabel: View {
    let choice: VoteChoice
    var stacked = false
    var isCurrent = false
    var isInked = false

    /// 15.5 pt on the `button` role's 16 pt curve.
    static let wordScale: CGFloat = 15.5 / 16

    var body: some View {
        VStack(spacing: 2) {
            if stacked {
                VStack(spacing: 3) { box; word }
            } else {
                HStack(spacing: 7) { box; word }
            }
            if isCurrent {
                Text(BillVoteBarModel.currentVoteLine)
                    .textRole(.caption)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }

    private var box: some View {
        BallotBox(choice: choice, fill: isInked ? .inked : .empty)
    }

    private var word: some View {
        Text(choice.title)
            .textRole(.button, scale: Self.wordScale)
            .lineLimit(1)
            .fixedSize()
    }
}

// MARK: - Strips

/// An opaque strip in the vote panel, or the same row in Your vote from xxxLarge up (spec 3.10, 3.10.1,
/// 3.10.2, 3.13): a `sheet` with a 1 pt `rule` (the refusal: a 1.5 pt `danger` rule, 2 pt with Increase
/// Contrast, as the ballot's other rings, spec 2.9, 7.6). In the panel its top corners are concentric (20 pt)
/// and its bottom ones 8 pt; in Your vote it is a 16 pt slip.
///
/// - Caption: "This bill's summary changed. Vote again:" or "Checking your vote…" (`caption`, ink 2), id
///   `bill.vote.caption`.
/// - Changing: "Change your vote" (`caption`, ink 2) and Cancel (an ink text button, 44 pt target).
/// - Coach mark: its words (`caption`, ink) and Not now (an ink text button, 44 pt target); no hand symbol.
/// - Refusal: `exclamationmark.circle` in `danger` and the refusal's text (`caption`, ink), one element read
///   "Error: …", id `bill.vote.refusal`.
struct VoteStrip: View {
    enum Kind: Equatable {
        case caption(String)
        case changing
        case coachMark(String)
        case refusal(String)
    }

    enum Placement {
        /// At the top of the vote panel.
        case panel
        /// A row of Your vote.
        case page
    }

    let kind: Kind
    var placement: Placement = .panel
    var onCancel: () -> Void = {}
    var onDismissCoachMark: () -> Void = {}
    /// The refusal strip takes VoiceOver focus after a refusal (`.refusal`).
    var focus: AccessibilityFocusState<VoteFocusTarget?>.Binding? = nil

    static let refusalRuleWidth: CGFloat = 1.5
    static let refusalRuleWidthHighContrast: CGFloat = 2
    /// The bottom corners of a strip in the panel.
    static let panelBottomRadius: CGFloat = 8

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorSchemeContrast) private var contrast

    private var shape: UnevenRoundedRectangle {
        switch placement {
        case .panel:
            let top = BillVoteBar.innerCornerRadius
            let bottom = Self.panelBottomRadius
            return UnevenRoundedRectangle(
                topLeadingRadius: top,
                bottomLeadingRadius: bottom,
                bottomTrailingRadius: bottom,
                topTrailingRadius: top,
                style: .continuous
            )
        case .page:
            let radius = BillboardStyle.Radius.slip
            return UnevenRoundedRectangle(
                topLeadingRadius: radius,
                bottomLeadingRadius: radius,
                bottomTrailingRadius: radius,
                topTrailingRadius: radius,
                style: .continuous
            )
        }
    }

    /// The refusal's `danger` rule: 1.5 pt, 2 pt with Increase Contrast.
    private var refusalRuleWidth: CGFloat {
        contrast == .increased ? Self.refusalRuleWidthHighContrast : Self.refusalRuleWidth
    }

    private var isRefusal: Bool {
        if case .refusal = kind { return true }
        return false
    }

    var body: some View {
        content
            .padding(.horizontal, placement == .panel ? 14 : BillboardStyle.Space.m)
            .padding(.vertical, placement == .panel ? 9 : 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(BillboardColors.cardBackground))
            .overlay(
                shape.strokeBorder(
                    isRefusal ? BillboardColors.danger : BillboardColors.separator,
                    lineWidth: isRefusal ? refusalRuleWidth : 1
                )
            )
    }

    @ViewBuilder
    private var content: some View {
        switch kind {
        case .caption(let text):
            Text(text)
                .textRole(.caption)
                .foregroundStyle(BillboardColors.secondaryText)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(BillVoteBarModel.captionIdentifier)
        case .changing:
            HStack(spacing: 10) {
                Text(BillVoteBarModel.changingCaption)
                    .textRole(.caption)
                    .foregroundStyle(BillboardColors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: BillboardStyle.Space.xs)
                textButton(BillVoteBarModel.cancelTitle, identifier: BillVoteBarModel.cancelIdentifier, action: onCancel)
            }
        case .coachMark(let text):
            Group {
                // The words wrap beside Not now; at the accessibility sizes Not now goes under them.
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: BillboardStyle.Space.xs) {
                        coachMarkText(text)
                        coachMarkDismiss
                    }
                } else {
                    HStack(spacing: 10) {
                        coachMarkText(text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        coachMarkDismiss
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(BillVoteBarModel.coachMarkIdentifier)
        case .refusal(let text):
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Image(systemName: "exclamationmark.circle")
                    .textRole(.caption)
                    .foregroundStyle(BillboardColors.danger)
                Text(text)
                    .textRole(.caption)
                    .foregroundStyle(BillboardColors.primaryText)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(BillVoteBarModel.refusalAccessibilityLabel(text))
            .accessibilityIdentifier(BillVoteBarModel.refusalIdentifier)
            .accessibilityFocusTarget(focus, equals: .refusal)
        }
    }

    private func coachMarkText(_ text: String) -> some View {
        Text(text)
            .textRole(.caption)
            .foregroundStyle(BillboardColors.primaryText)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var coachMarkDismiss: some View {
        textButton(
            BillVoteBarModel.coachMarkDismissTitle,
            identifier: BillVoteBarModel.coachMarkDismissIdentifier,
            action: onDismissCoachMark
        )
    }

    /// An ink text button at the strip's text size, its 44 pt target reaching past the strip's edge rather
    /// than growing it.
    private func textButton(_ title: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .textRole(.caption)
                .fontWeight(.semibold)
                .lineLimit(1)
                .fixedSize()
        }
        .buttonStyle(BillboardButtonStyle(kind: .textButton))
        .accessibilityIdentifier(identifier)
    }
}

// MARK: - Panel capsule

/// Change, and the voted button at the accessibility sizes (spec 3.11): the panel-secondary capsule, an opaque
/// `sheet` with a 1 pt `controlRule` (2 pt with Increase Contrast) and an ink label in the `button` role, as tall
/// as the panel's other controls. Pressed, it scales to 0.98 (no haptic; a fade with Reduce Motion).
struct PanelCapsuleButtonStyle: ButtonStyle {
    var height: CGFloat = BillVoteBarModel.minimumControlHeight
    var fullWidth = false

    static let horizontalPadding: CGFloat = 18

    func makeBody(configuration: Configuration) -> some View {
        PanelCapsuleBody(label: configuration.label, height: height, fullWidth: fullWidth, isPressed: configuration.isPressed)
    }
}

private struct PanelCapsuleBody<Label: View>: View {
    let label: Label
    let height: CGFloat
    let fullWidth: Bool
    let isPressed: Bool

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shape = Capsule(style: .continuous)
        label
            .textRole(.button)
            .foregroundStyle(BillboardColors.interactive)
            .multilineTextAlignment(.center)
            .padding(.horizontal, PanelCapsuleButtonStyle.horizontalPadding)
            .padding(.vertical, BillVoteBarModel.controlLabelPadding)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: height)
            .fixedSize(horizontal: !fullWidth, vertical: false)
            .background(shape.fill(BillboardColors.cardBackground))
            .overlay(
                shape.strokeBorder(
                    BillboardColors.controlRule,
                    lineWidth: contrast == .increased
                        ? BillboardButtonChromeModifier.panelRuleWidthHighContrast
                        : BillboardButtonChromeModifier.panelRuleWidth
                )
            )
            .contentShape(shape)
            .modifier(CapsulePressEffect(isPressed: isPressed))
    }
}

// MARK: - Layout and focus helpers

/// Lays its children out in one row of equal widths and one height. Its ideal width is the widest child's
/// ideal width times the count plus spacing, so `ViewThatFits` falls back as soon as any one label would not
/// fit its equal share (the three vote buttons stay equal in size and weight). Its height is the tallest
/// child's ideal height, and every child is offered it (the ballot buttons fill it).
struct EqualWidthRow: Layout {
    var spacing: CGFloat = 8

    private func cellWidth(total: CGFloat, count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        return max(0, (total - spacing * CGFloat(count - 1)) / CGFloat(count))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let count = subviews.count
        let widest = subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        let required = widest * CGFloat(count) + spacing * CGFloat(count - 1)
        // Never report less than every child at its ideal width needs, so a container that compares
        // the reported width with the space it has (ViewThatFits) sees when the row does not fit.
        let width: CGFloat
        if let proposed = proposal.width, proposed.isFinite {
            width = max(proposed, required)
        } else {
            width = required
        }
        let cell = cellWidth(total: width, count: count)
        // Each child's own height at the cell's width: a child that fills the height offered (a ballot
        // button) reports its least height here, not the height around the row.
        let height = subviews
            .map { $0.sizeThatFits(ProposedViewSize(width: cell, height: nil)).height }
            .max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let cell = cellWidth(total: bounds.width, count: subviews.count)
        var x = bounds.minX
        for subview in subviews {
            subview.place(
                at: CGPoint(x: x, y: bounds.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: cell, height: bounds.height)
            )
            x += cell + spacing
        }
    }
}

/// The stamp and Change after a vote (spec 3.10 "BallotStamp" width): side by side, Change as wide as its label and
/// the stamp taking the rest, where the stamp's no-date form fits beside Change; else the stamp on its own row and
/// Change under it, both full width (and always so with `alwaysStacked`, xxxLarge). Subviews, in order: the stamp,
/// Change, and a hidden no-date stamp that only measures. Both forms place the same stamp view, unlike a
/// `ViewThatFits`, so the stamp can be matched with the inked button (`BillVoteBar.morphID`).
struct BallotVotedRow: Layout {
    var spacing: CGFloat = 8
    var alwaysStacked = false

    /// The stamp and Change side by side in `width` (nil: as wide as they want).
    private func isBeside(width: CGFloat?, subviews: Subviews) -> Bool {
        guard !alwaysStacked, subviews.count == 3 else { return false }
        guard let width, width.isFinite else { return true }
        let change = subviews[1].sizeThatFits(.unspecified).width
        let leastStamp = subviews[2].sizeThatFits(.unspecified).width
        return leastStamp + spacing + change <= width
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count >= 2 else { return .zero }
        let stamp = subviews[0]
        let change = subviews[1]
        if isBeside(width: proposal.width, subviews: subviews) {
            let changeSize = change.sizeThatFits(.unspecified)
            let width = proposal.width ?? (stamp.sizeThatFits(.unspecified).width + spacing + changeSize.width)
            let stampSize = stamp.sizeThatFits(ProposedViewSize(width: max(0, width - spacing - changeSize.width), height: nil))
            return CGSize(width: width, height: max(stampSize.height, changeSize.height))
        }
        let width = proposal.width ?? max(stamp.sizeThatFits(.unspecified).width, change.sizeThatFits(.unspecified).width)
        let row = ProposedViewSize(width: width, height: nil)
        let stampSize = stamp.sizeThatFits(row)
        let changeSize = change.sizeThatFits(row)
        // Never less than the stamp needs, so a stamp too wide for the panel shows (it never is: tested).
        return CGSize(width: max(width, stampSize.width, changeSize.width), height: stampSize.height + spacing + changeSize.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count >= 2 else { return }
        let stamp = subviews[0]
        let change = subviews[1]
        if isBeside(width: bounds.width, subviews: subviews) {
            let changeWidth = change.sizeThatFits(.unspecified).width
            stamp.place(
                at: bounds.origin,
                anchor: .topLeading,
                proposal: ProposedViewSize(width: max(0, bounds.width - spacing - changeWidth), height: bounds.height)
            )
            change.place(
                at: CGPoint(x: bounds.maxX - changeWidth, y: bounds.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: changeWidth, height: bounds.height)
            )
        } else {
            let row = ProposedViewSize(width: bounds.width, height: nil)
            let stampHeight = stamp.sizeThatFits(row).height
            stamp.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: stampHeight))
            change.place(
                at: CGPoint(x: bounds.minX, y: bounds.minY + stampHeight + spacing),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: bounds.width, height: change.sizeThatFits(row).height)
            )
        }
        for measure in subviews.dropFirst(2) {
            measure.place(at: bounds.origin, anchor: .topLeading, proposal: .zero)
        }
    }
}

extension View {
    /// `.accessibilityFocused(binding, equals: value)` when there is a binding; the view unchanged otherwise
    /// (`ImageRenderer` drops a view that carries `.accessibilityFocused`, so render tests pass none).
    func accessibilityFocusTarget<Value: Hashable>(
        _ binding: AccessibilityFocusState<Value?>.Binding?,
        equals value: Value
    ) -> some View {
        modifier(AccessibilityFocusTarget(binding: binding, value: value))
    }

    /// The ballot stamp's id (`bill.vote.summary`), its "Go to Results" action and its focus (spec 3.10.3).
    func ballotStampAccessibility(
        focus: AccessibilityFocusState<VoteFocusTarget?>.Binding?,
        onGoToResults: @escaping () -> Void
    ) -> some View {
        accessibilityIdentifier(BillVoteBarModel.summaryIdentifier)
            .accessibilityAction(named: BillVoteBarModel.goToResultsAction, onGoToResults)
            .accessibilityFocusTarget(focus, equals: .stamp)
    }
}

private struct AccessibilityFocusTarget<Value: Hashable>: ViewModifier {
    let binding: AccessibilityFocusState<Value?>.Binding?
    let value: Value

    func body(content: Content) -> some View {
        if let binding {
            content.accessibilityFocused(binding, equals: value)
        } else {
            content
        }
    }
}
