# Third-party notices

Billboard's own code is licensed as stated in [LICENSE](LICENSE). This file lists the third-party material the
project depends on or ships, with what is known about its licence. It is not legal advice.

## Swift packages

The app target declares one package, `amplify-swift`, and links its products `Amplify`, `AWSAPIPlugin`, `AWSCognitoAuthPlugin`. Swift Package Manager resolves the rest of the list below as their dependencies; only seven of
them are linked into the app (see [In the app](#in-the-app)). The list is every pin in `BillBoard.xcworkspace/xcshareddata/swiftpm/Package.resolved` (34 packages). Nothing is vendored in this repository: Xcode downloads each package from its own
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
| `swift-nio` | 2.100.0 | Apache-2.0 | <https://github.com/apple/swift-nio> | ships a NOTICE file |
| `swift-nio-extras` | 1.34.1 | Apache-2.0 | <https://github.com/apple/swift-nio-extras> | ships a NOTICE file |
| `swift-nio-http2` | 1.44.0 | Apache-2.0 | <https://github.com/apple/swift-nio-http2> | ships a NOTICE file |
| `swift-nio-ssl` | 2.36.0 | Apache-2.0 | <https://github.com/apple/swift-nio-ssl> | ships a NOTICE file |
| `swift-nio-transport-services` | 1.26.0 | Apache-2.0 | <https://github.com/apple/swift-nio-transport-services> |  |
| `swift-numerics` | 1.1.1 | Apache-2.0 WITH Swift-exception | <https://github.com/apple/swift-numerics> |  |
| `swift-protobuf` | 1.33.3 | Apache-2.0 WITH Swift-exception | <https://github.com/apple/swift-protobuf> |  |
| `swift-service-context` | 1.2.1 | Apache-2.0 | <https://github.com/apple/swift-service-context> | ships a NOTICE file |
| `swift-service-lifecycle` | 2.9.1 | Apache-2.0 | <https://github.com/swift-server/swift-service-lifecycle> | ships a NOTICE file |
| `swift-system` | 1.6.3 | Apache-2.0 WITH Swift-exception | <https://github.com/apple/swift-system> |  |
| `thrift-swift` | 1.1.2 | Apache-2.0 | <https://github.com/undefinedlabs/Thrift-Swift> | licence read from source-file headers (the package ships no LICENSE file) |

Apache-2.0: <https://www.apache.org/licenses/LICENSE-2.0>. MIT: the text in the package's own LICENSE file.

## In the app

The app shows these notices on its **Open-source licenses** screen (About Billboard). Seven packages are linked into
the app; the other 27 pins above are resolved only for targets the app does not link (Amplify's DataStore, Storage and
push notifications, smithy-swift's SwiftNIO client, opentelemetry-swift's gRPC and other exporters). Some parts of the
linked packages are not in the app either: aws-crt-swift's command-line tools, and the s2n-tls and AWS-LC libraries
bundled inside aws-crt-swift, which are built only on Linux (see the notes under the table).

The table below drives the screen. `scripts/generate-open-source-licenses.sh` reads it and, for each row, the listed
files from the package at its pinned revision (and any linked file from `licenses/`), and writes them to
`Billboard/Billboard/Resources/OpenSourceLicenses.json`, which the app bundles. That file is checked in, so a build
needs no network and no build script. `./scripts/generate-open-source-licenses.sh --check` (a step of
`scripts/test.sh`) needs no package checkouts: it fails when the file was not regenerated after a change to this
table, to a pin of a package in it, to the package products the app target links (in `project.pbxproj`), to the
repository's `NOTICE` or `LICENSE`, or to a file in `licenses/` that the table links, and when the file was edited by
hand.

- **Part**: a library bundled inside the package (empty for the package itself).
- **Notice**: NOTICE files, shown whole.
- **Licence text**: licence files, shown whole. A source file here means the licence comment at its top (a block with
  a copyright line, other than a one-line SPDX header). A link is a file in this repository's `licenses/` folder: the
  full text of a licence that the package names but does not include.
- **Copyright lines from**: the source folders of the targets the app links; the screen lists each distinct copyright
  line found at the top of their files.

The set was worked out from the package manifests at the pinned revisions: the targets that the app's three Amplify
products depend on when built for iOS. It matches the package objects a simulator build links (the app target's
`Billboard.LinkFileList`, checked on 2026-11-22). When a pin changes, or a package product is added to or removed
from the app target, check that set again (that file, or a Release build with `LD_GENERATE_MAP_FILE=YES`), update this
table and the one above, and run the generator.

<!-- open-source-licenses:begin -->
| Package | Part | Licence (SPDX) | Notice | Licence text | Copyright lines from |
|---|---|---|---|---|---|
| `amplify-swift` | | Apache-2.0 | `NOTICE` | `LICENSE` | `Amplify`, `AmplifyPlugins/Core/AWSPluginsCore`, `AmplifyPlugins/Core/AmplifyCredentials`, `AmplifyPlugins/API/Sources/AWSAPIPlugin`, `AmplifyPlugins/Auth/Sources/AmplifyAvailability`, `AmplifyPlugins/Auth/Sources/AmplifyBigInteger`, `AmplifyPlugins/Auth/Sources/AmplifySRP`, `AmplifyPlugins/Auth/Sources/AWSCognitoAuthPlugin` |
| `amplify-swift` | libtommath | Unlicense | | `AmplifyPlugins/Auth/Sources/libtommath/LICENSE` | `AmplifyPlugins/Auth/Sources/libtommath` |
| `amplify-swift` | Reachability.swift | BSD-2-Clause | | `AmplifyPlugins/API/Sources/AWSAPIPlugin/Reachability/AmplifyReachability.swift` | |
| `aws-crt-swift` | | Apache-2.0 | `NOTICE` | `LICENSE` | `Source/AwsCommonRuntimeKit` |
| `aws-crt-swift` | aws-c-auth | Apache-2.0 | `aws-common-runtime/aws-c-auth/NOTICE` | `aws-common-runtime/aws-c-auth/LICENSE` | `aws-common-runtime/aws-c-auth/include`, `aws-common-runtime/aws-c-auth/source` |
| `aws-crt-swift` | aws-c-cal | Apache-2.0 | `aws-common-runtime/aws-c-cal/NOTICE` | `aws-common-runtime/aws-c-cal/LICENSE` | `aws-common-runtime/aws-c-cal/include`, `aws-common-runtime/aws-c-cal/source` |
| `aws-crt-swift` | aws-c-cal | APSL-2.0 | | `aws-common-runtime/aws-c-cal/source/darwin/common_cryptor_spi.h` | |
| `aws-crt-swift` | aws-c-common | Apache-2.0 | `aws-common-runtime/aws-c-common/NOTICE` | `aws-common-runtime/aws-c-common/LICENSE` | `aws-common-runtime/aws-c-common/include`, `aws-common-runtime/aws-c-common/source` |
| `aws-crt-swift` | aws-c-common | BSD-3-Clause AND MIT | | `aws-common-runtime/aws-c-common/THIRD-PARTY-LICENSES.txt` | |
| `aws-crt-swift` | aws-c-common | BSD-3-Clause | | `aws-common-runtime/aws-c-common/source/posix/time.c` | |
| `aws-crt-swift` | aws-c-compression | Apache-2.0 | `aws-common-runtime/aws-c-compression/NOTICE` | `aws-common-runtime/aws-c-compression/LICENSE` | `aws-common-runtime/aws-c-compression/include`, `aws-common-runtime/aws-c-compression/source` |
| `aws-crt-swift` | aws-c-event-stream | Apache-2.0 | `aws-common-runtime/aws-c-event-stream/NOTICE` | `aws-common-runtime/aws-c-event-stream/LICENSE` | `aws-common-runtime/aws-c-event-stream/include`, `aws-common-runtime/aws-c-event-stream/source` |
| `aws-crt-swift` | aws-c-http | Apache-2.0 | `aws-common-runtime/aws-c-http/NOTICE` | `aws-common-runtime/aws-c-http/LICENSE` | `aws-common-runtime/aws-c-http/include`, `aws-common-runtime/aws-c-http/source` |
| `aws-crt-swift` | aws-c-io | Apache-2.0 | `aws-common-runtime/aws-c-io/NOTICE` | `aws-common-runtime/aws-c-io/LICENSE` | `aws-common-runtime/aws-c-io/include`, `aws-common-runtime/aws-c-io/source` |
| `aws-crt-swift` | aws-c-mqtt | Apache-2.0 | `aws-common-runtime/aws-c-mqtt/NOTICE` | `aws-common-runtime/aws-c-mqtt/LICENSE` | `aws-common-runtime/aws-c-mqtt/include`, `aws-common-runtime/aws-c-mqtt/source` |
| `aws-crt-swift` | aws-c-sdkutils | Apache-2.0 | `aws-common-runtime/aws-c-sdkutils/NOTICE` | `aws-common-runtime/aws-c-sdkutils/LICENSE` | `aws-common-runtime/aws-c-sdkutils/include`, `aws-common-runtime/aws-c-sdkutils/source` |
| `aws-crt-swift` | aws-checksums | Apache-2.0 | | `aws-common-runtime/aws-checksums/LICENSE` | `aws-common-runtime/aws-checksums/include`, `aws-common-runtime/aws-checksums/source` |
| `aws-sdk-swift` | | Apache-2.0 | `NOTICE` | `LICENSE` | `Sources/Core`, `Sources/Services/AWSCognitoIdentity`, `Sources/Services/AWSCognitoIdentityProvider` |
| `opentelemetry-swift` | | Apache-2.0 | | `LICENSE` | `Sources/OpenTelemetryApi`, `Sources/OpenTelemetrySdk`, `Sources/Exporters/InMemory`, `Sources/Exporters/OpenTelemetryProtocolCommon`, `Sources/Exporters/OpenTelemetryProtocolHttp`, `Sources/Exporters/DataCompression` |
| `smithy-swift` | | Apache-2.0 | `NOTICE` | `LICENSE` | `Sources` |
| `swift-log` | | Apache-2.0 | `NOTICE.txt` | `LICENSE.txt` | `Sources/Logging` |
| `swift-protobuf` | | Apache-2.0 WITH Swift-exception | | `LICENSE.txt` | `Sources/SwiftProtobuf` |
| `swift-protobuf` | | BSD-3-Clause | | `Sources/SwiftProtobuf/descriptor.pb.swift` | |
<!-- open-source-licenses:end -->

Notes on the table:

- `aws-crt-swift` builds ten of its bundled C libraries for iOS; s2n-tls and AWS-LC are built only on Linux.
  `aws-c-common` also bundles cJSON, libcbor and an Intel header, under the licences in its
  `THIRD-PARTY-LICENSES.txt`, and one file (`source/posix/time.c`) carries a BSD-3-Clause notice.
- `amplify-swift`'s API plugin includes a copy of Reachability.swift under BSD-2-Clause.
- `swift-protobuf`'s generated Google well-known types (`*.pb.swift` in `Sources/SwiftProtobuf`) carry the Protocol
  Buffers BSD-3-Clause notice; one of them is listed, as the notice is the same in each.
- `opentelemetry-swift`'s `DataCompression` file carries its own copyright line, which the screen lists.

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
