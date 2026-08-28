# Issue #674: legacy DE1 account identity resolution

Branch: `fix/674-legacy-de1-identity`
Issue: https://github.com/decentespresso/decaid/issues/674

## Goal

Resolve missing or incorrect legacy DE1 serial/model values from the linked Decent account without changing MMR values on the machine. Keep Bengle out of this flow and preserve normal machine operation whenever account data or user input is unavailable.

Baseline: `rtk flutter test` passes 3,527 tests on this branch before implementation.

## Design constraints

- Keep raw MMR reads in `UnifiedDe1`; account and dialog logic stay in the application/controller layer.
- The support API becomes authoritative only after one registered machine is confidently selected.
- Persist account data through the existing `CredentialStore`; do not add a database table or dependency.
- Keep one current linked-account cache plus account-qualified device mappings. Explicit logout or successful account replacement clears that account's cache/mappings. A rejected session leaves persisted recovery data intact but it must not be used while auth is definitively invalid.
- Treat `deviceId` as opaque. Mapping identity is `(normalized account email, transportType.name, exact deviceId)`.
- Unknown SKU formats remain unknown. They may supply authoritative serial data after an exact serial match, but are not candidates for serial-0 auto/manual selection because they cannot safely be distinguished from out-of-scope hardware.
- Never write inferred `SerialN`, `v13Model`, or `Model` values to the machine.
- Preserve the existing serial-mismatch email behavior for a real nonzero serial not registered to the linked account, but run it only after identity resolution finishes.

## Milestone 1: canonical records and pure resolution (test first)

1. Add failing unit tests for all firmware values `0..7`, Bengle values `>=128`, and explicit SKU tokens.
2. Expand `DecentMachineModel` to the canonical legacy set while preserving existing public names where already established:
   - 0 unknown
   - 1 DE1
   - 2 DE1+
   - 3 DE1Pro
   - 4 DE1XL
   - 5 DE1Cafe
   - 6 DE1XXL
   - 7 DE1XXXL
   - >=128 Bengle
3. Add `RegisteredDecentMachine` with serial, raw SKU, and recognized model. Replace the serial-only parser with a record parser; keep `parseSerialNumbers()`/`fetchSerialNumbers()` as compatibility projections.
4. Parse only anchored, explicit DE1-family SKU model tokens (plus explicit Bengle detection for exclusion). Do not infer a model from a partial/unknown token.
5. Add a pure `LegacyDe1IdentityResolver` with results for resolved, ambiguous, and unavailable. Cover:
   - exact nonzero serial match; recognized API model overrides conflicting raw model
   - unmatched nonzero serial remains unchanged
   - valid persisted mapping
   - one known legacy DE1 candidate
   - unique raw-model hint among multiple candidates
   - contradictory/no-result hints ignored rather than forced
   - ambiguous candidates
   - Bengle and unknown-SKU records excluded from serial-0 candidates
   - unknown API model retains the raw model on exact serial match

Verify focused model/parser/resolver tests, format touched files, then commit:
`feat(account): model registered machines and resolve legacy identity`

## Milestone 2: account cache and mappings (test first)

1. Add account-service tests before implementation for:
   - `/support/api/sn?onlyespressomachines=1&withskus=1`
   - login fetch + persistence
   - startup cache load before refresh
   - successful stored-credential validation refresh
   - transient fetch failure preserving the last good list
   - definitive auth rejection retaining persisted data but making it unusable for the session
   - logout and successful account replacement clearing scoped cache/mappings
   - failed replacement login preserving the existing account and data
   - mapping round-trip and stale mapping removal when its serial disappears
2. Extend `DecentAccountService` with an in-memory registered-machine list and explicit startup initialization. Load the linked account's cached JSON immediately, then validate stored credentials and refresh in the background/best-effort path.
3. On successful login, replace credentials safely, clear old-account state only when the authenticated email changed, and attempt a machine-list refresh. A list-fetch failure must not turn a valid login into a failed login or erase a same-account last-good cache.
4. Persist mappings as one small JSON document through `CredentialStore`, with account/transport/device fields rather than one unenumerable secure-store key per device. Prune mappings whose serial is absent after a successful refresh.
5. Expose only the minimum methods needed by the controller: usable registered records, lookup/save mapping, and auth/cache availability. Do not create a second persistence abstraction.
6. Call account-service initialization from `main.dart` before `runApp`; keep network refresh non-blocking after the secure-store cache load.

Verify focused account tests, format touched files, then commit:
`feat(account): cache registered machines and identity mappings`

## Milestone 3: effective identity and native prompts (test first)

1. Add an in-memory effective-identity override to `UnifiedDe1` while retaining raw `MachineInfo`/raw model value for matching and diagnostics. The override changes only serial/model; firmware, GHC, voltage, refill-kit, and other fields remain byte-for-byte equivalent. Add a unit test proving no MMR write occurs when applying it.
2. Integrate resolution in `De1StateManager` for `DeviceImplementation.unifiedDe1` only. Use a connection/device generation guard so an awaited account call or dialog cannot update a disconnected/replaced machine.
3. Resolve before `_checkSerialOwnership()`:
   - use current cached account records unless auth is definitively invalid
   - apply confident results to effective `MachineInfo`
   - persist a manual choice by account + transport + opaque device ID
   - leave raw identity untouched on unavailable/no-match/cancel
4. For ambiguous known legacy candidates, show one native Flutter dialog listing serial, friendly model, and raw SKU. Do not offer Bengle or unknown-SKU records.
5. If raw serial is `0` or raw model value is `0` and no usable account/cache exists, show a non-blocking link-account prompt. On acceptance, navigate to `AccountPage.routeName`; when that route returns, retry resolution once. Cancel/dismiss leaves the machine usable.
6. Deduplicate prompts per connected device and avoid showing UI after disposal/background replacement.
7. Add focused resolver/controller/widget coverage for manual selection, mapping reuse, changed device ID fallback, login prompt dismissal, effective `MachineInfo`, and unchanged real-nonzero mismatch reporting.
8. Update `doc/DeviceManagement.md` with the post-connect legacy DE1 identity flow and explicit no-write/Bengle exclusions.

Verify focused tests, `dart format lib test`, `flutter analyze`, and full `flutter test`, then commit:
`feat(de1): apply account-resolved legacy machine identity`

## Completion and PR

- Review the complete diff against #674 acceptance criteria and repo rules.
- Fix only concrete correctness, lifecycle, UI, or test gaps; no adjacent refactors.
- Archive this design/plan under `doc/plans/archive/legacy-de1-account-identity/` before the final PR commit, retaining the rationale.
- Fill every required section of `.github/pull_request_template.md`.
- Final evidence: focused tests, `dart format lib test`, `flutter analyze`, full `flutter test`.
