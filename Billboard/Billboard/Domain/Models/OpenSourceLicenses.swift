import Foundation

/// What the Open-source licenses screen shows (APPF-32): the bundled `OpenSourceLicenses.json`, which
/// `scripts/generate-open-source-licenses.sh` writes from THIRD_PARTY_NOTICES.md ("In the app") and the Swift package
/// checkouts at their pinned revisions, plus the repository's own NOTICE and LICENSE. Each licence text is stored once
/// (`texts`) and named by its hash. Pure, for `OpenSourceLicensesTests`.
nonisolated struct OpenSourceLicenses: Decodable, Equatable, Sendable {
    /// The file's format; the generator writes 1.
    static let formatVersion = 1
    static let resourceName = "OpenSourceLicenses"

    /// A NOTICE file, shown whole: the package's own, or one of a bundled library (`part`).
    nonisolated struct Notice: Decodable, Equatable, Hashable, Sendable {
        let part: String
        let file: String
        let text: String
    }

    /// One licence text and the parts of the package under it: the package itself and any bundled libraries with
    /// the same text. `text` is the key of the text in `texts`.
    nonisolated struct License: Decodable, Equatable, Hashable, Sendable {
        let parts: [String]
        let spdx: String
        let files: [String]
        let text: String

        /// The names of the files the text was read from, each once: "LICENSE", "time.c".
        var fileNames: [String] {
            var names: [String] = []
            for name in files.map({ ($0 as NSString).lastPathComponent }) where !names.contains(name) {
                names.append(name)
            }
            return names
        }

        /// "Apache-2.0 · LICENSE", "BSD-3-Clause · time.c": the licence and the files it was read from.
        var sourceLine: String {
            ([spdx] + fileNames).joined(separator: " · ")
        }

        /// What VoiceOver reads for `sourceLine`: "BSD 3-Clause License, time.c".
        var spokenSourceLine: String {
            ([OpenSourceLicenses.spokenName(forSPDX: spdx)] + fileNames).joined(separator: ", ")
        }
    }

    /// A Swift package linked into the app.
    nonisolated struct Component: Decodable, Equatable, Identifiable, Sendable {
        let name: String
        let version: String
        let spdx: String
        let notices: [Notice]
        /// The distinct copyright lines at the top of the linked sources, the most common first.
        let copyrights: [String]
        let licenses: [License]

        var id: String { name }

        /// The licence's name as VoiceOver reads it: "Apache License 2.0".
        var spokenLicenseName: String { OpenSourceLicenses.spokenName(forSPDX: spdx) }

        /// The row's VoiceOver label: "amplify-swift, Apache License 2.0".
        var accessibilityLabel: String { "\(name), \(spokenLicenseName)" }

        /// Whether the notices come from more than one part, so each needs its part's name over it.
        var namesNoticeParts: Bool { Set(notices.map(\.part)).count > 1 || notices.contains { $0.part != name } }

        /// Whether the licence texts need their parts and files over them: more than one text, or one that covers
        /// bundled libraries too.
        var namesLicenseParts: Bool { licenses.count > 1 || licenses.contains { $0.parts != [name] } }
    }

    /// Billboard's own copyright and licence (the repository's NOTICE and LICENSE).
    nonisolated struct Billboard: Decodable, Equatable, Sendable {
        /// "Copyright 2025-2027 The Billboard Authors", read from NOTICE, never typed.
        let copyright: String
        let notice: String
        let license: String
    }

    let formatVersion: Int
    let billboard: Billboard
    let components: [Component]
    let texts: [String: String]

    /// The full text of `license`, or "" when the file does not hold it (the generator's check rules that out).
    func text(of license: License) -> String {
        texts[license.text] ?? ""
    }

    /// The Apache License 2.0 text Billboard is under.
    var billboardLicenseText: String {
        texts[billboard.license] ?? ""
    }

    /// Billboard's section text (approved D2): the copyright line from NOTICE, then the licence and trademark lines.
    var billboardStatement: String {
        "\(billboard.copyright). Licensed under the Apache License, Version 2.0. The Billboard name and logos are not covered by that license."
    }

    /// The app's bundled file, read once; nil only if the bundle lacks it or it does not decode.
    static let bundled: OpenSourceLicenses? = load(from: .main)

    static func load(from bundle: Bundle) -> OpenSourceLicenses? {
        let url = bundle.url(forResource: resourceName, withExtension: "json")
            ?? bundle.url(forResource: resourceName, withExtension: "json", subdirectory: "Resources")
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return decode(data)
    }

    static func decode(_ data: Data) -> OpenSourceLicenses? {
        guard let decoded = try? JSONDecoder().decode(OpenSourceLicenses.self, from: data),
              decoded.formatVersion == formatVersion else { return nil }
        return decoded
    }

    // MARK: - Words

    /// What VoiceOver says for an SPDX expression; the expression itself when it has no entry.
    static func spokenName(forSPDX spdx: String) -> String {
        spokenNames[spdx] ?? spdx
    }

    static let spokenNames: [String: String] = [
        "Apache-2.0": "Apache License 2.0",
        "Apache-2.0 WITH Swift-exception": "Apache License 2.0 with the Swift runtime library exception",
        "APSL-2.0": "Apple Public Source License 2.0",
        "BSD-2-Clause": "BSD 2-Clause License",
        "BSD-3-Clause": "BSD 3-Clause License",
        "BSD-3-Clause AND MIT": "BSD 3-Clause License and MIT License",
        "MIT": "MIT License",
        "Unlicense": "The Unlicense"
    ]

    // MARK: - Paragraphs

    /// `text` as the paragraphs the screen draws, one VoiceOver stop each. Paragraphs are split at blank lines.
    /// Inside one, a line that was only wrapped to fit 80 columns joins the line before it, so the text reflows to
    /// the screen; a short line (a title, a name) or a line that starts a list item, a copyright line or a link keeps
    /// its own line. No word is dropped or changed: only line breaks become spaces.
    static func paragraphs(_ text: String) -> [String] {
        var out: [String] = []
        var current: [String] = []

        func flush() {
            guard !current.isEmpty else { return }
            var paragraph = current[0]
            for index in 1..<current.count {
                let previous = current[index - 1]
                let line = current[index]
                let joins = previous.count >= reflowWidth && !startsOwnLine(line)
                paragraph += (joins ? " " : "\n") + line
            }
            out.append(paragraph)
            current = []
        }

        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flush()
            } else {
                current.append(line)
            }
        }
        flush()
        return out
    }

    /// A line at least this long was wrapped to fit, so the next line continues it.
    static let reflowWidth = 40

    /// Starts of a line that begins something new: a list item ("* ", "1. ", "(a) "), a rule, a copyright or
    /// SPDX line, a link or an address.
    private static let ownLinePrefixes = ["*", "-", "•", "=", "Copyright", "SPDX-", "http://", "https://", "<", "@"]

    static func startsOwnLine(_ line: String) -> Bool {
        if ownLinePrefixes.contains(where: { line.hasPrefix($0) }) { return true }
        // "1. Definitions." or "2) ": a number of one or two digits, then a full stop or a bracket and a space.
        let digits = line.prefix { $0.isASCII && $0.isNumber }
        if (1...2).contains(digits.count) {
            let rest = line.dropFirst(digits.count)
            if rest.hasPrefix(". ") || rest.hasPrefix(") ") { return true }
        }
        // "(a) " or "(1) ".
        if line.hasPrefix("("), let close = line.firstIndex(of: ")") {
            let inside = line[line.index(after: line.startIndex)..<close]
            let after = line[line.index(after: close)...]
            if (1...2).contains(inside.count), inside.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }), after.hasPrefix(" ") {
                return true
            }
        }
        return false
    }
}
