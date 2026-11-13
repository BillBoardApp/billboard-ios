import SwiftUI

// The settings lists (Civic Record spec 3.25): Settings, App settings, About Billboard, Delete account and
// data. They keep the system inset-grouped `List` and `Form` for their native behaviour, set on paper with
// rows on sheet, separators in `rule`, row text in `body` `ink` and footers in `caption` `ink2`. Dark mode is
// then night paper and dark sheet, not system black. The system's inset-grouped corner radius is the one
// exception to the radii (spec 2.6).

extension View {
    /// A settings list on paper (spec 3.25): no system background behind the rows' groups.
    func recordList() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(BillboardColors.background.ignoresSafeArea())
            .tint(BillboardColors.interactive)
    }

    /// A settings list's rows on sheet with `rule` separators (spec 3.25). Put it on each `Section`.
    func recordListRows() -> some View {
        self
            .listRowBackground(BillboardColors.cardBackground)
            .listRowSeparatorTint(BillboardColors.separator)
    }
}

/// A settings list section's header (spec 3.25): the `label` role (capitals by style) in `ink3`.
struct RecordListHeader: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .textRole(.label)
            .foregroundStyle(BillboardColors.dimText)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A settings list section's footer (spec 3.25): `caption` in `ink2`.
struct RecordListFooter: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .textRole(.caption)
            .foregroundStyle(BillboardColors.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }
}
