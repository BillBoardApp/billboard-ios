import SwiftUI

/// Settings, from the gear on Profile (spec D 2.5.7; Civic Record spec 4.68): App settings, About Billboard,
/// Delete account and data, Sign out, as a settings list on paper (spec 3.25). The header row carries the
/// user's 34 pt monogram, name and email; the rows have no leading symbols, and the two destructive rows are
/// in `danger`. What R1 kept under Personal Info and Subscriptions is edited in place on Profile now, and the
/// in-app roadmap is replaced by a link in About (spec D 2.7).
struct ProfileSettingsMenuView: View {
    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var userStore: UserStore

    var body: some View {
        List {
            Section {
                SettingsHeader(displayName: userStore.profile.displayName, email: userStore.profile.email)
                    .padding(.vertical, BillboardStyle.Space.xs)
                    .accessibilityElement(children: .combine)
            }
            .recordListRows()

            Section {
                NavigationLink {
                    AppSettingsView()
                } label: {
                    SettingsRowText("App settings")
                }
                .accessibilityIdentifier("settings.appSettings")

                NavigationLink {
                    AboutView()
                } label: {
                    SettingsRowText("About Billboard")
                }
                .accessibilityIdentifier("settings.about")
            }
            .recordListRows()

            Section {
                // The way to delete an account: Profile > Settings > Delete.
                NavigationLink {
                    DeleteAccountDataView()
                } label: {
                    SettingsRowText(DeleteAccountCopy.buttonTitle, color: BillboardColors.danger)
                }
                .accessibilityIdentifier("settings.deleteAccount")
            }
            .recordListRows()

            Section {
                Button(role: .destructive) {
                    Task { await auth.signOut() }
                } label: {
                    SettingsRowText("Sign out", color: BillboardColors.danger)
                }
                .accessibilityIdentifier("settings.signOut")
            }
            .recordListRows()
        }
        .recordList()
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .glassNavigationBar()
        .accessibilityIdentifier("settings.screen")
    }
}

/// Settings' first row (spec 4.68): the user's 34 pt monogram, name and email. At accessibility sizes the monogram
/// sits above and the name and email take the row's width, as on Profile (spec 2.5, 4.60): beside the monogram
/// at AX5 a one-word name such as "alex.morgan" broke in the middle.
struct SettingsHeader: View {
    let displayName: String
    let email: String

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: BillboardStyle.Space.s) {
                MemberMonogram(name: displayName, size: .settings)
                identity
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(spacing: BillboardStyle.Space.m) {
                MemberMonogram(name: displayName, size: .settings)
                identity
            }
        }
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(displayName)
                .textRole(.name)
                .foregroundStyle(BillboardColors.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            if !email.isEmpty {
                EmailText(email)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A settings row's words in the `body` role, `ink` unless told otherwise (`danger` for the destructive
/// rows). No leading symbol (spec 3.25).
struct SettingsRowText: View {
    let title: String
    var color: Color = BillboardColors.primaryText

    init(_ title: String, color: Color = BillboardColors.primaryText) {
        self.title = title
        self.color = color
    }

    var body: some View {
        Text(title)
            .textRole(.body)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}
