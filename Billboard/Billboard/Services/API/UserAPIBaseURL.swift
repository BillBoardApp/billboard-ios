import Foundation

enum UserAPIBaseURL {
    enum UserAPIBaseURLError: LocalizedError {
        case missingAmplifyConfiguration
        case invalidAmplifyConfiguration
        case missingEndpoint
        case invalidEndpoint(String)

        var errorDescription: String? {
            switch self {
            case .missingAmplifyConfiguration:
                return "Missing amplifyconfiguration.json in app bundle."
            case .invalidAmplifyConfiguration:
                return "Unable to parse amplifyconfiguration.json."
            case .missingEndpoint:
                return "Missing API endpoint for configured Amplify REST API."
            case .invalidEndpoint(let raw):
                return "Invalid API endpoint URL: \(raw)"
            }
        }
    }

    /// Returns the REST API base URL configured in `amplifyconfiguration.json` (apiName: `myapi`).
    static func resolve() throws -> URL {
        guard let url = Bundle.main.url(forResource: "amplifyconfiguration", withExtension: "json") else {
            throw UserAPIBaseURLError.missingAmplifyConfiguration
        }
        let data = try Data(contentsOf: url)
        let obj = try JSONSerialization.jsonObject(with: data)
        guard let json = obj as? [String: Any] else {
            throw UserAPIBaseURLError.invalidAmplifyConfiguration
        }

        // api.plugins.awsAPIPlugin.myapi.endpoint
        let api = (json["api"] as? [String: Any])
        let plugins = (api?["plugins"] as? [String: Any])
        let apiPlugin = (plugins?["awsAPIPlugin"] as? [String: Any])
        let myapi = (apiPlugin?["myapi"] as? [String: Any])
        let endpoint = (myapi?["endpoint"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let endpoint, !endpoint.isEmpty else {
            throw UserAPIBaseURLError.missingEndpoint
        }

        guard let baseURL = URL(string: endpoint) else {
            throw UserAPIBaseURLError.invalidEndpoint(endpoint)
        }

        return baseURL
    }
}
