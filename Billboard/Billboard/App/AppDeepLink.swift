import Foundation

/// Validation for bill guids that arrive from outside the app (deep links,
/// push payloads). Guids look like `BILLS-119hr1234ih`.
enum BillGuid {
    nonisolated static let maxLength = 64
    nonisolated private static let pattern = #"^BILLS-[0-9]+[a-z]+[0-9]+[a-z]*$"#

    nonisolated static func isValid(_ guid: String) -> Bool {
        guard !guid.isEmpty, guid.count <= maxLength else { return false }
        return guid.range(of: pattern, options: .regularExpression) != nil
    }

    /// Trimmed guid if it is well formed, otherwise nil.
    nonisolated static func validated(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              isValid(trimmed) else {
            return nil
        }
        return trimmed
    }
}

enum AppDeepLink: Equatable {
    case bill(guid: String)

    /// Accepts `billboard://bill?guid=<guid>` (and the `/b/<guid>`, `/bill/<guid>`
    /// path forms) plus `https://<share host>/b/<guid>`, where the share host
    /// comes from `SHARE_SITE_BASE_URL`. Anything else, or a malformed guid, is
    /// rejected.
    nonisolated init?(url: URL, allowedWebHosts: Set<String> = AppDeepLink.shareSiteHosts()) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }

        let candidate: String?
        switch components.scheme?.lowercased() {
        case "billboard":
            candidate = Self.guidFromBillboardScheme(components: components)
        case "https":
            let host = (components.host ?? "").lowercased()
            guard allowedWebHosts.contains(host) else { return nil }
            candidate = Self.guidFromPath(path: components.path, allowSingleSegment: false)
        default:
            candidate = nil
        }

        guard let guid = BillGuid.validated(candidate) else { return nil }
        self = .bill(guid: guid)
    }

    /// Hosts that may open the app: the `SHARE_SITE_BASE_URL` host (Info.plist,
    /// or the same-named environment override `BillShareURLBuilder` honours in
    /// development) and its `www.` / `share.` siblings on the same domain.
    nonisolated static func shareSiteHosts(bundle: Bundle = .main) -> Set<String> {
        let key = "SHARE_SITE_BASE_URL"
        let configured = [
            bundle.object(forInfoDictionaryKey: key) as? String,
            ProcessInfo.processInfo.environment[key]
        ]

        var hosts = Set<String>()
        for raw in configured.compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) }) {
            guard let host = URL(string: raw)?.host?.lowercased(), !host.isEmpty else { continue }
            hosts.insert(host)

            var baseDomain = host
            for prefix in ["www.", "share."] where baseDomain.hasPrefix(prefix) {
                baseDomain = String(baseDomain.dropFirst(prefix.count))
            }

            // Only derive siblings for a real registrable domain (at least one dot).
            if baseDomain.contains(".") {
                hosts.insert("www.\(baseDomain)")
                hosts.insert("share.\(baseDomain)")
            }
        }
        return hosts
    }

    nonisolated private static func guidFromBillboardScheme(components: URLComponents) -> String? {
        let host = (components.host ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard host == "bill" || host == "b" else { return nil }

        let queryGuid = components.queryItems?.first(where: {
            ($0.name == "guid" || $0.name == "billId") && ($0.value?.isEmpty == false)
        })?.value?.trimmingCharacters(in: .whitespacesAndNewlines)

        if let queryGuid, !queryGuid.isEmpty {
            return queryGuid
        }

        return guidFromPath(path: components.path, allowSingleSegment: true)
    }

    nonisolated private static func guidFromPath(path: String, allowSingleSegment: Bool) -> String? {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { return nil }

        let tokens = trimmedPath
            .split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty }

        if tokens.count == 2, (tokens[0].lowercased() == "b" || tokens[0].lowercased() == "bill") {
            let guid = tokens[1].trimmingCharacters(in: .whitespacesAndNewlines)
            return guid.isEmpty ? nil : guid
        }

        if allowSingleSegment, tokens.count == 1 {
            let guid = tokens[0].trimmingCharacters(in: .whitespacesAndNewlines)
            return guid.isEmpty ? nil : guid
        }

        return nil
    }
}
