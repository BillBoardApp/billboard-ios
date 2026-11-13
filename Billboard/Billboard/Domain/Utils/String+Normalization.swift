import Foundation

extension String {
    nonisolated var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated var trimmedNonEmpty: String? {
        let value = trimmed
        return value.isEmpty ? nil : value
    }

    nonisolated var uppercasedTrimmed: String {
        trimmed.uppercased()
    }
}

extension Optional where Wrapped == String {
    nonisolated var trimmedNonEmpty: String? {
        switch self {
        case .some(let value):
            return value.trimmedNonEmpty
        case .none:
            return nil
        }
    }
}

enum ScopedStorageKey {
    nonisolated static func normalizedScope(_ scope: String?) -> String? {
        scope.trimmedNonEmpty
    }

    nonisolated static func make(base: String, scope: String?) -> String {
        guard let normalizedScope = normalizedScope(scope) else {
            return base
        }

        return "\(base).\(normalizedScope)"
    }
}
