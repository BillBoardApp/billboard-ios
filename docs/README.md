# docs

Billboard's design notes, plans and trackers are internal to the project and are not part of this repository. The
code still cites them in comments and test names. This page explains those references, so you can read the code
without the notes. The code next to a reference is meant to stand on its own; if it does not, open an issue and we
will explain it in the code.

## Tracker IDs

An ID is a prefix and a number, for example `UX-29`. The prefix says what kind of item it is:

| Prefix | Meaning |
|---|---|
| `APPF` | A functional bug in the app, found on a device |
| `UX` | Usability, appearance or wording |
| `INT` | Vote integrity: who may vote, and how votes are counted |
| `LLM` | Quality and neutrality of the AI-written bill summaries and news picks |
| `REL` | Reliability of the service and of the data it serves |
| `SEC` | Security and privacy |
| `CAP` | Capacity and cost |
| `CON` | The API contracts and how the repositories are organized |
| `D-` | A project decision, for example `D-15` |

## Spec references

- `spec D 2.8.4` and similar: a section of the app's internal design specification.
- `spec C3 3.10` or `C3 3.10`: a section of the internal specification for the user API and its request checks.
- `R1` and `R2`: the first two design rounds of the app. `R2` is the current design; a note that something was
  "removed in R2" explains why the code no longer has it.

## Repository names

The two repositories were called `billboard-platform` (now `billboard-backend`) and `billboard-app` (now
`billboard-ios`) before they were published. Older comments, and the header of the generated contract file, may
still use the old names. They mean the same repositories.

## Public documentation

- [README.md](../README.md): what is here, and how to build and test it
- [CONTRIBUTING.md](../CONTRIBUTING.md): how to contribute, and how to run your own build
- [SECURITY.md](../SECURITY.md): how to report a security problem
- The backend's documentation is in the
  [billboard-backend](https://github.com/BillBoardApp/billboard-backend) repository.
