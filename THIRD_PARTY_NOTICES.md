# Third-party notices

Billboard's own code is licensed as stated in [LICENSE](LICENSE). This file lists the third-party material the
project depends on or ships, with what is known about its licence. It is not legal advice.

## Swift packages

The app target declares one package, `amplify-swift`, and links its products `Amplify`, `AWSAPIPlugin`, `AWSCognitoAuthPlugin`. Swift Package Manager resolves the rest of the list below as their dependencies (some may not be linked into
the app). The list is every pin in `BillBoard.xcworkspace/xcshareddata/swiftpm/Package.resolved` (34 packages). Nothing is vendored in this repository: Xcode downloads each package from its own
repository, which carries its licence text and any NOTICE file.

Licence identifiers were read from each package's own LICENSE file at the pinned revision. `Apache-2.0 WITH Swift-exception` marks a package whose licence adds the Swift Runtime Library Exception.

| Package | Version | Licence (SPDX) | Source | Notes |
|---|---|---|---|---|
| `amplify-swift` | 2.53.2 | Apache-2.0 | <https://github.com/aws-amplify/amplify-swift> | ships a NOTICE file |
| `amplify-swift-utils-notifications` | 1.1.1 | Apache-2.0 | <https://github.com/aws-amplify/amplify-swift-utils-notifications> | ships a NOTICE file |
| `async-http-client` | 1.30.2 | Apache-2.0 | <https://github.com/swift-server/async-http-client> | ships a NOTICE file |
| `aws-crt-swift` | 0.54.2 | Apache-2.0 | <https://github.com/awslabs/aws-crt-swift> | ships a NOTICE file |
| `aws-sdk-swift` | 1.6.7 | Apache-2.0 | <https://github.com/awslabs/aws-sdk-swift> | ships a NOTICE file |
| `grpc-swift` | 1.26.1 | Apache-2.0 | <https://github.com/grpc/grpc-swift> | ships a NOTICE file |
| `opentelemetry-swift` | 1.17.1 | Apache-2.0 | <https://github.com/open-telemetry/opentelemetry-swift> |  |
| `opentracing-objc` | 0.5.2 | MIT | <https://github.com/undefinedlabs/opentracing-objc> |  |
| `smithy-swift` | 0.175.0 | Apache-2.0 | <https://github.com/smithy-lang/smithy-swift> | ships a NOTICE file |
| `sqlite.swift` | 0.15.3 | MIT | <https://github.com/stephencelis/SQLite.swift> |  |
| `swift-algorithms` | 1.2.1 | Apache-2.0 WITH Swift-exception | <https://github.com/apple/swift-algorithms> |  |
| `swift-argument-parser` | 1.7.0 | Apache-2.0 WITH Swift-exception | <https://github.com/apple/swift-argument-parser> |  |
| `swift-asn1` | 1.5.1 | Apache-2.0 | <https://github.com/apple/swift-asn1> | ships a NOTICE file |
| `swift-async-algorithms` | 1.1.1 | Apache-2.0 WITH Swift-exception | <https://github.com/apple/swift-async-algorithms> |  |
| `swift-atomics` | 1.3.0 | Apache-2.0 WITH Swift-exception | <https://github.com/apple/swift-atomics> |  |
| `swift-certificates` | 1.17.0 | Apache-2.0 | <https://github.com/apple/swift-certificates> | ships a NOTICE file |
| `swift-collections` | 1.3.0 | Apache-2.0 WITH Swift-exception | <https://github.com/apple/swift-collections> |  |
| `swift-crypto` | 4.2.0 | Apache-2.0 | <https://github.com/apple/swift-crypto> | ships a NOTICE file |
| `swift-distributed-tracing` | 1.3.1 | Apache-2.0 | <https://github.com/apple/swift-distributed-tracing> |  |
| `swift-http-structured-headers` | 1.6.0 | Apache-2.0 | <https://github.com/apple/swift-http-structured-headers> |  |
| `swift-http-types` | 1.5.1 | Apache-2.0 | <https://github.com/apple/swift-http-types> | ships a NOTICE file |
| `swift-log` | 1.8.0 | Apache-2.0 | <https://github.com/apple/swift-log> | ships a NOTICE file |
| `swift-metrics` | 2.7.1 | Apache-2.0 | <https://github.com/apple/swift-metrics> | ships a NOTICE file |
| `swift-nio` | 2.92.1 | Apache-2.0 | <https://github.com/apple/swift-nio> | ships a NOTICE file |
| `swift-nio-extras` | 1.31.2 | Apache-2.0 | <https://github.com/apple/swift-nio-extras> | ships a NOTICE file |
| `swift-nio-http2` | 1.39.0 | Apache-2.0 | <https://github.com/apple/swift-nio-http2> | ships a NOTICE file |
| `swift-nio-ssl` | 2.36.0 | Apache-2.0 | <https://github.com/apple/swift-nio-ssl> | ships a NOTICE file |
| `swift-nio-transport-services` | 1.26.0 | Apache-2.0 | <https://github.com/apple/swift-nio-transport-services> |  |
| `swift-numerics` | 1.1.1 | Apache-2.0 WITH Swift-exception | <https://github.com/apple/swift-numerics> |  |
| `swift-protobuf` | 1.33.3 | Apache-2.0 WITH Swift-exception | <https://github.com/apple/swift-protobuf> |  |
| `swift-service-context` | 1.2.1 | Apache-2.0 | <https://github.com/apple/swift-service-context> | ships a NOTICE file |
| `swift-service-lifecycle` | 2.9.1 | Apache-2.0 | <https://github.com/swift-server/swift-service-lifecycle> | ships a NOTICE file |
| `swift-system` | 1.6.3 | Apache-2.0 WITH Swift-exception | <https://github.com/apple/swift-system> |  |
| `thrift-swift` | 1.1.2 | Apache-2.0 | <https://github.com/undefinedlabs/Thrift-Swift> | licence read from source-file headers (the package ships no LICENSE file) |

Apache-2.0: <https://www.apache.org/licenses/LICENSE-2.0>. MIT: the text in the package's own LICENSE file.

## Data in this repository

### District map geometry

`Billboard/Billboard/Resources/VoterMap` holds 52 JSON files that the vote map draws:

- `VoterMapNational.json`: the outlines of the 50 states and the District of Columbia.
- `Districts/VoterMapDistricts_<state>.json`: one file per state and for DC with its congressional-district
  outlines. There are 436 in all: the 435 House seats of the 119th Congress plus DC's delegate seat.

They were generated in March 2026 from the U.S. Census Bureau's 2024 cartographic boundary files, published at
<https://www2.census.gov/geo/tiger/GENZ2024/shp/>:

| File | Used for |
| --- | --- |
| `cb_2024_us_state_500k` | state outlines |
| `cb_2024_us_cd119_500k` | congressional districts of the 119th Congress |

The conversion kept the longitude and latitude as flat x and y and scaled them to each file's drawing canvas. It
then simplified the outlines and rounded points to 0.01. On the national map, Alaska and Hawaii are drawn in
enlarged insets, and Alaska's islands west of the 180th meridian are joined to the rest of the state. DC's
delegate district (Census code `98`) is written as `DC-AL`.

The Census Bureau's boundary files are works of the U.S. federal government and are not subject to copyright in
the United States (17 U.S.C. § 105). The source is credited here as a courtesy. The Census Bureau does not endorse
Billboard. States that adopt new House maps for the 120th Congress need their district files regenerated from a
later Census release.

## Not bundled

The app draws its text with the Apple system faces and its icons with SF Symbols, both reached by name through
system APIs. No font or symbol file is in this repository. They remain Apple's, under Apple's terms.
