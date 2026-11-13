# Contributing to Billboard (iOS app)

Thank you for helping. This repository, `billboard-ios`, is Billboard's iOS app. The backend, the wire contracts and
the website are in the `billboard-backend` repository, cloned next to this one; the app reads its Swift API contract
from `../billboard-backend/contracts`. Requirements and commands are in [README.md](README.md). Everyone who takes part
follows the [code of conduct](CODE_OF_CONDUCT.md).

## Licence of contributions

Both Billboard repositories are under the [Apache License 2.0](LICENSE). Under its section 5, anything you submit for
inclusion is under that same licence, with no extra terms. The project does not accept contributions under other
terms. There is no contributor licence agreement and no sign-off line to add.

The copyright line in [NOTICE](NOTICE) reads "The Billboard Authors". That means everyone who has contributed to
Billboard. You keep the copyright in your contribution, and git history is the record of who did what. The project
keeps no list of names: there is no AUTHORS file, and the project's docs and release notes name no one.

Please do not add copyright headers or author lines to files you write. Keep any header that third-party code
already carries.

Your commit name and email address become part of the public history. Commit with your GitHub noreply address
(GitHub Settings > Emails). The pull request checks reject other addresses.

The licence does not cover the Billboard name and logos. See [TRADEMARKS.md](TRADEMARKS.md).

## Branches and pull requests

- Fork the repository, branch from an up-to-date `main` (for example `fix/deep-link-tests`) and open a pull request.
  Fill in every section of the pull request template.
- Run `./scripts/test.sh` (contract check, UI rules, unit tests) and paste its summary into the pull request. The
  build must have no warnings. The repository's CI runs the same gate.
- Keep a pull request to one change. For UI-visible changes, attach simulator screenshots.
- If a change needs a backend change, open the `billboard-backend` pull request too, and say so in the description.
- Never commit secrets: no `.env*` files, credential plists, `.p8` or `.p12` files, provisioning profiles, tokens or
  passwords.

## AI-assisted contributions

The project is developed with an AI coding agent, Claude Code. It works under the direction of the project's
maintainers, who are responsible for what it commits. Its commits carry a `Co-Authored-By:` trailer that names the
model. Its changes go through pull requests and the same required checks as yours, and it may merge its own pull
requests once those checks pass. It never approves a production deploy.

You may use AI tools too. The rules are the same for every change, however it was written:

- **Understand and stand behind every line.** You must be able to explain any part of your change in review, and fix
  it if it is wrong. "The tool wrote it" is not an answer.
- **Say when a tool did a lot of the work.** If an AI tool wrote a substantial part of the change, such as whole
  functions, tests or documents, say so in the pull request and name the tool. Small completions need no note. Do not
  add a co-author line for the tool.
- **Keep the checks green.** Run the local checks before you open the pull request, with no warnings. Do not weaken,
  skip or delete tests, lint rules or the coverage gate to make a change pass.
- **Check the facts.** AI tools can be confidently wrong. Check anything about bills, laws, votes or members of
  Congress against Congress.gov or the source the code uses. Check that any package or API a tool suggests really
  exists.
- **Never paste secrets or personal data into a tool.** That means no keys, tokens, passwords, `.env` files or logs
  from a real deployment, and nobody's email address, street address or votes. Use the synthetic test data in the
  repository.
- **Keep tool files out.** Do not commit your tool's settings, prompts or memory files, such as `CLAUDE.md`,
  `AGENTS.md` or a `.claude/` folder.
- **Keep pull requests reviewable.** We may close a large generated change that nobody asked for. Open an issue first
  for anything big.

**How this fits the licence.** A tool's help does not change section 5 of the Apache License. You are the contributor,
not the tool. By submitting, you confirm you have the right to license the change under Apache-2.0. Use only tools
whose terms allow that. Do not submit output that copies someone else's code or text, such as a long passage you
recognize or a file with another licence header, unless you name its source and its licence is compatible with
Apache-2.0.

## Unit tests

Run only the unit-test target on a simulator. The tests need no credentials:

```bash
xcodebuild -workspace BillBoard.xcworkspace -scheme Billboard -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:BillboardTests -parallel-testing-enabled NO test | xcpretty
```

- Use any simulator that `xcrun simctl list devices available` shows, and change `name=` to match (or use `id=<UDID>`).
- `-only-testing:BillboardTests` keeps runs fast. Without it the scheme also runs `BillboardUITests`, whose signed-in
  journeys are skipped when no login is set; you will not have one, and that is fine.
- Both test targets are folder-synchronized: a new file in `Billboard/BillboardTests` joins the unit-test target
  without a project edit.
- Keep unit tests off the network. Stores take their API services as protocols
  (`Services/API/APIServiceProtocols.swift`), so tests pass the fakes in `BillboardTests/ServiceFakes.swift`. To test
  a service's requests, run it inside `APIClient.$current.withValue(RecordingTransport().client) { ... }`.

## Running your own build

**Builds from source.** You may build the app from `billboard-ios` and use it with the project's hosted service.
The bundled `Billboard/Billboard/amplifyconfiguration.json` points at that service, the same one the App Store app
uses. So your build signs in and reads bills there. Votes and sign-ups also go through the app integrity check. A
build you sign yourself cannot pass it, so the service may limit or refuse them. The
[privacy policy](https://billboard-project.com/privacy.html) applies to your account as it does in the App Store app.

- Push notifications depend on the project's Apple developer account, so they may not work in a build you sign
  yourself.
- The service can require a newer app version. Keep your build up to date with `main`.
- The signed-in UI tests skip themselves when no test login is set, and the smoke-test runner stops with a message.
  Do not set one up with an account on the hosted service.

### Acceptable use of the hosted service

If you use the project's hosted service from anything other than the project's App Store or TestFlight builds (a
build you made, or your own code):

- **Use your own account and vote as yourself.** Do not create accounts in bulk or with throwaway email addresses.
- **Keep test votes few.** Votes count toward results other people see.
- **No scripts or bots.** Do not script sign-ups, votes or reads, scrape the service or the share site, or load-test
  it. For bill data in bulk, use Congress.gov and GovInfo.
- **Respect the limits and checks.** Do not try to get around the service's limits, sign-up checks or app integrity
  check. If you find a way, report it privately as [SECURITY.md](SECURITY.md) describes, and do not use it.
- **Leave other people alone.** Do not try to see how anyone else voted or get into other accounts, and do not enter
  anyone else's email address or street address.

The project may limit, suspend or delete accounts, votes or builds that break these rules. It may change or stop the
service at any time, and builds from older or changed code may stop working.

### If you ship a build or run a service

Please run your own backend. This applies if you give a build to other people (through TestFlight, the App Store or
any other way), or if you run any part of this code as a service for others. The hosted service's limits, costs and
privacy policy are set for the project's own app, and your users would be outside them. This is a request about the
service, not a condition of the licence: Apache-2.0 lets you use the code freely.

1. Deploy `billboard-backend` in your own AWS account, following "Deploying your own copy" in its
   [infra/README.md](https://github.com/BillBoardApp/billboard-backend/blob/main/infra/README.md#deploying-your-own-copy).
   You need Amazon Bedrock model access, a Congress.gov API key from api.data.gov, an Apple developer account (for
   push notifications and App Attest) and your own domain.
2. In `services/src/shared/appAttest/config.ts`, set `APPLE_TEAM_ID` and `APP_BUNDLE_ID` to your own, and set
   `APP_ID_HASH` to the SHA-256 of your App ID (`<team ID>.<bundle ID>`). Use the same team and bundle ID in the
   Xcode project.
3. In the app, replace the values in `Billboard/Billboard/amplifyconfiguration.json` with your stack outputs
   `UserPoolId`, `UserPoolClientId` and `UserApiUrl`. Set `WEBSITE_BASE_URL` and `SHARE_SITE_BASE_URL` in
   `Billboard/Info.plist` to your own domain.
4. Use your own app name, icon and bundle ID, as [TRADEMARKS.md](TRADEMARKS.md) asks.
5. Publish your own privacy policy. The project's policy covers only its hosted service.

## Screens, colours and words

- Colours come only from the tokens in `Theme/BillboardTheme.swift` (`BillboardColors`), which have light, dark and
  high-contrast values. Do not use `Color.white`/`Color.black` as a surface or for text, system colours (`.red`,
  `.blue`...), `Color(red:...)` outside `Theme/`, or a forced appearance. The app follows the system appearance; the
  only override is the user's Appearance setting.
- Yea, Nay and Abstain always show their symbol and word (`VoteChoice`), parties their letter (`PartyBadge`), and a
  bill's status its stamped word (`StatusStamp`), so colour never carries meaning alone. Tags (`IndexTag`) have no
  hue.
- Use one word per concept: Billboard (never "BillBoard" on screen), Bills (tab), Updates, Notifications (pushes only),
  Watch (a bill), Follow (a topic or member), Topic, Skip (a card on Bills), Clear (a row in Updates), Results,
  Verified voter.
- `./scripts/check-ui-rules.sh` enforces these. A justified exception goes on the line as
  `// ui-rules:allow <rule>` or in `scripts/ui-rules-allowlist.txt`.
- Set text in a type role (`.textRole(_:)`) so it follows Dynamic Type, and check a new screen at an accessibility
  text size. Add or extend a `*RenderTests` or `*SnapshotTests` file so the screen is drawn in light and dark.

## Contracts

`contracts/` in `billboard-backend` is the source of truth for `UserAPIContractsV1.swift`; the Swift file there is
generated from the JSON schemas. After a contract change merges in the backend, run the sync here and commit the
copy it writes to `Billboard/Billboard/Domain/Contracts/`, in the same pull request as any code that uses the new
fields:

```bash
./scripts/syncContracts.sh           # copies from ../billboard-backend/contracts
./scripts/syncContracts.sh --check   # exit 1 when the app copy has drifted
```

`BILLBOARD_CONTRACTS_ROOT=/path/to/contracts` points it at another checkout. Do not edit the copy by hand.

## Staying neutral

Billboard is for every voter, whatever their views. Changes must keep it that way:

- No wording, ordering, defaults or notifications that take the side of a party, candidate, bill or cause.
- Bill summaries say what a bill does, not whether it is good. If you change the summary prompts or the list of loaded
  words, explain why in the pull request and show output from before and after.
- Facts about bills, votes and members must come from official sources such as Congress.gov, GovInfo and the Senate.

## What maintainers do

The project's maintainers:

- triage issues, review pull requests (sometimes with AI help), ask for changes and merge;
- approve check runs for outside pull requests. GitHub holds those runs until one of the maintainers approves them,
  and they run with a read-only token and no secrets;
- start and approve every production deploy;
- make app release builds and submit them to the App Store;
- handle security and conduct reports in private.

| You can | Done only by the project's maintainers |
|---|---|
| Open issues and pull requests | Merging to `main` |
| Run every check and test locally, with no credentials | Approving check runs for outside pull requests |
| Build the app and use it with the hosted service | Starting and approving production deploys |
| Deploy your own copy in your own AWS account | TestFlight and App Store releases |
| | Holding secrets, AWS access and Apple credentials |

**How a change reaches production.** A merge to `main` in `billboard-backend` runs the checks and builds a release,
but it does not deploy. A deploy is started by hand from `main`: first a preview of what would change, then the
deploy itself. GitHub holds each of these runs in the `production` environment until the project's maintainers
approve it. The repository's workflows can reach AWS only from an approved run on `main`. The AI agent never approves
a deploy.

**App releases.** Release builds of `billboard-ios` are made by hand from `main` in Xcode Cloud. A version goes to the
App Store only after the server changes it needs are live.

**Secrets and access.** Outside contributors never get secrets, deploy access, AWS access or write access. Pull
request checks need none of them. If part of your change can only be checked against a real deployment, say so in
the pull request, and the maintainers will check that part.

## Commit messages

Write one line, in sentence case, with no trailing period, usually starting with a present participle, such as
`Adding deep link tests` or `Improving queue load speed`. Prefix bug fixes with `Bug fix:`, as in
`Bug fix: adding congress member bills to queue`.

## Security

Do not report vulnerabilities in a public issue. See [SECURITY.md](SECURITY.md).
