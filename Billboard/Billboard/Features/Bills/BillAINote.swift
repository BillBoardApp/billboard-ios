import SwiftUI

/// The note under AI-written text on the bill page (UX-37, feature review N3): "Written with AI from the official
/// text · Report a problem". Why it matters, the Breakdown and the Summary are set in New York on the document, the
/// most official-looking text in the app, and the only other AI notes are at sign-up and in the tour, which a reader
/// arriving from a push or a share never sees. That approved line (Create account, tour step 1) is unchanged.
///
/// One quiet line in the `caption` role, `ink2`, with "Report a problem" in ink and underlined. The whole line is
/// one button, so VoiceOver reads it as one element ("Written with AI from the official text. Report a problem,
/// button"), Voice Control takes "Tap Report a problem", and a tap anywhere on it starts the report (`ReportProblem`).
struct BillAINote: View {
    let bill: ReportProblem.BillReference

    @Environment(\.openURL) private var openURL
    @State private var fallback: ContactUs.Fallback?

    static let text = "Written with AI from the official text"
    static let identifier = "bill.aiNote"

    /// The line as printed: no-break spaces keep the dot with the words before it and "Report a problem" whole,
    /// so the line breaks only after the dot.
    static let printedText = text + "\u{00A0}· "
    static let printedLink = ReportProblem.title.replacingOccurrences(of: " ", with: "\u{00A0}")

    /// "Written with AI from the official text. Report a problem".
    static let accessibilityLabel = SpokenSentences.sentence(text) + " " + ReportProblem.title

    /// What Voice Control takes: "Report a problem", the words drawn as the link, then the whole spoken name, as the
    /// app's other buttons with a short visible command do (Put back, Unfollow).
    static let inputLabels = [ReportProblem.title, accessibilityLabel]

    var body: some View {
        Button {
            ReportProblem.open(bill: bill, openURL: openURL) { fallback = $0 }
        } label: {
            Text("\(Self.printedText)\(Text(Self.printedLink).foregroundStyle(BillboardColors.interactive).underline())")
                .textRole(.caption)
                .foregroundStyle(BillboardColors.secondaryText)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .billboardMinimumHitTarget()
        }
        .buttonStyle(RowButtonStyle())
        .accessibilityLabel(Self.accessibilityLabel)
        .accessibilityInputLabels(Self.inputLabels)
        .accessibilityHint(ReportProblem.accessibilityHint)
        .accessibilityIdentifier(Self.identifier)
        // The one mail fallback (`ContactUs`): titled Report a problem, its message naming the bill, and "Open
        // email app" opening this bill's email.
        .emailFallbackAlert(
            $fallback,
            title: ReportProblem.title,
            mailURL: ReportProblem.mailURL(for: bill),
            about: ReportProblem.aboutBill(bill)
        )
    }
}

/// Report a problem with a bill's AI-written text (UX-37): a new email to Billboard whose subject names the bill's
/// number and title. When Mail isn't set up, or no app opens the address, the address is shown with Copy instead,
/// so the report works without Mail. The address, the email link, the way it opens and that fallback are
/// `ContactUs`'s, the one mail helper; this adds only what the email says.
enum ReportProblem {
    static let title = "Report a problem"
    static let accessibilityHint = "Opens an email to Billboard about this bill's text."

    /// What the email names: the bill's number ("H.R. 1234"), its title as the page shows it, and its ID (the
    /// text version the AI wrote from).
    struct BillReference: Equatable {
        let number: String?
        let title: String?
        let guid: String?

        init(number: String?, title: String?, guid: String?) {
            self.number = number?.trimmedNonEmpty
            self.title = title?.trimmedNonEmpty
            self.guid = guid?.trimmedNonEmpty
        }

        init(bill: Bill) {
            self.init(number: bill.officialBillNumber, title: bill.title.trimmedNonEmpty ?? bill.officialTitle, guid: bill.guid)
        }

        /// "H.R. 1234, Clean Energy Reporting Act", or whichever of the two there is.
        var name: String? {
            [number, title].compactMap { $0 }.joined(separator: ", ").trimmedNonEmpty
        }
    }

    /// "Report a problem: H.R. 1234, Clean Energy Reporting Act".
    static func subject(for bill: BillReference) -> String {
        guard let name = bill.name else { return title }
        return "\(title): \(name)"
    }

    /// "Bill ID: BILLS-119hr1234ih" and an empty line to write under, or nothing without an ID.
    static func body(for bill: BillReference) -> String? {
        bill.guid.map { "Bill ID: \($0)\r\n\r\n" }
    }

    /// `mailto:contact@billboard-project.com?subject=…&body=…`.
    static func mailURL(for bill: BillReference) -> URL {
        ContactUs.mailURL(subject: subject(for: bill), body: body(for: bill))
    }

    /// How the fallback's message ends: "about H.R. 1234", or "and name the bill" when the bill has no number
    /// ("Write to contact@billboard-project.com from any email app about H.R. 1234.").
    static func aboutBill(_ bill: BillReference) -> String {
        bill.number.map { "about \($0)" } ?? "and name the bill"
    }

    /// Opens a new email about `bill`, or calls `showFallback` when Mail isn't set up or nothing opened it.
    /// - Parameter canSendMail: nil asks Mail.
    @MainActor
    static func open(
        bill: BillReference,
        canSendMail: Bool? = nil,
        openURL: OpenURLAction,
        showFallback: @escaping (ContactUs.Fallback) -> Void
    ) {
        ContactUs.open(mailURL(for: bill), canSendMail: canSendMail, openURL: openURL, showFallback: showFallback)
    }
}
