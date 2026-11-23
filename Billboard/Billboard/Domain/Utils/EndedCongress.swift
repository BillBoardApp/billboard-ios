import Foundation

/// A bill whose Congress has ended (REL-46, D16): the ENDED WITH THE 119TH CONGRESS stamp, the note under the bill
/// page's title, and the line that says how far a passed bill got ("Passed the House only."). The rule and the words
/// are the backend's shared-bill page's (website/app.js, `endedNote` and `endedStampWord`), so the page and the app
/// say the same about every bill; keep them in step.
///
/// The note is held when in doubt, because a wrong "did not become law" on a bill that was signed is a factual error:
/// - for a status the app does not know (none sent, or one it cannot read), which reads New;
/// - before the Congress ends (noon Eastern on January 3, `CongressCalendar.endTime(ofCongress:)`), for a bill that
///   became law or whose actions say so, and for a Congress before the 74th (they ended on March 4);
/// - for a Passed bill, or one whose actions show a passage or the President, until February 1 of the end year: the
///   actions that make a bill Became law can arrive weeks after it is signed;
/// - for a passed simple or concurrent resolution, which is finished and never becomes law, and a passed joint
///   resolution proposing a constitutional amendment, which goes to the states instead.
///
/// Only a New or Updated bill is stamped: Became law, Vetoed, Passed and Failed are outcomes and stand over the ended
/// stamp, as on the shared-bill page. Ended bills stay votable (project decision 1); they leave the Bills list
/// (`BillboardQueueDerivation`).
nonisolated enum EndedCongress {
    /// What the rule reads of a bill (or of a Weekly Brief item, which carries no actions).
    struct Record: Sendable {
        var congress: Int?
        /// "hr", "s", "hjres", "sjres", "hres", "sres", "hconres" or "sconres".
        var typeCode: String?
        var status: BillStatus
        /// The server sent a status the app knows (`Bill.statusIsUnknown`): an unknown one reads New, and gets no note.
        var statusIsKnown = true
        /// The bill is vetoed and did not become law (`Bill.isVetoed`): an outcome, so never stamped ENDED.
        var isVetoed = false
        var actions: [Bill.BillAction] = []
        /// The official title and the headline, where a proposed constitutional amendment names itself.
        var titles = ""
    }

    static let billTypes: Set<String> = ["hr", "s"]
    static let jointResolutionTypes: Set<String> = ["hjres", "sjres"]
    static let resolutionTypes: Set<String> = ["hres", "sres", "hconres", "sconres"]

    /// The statuses that can get the note: every one but Became law (Finalized).
    private static let noteStatuses: Set<BillStatus> = [.new, .updated, .passed, .failed]

    /// Action codes 8000 and 17000: a passage in the House and in the Senate (RUNBOOK 4.11).
    static let housePassageCode = "8000"
    static let senatePassageCode = "17000"

    /// "Ended with the 119th Congress": the stamp's word, read the same by VoiceOver.
    static func stampWord(congress: Int) -> String {
        "Ended with the \(SpokenForm.ordinal(congress)) Congress"
    }

    /// When a passed bill's note may show: February 1 of the end year at midnight Eastern, 05:00 UTC.
    static func passedHoldTime(ofCongress congress: Int) -> Date {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let components = DateComponents(year: CongressCalendar.endYear(ofCongress: congress), month: 2, day: 1, hour: 5)
        return utc.date(from: components) ?? .distantFuture
    }

    /// The note for a bill whose Congress ended without it becoming law, or nil for none: "The 119th Congress ended
    /// on January 3, 2027. This bill did not become law. To move forward it would have to be introduced again."
    static func note(for record: Record, at now: Date) -> String? {
        guard let congress = record.congress, congress >= CongressCalendar.firstJanuaryCongress,
              let type = record.typeCode, isKnownType(type) else { return nil }
        guard record.statusIsKnown, noteStatuses.contains(record.status), CongressCalendar.hasEnded(congress, at: now) else {
            return nil
        }
        guard !actionsShowLaw(record.actions) else { return nil }

        let passed = record.status == .passed || actionsShowPassage(record.actions)
        let ended = "The \(SpokenForm.ordinal(congress)) Congress ended on January 3, \(CongressCalendar.endYear(ofCongress: congress))."
        let again = "To move forward it would have to be introduced again."
        if resolutionTypes.contains(type) {
            return passed ? nil : "\(ended) This resolution was not agreed to. \(again)"
        }
        if jointResolutionTypes.contains(type), proposesConstitutionalAmendment(record.titles) {
            return passed ? nil : "\(ended) This proposed amendment did not pass Congress. \(again)"
        }
        if passed, now < passedHoldTime(ofCongress: congress) { return nil }
        let kind = jointResolutionTypes.contains(type) ? "joint resolution" : "bill"
        return "\(ended) This \(kind) did not become law. \(again)"
    }

    /// The Congress a bill's stamp says it ended with, or nil: a New or Updated bill (no outcome, not vetoed) that
    /// gets the note.
    static func stampCongress(for record: Record, at now: Date) -> Int? {
        guard record.status == .new || record.status == .updated, !record.isVetoed,
              note(for: record, at: now) != nil else { return nil }
        return record.congress
    }

    /// "Passed the House only." or "Passed the Senate only.": how far a bill with the note got, from its actions (a
    /// passage in one chamber, codes 8000 and 17000, and nothing sent to the President). Only from February 1 of the
    /// end year, when the note shows for a passed bill; nil otherwise.
    static func oneChamberLine(for record: Record, at now: Date) -> String? {
        guard let congress = record.congress, now >= passedHoldTime(ofCongress: congress),
              note(for: record, at: now) != nil else { return nil }
        let reachedThePresident = record.actions.contains { action in
            let type = trimmed(action.type).lowercased()
            return type == "president" || type == "veto" || action.isVetoAction
        }
        guard !reachedThePresident else { return nil }
        let codes = Set(record.actions.map { trimmed($0.actionCode) })
        switch (codes.contains(housePassageCode), codes.contains(senatePassageCode)) {
        case (true, false): return "Passed the House only."
        case (false, true): return "Passed the Senate only."
        default: return nil
        }
    }

    // MARK: - Reading the actions

    /// Actions that say the bill became law, even when its status does not yet.
    static func actionsShowLaw(_ actions: [Bill.BillAction]) -> Bool {
        actions.contains { action in
            let line = trimmed(action.text)
            return trimmed(action.type).lowercased() == "becamelaw"
                || trimmed(action.actionCode) == "36000"
                || line.range(of: #"became (public|private) law"#, options: [.regularExpression, .caseInsensitive]) != nil
                || line.range(of: #"signed by (the )?president"#, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    /// Actions that show the bill passed a chamber or reached the President, whatever its status says.
    static func actionsShowPassage(_ actions: [Bill.BillAction]) -> Bool {
        actions.contains { action in
            let code = trimmed(action.actionCode)
            let type = trimmed(action.type).lowercased()
            return code == housePassageCode || code == senatePassageCode || type == "president" || type == "veto"
        }
    }

    /// A joint resolution proposing a constitutional amendment goes to the states, not the President, so it never
    /// "becomes law": once Congress passes it, it is finished there.
    static func proposesConstitutionalAmendment(_ titles: String) -> Bool {
        titles.range(of: #"\bamendment to the constitution\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func isKnownType(_ type: String) -> Bool {
        billTypes.contains(type) || jointResolutionTypes.contains(type) || resolutionTypes.contains(type)
    }

    private static func trimmed(_ value: String?) -> String {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Bills

extension Bill {
    /// What `EndedCongress` reads of the bill.
    nonisolated var endedCongressRecord: EndedCongress.Record {
        EndedCongress.Record(
            congress: congressNumber,
            typeCode: billTypeCode,
            status: billStatus,
            statusIsKnown: statusIsUnknown != true,
            isVetoed: isVetoed,
            actions: actions,
            titles: "\(officialTitle ?? "") \(title)"
        )
    }

    /// The bill page's note when the bill's Congress ended without it becoming law (`EndedCongress.note`).
    nonisolated func endedNote(at now: Date = CongressCalendar.now()) -> String? {
        EndedCongress.note(for: endedCongressRecord, at: now)
    }

    /// The Congress the bill's stamp says it ended with ("ENDED WITH THE 119TH CONGRESS"), or nil
    /// (`EndedCongress.stampCongress`).
    nonisolated func endedCongress(at now: Date = CongressCalendar.now()) -> Int? {
        EndedCongress.stampCongress(for: endedCongressRecord, at: now)
    }

    /// "Passed the House only." or "Passed the Senate only." on the bill page (`EndedCongress.oneChamberLine`).
    nonisolated func oneChamberLine(at now: Date = CongressCalendar.now()) -> String? {
        EndedCongress.oneChamberLine(for: endedCongressRecord, at: now)
    }

    /// The bill is of an earlier Congress than `currentCongress` (`CongressCalendar.currentCongress(at:)`), whatever
    /// its status: it is off the Bills list (REL-46). False when its Congress is unknown.
    nonisolated func isFromEarlierCongress(than currentCongress: Int) -> Bool {
        guard let congress = congressNumber else { return false }
        return congress < currentCongress
    }
}
