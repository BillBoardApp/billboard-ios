import Foundation

/// The app's JSON decoders, one factory per key strategy. API responses and on-device
/// caches take a decoder from here instead of configuring their own.
extension JSONDecoder {
    /// Keys are matched as written (`.useDefaultKeys`).
    nonisolated static func usingDefaultKeys(
        dates: DateDecodingStrategy = .deferredToDate
    ) -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = dates
        return decoder
    }

    /// snake_case keys are converted to camelCase before matching
    /// (`.convertFromSnakeCase`); camelCase keys still match.
    nonisolated static func convertingFromSnakeCase(
        dates: DateDecodingStrategy = .deferredToDate
    ) -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = dates
        return decoder
    }
}
