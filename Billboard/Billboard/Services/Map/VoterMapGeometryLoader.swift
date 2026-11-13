import Foundation

nonisolated struct VoterMapGeometry: Decodable, Equatable {
    nonisolated struct Canvas: Decodable, Equatable {
        let width: Double
        let height: Double

        enum CodingKeys: String, CodingKey {
            case width
            case height
        }

        nonisolated init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            width = try container.decode(Double.self, forKey: .width)
            height = try container.decode(Double.self, forKey: .height)
        }
    }

    let version: Int
    let canvas: Canvas
    let features: [VoterMapFeature]

    enum CodingKeys: String, CodingKey {
        case version
        case canvas
        case features
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        canvas = try container.decode(Canvas.self, forKey: .canvas)
        features = try container.decode([VoterMapFeature].self, forKey: .features)
    }
}

nonisolated struct VoterMapFeature: Decodable, Equatable, Identifiable {
    let id: String
    let label: String
    let polygons: [VoterMapPolygon]
    let bbox: VoterMapBoundingBox

    enum CodingKeys: String, CodingKey {
        case id
        case label
        case polygons
        case bbox
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        label = try container.decode(String.self, forKey: .label)
        polygons = try container.decode([VoterMapPolygon].self, forKey: .polygons)
        bbox = try container.decode(VoterMapBoundingBox.self, forKey: .bbox)
    }
}

nonisolated struct VoterMapPolygon: Decodable, Equatable {
    let rings: [[VoterMapPoint]]

    enum CodingKeys: String, CodingKey {
        case rings
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rings = try container.decode([[VoterMapPoint]].self, forKey: .rings)
    }
}

nonisolated struct VoterMapBoundingBox: Decodable, Equatable {
    let minX: Double
    let minY: Double
    let maxX: Double
    let maxY: Double

    enum CodingKeys: String, CodingKey {
        case minX
        case minY
        case maxX
        case maxY
    }

    init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        minX = try container.decode(Double.self, forKey: .minX)
        minY = try container.decode(Double.self, forKey: .minY)
        maxX = try container.decode(Double.self, forKey: .maxX)
        maxY = try container.decode(Double.self, forKey: .maxY)
    }

    func contains(_ point: VoterMapPoint) -> Bool {
        point.x >= minX && point.x <= maxX && point.y >= minY && point.y <= maxY
    }

    var width: Double {
        maxX - minX
    }

    var height: Double {
        maxY - minY
    }
}

nonisolated struct VoterMapPoint: Decodable, Equatable {
    let x: Double
    let y: Double

    init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    nonisolated init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        x = try container.decode(Double.self)
        y = try container.decode(Double.self)
    }
}

extension VoterMapGeometry {
    nonisolated var featureBounds: VoterMapBoundingBox {
        guard let first = features.first?.bbox else {
            return VoterMapBoundingBox(minX: 0, minY: 0, maxX: canvas.width, maxY: canvas.height)
        }

        return features.dropFirst().reduce(first) { partial, feature in
            VoterMapBoundingBox(
                minX: min(partial.minX, feature.bbox.minX),
                minY: min(partial.minY, feature.bbox.minY),
                maxX: max(partial.maxX, feature.bbox.maxX),
                maxY: max(partial.maxY, feature.bbox.maxY)
            )
        }
    }
}

actor VoterMapGeometryLoader {
    enum LoadError: LocalizedError {
        case invalidStateCode
        case missingResource(String)
        case invalidPayload(String)

        var errorDescription: String? {
            switch self {
            case .invalidStateCode:
                return "Invalid state code."
            case .missingResource(let resource):
                return "Map resource not found: \(resource)"
            case .invalidPayload(let resource):
                return "Map resource is invalid: \(resource)"
            }
        }
    }

    static let shared = VoterMapGeometryLoader()

    private var cache: [String: VoterMapGeometry] = [:]

    static func normalizedStateCode(_ raw: String) -> String? {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard cleaned.count == 2 else { return nil }
        guard cleaned.range(of: "^[A-Z]{2}$", options: .regularExpression) != nil else { return nil }
        return cleaned
    }

    static func decodeGeometry(from data: Data, resourceName: String = "inline") throws -> VoterMapGeometry {
        do {
            return try JSONDecoder.usingDefaultKeys().decode(VoterMapGeometry.self, from: data)
        } catch {
            throw LoadError.invalidPayload(resourceName)
        }
    }

    func nationalGeometry() throws -> VoterMapGeometry {
        try load(
            name: "VoterMapNational",
            subdirectories: ["VoterMap", "Resources/VoterMap", nil]
        )
    }

    func districtGeometry(stateCode: String) throws -> VoterMapGeometry {
        guard let stateCode = Self.normalizedStateCode(stateCode) else {
            throw LoadError.invalidStateCode
        }
        return try load(
            name: "VoterMapDistricts_\(stateCode)",
            subdirectories: ["VoterMap/Districts", "Resources/VoterMap/Districts", "Districts", nil]
        )
    }

    private func load(name: String, subdirectories: [String?]) throws -> VoterMapGeometry {
        let cacheKey = "\(name)|\(subdirectories.map { $0 ?? "<root>" }.joined(separator: ","))"
        if let cached = cache[cacheKey] {
            return cached
        }

        let bundles = [Bundle.main, Bundle(for: BundleToken.self)]

        for bundle in bundles {
            for subdirectory in subdirectories {
                if let url = bundle.url(forResource: name, withExtension: "json", subdirectory: subdirectory) {
                    do {
                        let data = try Data(contentsOf: url)
                        let decoded = try Self.decodeGeometry(from: data, resourceName: cacheKey)
                        cache[cacheKey] = decoded
                        return decoded
                    } catch let loadError as LoadError {
                        throw loadError
                    } catch {
                        throw LoadError.invalidPayload(cacheKey)
                    }
                }
            }
        }

        throw LoadError.missingResource(cacheKey)
    }
}

private final class BundleToken {}
