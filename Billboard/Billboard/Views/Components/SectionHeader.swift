import SwiftUI

/// The head of a section on a tab root, a list screen, Profile or the Weekly Brief detail (Civic
/// Record spec 3.5): a 2 pt ink rule across the gutter, 8 pt, then on one baseline the title in the
/// `heading` role and an optional trailing item. The trailing item is a counter in the `docket` role
/// ("3", "50 of 1,002", a district code such as "VA-11", which VoiceOver hears as "Virginia's 11th
/// district") or a text button such as "Clear all", "Change" or "Edit". At accessibility text sizes
/// the trailing item wraps under the title.
///
/// The title (with a counter) is one element with the header trait; a button is its own element.
struct SectionHeader: View {
    enum Trailing {
        case none
        /// A count or code in the docket face; `spoken` is what VoiceOver reads when the printed form
        /// is a code.
        case counter(String, spoken: String? = nil)
        /// A district code ("VA-11"), read in its spoken form.
        case district(String)
        /// An ink text button (spec 3.16), with Button Shapes support. `accessibilityLabel` says what it
        /// acts on when the word alone does not ("Clear all passed bills"); the visible word stays an
        /// input label for Voice Control.
        case button(String, accessibilityLabel: String? = nil, accessibilityIdentifier: String? = nil, action: () -> Void)
    }

    let title: String
    var trailing: Trailing = .none

    init(_ title: String, trailing: Trailing = .none) {
        self.title = title
        self.trailing = trailing
    }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: BillboardStyle.Space.s) {
            HeavyRule(width: 2)
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: BillboardStyle.Space.xs) {
                    titleText
                    trailingView
                }
                .modifier(HeaderElement(label: headerLabel, combines: combinesTrailing))
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    titleText
                    Spacer(minLength: 0)
                    trailingView
                }
                .modifier(HeaderElement(label: headerLabel, combines: combinesTrailing))
            }
        }
    }

    private var titleText: some View {
        Text(title)
            .textRole(.heading)
            .foregroundStyle(BillboardColors.primaryText)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private var trailingView: some View {
        switch trailing {
        case .none:
            EmptyView()
        case let .counter(text, _), let .district(text):
            Text(text)
                .textRole(.docket)
                .foregroundStyle(BillboardColors.dimText)
                .fixedSize(horizontal: false, vertical: true)
        case let .button(label, spokenLabel, identifier, action):
            Button(label, action: action)
                .buttonStyle(BillboardButtonStyle(kind: .textButton))
                .modifier(TrailingButtonAccessibility(word: label, spokenLabel: spokenLabel, identifier: identifier))
        }
    }

    /// The trailing button's spoken label (with the visible word as an input label) and identifier, each
    /// only when given.
    private struct TrailingButtonAccessibility: ViewModifier {
        let word: String
        let spokenLabel: String?
        let identifier: String?

        func body(content: Content) -> some View {
            let labelled = Group {
                if let spokenLabel {
                    content
                        .accessibilityLabel(spokenLabel)
                        .accessibilityInputLabels([word, spokenLabel])
                } else {
                    content
                }
            }
            if let identifier {
                labelled.accessibilityIdentifier(identifier)
            } else {
                labelled
            }
        }
    }

    /// A counter joins the title in one header element; a button stays its own element.
    private var combinesTrailing: Bool {
        switch trailing {
        case .counter, .district: return true
        case .none, .button: return false
        }
    }

    /// "Your representatives, Virginia's 11th district"; the title alone without a counter.
    var headerLabel: String {
        switch trailing {
        case let .counter(text, spoken): return "\(title), \(spoken ?? text)"
        case let .district(code): return "\(title), \(SpokenForm.districtOrCode(code))"
        case .none, .button: return title
        }
    }

    /// Makes the title and a counter one header element with `label`.
    private struct HeaderElement: ViewModifier {
        let label: String
        let combines: Bool

        func body(content: Content) -> some View {
            if combines {
                content
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(label)
                    .accessibilityAddTraits(.isHeader)
            } else {
                content.accessibilityElement(children: .contain)
            }
        }
    }
}

/// A section of a document screen, the bill page and the member page (spec 3.5): no box. A hairline
/// on top (left out for the first section after a `DoubleRule`), 16 pt, the title in the `heading`
/// role, 12 pt, the content, 24 pt, all inside the 20 pt document gutter. Replaces R2's
/// `DetailSection` box, flair bar and shadow.
struct RecordSection<Content: View>: View {
    let title: String?
    var showsRule: Bool
    @ViewBuilder let content: Content

    init(_ title: String?, showsRule: Bool = true, @ViewBuilder content: () -> Content) {
        self.title = title
        self.showsRule = showsRule
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsRule {
                HairlineRule()
            }
            VStack(alignment: .leading, spacing: BillboardStyle.Space.m) {
                if let title {
                    Text(title)
                        .textRole(.heading)
                        .foregroundStyle(BillboardColors.primaryText)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                }
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, BillboardStyle.Space.l)
            .padding(.bottom, 24)
        }
        .padding(.horizontal, BillboardStyle.Space.xl)
    }
}

#Preview("Section headers") {
    VStack(alignment: .leading, spacing: 24) {
        SectionHeader("Your representatives", trailing: .district("VA-11"))
        SectionHeader("Recent actions", trailing: .button("Clear all") {})
        SectionHeader("Topics you follow", trailing: .counter("3"))
    }
    .padding(16)
    .background(BillboardColors.background)
}
