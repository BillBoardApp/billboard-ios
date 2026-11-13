# Billboard (iOS app)

Billboard is an iOS app for following bills in the U.S. Congress and recording how you would vote on them. It is an
independent project and is not affiliated with Congress or any government agency.

This repository, `billboard-ios`, is the app: SwiftUI, workspace `BillBoard.xcworkspace`, scheme `Billboard`. It signs
in with Amazon Cognito through Amplify and talks to the Billboard user API. The backend, the wire contracts and the
share website live in a second repository, `billboard-backend`. Clone the two side by side:

```text
<any folder>/
  billboard-ios/        this repository
  billboard-backend/    contracts/, services/, infra/, website/
```

## Licence

The code is licensed under the Apache License 2.0 ([LICENSE](LICENSE)). The Billboard name and logos are not; see
[TRADEMARKS.md](TRADEMARKS.md). Third-party software and data keep their own licences:
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

Contributions: [CONTRIBUTING.md](CONTRIBUTING.md). Security reports: [SECURITY.md](SECURITY.md). Code of conduct:
[CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).

## Requirements

- Xcode 27.2, with the iOS 27.2 simulator runtime and an iPhone 17 simulator: the repository's CI and the project's
  gate use exactly these. The app targets iOS 26.0. Install runtimes in Xcode > Settings > Components, and list
  simulators with `xcrun simctl list devices available`.
- Swift packages (Amplify) resolve on the first build from `BillBoard.xcworkspace/xcshareddata/swiftpm/Package.resolved`.
- Optional: `bundle install` once, for `xcpretty` (from the `Gemfile`). Without it, drop `| xcpretty` from the commands.
- `../billboard-backend`, for the API contract check (see "Contracts").

## Build and unit tests

From the repository root. Unit tests need no credentials and no network:

```bash
xcodebuild -workspace BillBoard.xcworkspace -scheme Billboard -configuration Debug \
  -destination 'generic/platform=iOS Simulator' build | xcpretty
xcodebuild -workspace BillBoard.xcworkspace -scheme Billboard -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:BillboardTests \
  -parallel-testing-enabled NO test | xcpretty
```

Change `name=iPhone 17` to any simulator you have (or use `id=<UDID>`). Keep `-only-testing:BillboardTests`: without
it the scheme also runs `BillboardUITests`, whose signed-in journeys are skipped when no login is set.

`./scripts/test.sh` is the local gate to run before a pull request: the contract check, the UI rules and the unit
tests (`--release` adds a Release build for the simulator; `DESTINATION=` picks the simulator). The build must have no
warnings. The CI workflow (`.github/workflows/ci.yml`) runs the same gate on every pull request and fails on any
compiler warning. Its commit-safety job checks the pull request's new commits: no secrets (gitleaks, with
`.gitleaks.toml`), and only the author, committer and trailer addresses that CONTRIBUTING.md allows.

Screens are checked by render tests (`*RenderTests`, drawn with `ImageRenderer` in light and dark at the default and
an accessibility text size) and snapshot tests (`*SnapshotTests`, drawn through UIKit, so scroll views, text fields and
toggles show as on a device). Both attach PNGs to the test result. To look at them, keep the gate's result bundle
and export its attachments:

```bash
RESULTS_DIR=/tmp/billboard-results ./scripts/test.sh
xcrun xcresulttool export attachments --path /tmp/billboard-results/UnitTests.xcresult --output-path /tmp/renders
```

## Contracts

`Billboard/Billboard/Domain/Contracts/UserAPIContractsV1.swift` is a copy of
`contracts/generated/swift/UserAPIContractsV1.swift` in `billboard-backend`, which is generated from the JSON
schemas there. Never edit the copy by hand.

```bash
./scripts/syncContracts.sh           # copy it from ../billboard-backend/contracts
./scripts/syncContracts.sh --check   # exit 1 if the app copy differs (drift)
```

Set `BILLBOARD_CONTRACTS_ROOT=/path/to/contracts` to read a checkout in another place. CI checks the copy against the
default branch of `billboard-backend`.

## Backend configuration

- `Billboard/Billboard/amplifyconfiguration.json` holds the Cognito user pool ID, the app client ID and the user API
  endpoint the app talks to. They ship inside every release of the app; none of them is a secret. The bundled file
  points at the project's own backend, so a build from this tree talks to it; a fork should point it at its own
  deployment: deploy `billboard-backend` in your own AWS account and replace the values with the stack outputs
  `UserPoolId`, `UserPoolClientId` and `UserApiUrl`. CONTRIBUTING.md, "Running your own build", says more.
- `WEBSITE_BASE_URL` in `Billboard/Info.plist` builds the About screen's Roadmap and Privacy policy links.
- Every request to the user API carries `X-Billboard-App-Version` (the app's version). Votes and sign-ups also carry an
  App Attest assertion made with a key kept per install in the Keychain (`Services/Security/AppAttestManager.swift`).
  A `426` with `APP_UPDATE_REQUIRED` shows an "Update Billboard" alert.
- `SHARE_SITE_BASE_URL` in `Billboard/Info.plist` builds share links: `<SHARE_SITE_BASE_URL>/b/{guid}`. The app's deep
  link is `billboard://bill?guid={guid}`, and it accepts only that scheme and the share host, with a validated guid.
  A link or push to a bill the app has not loaded fetches it from `GET /processed-bill`; the screen says "Bill not
  found" only when that answers 404.

## Scripts

| Script | What it does | Touches the hosted service |
|---|---|---|
| `scripts/test.sh [--release] [--no-tests]` | Local gate: contract check, UI rules, unit tests (and a Release simulator build with `--release`); exit 1 if any step fails | no |
| `scripts/check-ui-rules.sh [--summary] [PATH...]` | Checks the Swift sources for colours outside the theme tokens, forced light mode, words the app's glossary rules out ("Subscribe", "Dismiss", "BillBoard"...), and the visual rules: type roles only (no rounded, raw-size or stray New York text), continuous corners, brand teal only on navy, party and status colours only in their badge and stamp, a vote colour always with its symbol; every finding fails; exceptions in `scripts/ui-rules-allowlist.txt` | no |
| `scripts/check-ui-rules-selftest.sh` | Runs `check-ui-rules.sh` on small fixtures and checks what its subtler rules report and its exits; part of `test.sh` | no |
| `scripts/syncContracts.sh [--check]` | Copies or compares the Swift contract | no |
| `scripts/ci/check-commit-identities.sh <range>` | The CI's identity check: fails unless every commit in the range has only allowed author, committer and trailer addresses (GitHub noreply addresses, the project address, GitHub itself and the AI coding agent's co-author address); run it on `origin/main..HEAD` before you open a pull request | no |
| `scripts/ci/install-gitleaks.sh <dir>` | The CI's gitleaks install: the pinned release, SHA-256 checked (Linux x64) | no |
| `scripts/run-ui-smoke-tests.sh` | For the project's maintainers: runs `BillboardUITests` with the smoke-test login from `BB_UI_TEST_EMAIL` and `BB_UI_TEST_PASSWORD` in the environment (a git-ignored `.env.ui-tests` is also read when present). It stops with a message when no login is set | **yes**: signs in to the hosted service and changes that account's votes, one followed topic (put back) and one followed senator (put back) |
| `scripts/reset-ui-smoke-user-votes.sh` | For the project's maintainers: resets the smoke-test account's recent votes to `Abstain`; a dry run unless `DRY_RUN=0`; needs `AWS_PROFILE` and `ALLOWED_ACCOUNT_ID`, and refuses any account but `ALLOWED_ACCOUNT_ID` | **yes**: writes the hosted service's votes table |

## UI tests

`BillboardUITests` has two kinds of test. The signed-in journeys (bills, Updates and Congress; vote Yea then Change to
Nay; swipe to skip then Undo; edit followed topics in Profile) need a login for the project's backend, which only the
maintainers hold, so they are skipped when none is set. The signed-out ones (`testSignedOut…`) need no account and
send nothing; they are skipped when the simulator already holds a session.

No CI workflow holds the smoke-test login. The UI tests read `BB_UI_TEST_EMAIL` and `BB_UI_TEST_PASSWORD` from the
test runner's environment; xcodebuild forwards only variables prefixed with `TEST_RUNNER_`, so the smoke-test runner
exports `TEST_RUNNER_BB_UI_TEST_EMAIL` and `TEST_RUNNER_BB_UI_TEST_PASSWORD`. Nothing is written to disk.

## Releases

App Store and TestFlight builds are made by the project's maintainers: they start the Xcode Cloud workflow by hand on
`main`. A version is submitted to the App Store only after the server changes it needs are live in
`billboard-backend`. Versions 1.1 and 1.2 were built from the project's earlier private repository; release tags in
this repository start with the first version built from it.

## Reading the source

Comments and tests cite tracker and spec IDs, for example `UX-29`, `REL-53`, `INT-06`, `spec D 2.8.4` or `C3 3.10`.
They refer to the project's internal design notes, which are not public. The comment beside each one normally says what
the rule is. [docs/README.md](docs/README.md) explains the prefixes.

## Congress member civic profile

Member profiles (House and Senate) show a civic-profile radar chart from `GET /congress-member-civic-profile?bioguideId={id}`.
When the profile cannot be loaded, the card says official vote data is not available.
