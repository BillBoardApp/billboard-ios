<!-- See CONTRIBUTING.md. Write "none" instead of deleting a section. -->

## Summary

<!-- What changed and why, in a few sentences. Add simulator screenshots for UI changes. -->

## Related issue

<!-- A link or number, or "none". -->

## Test evidence

<!-- Say which simulator and Xcode version, and paste the test summary line. -->

- [ ] `./scripts/test.sh` passes (contract check, UI rules, unit tests) with no warnings
- [ ] Checked the change by hand in the simulator (screens and flows touched)

## Compatibility

<!-- Say "none" where a line does not apply. -->

- Replacements (Keychain items, UserDefaults keys, caches or files replaced or removed):
- Data migrations (stored data from older app versions that must still load):
- User-visible prompts or permissions added or changed:
- Backend (`billboard-backend`) changes this depends on, with a link to that pull request:

## App Store impact

<!-- What App Store users will see when this ships: new or changed screens, text, permissions or privacy answers.
"none" for changes users cannot see. A change that needs a backend change ships only after that change is live. -->

## AI assistance

<!-- "none", or the tool and what it wrote. -->

## Checklist

- [ ] I agree that this contribution is licensed under Apache-2.0 (see CONTRIBUTING.md).
- [ ] This PR does not push secrets: no `.env*` files, credential plists, `.p8` or `.p12` files, provisioning profiles, tokens or passwords.
- [ ] `UserAPIContractsV1.swift` comes from `./scripts/syncContracts.sh`, not hand edits (or no contract files changed).
