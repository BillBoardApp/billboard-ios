import SwiftUI

/// The one pattern for every empty, error and caught-up state (Civic Record spec 3.20), replacing R2's
/// `ContentUnavailableView`s, gold triangles and the big teal check: a hairline, 16 pt, a stamp
/// (NOTHING YET, NOT FOUND, ALL CAUGHT UP or COULDN'T LOAD), the title in the `subheadline` role
/// (`titleRole`), the message in `body` `ink2`, and an optional action (a secondary capsule or a text
/// link). Copy stays R2's.
///
/// VoiceOver reads the stamp, title and message as one element; the action is its own.
struct RecordNotice: View {
    enum Kind: CaseIterable {
        case nothingYet
        case notFound
        case allCaughtUp
        case couldNotLoad

        var stamp: StatusStamp.Kind {
            switch self {
            case .nothingYet: return .nothingYet
            case .notFound: return .notFound
            case .allCaughtUp: return .allCaughtUp
            case .couldNotLoad: return .couldNotLoad
            }
        }
    }

    /// How the action is drawn.
    enum ActionStyle {
        case secondary
        case textLink
    }

    struct Action {
        let title: String
        var style: ActionStyle = .secondary
        var accessibilityIdentifier: String? = nil
        let perform: () -> Void
    }

    /// The title's role: `subheadline`, so an empty state reads as a note under its section head (`heading`,
    /// 22 pt) rather than a second head. At the `name` role (20 pt bold condensed) the NOTHING YET blocks
    /// shouted louder than the content (feature review N10).
    static let titleRole: TextRole = .subheadline

    let kind: Kind
    let title: String
    /// What VoiceOver reads in place of `title`, when the title prints a code that has a spoken form ("VA-11"
    /// read "Virginia's 11th district"); nil reads the title.
    var spokenTitle: String? = nil
    var message: String? = nil
    var action: Action? = nil

    init(_ kind: Kind, title: String, spokenTitle: String? = nil, message: String? = nil, action: Action? = nil) {
        self.kind = kind
        self.title = title
        self.spokenTitle = spokenTitle
        self.message = message
        self.action = action
    }

    /// "All caught up. You're all caught up. No bills left to vote on from the last week."
    var accessibilityText: String {
        SpokenSentences.join([kind.stamp.spokenWord, spokenTitle ?? title, message])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HairlineRule()
            VStack(alignment: .leading, spacing: BillboardStyle.Space.s) {
                VStack(alignment: .leading, spacing: BillboardStyle.Space.s) {
                    StatusStamp(kind.stamp)
                    Text(title)
                        .textRole(Self.titleRole)
                        .foregroundStyle(BillboardColors.primaryText)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if let message, !message.isEmpty {
                        Text(message)
                            .textRole(.body)
                            .foregroundStyle(BillboardColors.secondaryText)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityText)

                if let action {
                    actionButton(action)
                        .padding(.top, BillboardStyle.Space.xs)
                }
            }
            .padding(.top, BillboardStyle.Space.l)
            .padding(.bottom, BillboardStyle.Space.xs)
        }
    }

    @ViewBuilder
    private func actionButton(_ action: Action) -> some View {
        let button = Button(action.title, action: action.perform)
            .buttonStyle(BillboardButtonStyle(kind: action.style == .secondary ? .secondary : .textLink, fullWidth: false))
        if let identifier = action.accessibilityIdentifier {
            button.accessibilityIdentifier(identifier)
        } else {
            button
        }
    }
}

#Preview("Record notices") {
    VStack(alignment: .leading, spacing: 24) {
        RecordNotice(.allCaughtUp, title: "You're all caught up", message: "No bills left to vote on from the last week.")
        RecordNotice(
            .couldNotLoad,
            title: "Couldn't load your bills",
            message: "Can't reach Billboard right now. Check your connection and try again.",
            action: .init(title: "Try again") {}
        )
    }
    .padding(16)
    .background(BillboardColors.background)
}
