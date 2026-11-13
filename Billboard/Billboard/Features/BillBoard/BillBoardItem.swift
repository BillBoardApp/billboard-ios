import Foundation

struct BillBoardItem: Identifiable, Sendable {
    enum ItemType: Sendable {
        case bill           // New bills: the vote bar on detail
        case updated        // Updated bills: summary changed, vote again on detail
        // Passed, Became law (Finalized) or Failed bills: the vote bar on detail, as on any bill (project
        // decision 1). The Bills list does not queue a decided bill (`BillboardQueueDerivation`).
        case passed
        // Action in Congress on a bill: opens the bill's page, with the vote bar. No list builds one
        // today; Congress actions show in Updates.
        case alert(BillAlert)
    }

    /// The card's bill id: for a companion group, the primary's (`UUID.deterministic(primaryGuid)`)
    /// when its bill is loaded.
    let id: UUID
    /// The card's bill: the group's primary when loaded (its title, summary and sponsor), else the
    /// member that is.
    let bill: Bill
    let date: Date
    var type: ItemType = .bill

    // MARK: Companion group (APPF-23); nil or empty for a bill in no group

    /// The group the card stands for.
    var companionGroup: BillCompanionGroup?
    /// The group's loaded bills, one per member, primary first.
    var memberBills: [Bill] = []
    /// What the status chip shows: the member furthest along ("Passed · S. 456").
    var statusLead: CompanionStatusLead?

    /// "H.R. 900 · S. 456" for a group, nil for a single bill (show `bill.officialBillNumber`).
    var companionNumbersLabel: String? {
        companionGroup.map(CompanionGroupIndex.numbersLabel(for:))
    }

    /// "Bill numbers H.R. 900 and S. 456, identical bills" for a group, nil for a single bill.
    var companionAccessibilityLabel: String? {
        companionGroup.map(CompanionGroupIndex.accessibilityLabel(for:))
    }
}

// MARK: - Skip (spec D 2.1.1)

extension BillBoardItem {
    /// What swiping the card left (or its Skip action) hides. Never a vote.
    var skipTarget: SkipTarget {
        switch type {
        case .bill, .updated:
            return .openBill(bill.id)
        case .passed:
            return .closedBill(bill.id)
        case .alert(let alert):
            return .alert(alert.id)
        }
    }

    /// The official numbers the card shows: every member's for a companion group, primary first;
    /// else the bill's own; empty when unknown.
    var billNumbers: [String] {
        if let companionGroup {
            return companionGroup.memberGuids.map(CompanionGroupIndex.billNumber(forGUID:))
        }
        return bill.officialBillNumber.map { [$0] } ?? []
    }

    /// "Skipped H.R. 1234".
    var skipUndoMessage: SkipUndoMessage {
        .skipped(numbers: billNumbers)
    }
}

/// The undo toast's text after a skip or Clear (spec D 2.1.2), and what VoiceOver announces.
nonisolated struct SkipUndoMessage: Equatable, Sendable {
    /// Shown in the toast: "Skipped H.R. 900 · S. 456".
    let text: String
    /// Announced: "Skipped H.R. 900 and S. 456. Undo available."
    let accessibilityText: String

    init(text: String, spokenText: String? = nil) {
        self.text = text
        self.accessibilityText = "\(spokenText ?? text). Undo available."
    }

    /// A skip on Bills: "Skipped H.R. 1234", or "Skipped a bill" when the number is unknown.
    static func skipped(numbers: [String]) -> SkipUndoMessage {
        named("Skipped", numbers: numbers)
    }

    /// A Clear on one Updates row: "Cleared S. 456".
    static func cleared(numbers: [String]) -> SkipUndoMessage {
        named("Cleared", numbers: numbers)
    }

    /// Clear all on Passed or Failed bills: "Cleared 3 bills".
    static func clearedBills(count: Int) -> SkipUndoMessage {
        SkipUndoMessage(text: "Cleared \(count) \(count == 1 ? "bill" : "bills")")
    }

    /// A Clear on actions in Congress: "Cleared 1 action", "Cleared 4 actions".
    static func clearedActions(count: Int) -> SkipUndoMessage {
        SkipUndoMessage(text: "Cleared \(count) \(count == 1 ? "action" : "actions")")
    }

    /// The official numbers of `bill`, or of every member of its companion group in `companions`.
    static func billNumbers(for bill: Bill, companions: CompanionGroupIndex) -> [String] {
        if let group = companions.group(for: bill) {
            return group.memberGuids.map(CompanionGroupIndex.billNumber(forGUID:))
        }
        return bill.officialBillNumber.map { [$0] } ?? []
    }

    private static func named(_ verb: String, numbers: [String]) -> SkipUndoMessage {
        let numbers = numbers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !numbers.isEmpty else { return SkipUndoMessage(text: "\(verb) a bill") }
        let spokenList: String
        if numbers.count <= 2 {
            spokenList = numbers.joined(separator: " and ")
        } else {
            spokenList = numbers.dropLast().joined(separator: ", ") + " and " + (numbers.last ?? "")
        }
        return SkipUndoMessage(
            text: "\(verb) \(numbers.joined(separator: " · "))",
            spokenText: "\(verb) \(spokenList)"
        )
    }
}
