import SwiftUI

/// The Cognito password policy for the Billboard user pool.
///
/// `billboard-backend: infra/lib/stacks/user-api-service.ts` sets no `passwordPolicy`, so
/// the CDK/Cognito defaults apply: at least 8 characters with an uppercase
/// letter, a lowercase letter, a number and a symbol. Keep this in sync if the
/// pool's policy changes. The checks drive the hints and keep a new-password
/// form's button disabled until they pass (`NewPasswordHints`), so they must never
/// be stricter than the pool; Cognito stays the judge.
///
/// Length counts UTF-16 code units, which are never fewer than the code points or
/// the characters on screen, so a password the pool takes is not held back here:
/// an accented letter typed as a letter and a combining mark, or an emoji with a
/// skin tone, counts as more than one character.
enum PasswordPolicy {
    static let minimumLength = 8

    /// Characters Cognito counts as symbols (space is allowed when not leading or trailing).
    private static let symbols = CharacterSet(charactersIn: "^$*.[]{}()?\"!@#%&/\\,><':;|_~`=+- ")

    enum Rule: CaseIterable {
        case length
        case uppercase
        case lowercase
        case number
        case symbol

        var label: String {
            switch self {
            case .length:
                return "8+ characters"
            case .uppercase:
                return "an uppercase letter"
            case .lowercase:
                return "a lowercase letter"
            case .number:
                return "a number"
            case .symbol:
                return "a symbol"
            }
        }
    }

    static func unmetRules(in password: String) -> [Rule] {
        Rule.allCases.filter { !isSatisfied($0, by: password) }
    }

    static func isSatisfied(_ rule: Rule, by password: String) -> Bool {
        switch rule {
        case .length:
            return password.utf16.count >= minimumLength
        case .uppercase:
            return password.unicodeScalars.contains { CharacterSet.uppercaseLetters.contains($0) }
        case .lowercase:
            return password.unicodeScalars.contains { CharacterSet.lowercaseLetters.contains($0) }
        case .number:
            return password.unicodeScalars.contains { CharacterSet.decimalDigits.contains($0) }
        case .symbol:
            return password.unicodeScalars.contains { symbols.contains($0) }
        }
    }
}

/// Helper text under a new-password field (Civic Record spec 4.12): the policy up front, then what is still
/// missing while the user types, in `caption` `ink2`. Once every rule is met the line starts with a
/// `checkmark` in ink (never green).
struct PasswordRequirementsHint: View {
    let password: String

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var isMet: Bool {
        !password.isEmpty && PasswordPolicy.unmetRules(in: password).isEmpty
    }

    var text: String {
        guard !password.isEmpty else {
            return "Use 8+ characters with upper and lower case letters, a number and a symbol."
        }

        let unmet = PasswordPolicy.unmetRules(in: password)
        guard !unmet.isEmpty else {
            return "Password meets the requirements."
        }
        return "Still needed: " + unmet.map(\.label).joined(separator: ", ") + "."
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if isMet {
                Image(systemName: "checkmark")
                    .font(TextRole.Face.text.font(size: TextRole.caption.scaledSize(for: dynamicTypeSize), weight: .bold))
                    .foregroundStyle(BillboardColors.primaryText)
                    .accessibilityHidden(true)
            }
            Text(text)
                .textRole(.caption)
                .foregroundStyle(BillboardColors.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Password requirements: \(text)")
    }
}

/// What a new password and its confirmation still need before the form's button turns on (Create account,
/// Forgot password's "Enter code", Set a new password). Each form says it on the disabled button's hint line
/// (spec 3.16) in its own words; the two lines here are the same on every form.
enum NewPasswordHints {
    /// The wording of `PasswordRequirementsHint` ("Password meets the requirements.").
    static let unmetRequirements = "Use a password that meets the requirements above to continue."
    /// `PasswordMismatchHint` says "Passwords don't match." under the field; this says what to do.
    static let mismatch = "Make both passwords match to continue."

    /// The first thing still needed, in the order the fields sit.
    enum Need: Equatable {
        /// No password yet.
        case password
        /// A password that does not meet the requirements yet. The confirmation waits for it, since it
        /// would have to be typed again.
        case requirements
        /// A password that meets the requirements, and no confirmation yet.
        case confirmation
        /// Both typed, and they differ.
        case match
    }

    /// Nil when the password meets the requirements and the confirmation matches it.
    static func need(password: String, confirmation: String) -> Need? {
        if password.isEmpty { return .password }
        if !PasswordPolicy.unmetRules(in: password).isEmpty { return .requirements }
        if confirmation.isEmpty { return .confirmation }
        if password != confirmation { return .match }
        return nil
    }
}

/// Inline message under a confirm-password field, as a field error (spec 3.17).
struct PasswordMismatchHint: View {
    static let message = "Passwords don't match."

    var body: some View {
        RecordErrorText(Self.message)
    }
}
