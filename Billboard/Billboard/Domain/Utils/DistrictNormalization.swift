import Foundation

enum DistrictNormalization {
    /// Normalizes a raw district string (e.g. "CA-12", "12th", "0", "At-Large") into a
    /// canonical form suitable for comparison.
    ///
    /// Returns `nil` when the input is empty or cannot be parsed.
    static func normalize(_ raw: String, userState: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let upper = trimmed.uppercased()
        let upperState = userState.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()

        // Common variants for at-large.
        if upper.contains("AT-LARGE") || upper == "AL" {
            return "AT-LARGE"
        }

        // Support formats like "CA-12" or "CA 12".
        var candidate = upper
        if !upperState.isEmpty {
            candidate = candidate.replacingOccurrences(of: upperState + "-", with: "")
            candidate = candidate.replacingOccurrences(of: upperState + " ", with: "")
        }

        // Extract digits if present ("12", "012", "12th").
        let digits = candidate.filter { $0.isNumber }
        if !digits.isEmpty {
            // Drop leading zeros only ("012" -> "12"); trailing zeros are significant ("10").
            let normalized = String(digits.drop(while: { $0 == "0" }))
            // If digits were all zeros (e.g. "0"), treat as at-large.
            if normalized.isEmpty {
                return "AT-LARGE"
            }
            return normalized
        }

        // Fallback: compare as-is.
        return candidate.isEmpty ? nil : candidate
    }
}
