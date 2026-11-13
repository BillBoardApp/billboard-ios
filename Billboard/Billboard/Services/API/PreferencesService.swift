import Amplify
import Foundation

struct PreferencesItem: Codable, Identifiable, Equatable {
    enum Kind: String, Codable {
        case topic
        case lifeArea
        case congressMember
        case bill
        case watch
        case contentType
    }

    /// Backward compatible payload key.
    let subCategory: String?

    /// New payload key (matches `preference` column in DB).
    let preference: String?

    /// Optional parent grouping for display / debugging.
    let category: String?

    /// New payload key (matches `type` column in DB). Example values: "Category", "Life Area", "Congress Member".
    let type: String?

    var value: String {
        (subCategory ?? preference ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var kind: Kind {
        let normalized = (type ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined()

        switch normalized {
        case "watch":
            return .watch
        case "bill":
            return .bill
        case "lifearea":
            return .lifeArea
        case "congressmember":
            return .congressMember
        case "contenttype":
            return .contentType
        default:
            return .topic
        }
    }

    var id: String {
        "\(kind.rawValue)|\(category ?? "")|\(value)"
    }
}

enum PreferencesService {
    private static let path = "preferences"
    private static let label = "PreferencesService preferences"

    static func getPreferences() async throws -> [PreferencesItem] {
        let session = try await Amplify.Auth.fetchAuthSession()
        guard session.isSignedIn else {
            throw APIServiceError.notSignedIn
        }

        let data = try await APIClient.current.payload(.get, path, label: label)

        guard !data.isEmpty else { return [] }

        let decoder = JSONDecoder.convertingFromSnakeCase()

        // Backend payloads may be either a raw array or wrapped in an object.
        if let items = try? decoder.decode([PreferencesItem].self, from: data) {
            return items
        }

        struct WrappedItems: Decodable {
            let items: [PreferencesItem]
        }

        if let wrapped = try? decoder.decode(WrappedItems.self, from: data) {
            return wrapped.items
        }

        struct WrappedPreferences: Decodable {
            let preferences: [PreferencesItem]
        }

        if let wrapped = try? decoder.decode(WrappedPreferences.self, from: data) {
            return wrapped.preferences
        }

        // If none matched, surface (and log) the original decoding error for the array.
        return try APIDecoding.decode([PreferencesItem].self, from: data, decoder: decoder, label: label)
    }

    // MARK: - Put (client) helpers

    /// Replace or upsert preferences for the current user.
    /// This will call `PUT /preferences` on the configured API.
    static func putPreferences(_ items: [PreferencesItem]) async throws {
        let session = try await Amplify.Auth.fetchAuthSession()
        guard session.isSignedIn else {
            throw APIServiceError.notSignedIn
        }

        struct Wrapper: Codable {
            let preferences: [PreferencesItem]
        }

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let bodyData = try encoder.encode(Wrapper(preferences: items))

        // Amplify will surface HTTP errors as `APIError.httpStatusError` which callers
        // can inspect. We don't swallow errors here; callers can use `debugString(for:)`.

        do {
            try await APIClient.current.payload(.put, path, body: bodyData, label: label)
            #if DEBUG
            print("[PreferencesService] PUT preferences -> success")
            #endif
        } catch {
            #if DEBUG
            print("[PreferencesService] PUT preferences -> error:\n\(debugString(for: error))")
            #endif
            throw error
        }
    }

    /// Delete one or more preferences for the current user.
    /// Expects the same preference objects the server understands (type, preference, optional category).
    static func deletePreferences(_ items: [PreferencesItem]) async throws {
        let session = try await Amplify.Auth.fetchAuthSession()
        guard session.isSignedIn else {
            throw APIServiceError.notSignedIn
        }

        struct Wrapper: Codable {
            let preferences: [PreferencesItem]
        }

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let bodyData = try encoder.encode(Wrapper(preferences: items))

        do {
            try await APIClient.current.payload(.delete, path, body: bodyData, label: label)
            #if DEBUG
            print("[PreferencesService] DELETE preferences -> success")
            #endif
        } catch {
            #if DEBUG
            print("[PreferencesService] DELETE preferences -> error:\n\(debugString(for: error))")
            #endif
            throw error
        }
    }

    static func debugString(for error: Error) -> String {
        APIErrorDebug.debugString(for: error)
    }
}
