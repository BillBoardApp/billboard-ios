import Foundation

enum WeeklyDigestService {
    private enum Paths {
        static let latest = "weekly-digests/latest"
    }

    static func fetchLatest() async throws -> WeeklyDigest? {
        let data = try await APIClient.current.payload(
            .get,
            Paths.latest,
            label: "WeeklyDigestService latest"
        )
        return try decodeLatest(from: data)
    }

    /// The digest in a `GET /weekly-digests/latest` payload (contract shape first, then
    /// the legacy shapes), or nil for an empty payload.
    private static func decodeLatest(from data: Data) throws -> WeeklyDigest? {
        guard !data.isEmpty else { return nil }

        if let digest = decodeContractDigest(from: data) {
            return digest
        }

        if let digest = decodeLegacyDigest(from: data) {
            return digest
        }

        logContractDecodeFailure(from: data)
        throw APIServiceError.invalidPayload(Paths.latest)
    }

    private static func decodeContractDigest(from data: Data) -> WeeklyDigest? {
        let decoder = JSONDecoder.convertingFromSnakeCase()

        if let dto = try? decoder.decode(UserAPIContractsV1.WeeklyDigest.self, from: data),
           let digest = try? WeeklyDigest(dto: dto) {
            return digest
        }

        return nil
    }

    /// No known shape matched: log why the contract shape did not decode or map.
    private static func logContractDecodeFailure(from data: Data) {
        let decoder = JSONDecoder.convertingFromSnakeCase()

        let label = "WeeklyDigestService latest"
        guard let dto = try? APIDecoding.decode(UserAPIContractsV1.WeeklyDigest.self, from: data, decoder: decoder, label: label) else {
            return
        }
        do {
            _ = try WeeklyDigest(dto: dto)
        } catch {
            AppLog.decodingFailure(error, decoding: WeeklyDigest.self, label: label)
        }
    }

    private static func decodeLegacyDigest(from data: Data) -> WeeklyDigest? {
        let decoder = JSONDecoder.convertingFromSnakeCase(dates: .iso8601)

        if let digest = try? decoder.decode(WeeklyDigest.self, from: data) {
            return digest
        }

        if let envelope = try? decoder.decode(LegacyDigestEnvelope.self, from: data) {
            return envelope.digest
        }

        if let envelope = try? decoder.decode(LegacyDigestsEnvelope.self, from: data) {
            return envelope.items.first
        }

        return nil
    }

    private struct LegacyDigestEnvelope: Decodable {
        let digest: WeeklyDigest
    }

    private struct LegacyDigestsEnvelope: Decodable {
        let items: [WeeklyDigest]
    }
}
