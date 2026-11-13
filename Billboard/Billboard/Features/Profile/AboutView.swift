import SwiftUI
import UIKit

/// What "About Billboard" shows (spec D 2.7): the version line and the two website links, built
/// from the bundle's Info.plist. Pure, for `AboutViewTests`.
struct AboutInfo: Equatable {
    /// Info.plist key of the public website (`https://billboard-project.com`), set by D0.
    static let websiteBaseURLKey = "WEBSITE_BASE_URL"
    static let roadmapPath = "roadmap.html"
    static let privacyPath = "privacy.html"

    /// Legal-facing: the project confirms this wording (spec D 7.4). The sources are the backend's:
    /// bills from the Congress.gov API and GovInfo; House roll calls from the Congress.gov API and
    /// Senate roll calls from senate.gov. The app shows no headlines: the priority resolver's
    /// Bedrock model reads news headlines (Google News search of AP, Reuters and NPR), picks the
    /// "In the news" bills and writes the reason shown under the chip, hence "chosen with AI".
    static let disclaimer = "Billboard is an independent app and is not affiliated with Congress or any government agency. Bill information comes from Congress.gov and GovInfo, roll-call votes from Congress.gov and the U.S. Senate, and In the news picks are chosen with AI from public news headlines."

    /// "Version 1.2 (45)".
    let versionLine: String
    /// "1.2 (45)", the version row's value; "1.2" without a build number.
    let versionNumber: String
    /// The public roadmap, or nil when the website key is missing or not an https URL.
    let roadmapURL: URL?
    /// The privacy policy, or nil when the website key is missing or not an https URL.
    let privacyURL: URL?

    init(infoDictionary: [String: Any]?) {
        let shortVersion = (infoDictionary?["CFBundleShortVersionString"] as? String).trimmedNonEmpty
        let build = (infoDictionary?["CFBundleVersion"] as? String).trimmedNonEmpty
        versionLine = Self.versionLine(shortVersion: shortVersion, build: build)
        versionNumber = Self.versionNumber(shortVersion: shortVersion, build: build)

        let base = Self.websiteBaseURL(from: infoDictionary?[Self.websiteBaseURLKey] as? String)
        roadmapURL = base.map { Self.page(Self.roadmapPath, on: $0) }
        privacyURL = base.map { Self.page(Self.privacyPath, on: $0) }
    }

    /// The running app's values.
    static var current: AboutInfo {
        AboutInfo(infoDictionary: Bundle.main.infoDictionary)
    }

    /// "Version 1.2 (45)", "Version 1.2" without a build number.
    static func versionLine(shortVersion: String?, build: String?) -> String {
        switch (shortVersion.trimmedNonEmpty, build.trimmedNonEmpty) {
        case let (version?, build?):
            return "Version \(version) (\(build))"
        case let (version?, nil):
            return "Version \(version)"
        case let (nil, build?):
            return "Build \(build)"
        case (nil, nil):
            return "Version not available"
        }
    }

    /// The version row's value: "1.2 (45)", "1.2" without a build number, "Build 45" without a version, "Not
    /// available" without either. Read from the bundle, never typed.
    static func versionNumber(shortVersion: String?, build: String?) -> String {
        switch (shortVersion.trimmedNonEmpty, build.trimmedNonEmpty) {
        case let (version?, build?):
            return "\(version) (\(build))"
        case let (version?, nil):
            return version
        case let (nil, build?):
            return "Build \(build)"
        case (nil, nil):
            return "Not available"
        }
    }

    /// The website's base URL: an absolute https URL with a host, else nil (an unset build
    /// variable such as `$(WEBSITE_BASE_URL)` or a typo hides the links instead of opening junk).
    static func websiteBaseURL(from raw: String?) -> URL? {
        guard let raw = raw.trimmedNonEmpty,
              let url = URL(string: raw),
              url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty,
              url.query == nil
        else { return nil }
        return url
    }

    private static func page(_ path: String, on base: URL) -> URL {
        base.appendingPathComponent(path)
    }
}

/// "About Billboard" (spec D 2.7; Civic Record spec 4.70, frame 16), from Settings, as a settings list on
/// paper under the system glass bar with the system back button: "Billboard" and the version (in the docket
/// face, read from the bundle), the public roadmap and the privacy policy in ink with a trailing
/// `arrow.up.right` (both open in Safari), Contact us (a new email to `ContactUs.address`, UX-39), and the
/// disclaimer, word for word. No row symbols.
struct AboutView: View {
    let info: AboutInfo

    init(info: AboutInfo = .current) {
        self.info = info
    }

    var body: some View {
        List {
            Section {
                SettingsRowText("Billboard")
                    .accessibilityAddTraits(.isHeader)

                HStack(alignment: .firstTextBaseline, spacing: BillboardStyle.Space.m) {
                    SettingsRowText("Version", color: BillboardColors.secondaryText)
                    Spacer(minLength: BillboardStyle.Space.s)
                    Text(info.versionNumber)
                        .textRole(.docket)
                        .foregroundStyle(BillboardColors.secondaryText)
                        .multilineTextAlignment(.trailing)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(info.versionLine)
                .accessibilityIdentifier("about.version")
            }
            .recordListRows()

            if info.roadmapURL != nil || info.privacyURL != nil {
                Section {
                    if let roadmapURL = info.roadmapURL {
                        AboutLinkRow(title: "Roadmap", destination: roadmapURL)
                            .accessibilityIdentifier("about.roadmap")
                    }
                    if let privacyURL = info.privacyURL {
                        AboutLinkRow(title: "Privacy policy", destination: privacyURL)
                            .accessibilityIdentifier("about.privacy")
                    }
                } footer: {
                    RecordListFooter("Opens in Safari.")
                }
                .recordListRows()
            }

            // UX-39: the one contact address, also for stranded sign-ups and data requests. The footer shows the
            // address for anyone without Mail.
            Section {
                ContactUsButton {
                    AboutRowLabel(title: ContactUs.title)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("about.contactUs")
                .contextMenu {
                    Button(ContactUs.copyAddressTitle) {
                        UIPasteboard.general.string = ContactUs.address
                    }
                }
            } footer: {
                RecordListFooter(ContactUs.footer)
            }
            .recordListRows()

            Section {
                // Legal-facing: word for word (`AboutInfo.disclaimer`).
                Text(AboutInfo.disclaimer)
                    .textRole(.caption)
                    .foregroundStyle(BillboardColors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("about.disclaimer")
            }
            .recordListRows()
        }
        .recordList()
        .navigationTitle("About Billboard")
        .navigationBarTitleDisplayMode(.inline)
        .glassNavigationBar()
        .accessibilityIdentifier("about.screen")
    }
}

/// A website link row (spec 4.70): the title in ink and a trailing `arrow.up.right` that says it leaves the
/// app. No leading symbol.
private struct AboutLinkRow: View {
    let title: String
    let destination: URL

    var body: some View {
        Link(destination: destination) {
            AboutRowLabel(title: title)
        }
        .accessibilityHint("Opens in Safari")
        .accessibilityAddTraits(.isLink)
    }
}

/// An About row that leaves the app (spec 4.70): the title in ink and a trailing `arrow.up.right`. The website
/// links and Contact us (which opens the email app) share it.
private struct AboutRowLabel: View {
    let title: String

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: BillboardStyle.Space.m) {
            SettingsRowText(title, color: BillboardColors.interactive)
            Spacer(minLength: BillboardStyle.Space.s)
            Image(systemName: "arrow.up.right")
                .font(TextRole.Face.text.font(size: TextRole.caption.scaledSize(for: dynamicTypeSize), weight: .semibold))
                .foregroundStyle(BillboardColors.interactive)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
    }
}

#Preview("About") {
    NavigationStack {
        AboutView(
            info: AboutInfo(infoDictionary: [
                "CFBundleShortVersionString": "1.2",
                "CFBundleVersion": "45",
                AboutInfo.websiteBaseURLKey: "https://billboard-project.com"
            ])
        )
    }
}
