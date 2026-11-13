import SwiftUI

/// The Bills tab's entry to Search bills (Civic Record spec 3.17, 4.24): the search capsule
/// (`SearchCapsule`, as Congress's "Find a member" field) with "Search bills" in `ink3`. Tapping it opens
/// Search bills, where you find a bill or browse your lists (Watching, Voted, Passed, Skipped, Topics, Life
/// areas).
struct BillsSearchEntryCard: View {
    var body: some View {
        NavigationLink {
            BillsSearchView()
        } label: {
            SearchCapsule {
                Text("Search bills")
                    .textRole(.body)
                    .foregroundStyle(BillboardColors.dimText)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    // Room above and below the words once they wrap at the largest sizes.
                    .padding(.vertical, BillboardStyle.Space.s)
                Spacer(minLength: 0)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(RowButtonStyle())
        .accessibilityLabel("Search bills")
        .accessibilityIdentifier("home.searchEntry")
    }
}
