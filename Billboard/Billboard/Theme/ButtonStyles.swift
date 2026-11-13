//
//  ButtonStyles.swift
//  Billboard
//
//  Reusable button styles. Civic Record's motion and haptics budget (spec 5): presses give a
//  plain visual response and no haptic.
//

import SwiftUI
import UIKit

// MARK: - Haptic Feedback Helpers

enum HapticFeedback {
    static func light() {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
    }

    static func selection() {
        let generator = UISelectionFeedbackGenerator()
        generator.selectionChanged()
    }
}

// MARK: - Capsule press

/// What a pressed capsule does (Civic Record spec 3.16, 5.2), for the capsule kinds of
/// `BillboardButtonStyle` and the vote panel's capsules: it scales to 0.98 (`.snappy`, 0.15 s), with no
/// haptic. Reduce Motion takes the scale away, and the capsule fades to `RowButtonStyle.pressedOpacity`
/// instead (a fade is not motion), so a press still shows. Rows, links, tabs, text buttons and icon
/// buttons use `RowButtonStyle`.
enum CapsulePress {
    static let pressedScale: CGFloat = 0.98

    static func scale(isPressed: Bool, reduceMotion: Bool) -> CGFloat {
        isPressed && !reduceMotion ? pressedScale : 1
    }

    static func opacity(isPressed: Bool, reduceMotion: Bool) -> Double {
        isPressed && reduceMotion ? RowButtonStyle.pressedOpacity : 1
    }
}

/// Applies `CapsulePress` for the environment's Reduce Motion setting.
struct CapsulePressEffect: ViewModifier {
    let isPressed: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .scaleEffect(CapsulePress.scale(isPressed: isPressed, reduceMotion: reduceMotion))
            .opacity(CapsulePress.opacity(isPressed: isPressed, reduceMotion: reduceMotion))
            .animation(.snappy(duration: 0.15), value: isPressed)
    }
}

// MARK: - Row Button Style (rows, links, tabs)

/// Rows, links, tabs and `NavigationLink`s (Civic Record spec 3.16, 5.2): 0.6 opacity while
/// pressed, no scale, no haptic, the same with Reduce Motion. Pass `textOnly: true` for a control
/// that is only text: with Button Shapes on, its label is then underlined and outlined
/// (`ButtonShapeOutline`), since ink text otherwise differs from the text around it only by weight.
struct RowButtonStyle: ButtonStyle {
    static let pressedOpacity: Double = 0.6

    var textOnly = false

    func makeBody(configuration: Configuration) -> some View {
        RowButtonBody(configuration: configuration, textOnly: textOnly)
    }
}

private struct RowButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let textOnly: Bool

    @Environment(\.accessibilityShowButtonShapes) private var showsButtonShapes

    var body: some View {
        configuration.label
            .modifier(ButtonShapeOutline(isOn: textOnly && showsButtonShapes))
            .opacity(configuration.isPressed ? RowButtonStyle.pressedOpacity : 1)
    }
}

/// What Button Shapes adds to a text-only control (Civic Record spec 3.16): the label underlined,
/// and a 1 pt `controlRule` capsule behind it, 10 pt wider and 6 pt taller than the label. Capsule
/// buttons already have a shape and do not use it.
struct ButtonShapeOutline: ViewModifier {
    static let horizontalOutset: CGFloat = 5
    static let verticalOutset: CGFloat = 3

    let isOn: Bool

    func body(content: Content) -> some View {
        content
            .underline(isOn)
            .background {
                if isOn {
                    Capsule(style: .continuous)
                        .strokeBorder(BillboardColors.controlRule, lineWidth: 1)
                        .padding(.horizontal, -Self.horizontalOutset)
                        .padding(.vertical, -Self.verticalOutset)
                        .accessibilityHidden(true)
                }
            }
    }
}

// MARK: - Vote choice (spec D 2.1.4, 2.3.1)

/// A vote the user can cast: its word, symbol and colour. The colour is never shown without the
/// symbol and the word (WCAG 1.4.1).
nonisolated enum VoteChoice: String, CaseIterable, Identifiable, Hashable, Sendable {
    case yea
    case nay
    case abstain

    var id: String { rawValue }

    init(_ voteType: VoteType) {
        switch voteType {
        case .yea: self = .yea
        case .nay: self = .nay
        case .abstain: self = .abstain
        }
    }

    var voteType: VoteType {
        switch self {
        case .yea: return .yea
        case .nay: return .nay
        case .abstain: return .abstain
        }
    }

    /// "Yea", "Nay", "Abstain".
    var title: String {
        switch self {
        case .yea: return "Yea"
        case .nay: return "Nay"
        case .abstain: return "Abstain"
        }
    }

    /// SF Symbol shown with the colour: `checkmark`, `xmark`, `minus`.
    var symbolName: String {
        switch self {
        case .yea: return "checkmark"
        case .nay: return "xmark"
        case .abstain: return "minus"
        }
    }

    /// VoiceOver label of the vote button: "Vote Yea", "Vote Nay", "Abstain".
    var accessibilityLabel: String {
        switch self {
        case .yea: return "Vote Yea"
        case .nay: return "Vote Nay"
        case .abstain: return "Abstain"
        }
    }

    /// "You voted Yea", "You voted Nay", "You abstained".
    var confirmationMessage: String {
        switch self {
        case .yea: return "You voted Yea"
        case .nay: return "You voted Nay"
        case .abstain: return "You abstained"
        }
    }

    var uiColor: UIColor {
        switch self {
        case .yea: return BillboardUIColors.voteYea
        case .nay: return BillboardUIColors.voteNay
        case .abstain: return BillboardUIColors.voteAbstain
        }
    }

    /// `voteYea`, `voteNay` or `voteAbstain`.
    var color: Color {
        Color(uiColor: uiColor)
    }

    /// The palette token behind `color`, for contrast checks.
    var paletteToken: BillboardColorToken {
        switch self {
        case .yea: return BillboardPalette.voteYea
        case .nay: return BillboardPalette.voteNay
        case .abstain: return BillboardPalette.voteAbstain
        }
    }
}

// MARK: - Ballot buttons (Civic Record spec 3.10)

/// The ballot box around a vote's symbol (spec 3.10): a 16 pt square that scales with the text, `Radius.mark`
/// corners, a 1.25 pt rule and the symbol (`VoteChoice.symbolName`) at 10 pt bold inside. Decorative: the
/// word beside it carries the vote, so VoiceOver skips it.
///
/// - `.empty`: the rule and the symbol in the vote colour, on the button's fill.
/// - `.filled`: the ballot stamp's box, filled with the vote colour, the symbol in `onFill`.
/// - `.inked`: the box in a button that has just been tapped (filled with the vote colour itself): an
///   `onFill` box with the symbol in the vote colour.
struct BallotBox: View {
    enum Fill {
        case empty
        case filled
        case inked
    }

    let choice: VoteChoice
    var fill: Fill = .empty

    static let side: CGFloat = 16
    static let ruleWidth: CGFloat = 1.25
    /// The symbol's size as a share of the box: 10 pt in 16.
    static let symbolRatio: CGFloat = 10 / 16

    @ScaledMetric(relativeTo: .callout) private var side: CGFloat = BallotBox.side

    private var symbolColor: Color {
        fill == .filled ? BillboardColors.onFill : choice.color
    }

    private var ruleColor: Color {
        fill == .inked ? BillboardColors.onFill : choice.color
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: BillboardStyle.Radius.mark, style: .continuous)
        Image(systemName: choice.symbolName)
            .font(TextRole.Face.text.font(size: side * Self.symbolRatio, weight: .bold))
            .foregroundStyle(symbolColor)
            .frame(width: side, height: side)
            .background {
                switch fill {
                case .empty: Color.clear
                case .filled: shape.fill(choice.color)
                case .inked: shape.fill(BillboardColors.onFill)
                }
            }
            .overlay(shape.strokeBorder(ruleColor, lineWidth: Self.ruleWidth))
            .accessibilityHidden(true)
    }
}

/// A vote button in the panel (spec 3.10 "BallotButton", 5.1): an opaque `sheet` fill with the vote colour
/// at 7% (6% in dark mode), a 1.5 pt ring in the vote colour (2 pt with Increase Contrast) and a 20 pt
/// corner, concentric with the 30 pt panel's 10 pt padding. The label (`BallotButtonLabel`: the ballot box
/// and the word) is drawn in the vote colour. The three buttons share one height: at least the panel's
/// control height (`BillVoteBarModel.controlHeight(for:)`), and as tall as the row offers.
///
/// - `.current`, while changing: the current vote with a 2.5 pt ring (its label adds "Your vote").
/// - `.inked`, the tapped button for the moment before it becomes the stamp: the solid vote colour, the label in
///   `onFill`, and an inner 0.75 pt `onFill` rule at 70%, inset 3 pt (the stamp's double rule), drawn in over
///   120 ms (at once with Reduce Motion, or when not `animatesInk`).
///
/// Pressed, it scales to 0.965 (`.snappy`, 0.18 s; no scale with Reduce Motion). There is no haptic on press:
/// the bill page plays one rigid haptic when the vote is committed (spec 5.1). Disabled, it draws at 45%.
struct BallotButtonStyle: ButtonStyle {
    enum State: Equatable {
        case ready
        case current
        case inked
    }

    let choice: VoteChoice
    var state: State = .ready
    /// The panel's control height at the current text size.
    var height: CGFloat = BillVoteBarModel.minimumControlHeight
    /// Draw the inked button's inner rule in (a vote just tapped), rather than drawn already.
    var animatesInk = false

    /// The vote colour over the `sheet` fill: 7% in light mode, 6% in dark (every label keeps 4.5:1, T8).
    static func tintOpacity(dark: Bool) -> Double {
        dark ? 0.06 : 0.07
    }

    static let cornerRadius: CGFloat = 20
    static let ringWidth: CGFloat = 1.5
    static let ringWidthHighContrast: CGFloat = 2
    static let currentRingWidth: CGFloat = 2.5
    static let innerRuleInset: CGFloat = 3
    static let innerRuleWidth: CGFloat = 0.75
    static let innerRuleOpacity: Double = 0.7
    static let pressedScale: CGFloat = 0.965
    static let disabledOpacity: Double = 0.45

    func makeBody(configuration: Configuration) -> some View {
        BallotButtonBody(
            label: configuration.label,
            choice: choice,
            state: state,
            height: height,
            animatesInk: animatesInk,
            isPressed: configuration.isPressed
        )
    }
}

/// The drawing of `BallotButtonStyle`, separate so the render tests can draw each state.
struct BallotButtonBody<Label: View>: View {
    let label: Label
    let choice: VoteChoice
    var state: BallotButtonStyle.State = .ready
    var height: CGFloat = BillVoteBarModel.minimumControlHeight
    var animatesInk = false
    var isPressed = false

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var ringWidth: CGFloat {
        if state == .current { return BallotButtonStyle.currentRingWidth }
        return contrast == .increased ? BallotButtonStyle.ringWidthHighContrast : BallotButtonStyle.ringWidth
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: BallotButtonStyle.cornerRadius, style: .continuous)
        let tint = BallotButtonStyle.tintOpacity(dark: colorScheme == .dark)
        label
            .foregroundStyle(state == .inked ? BillboardColors.onFill : choice.color)
            .multilineTextAlignment(.center)
            .padding(.horizontal, BillboardStyle.Space.s)
            .padding(.vertical, BillVoteBarModel.controlLabelPadding)
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: .infinity)
            .background {
                if state == .inked {
                    shape.fill(choice.color)
                } else {
                    ZStack {
                        shape.fill(BillboardColors.cardBackground)
                        shape.fill(choice.color.opacity(tint))
                    }
                }
            }
            .overlay(shape.strokeBorder(choice.color, lineWidth: ringWidth))
            .overlay {
                if state == .inked {
                    BallotInkRule(animates: animatesInk && !reduceMotion)
                }
            }
            .contentShape(shape)
            .opacity(isEnabled ? 1 : BallotButtonStyle.disabledOpacity)
            .scaleEffect(isPressed && !reduceMotion ? BallotButtonStyle.pressedScale : 1)
            .animation(.snappy(duration: 0.18), value: isPressed)
    }
}

/// The inked button's inner rule: 0.75 pt of `onFill` at 70%, inset 3 pt, drawn in once (trim 0 to 1) when
/// `animates`, else drawn already.
private struct BallotInkRule: View {
    let animates: Bool

    @State private var progress: CGFloat

    init(animates: Bool) {
        self.animates = animates
        _progress = State(initialValue: animates ? 0 : 1)
    }

    var body: some View {
        let inset = BallotButtonStyle.innerRuleInset + BallotButtonStyle.innerRuleWidth / 2
        RoundedRectangle(cornerRadius: BallotButtonStyle.cornerRadius, style: .continuous)
            .inset(by: inset)
            .trim(from: 0, to: progress)
            .stroke(BillboardColors.onFill.opacity(BallotButtonStyle.innerRuleOpacity), lineWidth: BallotButtonStyle.innerRuleWidth)
            .accessibilityHidden(true)
            .onAppear {
                guard progress < 1 else { return }
                withAnimation(BallotMoment.ink) { progress = 1 }
            }
    }
}

// MARK: - Civic Record buttons (spec 3.16)

/// The button kinds of Civic Record (spec 3.16). Links and buttons are navy ink, never teal.
enum BillboardButtonKind: CaseIterable {
    /// An `ink` capsule with the label in `onFill`, 50 pt tall, full width by default: Sign in,
    /// Create account, Find my district, Continue, Save, Done, Retry where it is the main action.
    case primary
    /// A capsule with a 1.25 pt white rule and a white label, 44 pt, for navy grounds (launch "Try again",
    /// spec 4.2).
    case primaryOnNavy
    /// A capsule with a 1.25 pt `ink` rule and an `ink` label, 44 pt: Choose topics, Unfollow,
    /// Put back, Try again on the sealed sheet.
    case secondary
    /// An opaque `sheet` capsule with a 1 pt `controlRule` and an `ink` label, 44 pt: Change in the
    /// vote panel, Reset on the map; anything that floats over glass or a picture.
    case panelSecondary
    /// An underlined `ink` label: Forgot password?, Resend code, Back to sign in, Add your address.
    case textLink
    /// An `ink` label with no underline: Change and Edit in section heads, Clear all, Not now, Undo.
    case textButton
    /// A text button in `danger`: Sign out in Settings.
    case destructive
    /// A `danger` capsule with the label in `onFill`: Delete account and data, I'm under 18.
    case destructiveFill

    /// Capsule kinds already have a shape; text kinds draw one under Button Shapes.
    var isCapsule: Bool {
        switch self {
        case .primary, .primaryOnNavy, .secondary, .panelSecondary, .destructiveFill: return true
        case .textLink, .textButton, .destructive: return false
        }
    }

    /// The capsule's height at the default text size. It grows with the label: the room above and
    /// below the label (`verticalPadding`) stays, so a primary button is about 85 pt at AX5 rather
    /// than 50 pt scaled to 138.
    var capsuleHeight: CGFloat {
        switch self {
        case .primary, .destructiveFill: return 50
        case .primaryOnNavy, .secondary, .panelSecondary, .textLink, .textButton, .destructive: return 44
        }
    }

    /// The room above and below a capsule's label.
    var verticalPadding: CGFloat {
        switch self {
        case .primary, .destructiveFill: return 14
        default: return 11
        }
    }

    /// The corner radius at the default size: half the height, so a capsule. The chrome scales it
    /// with the label, so a one-line button is a capsule at every text size.
    var cornerRadius: CGFloat {
        capsuleHeight / 2
    }

    /// Room either side of a capsule's label.
    var horizontalPadding: CGFloat {
        switch self {
        case .primary, .primaryOnNavy, .destructiveFill: return 22
        default: return 16
        }
    }

    /// Primary and destructive capsules span the width unless told not to.
    var expandsByDefault: Bool {
        self == .primary || self == .destructiveFill
    }

    /// What a loading spinner is drawn in on this kind.
    var progressTint: Color {
        switch self {
        case .primary, .destructiveFill: return BillboardColors.onFill
        case .primaryOnNavy: return BillboardColors.textOnNavy
        case .destructive: return BillboardColors.danger
        case .secondary, .panelSecondary, .textLink, .textButton: return BillboardColors.interactive
        }
    }
}

/// A Civic Record button (spec 3.16) for any label: the kind's chrome, its height (growing with the
/// label at larger text sizes), and its press: capsules scale to 0.98 (with Reduce Motion they fade to
/// 0.6 instead, `CapsulePress`), text buttons and links fade to 0.6. No haptic. Text buttons and links
/// honour Button Shapes (`ButtonShapeOutline`).
struct BillboardButtonStyle: ButtonStyle {
    var kind: BillboardButtonKind = .primary
    /// Whether a capsule spans the width; nil takes the kind's default.
    var fullWidth: Bool? = nil
    /// A taller floor for the capsule than the kind's height (R2 call sites that asked for one).
    var minHeight: CGFloat? = nil
    /// Extra room either side of a capsule's label beyond the kind's.
    var extraHorizontalPadding: CGFloat = 0
    /// Draws the enabled chrome while the button is disabled: a loading button takes no taps but keeps
    /// its `ink` capsule, so its `onFill` spinner and loading title stay readable (spec 3.16).
    var drawsAsEnabled = false

    func makeBody(configuration: Configuration) -> some View {
        BillboardButtonBody(
            label: configuration.label,
            kind: kind,
            fullWidth: fullWidth,
            minHeight: minHeight,
            extraHorizontalPadding: extraHorizontalPadding,
            isPressed: configuration.isPressed,
            drawsAsEnabled: drawsAsEnabled
        )
    }
}

/// The drawing of `BillboardButtonStyle`, separate so the render tests can draw the pressed state.
struct BillboardButtonBody<Label: View>: View {
    let label: Label
    let kind: BillboardButtonKind
    var fullWidth: Bool? = nil
    var minHeight: CGFloat? = nil
    var extraHorizontalPadding: CGFloat = 0
    var isPressed = false
    var drawsAsEnabled = false

    @Environment(\.isEnabled) private var environmentIsEnabled

    init(
        label: Label,
        kind: BillboardButtonKind,
        fullWidth: Bool? = nil,
        minHeight: CGFloat? = nil,
        extraHorizontalPadding: CGFloat = 0,
        isPressed: Bool = false,
        drawsAsEnabled: Bool = false
    ) {
        self.label = label
        self.kind = kind
        self.fullWidth = fullWidth
        self.minHeight = minHeight
        self.extraHorizontalPadding = extraHorizontalPadding
        self.isPressed = isPressed
        self.drawsAsEnabled = drawsAsEnabled
    }

    /// Whether the chrome is drawn enabled.
    private var isEnabled: Bool {
        environmentIsEnabled || drawsAsEnabled
    }

    var body: some View {
        if kind.isCapsule {
            label
                .textRole(.button)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, max(kind.horizontalPadding, extraHorizontalPadding))
                .padding(.vertical, kind.verticalPadding)
                .frame(
                    maxWidth: (fullWidth ?? kind.expandsByDefault) ? .infinity : nil,
                    minHeight: max(kind.capsuleHeight, minHeight ?? 0)
                )
                .modifier(BillboardButtonChromeModifier(kind: kind, isEnabled: isEnabled))
                .modifier(CapsulePressEffect(isPressed: isPressed))
        } else {
            label
                .textRole(.button)
                .multilineTextAlignment(.leading)
                .modifier(BillboardButtonChromeModifier(kind: kind, isEnabled: isEnabled))
                .opacity(isPressed ? RowButtonStyle.pressedOpacity : 1)
                .billboardMinimumHitTarget()
        }
    }
}

/// The colours and shape of each button kind (spec 3.16), without size or press:
///
/// - Primary: `ink` capsule, `onFill` label; disabled, a `well` capsule with an `ink3` label (still
///   readable, 5.12:1 light and 5.97:1 dark).
/// - Primary on navy: 1.25 pt white rule, white label; disabled, white at 74%.
/// - Secondary: 1.25 pt `ink` rule, `ink` label; disabled, `ink3`.
/// - Panel secondary: opaque `sheet` capsule, 1 pt `controlRule` (2 pt with Increase Contrast),
///   `ink` label.
/// - Destructive fill: `danger` capsule, `onFill` label; disabled like primary.
/// - Text link, text button, destructive: the label in `ink` (or `danger`), underlined for links;
///   `ink3` when disabled. With Button Shapes on, each is underlined and outlined
///   (`ButtonShapeOutline`), since ink text otherwise differs from the text around it only by weight.
struct BillboardButtonChromeModifier: ViewModifier {
    var kind: BillboardButtonKind = .primary
    let isEnabled: Bool

    static let secondaryRuleWidth: CGFloat = 1.25
    static let panelRuleWidth: CGFloat = 1
    static let panelRuleWidthHighContrast: CGFloat = 2

    @Environment(\.accessibilityShowButtonShapes) private var showsButtonShapes
    @Environment(\.colorSchemeContrast) private var contrast
    /// Scaled like the label, so a one-line button stays a capsule at every text size; a label that
    /// wraps gets a rounded shape no rounder than a one-line capsule.
    @ScaledMetric private var cornerRadius: CGFloat

    init(kind: BillboardButtonKind = .primary, isEnabled: Bool) {
        self.kind = kind
        self.isEnabled = isEnabled
        _cornerRadius = ScaledMetric(wrappedValue: kind.cornerRadius, relativeTo: .callout)
    }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        switch kind {
        case .primary, .destructiveFill:
            content
                .foregroundStyle(isEnabled ? BillboardColors.onFill : BillboardColors.dimText)
                .background(shape.fill(isEnabled ? fillColor : BillboardColors.secondaryBackground))
                .contentShape(shape)
        case .primaryOnNavy:
            let color = isEnabled ? BillboardColors.textOnNavy : BillboardColors.textOnNavyDim
            content
                .foregroundStyle(color)
                .overlay(shape.strokeBorder(color, lineWidth: Self.secondaryRuleWidth))
                .contentShape(shape)
        case .secondary:
            let color = isEnabled ? BillboardColors.interactive : BillboardColors.dimText
            content
                .foregroundStyle(color)
                .overlay(shape.strokeBorder(color, lineWidth: Self.secondaryRuleWidth))
                .contentShape(shape)
        case .panelSecondary:
            content
                .foregroundStyle(isEnabled ? BillboardColors.interactive : BillboardColors.dimText)
                .background(shape.fill(BillboardColors.cardBackground))
                .overlay(
                    shape.strokeBorder(
                        BillboardColors.controlRule,
                        lineWidth: contrast == .increased ? Self.panelRuleWidthHighContrast : Self.panelRuleWidth
                    )
                )
                .contentShape(shape)
        case .textLink, .textButton, .destructive:
            content
                .foregroundStyle(isEnabled ? textColor : BillboardColors.dimText)
                // Links are always underlined; Button Shapes underlines text buttons too.
                .underline(kind == .textLink || showsButtonShapes)
                .modifier(ButtonShapeOutline(isOn: showsButtonShapes))
        }
    }

    private var fillColor: Color {
        kind == .destructiveFill ? BillboardColors.danger : BillboardColors.interactive
    }

    private var textColor: Color {
        kind == .destructive ? BillboardColors.danger : BillboardColors.interactive
    }
}
