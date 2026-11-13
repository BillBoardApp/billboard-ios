import MessageUI
import SwiftUI
import UIKit

/// The one way to reach Billboard (UX-39, feature review N7), and the one mail helper: About's "Contact us" row,
/// every message that used to say "Contact support" (the sign-in step Billboard can't finish, the startup failure
/// screen), and the bill page's Report a problem (`ReportProblem`, UX-37), which writes to the same address with
/// its own subject. One address, one way to open a new email, and one fallback alert (`emailFallbackAlert`) for
/// when Mail isn't set up or no app opens the address. The privacy policy names the same address for data
/// requests.
enum ContactUs {
    nonisolated static let address = "contact@billboard-project.com"
    nonisolated static let mailURL = URL(string: "mailto:\(address)")!

    static let title = "Contact us"
    /// About's footer under the row: what to write about, and the address for anyone without Mail.
    static let footer = "Questions, a sign-in problem or a request about your data: email contact@billboard-project.com."
    static let accessibilityHint = "Opens your email app"

    /// RFC 3986's unreserved characters: everything else in a subject or body is percent-encoded (a "&" or "=" in
    /// a bill's title would otherwise end the field, and a "+" would read as a space).
    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// `mailto:contact@billboard-project.com?subject=…&body=…`, the fields percent-encoded whole.
    static func mailURL(subject: String, body: String? = nil) -> URL {
        func encoded(_ text: String) -> String {
            text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
        }
        var fields = ["subject=" + encoded(subject)]
        if let body {
            fields.append("body=" + encoded(body))
        }
        return URL(string: "mailto:\(address)?" + fields.joined(separator: "&")) ?? mailURL
    }

    /// Why the address is shown instead of a new email.
    enum Fallback: Equatable, Identifiable {
        /// Mail has no account on this iPhone. Another email app may still take the address.
        case mailNotSetUp
        /// iOS opened no app for the address.
        case couldNotOpen

        var id: Self { self }

        /// Contact us's words: "Mail isn't set up on this iPhone. Write to contact@billboard-project.com from any
        /// email app."
        var message: String { message(about: nil) }

        /// The words with what to write about at the end: Report a problem's "… from any email app about H.R.
        /// 1234." (`topic` "about H.R. 1234"); nil ends the sentence at the address.
        func message(about topic: String?) -> String {
            let end = topic.map { " \($0)." } ?? "."
            switch self {
            case .mailNotSetUp:
                return "Mail isn't set up on this iPhone. Write to \(ContactUs.address) from any email app" + end
            case .couldNotOpen:
                return "Billboard couldn't open an email app. Write to \(ContactUs.address)" + end
            }
        }

        /// "Open email app" tries the address anyway: a default email app other than Mail can take it.
        var offersEmailApp: Bool { self == .mailNotSetUp }
    }

    static let fallbackTitle = "Email us"
    static let copyAddressTitle = "Copy address"
    static let openEmailAppTitle = "Open email app"

    /// What a tap does first: a new email when Mail can send one, else the address (Mail isn't set up).
    static func firstFallback(canSendMail: Bool) -> Fallback? {
        canSendMail ? nil : .mailNotSetUp
    }

    /// Opens `url` (a new email to the address), or calls `showFallback` when Mail isn't set up or nothing
    /// opened it.
    /// - Parameter canSendMail: nil asks Mail (`MFMailComposeViewController.canSendMail()`).
    @MainActor
    static func open(
        _ url: URL = mailURL,
        canSendMail: Bool? = nil,
        openURL: OpenURLAction,
        showFallback: @escaping (Fallback) -> Void
    ) {
        if let fallback = firstFallback(canSendMail: canSendMail ?? MFMailComposeViewController.canSendMail()) {
            showFallback(fallback)
            return
        }
        openURL(url) { accepted in
            if !accepted { showFallback(.couldNotOpen) }
        }
    }
}

/// A button that opens a new email to `ContactUs.address`, with the address and Copy when Mail isn't set up or
/// no app opens it. The caller styles it.
struct ContactUsButton<Label: View>: View {
    @ViewBuilder let label: () -> Label

    @Environment(\.openURL) private var openURL
    @State private var fallback: ContactUs.Fallback?

    var body: some View {
        Button {
            ContactUs.open(openURL: openURL) { fallback = $0 }
        } label: {
            label()
        }
        .accessibilityHint(ContactUs.accessibilityHint)
        .emailFallbackAlert($fallback, title: ContactUs.fallbackTitle, mailURL: ContactUs.mailURL)
    }
}

/// The one fallback alert: the address, Copy address, "Open email app" when Mail isn't set up (it opens `mailURL`,
/// which another default email app can take), and Cancel.
private struct EmailFallbackAlert: ViewModifier {
    @Binding var fallback: ContactUs.Fallback?
    let title: String
    let mailURL: URL
    let topic: String?

    @Environment(\.openURL) private var openURL

    func body(content: Content) -> some View {
        content
            .alert(title, isPresented: isShowing, presenting: fallback) { reason in
                Button(ContactUs.copyAddressTitle) {
                    UIPasteboard.general.string = ContactUs.address
                }
                if reason.offersEmailApp {
                    Button(ContactUs.openEmailAppTitle) {
                        openURL(mailURL) { accepted in
                            if !accepted { fallback = .couldNotOpen }
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { reason in
                Text(reason.message(about: topic))
            }
    }

    private var isShowing: Binding<Bool> {
        Binding(
            get: { fallback != nil },
            set: { if !$0 { fallback = nil } }
        )
    }
}

extension View {
    /// While `fallback` is set, the alert titled `title` with the address, Copy address, "Open email app" (when
    /// Mail isn't set up; it opens `mailURL`) and Cancel. `topic` ends its message ("about H.R. 1234").
    func emailFallbackAlert(_ fallback: Binding<ContactUs.Fallback?>, title: String, mailURL: URL, about topic: String? = nil) -> some View {
        modifier(EmailFallbackAlert(fallback: fallback, title: title, mailURL: mailURL, topic: topic))
    }
}
