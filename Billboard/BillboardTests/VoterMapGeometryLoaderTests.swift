import XCTest
@testable import Billboard

final class VoterMapGeometryLoaderTests: XCTestCase {
    func testDecodeGeometryFromInlinePayload() throws {
        let json = """
        {
          "version": 1,
          "canvas": { "width": 100, "height": 50 },
          "features": [
            {
              "id": "CA",
              "label": "CA",
              "polygons": [
                {
                  "rings": [
                    [[0,0],[10,0],[10,10],[0,10]]
                  ]
                }
              ],
              "bbox": { "minX": 0, "minY": 0, "maxX": 10, "maxY": 10 }
            }
          ]
        }
        """

        let data = Data(json.utf8)
        let decoded = try VoterMapGeometryLoader.decodeGeometry(from: data)

        XCTAssertEqual(decoded.version, 1)
        XCTAssertEqual(decoded.features.count, 1)
        XCTAssertEqual(decoded.features.first?.id, "CA")
    }

    func testDecodeGeometryInvalidPayloadThrows() {
        let data = Data("{\"bad\":true}".utf8)
        XCTAssertThrowsError(try VoterMapGeometryLoader.decodeGeometry(from: data)) { error in
            guard case VoterMapGeometryLoader.LoadError.invalidPayload = error else {
                XCTFail("Expected invalidPayload error, got \(error)")
                return
            }
        }
    }

    func testDistrictGeometryMissingResourceThrows() async {
        do {
            _ = try await VoterMapGeometryLoader.shared.districtGeometry(stateCode: "ZZ")
            XCTFail("Expected missing resource error")
        } catch let error as VoterMapGeometryLoader.LoadError {
            guard case .missingResource = error else {
                XCTFail("Expected missingResource error, got \(error)")
                return
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testNationalAndStateGeometryAssetsLoad() async throws {
        let national = try await VoterMapGeometryLoader.shared.nationalGeometry()
        XCTAssertFalse(national.features.isEmpty)
        XCTAssertTrue(national.features.contains(where: { $0.id == "CA" }))

        let californiaDistricts = try await VoterMapGeometryLoader.shared.districtGeometry(stateCode: "CA")
        XCTAssertTrue(californiaDistricts.features.contains(where: { $0.id == "CA-01" }))
        XCTAssertTrue(californiaDistricts.features.contains(where: { $0.id == "CA-52" }))
    }

    func testFeatureBoundsCoverAllFeatures() throws {
        let json = """
        {
          "version": 1,
          "canvas": { "width": 100, "height": 50 },
          "features": [
            {
              "id": "CA",
              "label": "CA",
              "polygons": [
                {
                  "rings": [
                    [[10,10],[20,10],[20,20],[10,20]]
                  ]
                }
              ],
              "bbox": { "minX": 10, "minY": 10, "maxX": 20, "maxY": 20 }
            },
            {
              "id": "NV",
              "label": "NV",
              "polygons": [
                {
                  "rings": [
                    [[30,5],[40,5],[40,25],[30,25]]
                  ]
                }
              ],
              "bbox": { "minX": 30, "minY": 5, "maxX": 40, "maxY": 25 }
            }
          ]
        }
        """

        let data = Data(json.utf8)
        let decoded = try VoterMapGeometryLoader.decodeGeometry(from: data)

        XCTAssertEqual(decoded.featureBounds.minX, 10)
        XCTAssertEqual(decoded.featureBounds.minY, 5)
        XCTAssertEqual(decoded.featureBounds.maxX, 40)
        XCTAssertEqual(decoded.featureBounds.maxY, 25)
    }
}
