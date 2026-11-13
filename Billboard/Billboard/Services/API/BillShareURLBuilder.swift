import Foundation

enum BillShareURLBuilder {
    private static let infoKey = "SHARE_SITE_BASE_URL"
    private static let placeholderToken = "REPLACE_WITH_SHARE_SITE_URL"

    /// Builds the public read-only share URL for a bill guid.
    /// Expected shape: <share-base>/b/{guid}
    static func shareURL(forBillGuid guid: String) -> URL? {
        let cleanedGuid = guid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedGuid.isEmpty else { return nil }
        guard let baseURL = shareSiteBaseURL() else { return nil }

        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        let basePath = components?.path.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let escapedGuid = cleanedGuid.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? cleanedGuid
        components?.path = normalizedPath(basePath, appending: "/b/\(escapedGuid)")
        return components?.url
    }

    private static func shareSiteBaseURL(bundle: Bundle = .main) -> URL? {
        let infoValue = (bundle.object(forInfoDictionaryKey: infoKey) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let envValue = ProcessInfo.processInfo.environment[infoKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = envValue?.isEmpty == false ? envValue : infoValue

        guard let raw, !raw.isEmpty else { return nil }
        guard !raw.localizedCaseInsensitiveContains(placeholderToken) else { return nil }
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(), scheme == "https" else {
            return nil
        }
        return url
    }

    private static func normalizedPath(_ base: String, appending suffix: String) -> String {
        let trimmedBase = base.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let trimmedSuffix = suffix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        if trimmedBase.isEmpty {
            return "/" + trimmedSuffix
        }

        return "/" + trimmedBase + "/" + trimmedSuffix
    }
}
