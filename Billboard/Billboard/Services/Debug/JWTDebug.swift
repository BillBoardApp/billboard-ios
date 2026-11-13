#if DEBUG
import Foundation

/// DEBUG-only: prints non-secret JWT claims (issuer, token_use, audience, expiry)
/// once per process to diagnose authorizer mismatches. Never prints the token.
enum JWTDebug {
    private static var didLogOnce = false

    /// Logs minimal, non-sensitive JWT metadata (issuer/token_use/aud/client_id/exp) once per process.
    static func logTokensOnce(accessToken: String, idToken: String) {
        guard !didLogOnce else { return }
        didLogOnce = true

        let access = describe(jwt: accessToken)
        let id = describe(jwt: idToken)
        print("[JWTDebug] access: \(access)")
        print("[JWTDebug] id: \(id)")
    }

    static func describe(jwt: String) -> String {
        guard let payload = decodePayload(jwt) else { return "<unparseable>" }

        func s(_ key: String) -> String? {
            if let v = payload[key] as? String { return v }
            return nil
        }

        func i(_ key: String) -> Int? {
            if let v = payload[key] as? Int { return v }
            if let v = payload[key] as? Double { return Int(v) }
            return nil
        }

        let iss = s("iss") ?? "?"
        let tokenUse = s("token_use") ?? "?"
        let aud = s("aud") ?? s("client_id") ?? "?"
        let exp = i("exp").map(String.init) ?? "?"

        // Only return the most useful fields for diagnosing authorizer mismatches.
        return "iss=\(iss) token_use=\(tokenUse) aud/client_id=\(aud) exp=\(exp)"
    }

    private static func decodePayload(_ jwt: String) -> [String: Any]? {
        // JWT: header.payload.signature (base64url)
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        return decodeBase64UrlJSON(String(parts[1]))
    }

    private static func decodeBase64UrlJSON(_ base64Url: String) -> [String: Any]? {
        var s = base64Url
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        // Pad to multiple of 4.
        let pad = 4 - (s.count % 4)
        if pad < 4 {
            s += String(repeating: "=", count: pad)
        }

        guard let data = Data(base64Encoded: s) else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: data, options: []) else { return nil }
        return obj as? [String: Any]
    }
}
#endif
