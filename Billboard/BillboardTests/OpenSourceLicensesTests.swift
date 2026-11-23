import SwiftUI
import UIKit
import XCTest
@testable import Billboard

/// The Open-source licenses screen (APPF-32): the bundled `OpenSourceLicenses.json` that
/// `scripts/generate-open-source-licenses.sh` writes from THIRD_PARTY_NOTICES.md decodes and holds every linked
/// package's notices and licence texts, Billboard's own copyright comes from the bundled NOTICE, the texts are split
/// into paragraphs without losing a word, and the list and a package's page are ink only and read by VoiceOver.
@MainActor
final class OpenSourceLicensesTests: XCTestCase {
    /// The packages the app links (THIRD_PARTY_NOTICES.md, "In the app"), in the screen's order.
    private let linked = [
        "amplify-swift", "aws-crt-swift", "aws-sdk-swift", "opentelemetry-swift", "smithy-swift", "swift-log", "swift-protobuf"
    ]

    private func bundled() throws -> OpenSourceLicenses {
        try XCTUnwrap(OpenSourceLicenses.bundled, "OpenSourceLicenses.json is in the app bundle and decodes")
    }

    private func component(_ name: String) throws -> OpenSourceLicenses.Component {
        try XCTUnwrap(bundled().components.first { $0.name == name }, name)
    }

    // MARK: - The bundled file

    func testTheBundledFileDecodesAndListsTheLinkedPackages() throws {
        let licenses = try bundled()
        XCTAssertEqual(licenses.formatVersion, OpenSourceLicenses.formatVersion)
        XCTAssertEqual(licenses.components.map(\.name), linked)
        for component in licenses.components {
            XCTAssertFalse(component.version.isEmpty, component.name)
            XCTAssertFalse(component.copyrights.isEmpty, "\(component.name) lists its copyright lines")
        }
    }

    func testEveryPackageHasItsFullLicenseTexts() throws {
        let licenses = try bundled()
        for component in licenses.components {
            XCTAssertFalse(component.licenses.isEmpty, component.name)
            for license in component.licenses {
                let text = licenses.text(of: license)
                XCTAssertGreaterThan(text.count, 400, "\(component.name) \(license.parts): the whole text, not a pointer to it")
                if license.spdx.hasPrefix("Apache-2.0") {
                    XCTAssertTrue(text.contains("Apache License"), "\(component.name) \(license.parts)")
                    XCTAssertTrue(text.contains("Version 2.0"), "\(component.name) \(license.parts)")
                    XCTAssertTrue(text.contains("TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION"), "\(component.name) \(license.parts)")
                }
            }
            // The package's own licence is listed under its own name.
            XCTAssertTrue(component.licenses.contains { $0.parts.contains(component.name) && $0.spdx == component.spdx }, component.name)
        }
        XCTAssertTrue(try component("swift-protobuf").licenses.contains { licenses.text(of: $0).contains("Runtime Library Exception") })
    }

    /// The packages that ship a NOTICE file show it whole (Apache-2.0 section 4(d)); aws-crt-swift also shows each
    /// bundled C library's.
    func testPackagesWithANoticeShowIt() throws {
        let licenses = try bundled()
        let withNotice: Set = ["amplify-swift", "aws-crt-swift", "aws-sdk-swift", "smithy-swift", "swift-log"]
        for component in licenses.components {
            XCTAssertEqual(!component.notices.isEmpty, withNotice.contains(component.name), component.name)
            for notice in component.notices {
                XCTAssertFalse(notice.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(component.name) \(notice.file)")
            }
        }
        let crt = try component("aws-crt-swift")
        XCTAssertEqual(
            crt.notices.map(\.part),
            ["aws-crt-swift", "aws-c-auth", "aws-c-cal", "aws-c-common", "aws-c-compression", "aws-c-event-stream", "aws-c-http", "aws-c-io", "aws-c-mqtt", "aws-c-sdkutils"]
        )
        XCTAssertTrue(crt.licenses.contains { $0.files.contains("aws-common-runtime/aws-c-common/THIRD-PARTY-LICENSES.txt") })
        XCTAssertTrue(try component("amplify-swift").licenses.contains { $0.parts == ["libtommath"] && $0.spdx == "Unlicense" })
        XCTAssertTrue(try component("opentelemetry-swift").copyrights.contains { $0.hasPrefix("Copyright 2016,") }, "DataCompression's own line")
        XCTAssertTrue(
            try component("amplify-swift").copyrights.contains("Modifications Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved."),
            "libtommath's sources' line, with a word before Copyright"
        )
    }

    /// Billboard's section reads its copyright line from the bundled NOTICE (approved D2), never typed, and shows the
    /// whole Apache License 2.0.
    func testBillboardsCopyrightComesFromItsNotice() throws {
        let licenses = try bundled()
        XCTAssertEqual(licenses.billboard.copyright, "Copyright 2025-2027 The Billboard Authors")
        XCTAssertTrue(licenses.billboard.notice.split(separator: "\n").map(String.init).contains(licenses.billboard.copyright))
        XCTAssertEqual(
            licenses.billboardStatement,
            "Copyright 2025-2027 The Billboard Authors. Licensed under the Apache License, Version 2.0. The Billboard name and logos are not covered by that license."
        )
        // The text keeps the file's own layout: the title is centred with spaces.
        let firstLine = licenses.billboardLicenseText.split(separator: "\n").first.map { $0.trimmingCharacters(in: .whitespaces) }
        XCTAssertEqual(firstLine, "Apache License")
        XCTAssertTrue(licenses.billboardLicenseText.contains("Version 2.0, January 2004"))
        XCTAssertTrue(licenses.billboardLicenseText.contains("APPENDIX: How to apply the Apache License to your work."))
    }

    func testAMissingOrStaleFileIsNotUsed() {
        XCTAssertNil(OpenSourceLicenses.decode(Data("not json".utf8)))
        XCTAssertNil(OpenSourceLicenses.decode(Data(#"{"formatVersion":2,"billboard":{"copyright":"","notice":"","license":""},"components":[],"texts":{}}"#.utf8)))
        XCTAssertNotNil(OpenSourceLicenses.decode(Data(#"{"formatVersion":1,"billboard":{"copyright":"","notice":"","license":""},"components":[],"texts":{}}"#.utf8)))
    }

    // MARK: - Words

    /// VoiceOver reads a licence's name, not its SPDX id (plan copy).
    func testLicensesAreSpokenByName() throws {
        let licenses = try bundled()
        XCTAssertEqual(try component("amplify-swift").accessibilityLabel, "amplify-swift, Apache License 2.0")
        XCTAssertEqual(
            try component("swift-protobuf").accessibilityLabel,
            "swift-protobuf, Apache License 2.0 with the Swift runtime library exception"
        )
        XCTAssertEqual(OpenSourceLicenses.spokenName(forSPDX: "MIT"), "MIT License")
        XCTAssertEqual(OpenSourceLicenses.spokenName(forSPDX: "GPL-9.9"), "GPL-9.9", "an unknown id is read as it is")
        for component in licenses.components {
            XCTAssertNotNil(OpenSourceLicenses.spokenNames[component.spdx], component.spdx)
            for license in component.licenses {
                XCTAssertNotNil(OpenSourceLicenses.spokenNames[license.spdx], "\(component.name): \(license.spdx)")
            }
        }
    }

    func testCopyIsTheApprovedText() {
        XCTAssertEqual(OpenSourceLicensesCopy.title, "Open-source licenses")
        XCTAssertEqual(
            OpenSourceLicensesCopy.intro,
            "Billboard is built with the open-source software below. Each part is used under the license shown, and its full text is here."
        )
        XCTAssertEqual(
            OpenSourceLicensesCopy.mapData,
            "State and district outlines: U.S. Census Bureau, 2024 cartographic boundary files. Public domain. The Census Bureau does not endorse Billboard."
        )
        XCTAssertEqual(OpenSourceLicensesCopy.fontsFooter, "Text uses Apple's system fonts and SF Symbols, which are part of iOS.")
        for text in [OpenSourceLicensesCopy.title, OpenSourceLicensesCopy.intro, OpenSourceLicensesCopy.mapData] {
            XCTAssertNil(text.range(of: "licence", options: .caseInsensitive), "US spelling, as approved: \(text)")
        }
    }

    // MARK: - Paragraphs

    /// Splitting a text into paragraphs reflows the lines wrapped at 80 columns and keeps every word in order.
    func testParagraphsKeepEveryWord() throws {
        let licenses = try bundled()
        var texts = Array(licenses.texts.values) + [licenses.billboard.notice]
        texts += licenses.components.flatMap { $0.notices.map(\.text) }
        func words(_ text: String) -> [Substring] {
            text.split(whereSeparator: { $0.isWhitespace })
        }
        for text in texts {
            let paragraphs = OpenSourceLicenses.paragraphs(text)
            XCTAssertFalse(paragraphs.isEmpty)
            XCTAssertEqual(words(paragraphs.joined(separator: " ")), words(text), String(text.prefix(60)))
            for paragraph in paragraphs {
                XCTAssertFalse(paragraph.contains("\n\n"), "a paragraph has no blank line")
                XCTAssertEqual(paragraph, paragraph.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }

    func testParagraphsReflowWrappedLinesAndKeepShortOnes() {
        let text = """
                                 Apache License
                           Version 2.0, January 2004

           1. Definitions.

              "License" shall mean the terms and conditions for use, reproduction,
              and distribution as defined by Sections 1 through 9 of this document.

        AWS C Auth
        Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
        SPDX-License-Identifier: Apache-2.0.

        Redistribution and use in source and binary forms, with or without
        modification, are permitted provided that the following conditions are met:
        1. Redistributions of source code must retain the above copyright notice, this
        list of conditions and the following disclaimer.
        """
        XCTAssertEqual(OpenSourceLicenses.paragraphs(text), [
            "Apache License\nVersion 2.0, January 2004",
            "1. Definitions.",
            "\"License\" shall mean the terms and conditions for use, reproduction, and distribution as defined by Sections 1 through 9 of this document.",
            "AWS C Auth\nCopyright Amazon.com, Inc. or its affiliates. All Rights Reserved.\nSPDX-License-Identifier: Apache-2.0.",
            "Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:\n1. Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer."
        ])
    }

    func testListItemsCopyrightLinesAndLinksStartTheirOwnLine() {
        for line in ["1. Definitions.", "10. Something", "2) Two", "(a) You must", "(iv) four", "* Redistributions", "- item",
                     "Copyright 2019 Amazon", "SPDX-License-Identifier: MIT", "https://example.org", "<https://example.org>", "====="] {
            XCTAssertTrue(OpenSourceLicenses.startsOwnLine(line), line)
        }
        for line in ["notice, this list of conditions", "2019 was a year", "(the \"Software\"), to deal", "100. Not a list"] {
            XCTAssertFalse(OpenSourceLicenses.startsOwnLine(line), line)
        }
    }

    // MARK: - A package's page

    /// A package's page has the headings Notice, Copyright and License (approved D2), in that order; the parts' names
    /// and files go over the texts only when there is more than one part.
    func testAPackagesPageIsNoticeThenCopyrightThenLicense() throws {
        let licenses = try bundled()
        func headings(_ blocks: [LicensePageBlock]) -> [String] {
            blocks.compactMap { if case .heading(let text) = $0 { return text } else { return nil } }
        }
        func parts(_ blocks: [LicensePageBlock]) -> [String] {
            blocks.compactMap { if case .part(let text) = $0 { return text } else { return nil } }
        }
        func sources(_ blocks: [LicensePageBlock]) -> [String] {
            blocks.compactMap { if case .source(let text, _) = $0 { return text } else { return nil } }
        }

        let log = LicensePageBlock.page(for: try component("swift-log"), in: licenses)
        XCTAssertEqual(headings(log), ["Notice", "Copyright", "License"])
        XCTAssertEqual(parts(log), [], "one part needs no name over its texts")
        XCTAssertEqual(sources(log), ["Version 1.8.0 · Apache-2.0"])
        XCTAssertEqual(log.first, .source(text: "Version 1.8.0 · Apache-2.0", spoken: "Version 1.8.0, Apache License 2.0"))

        let telemetry = LicensePageBlock.page(for: try component("opentelemetry-swift"), in: licenses)
        XCTAssertEqual(headings(telemetry), ["Copyright", "License"], "no NOTICE file, no Notice heading")

        let crt = LicensePageBlock.page(for: try component("aws-crt-swift"), in: licenses)
        XCTAssertEqual(headings(crt), ["Notice", "Copyright", "License"])
        XCTAssertTrue(parts(crt).contains("aws-c-auth"), "\(parts(crt))")
        XCTAssertTrue(sources(crt).contains("BSD-3-Clause · time.c"), "\(sources(crt))")
        XCTAssertTrue(sources(crt).contains("BSD-3-Clause AND MIT · THIRD-PARTY-LICENSES.txt"), "\(sources(crt))")
        XCTAssertTrue(crt.contains(.source(text: "BSD-3-Clause · time.c", spoken: "BSD 3-Clause License, time.c")))

        // Every paragraph of every text is on the page.
        let crtComponent = try component("aws-crt-swift")
        let paragraphs = Set(crt.compactMap { if case .paragraph(let text) = $0 { return text } else { return nil } })
        for license in crtComponent.licenses {
            XCTAssertTrue(OpenSourceLicenses.paragraphs(licenses.text(of: license)).allSatisfy(paragraphs.contains), "\(license.parts)")
        }
        for notice in crtComponent.notices {
            XCTAssertTrue(OpenSourceLicenses.paragraphs(notice.text).allSatisfy(paragraphs.contains), notice.part)
        }
    }

    // MARK: - VoiceOver

    /// The list reads each package as its name and its licence's name, and its sections in order.
    func testTheListReadsEachPackageWithItsLicenseName() throws {
        let licenses = try bundled()
        let host = AccessibilityTreeText.Host(NavigationStack { OpenSourceLicensesView(licenses: licenses) }, size: CGSize(width: 390, height: 2400), settle: 0.4)
        defer { host.close() }
        let text = host.text()
        XCTAssertTrue(text.contains(OpenSourceLicensesCopy.intro), text)
        for component in licenses.components {
            XCTAssertNotNil(host.frame(of: component.accessibilityLabel), "\(component.accessibilityLabel) in \(text)")
        }
        XCTAssertTrue(text.contains(OpenSourceLicensesCopy.mapData), text)
        XCTAssertTrue(text.contains(licenses.billboardStatement), text)
        XCTAssertTrue(text.contains(OpenSourceLicensesCopy.apacheLicense), text)
        XCTAssertTrue(text.contains(OpenSourceLicensesCopy.fontsFooter), text)
        for header in ["Included software", "Map data", "Billboard"] {
            // The `label` role draws capitals; the label may read either way.
            let traits = try XCTUnwrap(host.traits(of: header) ?? host.traits(of: header.uppercased()), "\(header) in \(text)")
            XCTAssertTrue(traits.contains(.header), header)
        }
        for element in host.elements() {
            XCTAssertFalse(element.label.trimmingCharacters(in: .whitespaces).isEmpty, "an element without a label: \(element.identifier)")
        }
    }

    /// A package's page: each heading and part name is a heading, the source lines are read by licence name, and
    /// VoiceOver reads every element. A selectable paragraph is read as a text view is, by its value.
    func testAPackagesPageReadsHeadingsAndParagraphs() throws {
        let licenses = try bundled()
        let crt = try component("aws-crt-swift")
        let host = AccessibilityTreeText.Host(
            NavigationStack { LicensePage(title: crt.name, blocks: LicensePageBlock.page(for: crt, in: licenses)) },
            // Tall enough that the lazy stack draws the License heading, after ten notices and the copyright lines.
            size: CGSize(width: 390, height: 5000),
            settle: 0.4
        )
        defer { host.close() }
        for heading in ["Notice", "Copyright", "License", "aws-c-auth"] {
            let traits = try XCTUnwrap(host.traits(of: heading), heading)
            XCTAssertTrue(traits.contains(.header), heading)
        }
        XCTAssertNotNil(host.frame(of: "Version 0.54.2, Apache License 2.0"), host.text())
        let spoken = Self.spokenElements(under: host.window)
        XCTAssertFalse(spoken.isEmpty)
        for (label, value) in spoken {
            XCTAssertFalse((label + value).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "an element VoiceOver reads as nothing")
        }
        let strings = Set(host.strings())
        let firstNotice = try XCTUnwrap(crt.notices.first)
        for paragraph in OpenSourceLicenses.paragraphs(firstNotice.text) {
            XCTAssertTrue(strings.contains(paragraph), "\(paragraph) in \(strings)")
        }
    }

    // MARK: - Drawn

    /// The list and a package's page in light and dark, at the default size and AX5: on paper (the list's rows on
    /// sheet), ink only, nothing drawn in a hue.
    func testTheListAndAPageAreInkOnlyInLightAndDarkAtEverySize() throws {
        let licenses = try bundled()
        let log = try component("swift-log")
        let screens: [(String, AnyView)] = [
            ("list", AnyView(NavigationStack { OpenSourceLicensesView(licenses: licenses) })),
            ("page", AnyView(NavigationStack { LicensePage(title: log.name, blocks: LicensePageBlock.page(for: log, in: licenses)) }))
        ]
        for (sizeName, size) in [("default", DynamicTypeSize.large), ("ax5", .accessibility5)] {
            for (styleName, style) in [("light", UIUserInterfaceStyle.light), ("dark", .dark)] {
                let paper = style == .dark ? BillboardPalette.background.dark : BillboardPalette.background.light
                for (name, view) in screens {
                    let image = try snapshot(AnyView(view.environment(\.dynamicTypeSize, size)), style: style)
                    let attachment = XCTAttachment(image: image)
                    attachment.name = "open-source-licenses-\(name)-\(sizeName)-\(styleName)"
                    attachment.lifetime = .keepAlways
                    add(attachment)

                    let margin = try SnapshotPixels.column(of: image, x: 4)
                    XCTAssertTrue(
                        SnapshotPixels.matches(margin[margin.count - 60], paper, tolerance: 0.02),
                        "\(name) \(sizeName) \(styleName): paper, got \(margin[margin.count - 60])"
                    )
                    let chroma = try maximumChroma(of: try XCTUnwrap(image.cgImage))
                    XCTAssertLessThan(chroma, 0.2, "\(name) \(sizeName) \(styleName): the most colourful pixel is \(chroma) apart in its channels")
                }
            }
        }
    }

    // MARK: - Helpers

    /// The label and value of each accessibility element under `root`: what VoiceOver says when it stops there.
    private static func spokenElements(under root: NSObject) -> [(label: String, value: String)] {
        var found: [(label: String, value: String)] = []
        var seen = Set<ObjectIdentifier>()
        func visit(_ object: NSObject, depth: Int) {
            guard depth < 80, seen.insert(ObjectIdentifier(object)).inserted else { return }
            if object.isAccessibilityElement {
                found.append((object.accessibilityLabel ?? "", object.accessibilityValue ?? ""))
            }
            var children: [NSObject] = (object.accessibilityElements ?? []).compactMap { $0 as? NSObject }
            if object.accessibilityElements == nil {
                let count = object.accessibilityElementCount()
                if count != NSNotFound, count > 0 {
                    children += (0..<count).compactMap { object.accessibilityElement(at: $0) as? NSObject }
                }
            }
            if let view = object as? UIView {
                children += view.subviews
            }
            for child in children {
                visit(child, depth: depth + 1)
            }
        }
        visit(root, depth: 0)
        return found
    }

    /// Hosts `view` in its own window with the given appearance and draws the window through UIKit, which draws
    /// system lists (`ImageRenderer` cannot).
    private func snapshot(_ view: AnyView, style: UIUserInterfaceStyle) throws -> UIImage {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "the hosted test app has a window scene"
        )
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: CGSize(width: 390, height: 844))
        window.overrideUserInterfaceStyle = style
        let host = UIHostingController(rootView: view.tint(BillboardColors.interactive))
        window.rootViewController = host
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        host.view.layoutIfNeeded()

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    /// The largest gap between a pixel's channels, from 0 (grey) to 1 (a pure hue).
    private func maximumChroma(of image: CGImage) throws -> Double {
        let width = image.width
        let height = image.height
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        XCTAssertTrue(drawn, "bitmap context")
        var maximum = 0
        for index in stride(from: 0, to: bytes.count, by: 4) where bytes[index + 3] > 0 {
            let channels = [Int(bytes[index]), Int(bytes[index + 1]), Int(bytes[index + 2])]
            maximum = max(maximum, (channels.max() ?? 0) - (channels.min() ?? 0))
        }
        return Double(maximum) / 255
    }
}
