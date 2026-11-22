import SwiftUI

/// The Open-source licenses screen's words (APPF-32), approved with the open-source switch texts (decision 17,
/// 2026-11-08, D2), in US spelling as approved.
enum OpenSourceLicensesCopy {
    static let title = "Open-source licenses"
    static let intro = "Billboard is built with the open-source software below. Each part is used under the license shown, and its full text is here."
    static let includedSoftwareHeader = "Included software"
    static let mapDataHeader = "Map data"
    static let mapData = "State and district outlines: U.S. Census Bureau, 2024 cartographic boundary files. Public domain. The Census Bureau does not endorse Billboard."
    static let billboardHeader = "Billboard"
    static let apacheLicense = "Apache License 2.0"
    static let fontsFooter = "Text uses Apple's system fonts and SF Symbols, which are part of iOS."
    static let noticeHeading = "Notice"
    static let copyrightHeading = "Copyright"
    static let licenseHeading = "License"

    /// "Version 2.53.2", the package's pinned version.
    static func version(_ version: String) -> String {
        "Version \(version)"
    }
}

/// One line of a licence page, in reading order: a heading ("Notice", "Copyright", "License"), the name of a part
/// over its text, the licence and files a text comes from, or a paragraph. A flat list, so a long page (aws-crt-swift's
/// C libraries) is drawn lazily and VoiceOver moves through it paragraph by paragraph.
enum LicensePageBlock: Hashable {
    case heading(String)
    case part(String)
    /// The licence and its files ("Apache-2.0 · LICENSE"), and what VoiceOver reads for it.
    case source(text: String, spoken: String)
    case paragraph(String)

    /// A package's page (approved D2): its NOTICE files, then its copyright lines, then its licence texts. The parts'
    /// names go over their texts only when the page has texts from more than one part.
    static func page(for component: OpenSourceLicenses.Component, in licenses: OpenSourceLicenses) -> [LicensePageBlock] {
        let version = OpenSourceLicensesCopy.version(component.version)
        var blocks: [LicensePageBlock] = [
            .source(text: "\(version) · \(component.spdx)", spoken: "\(version), \(component.spokenLicenseName)")
        ]
        if !component.notices.isEmpty {
            blocks.append(.heading(OpenSourceLicensesCopy.noticeHeading))
            for notice in component.notices {
                if component.namesNoticeParts { blocks.append(.part(notice.part)) }
                blocks += OpenSourceLicenses.paragraphs(notice.text).map(LicensePageBlock.paragraph)
            }
        }
        if !component.copyrights.isEmpty {
            blocks.append(.heading(OpenSourceLicensesCopy.copyrightHeading))
            blocks += component.copyrights.map(LicensePageBlock.paragraph)
        }
        blocks.append(.heading(OpenSourceLicensesCopy.licenseHeading))
        for license in component.licenses {
            if component.namesLicenseParts {
                blocks.append(.part(license.parts.joined(separator: ", ")))
                blocks.append(.source(text: license.sourceLine, spoken: license.spokenSourceLine))
            }
            blocks += OpenSourceLicenses.paragraphs(licenses.text(of: license)).map(LicensePageBlock.paragraph)
        }
        return blocks
    }

    /// A licence text alone (Billboard's Apache License 2.0).
    static func page(forText text: String) -> [LicensePageBlock] {
        OpenSourceLicenses.paragraphs(text).map(LicensePageBlock.paragraph)
    }
}

/// "Open-source licenses" (APPF-32), from About Billboard: a settings list per Civic Record spec 3.25. The intro,
/// "Included software" with a row per linked package (its name, and its licence's SPDX id on the trailing side) that
/// opens the package's notices and licence texts, "Map data", "Billboard" (the copyright line read from the bundled
/// NOTICE and a row to the full Apache License 2.0) and the Apple fonts footer. Everything comes from the bundled
/// `OpenSourceLicenses.json`, generated from THIRD_PARTY_NOTICES.md.
struct OpenSourceLicensesView: View {
    let licenses: OpenSourceLicenses?

    init(licenses: OpenSourceLicenses? = .bundled) {
        self.licenses = licenses
    }

    var body: some View {
        List {
            Section {
                Text(OpenSourceLicensesCopy.intro)
                    .textRole(.body)
                    .foregroundStyle(BillboardColors.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("licenses.intro")
            }
            .recordListRows()

            if let licenses, !licenses.components.isEmpty {
                Section {
                    ForEach(licenses.components) { component in
                        NavigationLink {
                            LicensePage(title: component.name, blocks: LicensePageBlock.page(for: component, in: licenses))
                        } label: {
                            OpenSourceComponentRow(component: component)
                        }
                        .accessibilityIdentifier("licenses.component.\(component.name)")
                    }
                } header: {
                    RecordListHeader(OpenSourceLicensesCopy.includedSoftwareHeader)
                }
                .recordListRows()
            }

            Section {
                Text(OpenSourceLicensesCopy.mapData)
                    .textRole(.body)
                    .foregroundStyle(BillboardColors.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("licenses.mapData")
            } header: {
                RecordListHeader(OpenSourceLicensesCopy.mapDataHeader)
            }
            .recordListRows()

            if let licenses {
                Section {
                    Text(licenses.billboardStatement)
                        .textRole(.body)
                        .foregroundStyle(BillboardColors.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("licenses.billboard")

                    NavigationLink {
                        LicensePage(title: OpenSourceLicensesCopy.apacheLicense, blocks: LicensePageBlock.page(forText: licenses.billboardLicenseText))
                    } label: {
                        SettingsRowText(OpenSourceLicensesCopy.apacheLicense)
                    }
                    .accessibilityIdentifier("licenses.billboardLicense")
                } header: {
                    RecordListHeader(OpenSourceLicensesCopy.billboardHeader)
                } footer: {
                    RecordListFooter(OpenSourceLicensesCopy.fontsFooter)
                }
                .recordListRows()
            }
        }
        .recordList()
        .navigationTitle(OpenSourceLicensesCopy.title)
        .navigationBarTitleDisplayMode(.inline)
        .glassNavigationBar()
        .accessibilityIdentifier("licenses.screen")
    }
}

/// A package on the licenses list: its name in ink and its licence's SPDX id in `ink2` on the trailing side, or under
/// the name when both do not fit on one line (long ids, accessibility sizes). VoiceOver reads the licence's name:
/// "swift-protobuf, Apache License 2.0 with the Swift runtime library exception".
struct OpenSourceComponentRow: View {
    let component: OpenSourceLicenses.Component

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: BillboardStyle.Space.m) {
                name
                Spacer(minLength: BillboardStyle.Space.s)
                licence.multilineTextAlignment(.trailing)
            }
            VStack(alignment: .leading, spacing: BillboardStyle.Space.xs) {
                name
                licence
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(component.accessibilityLabel)
    }

    private var name: some View {
        SettingsRowText(component.name)
    }

    private var licence: some View {
        Text(component.spdx)
            .textRole(.caption)
            .foregroundStyle(BillboardColors.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A licence page (APPF-32): a package's notices, copyright lines and licence texts, or one licence text, on paper in
/// the 16 pt gutter. Each paragraph is its own text, drawn lazily, selectable, and one VoiceOver stop; the headings and
/// part names are headings for the rotor.
struct LicensePage: View {
    let title: String
    let blocks: [LicensePageBlock]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: BillboardStyle.Space.m) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    row(block)
                }
            }
            .padding(.horizontal, BillboardStyle.Space.l)
            .padding(.top, BillboardStyle.Space.l)
            .padding(.bottom, BillboardStyle.Space.xxl)
        }
        .billboardBackground()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .glassNavigationBar()
        .accessibilityIdentifier("licenses.page")
    }

    @ViewBuilder
    private func row(_ block: LicensePageBlock) -> some View {
        switch block {
        case .heading(let text):
            Text(text)
                .textRole(.heading)
                .foregroundStyle(BillboardColors.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, BillboardStyle.Space.m)
                .accessibilityAddTraits(.isHeader)
        case .part(let text):
            Text(text)
                .textRole(.name)
                .foregroundStyle(BillboardColors.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, BillboardStyle.Space.s)
                .accessibilityAddTraits(.isHeader)
        case let .source(text, spoken):
            Text(text)
                .textRole(.caption)
                .foregroundStyle(BillboardColors.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(spoken)
        case .paragraph(let text):
            Text(text)
                .textRole(.subheadline)
                .foregroundStyle(BillboardColors.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }
}

#Preview("Open-source licenses") {
    NavigationStack {
        OpenSourceLicensesView()
    }
}
