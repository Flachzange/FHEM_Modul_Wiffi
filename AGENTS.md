# AGENTS.md — FHEM WIFFI Collector

This repository develops an event-driven FHEM integration for the classic STALL WIFFI TCP/JSON device family. This file is binding guidance for coding agents, review, documentation, testing, and releases. Keep the implementation small, idiomatic, and evidence-driven.

## Source of truth and project identity

- The authoritative editable sources are the **current files in this repository**, on the branch being changed:
  - `FHEM/00_WIFFI_Collector.pm` — FHEM TCP server, device dispatch, shared MAC/JSON/frame parser.
  - `FHEM/10_WIFFI_DEVICE.pm` — per-device FHEM endpoint.
  - `t/`, `.github/workflows/`, `README.md` — tests and documented behavior.
- Read current code and trace all affected paths before editing. Do not use old branches, generated archives, chat excerpts, cached copies, or prior releases as authoritative code.
- Module types: `WIFFI_Collector` and `WIFFI_DEVICE`. Keep FHEM callback/global function prefixes `WIFFI_Collector_` and `WIFFI_DEVICE_`; shared parser functions use the `WIFFI_Collector_` prefix in the collector module. Ensure they are available even when `WIFFI_DEVICE` is defined before the collector.
- License: **GPL-2.0-or-later**. The `LICENSE` file contains the unmodified GPLv2 text; project SPDX notices and the README explicitly grant GPLv2 *or (at the user's option) any later version*. Keep those statements consistent and do not change license terms without maintainer approval.
- Maintainer: Flachzange. Status: **experimental, not production-validated**.
- The module shall not depend on Node-RED, MQTT, polling, `notify`, or `dummy` devices for normal ingestion. WIFFI HTTP control uses FHEM `HttpUtils_NonblockingGet` without introducing blocking commands or timers.
- Generated releases belong under `dist/` and are not hand-edited or committed. Do not introduce a release layout until it is actually needed and tested.

## Evidence and communication

1. Do not guess STALL firmware, WIFFI protocol, FHEM callback, or Perl library semantics. Check actual source, manufacturer documentation, or reproducible captures/tests.
2. Distinguish verified specifications, observed device behavior, third-party reports, hypotheses, and unresolved questions. Cite source revision, firmware, and inspection date where practical.
3. An observed payload is evidence of its shape, **not** proof of invariance across models or firmware.
4. Treat existing implementation as something to audit, not as proof of correctness.
5. Never infer a unit, scaling, update interval, writability, or meaning from a field name alone. Keep ambiguities explicit.
6. Document new or changed protocol assumptions with the evidence and limits, preferably in a maintained protocol-evidence section or document. Do not assert features that were not tested.
7. Never turn an unknown or malformed state into a valid default (for example, do not silently map invalid data to zero or `off`).
8. Be precise about what the module, FHEM core, or an upstream device can guarantee. Do not claim end-to-end safety from unit tests alone.

## WIFFI wire protocol and identity contract

- A classic telegram is expected to contain `modultyp`, a `vars` array, and `Systeminfo`. Support documented format variations deliberately; never assume JSON array order is stable.
- **Public sensor reading names come exactly from `vars[].homematic_name`**, not from `desc`, MQTT aliases, or array indexes. Do not silently prefix or rename them. Reject or explicitly report invalid names/collisions; do not overwrite one value with another.
- `vars[].name` is a protocol variable identifier, not the default public reading name. Preserve it as useful internal context when needed for identity/validation.
- Keep each device's readings on its own logical `WIFFI_DEVICE`; identical `homematic_name` values on *different devices* are valid.
- Keep `Systeminfo` readings in a separately documented namespace such as `Systeminfo_firmware` and `Systeminfo_sec_seit_reset`, without collisions with sensor readings.
- Normalize valid MAC spellings (for example `b4:e6:2d:17:db:7` and `B4:E6:2D:17:DB:07`) for lookup while retaining enough raw context for diagnosis.
- MAC identification is not absolute proof of uniqueness. The two PULSECOUNTER2-LAN units originally advertised the same MAC until parameter 6 was changed. Detect conflicting simultaneous MAC/IP identities; never silently merge different physical devices. A change of sender IP requires an explicit, justified policy.
- Compare TCP peer identity with payload identity where available, but account for routed/NATed setups and do not blindly trust a self-reported IP address.
- Preserve device values without undocumented rounding, unit conversion, clamping, or zero substitution. This is especially important for large PULSECOUNTER counters, precision, `type:number` values encoded as strings, and `type:boolean` values encoded as `"false"`/`"true"`.
- Reject or explicitly surface malformed entries, missing required structure, duplicate names, unsupported container types and incompatible schema changes without publishing partial telegrams. JSON `null` for a present sensor value or optional Systeminfo field means **no new value**: retain the existing reading/timestamp and process other valid entries; an absent optional measurement is not an error. Do not invent mandatory sensor fields without protocol evidence.
- Only add device-specific rules when required by independently verified device behavior; keep the core parser generic.

## TCP and framing contract

- TCP is a **byte stream**, not a packet/message protocol. A read may contain a partial telegram, several telegrams, or a delimiter split across reads.
- Buffer **per accepted connection**, not globally. Implement and test boundaries using observed ETX/EOT (`0x03`/`0x04`) and actual device close-on-send behavior. EOF processing is not automatically equivalent to a validated frame.
- Never call JSON decoding on arbitrary partial TCP fragments; never process an unvalidated remainder after an error.
- Bound input memory, frame size, connection count where relevant, and malformed-input log amplification. Oversized input, dropped connections, invalid JSON, and abandoned connections must be handled safely and observably.
- Keep sockets nonblocking and use FHEM's verified TCP framework. No sleeps, blocking retry loops, recurring polling, or ad hoc alternative listener implementations.
- Check listener/client socket lifetime, `allowfrom`, partial writes/reads where applicable, close/error behavior, undefined/deleted clients, and port changes.
- For every accepted connection, ensure cleanup of its FHEM temporary device and buffer on EOF, error, undefine, disable, restart, and reload as applicable; do not leave duplicate listeners or abandoned selectlist entries.
- Do not claim that an offline detector exists if no such detector is implemented. A heartbeat reading's timestamp can support an external event-driven watchdog, but **unchanged data still need to refresh heartbeat age**.
- Distinguish transport-level receipt, JSON validity, successful identity assignment, and successful publication to the logical device when counting and reporting diagnostics.

## FHEM runtime engineering rules

- Verify uncertain FHEM behavior against current FHEM source/commandref. Never invent attribute semantics, callbacks, event rules, TCP helpers, or lifecycle guarantees.
- Follow the complete called-framework path, not just our wrapper: especially `TcpServer_Open`, `TcpServer_Accept`, `TcpServer_Close`, `CommandDefine`, `CommandDelete`, `InternalTimer`, `RemoveInternalTimer`, and reading-update functions.
- Record the inspected FHEM source revision/date and relevant side effects (return values, events, logging, timers, cleanup, security) in a PR when these functions matter.
- Treat `$hash->{STATE}` and public readings as *presentations*, not authoritative transient socket/lifecycle state. FHEM can apply `stateFormat` or restore stale readings. Keep transient ownership/state in dedicated internals.
- Update authoritative internal state **before** publishing FHEM readings or events: event processing may reenter module callbacks.
- Preserve configured device attributes and FHEM ownership across realistic define/modify, autocreate, rename, rereadcfg, reload, disable/enable, undefine/delete, shutdown, and restart sequences.
- Do not assume a callback return value is propagated by FHEM: inspect the actual caller. Recover or remain coherent even if a later callback fails after an earlier framework mutation.
- Classify every new internal state value by lifetime: local operation, device hash, FHEM process, or persistence across restart. Do not rely on stale restored readings or a mutable device name for durable ownership.
- Use stable ownership evidence (for example FUUID) before any persistent overwrite/deletion/migration. Never adopt data merely because an old name is reused.
- Prefer `readingsBeginUpdate`/`readingsBulkUpdate`/`readingsEndUpdate` for coherent per-telegram changes; verify how event-on-change/update attributes interact with value timestamps and downstream consumers.
- Keep public diagnostic readings minimal. Avoid publishing redundant copies of raw JSON, protocol metadata, and internal counters as readings without a real user-facing need.
- For newly autocreated WIFFI devices, apply `event-on-change-reading .*`, `event-on-update-reading Systeminfo_sec_seit_reset`, and `DbLogExclude ^Systeminfo_sec_seit_reset$` as user-editable defaults. This suppresses unchanged-value events while retaining a heartbeat event without filling DbLog with uptime counters. Do not change these attributes on existing devices or overwrite values set by `DEFINED` hooks. Pump-specific `stateFormat`/`devStateIcon` defaults still apply only to `wiffi-pump`. Avoid per-sensor custom timers. Explicitly document consequences for logging and periodic graph samples.
- New dependencies require justification, documentation, and CI coverage. Do not introduce a generic framework or many single-purpose helpers where one clear path suffices.

## Development simplicity and scope

- Prefer extending/consolidating existing code paths rather than stacking helper functions and parallel implementations. Every new function must have a distinct, reviewable responsibility.
- Avoid speculative compatibility layers, migration aliases, duplicated readings, or generated fields. A breaking interface change must be explicit, documented, tested, and approved in scope.
- User-specific FHEM computed readings (`userReadings`), DOIF logic, unit conversions, moving averages, statistics, and DbLog migration belong in migration documentation, not silently in a generic protocol collector.
- Keep the module event-driven. New recurring timers require a demonstrated feature need, ownership/cleanup review, and explicit approval.
- Default to protocol correctness and maintainability over one-off accommodations for a single capture.

## Security and privacy

- Treat all incoming TCP data as untrusted. Validate lengths, schema, identifier formats, numeric representations, and command inputs before using them for FHEM commands or dynamic device names.
- `autocreate` is off by default; generate deterministic names from the **full normalized MAC**, never from untrusted `modultyp`; preserve manually renamed devices and refuse duplicate logical MAC/peer identity assignments. Never allow untrusted fields to inject FHEM commands, impersonate an existing device, or overwrite its configuration.
- Favor restricting listeners to trusted networks and allowlists. A source-IP check is not cryptographic authentication; document that limitation.
- Do not log entire captured telegrams by default. Never publish real network addresses, identifiers, wireless SSIDs, tokens, private endpoints, or unredacted raw payloads in committed fixtures, error reports, docs, or CI output.
- Use reserved test-network addresses, synthetic MACs, and minimum synthetic payloads in public tests. Redact before copying from a production capture.
- Error logs should identify failure type safely without uncontrolled dumping of untrusted input.

## Tests: fidelity over green checks

- The current CI suite is `prove -I t/lib t/parser.t t/device.t t/autocreate.t t/set.t t/transport.t t/lifecycle.t t/reentrancy.t`; GitHub Actions also performs isolated Perl syntax checks. These checks do **not** establish that real FHEM listener, callbacks, or lifecycle behavior works. Keep this list synchronized with `.github/workflows/perl-tests.yml`.
- Before presenting a collector implementation as ready, add integration-oriented tests that exercise real or faithfully modeled FHEM accept/read/dispatch/close behavior. Track any framework stubs' provenance and limitations.
- A stub must reproduce *all relevant side effects* for the claim being tested (event publication, return handling, timer ownership, socket/FD registration, `%defs`, `%selectlist`, `CommandDelete`, etc.). A no-op stub must never be cited as evidence for behavior it omits.
- Test: split and concatenated TCP telegrams; ETX/EOT and EOF; payloads without terminators; oversized and malformed frames; UTF-8, invalid JSON, missing/duplicate names; different firmware-type values; reconnect, duplicate MACs/IP conflicts; unknown and renamed devices; autocreate collision/injection.
- Test: large/invalid numeric counters and value precision, string booleans, unchanged values/heartbeat timestamp refresh, event-on-change/update interactions, DbLog effects, and reentrant callbacks.
- Test lifecycle/failure injection including startup, port bind failure, modify/reload, rereadcfg, disable/enable, missing device, socket I/O errors, undefine/delete, shutdown, and restart.
- Confirm behavior on a **real test FHEM** and ideally a real WIFFI device before any production recommendation. State exactly what live tests were **not** done.
- Use negative controls when practical: prove a test fails with a known bad frame, stale timer, conflicting identity, or dropped cleanup.
- The test command should become a documented `scripts/ci.sh` entry point when this project gains a complete test suite; do not claim that it already exists.

## Mandatory repository-wide post-implementation review and requirement closure

**Required after every implementation, bug fix, refactor, test change, or documentation update, before reporting the task as finished.** A green CI run and review of only changed lines are not sufficient. Take a separate, critical review pass against the **current branch head after the change**; the goal is to uncover design and integration weaknesses, not merely to confirm the implementation.

1. **Review the complete implementation, not just the diff.** Re-read both entire FHEM modules (`FHEM/00_WIFFI_Collector.pm`, `FHEM/10_WIFFI_DEVICE.pm`) and inspect applicable tests, fixtures, CI, `README.md`, commandref/docs and this `AGENTS.md`. Trace callers/callees end-to-end, including relevant code untouched by the current issue.
2. **Audit coherence, straightforwardness, and maintainability.** Challenge the architecture, separation of collector/device responsibilities, data flow, shared invariants, names, API signatures, value semantics, INTERNALS vs. Readings, defaults, error/log levels and code style. Identify duplicated or contradictory logic/state, dead/obsolete code, unnecessary helpers, workarounds, inconsistent conventions, misleading comments, magic values and overengineering. Prefer one clear path to parallel special cases.
3. **Check FHEM and Perl conventions against evidence.** Verify callback signatures/ownership and lifecycle (`define`, `modify`, `rename`, `undef`, `rereadcfg`, restart), `AttrList`/`SetFn`, `TcpServerUtils`/`HttpUtils`, `%defs`/`%selectlist`, return values, timer cleanup, nonblocking I/O, Reading/state events, DbLog and reentrant callbacks. For uncertain framework behavior inspect actual FHEM source rather than treating guesses as established rules.
4. **Actively seek failure modes and regressions.** Trace valid, malformed, missing, optional and null values; edge cases and size/connection limits; duplicate identities, renamed devices, IP changes, multiple clients, timeouts, bind/reopen failures, device deletion during callback, pending HTTP and shutdown. Look for incorrect resource ownership, extra events/database writes, security/privacy mistakes and missing or inconsistent error logs. Confirm older features still work with the new change.
5. **Reconcile the full repository.** Ensure code, requirements, tests, CI commands, examples, README, protocol evidence, documentation and contributor guidance agree on current behavior. Check for contradictions introduced by the change; correct outdated rules and remove duplicates rather than appending another explanation. Respect established project decisions and distinguish framework requirements from project preferences.
6. **Fix, verify, and re-review.** Resolve in-scope confirmed defects before completion; rerun focused tests **and the full CI suite** and repeat the relevant whole-code review after any correction. Record unrelated or uncertain problems as evidence-backed follow-up issues instead of broadening scope with speculative rewrites.
7. **Make review evidence visible.** In the PR/issue completion note say that the repository-wide consistency review was done, what code/docs/tests were examined, which findings were fixed, what tests actually passed, and what risks or real-FHEM verifications remain. If a full pass or tests could not be done, state the gap; **never claim it occurred without evidence**. Do not close an issue with unmet acceptance criteria.

This quality gate applies **after each change**, not just before a release. The deeper framework compatibility audit in issue #10 remains a separate task; fold its **verified** reusable conclusions into these rules when available.

## Documentation, interface, and release workflow

- A user-visible change updates the relevant module sources, `README.md`, examples, tests, and changelog when introduced. Add German and English FHEM commandref documentation before release; keep both synchronized.
- When a version is introduced, keep source version, embedded META, changelog, README, release artifacts, and tests consistent. Do **not** bump versions for docs-only/tests-only work.
- Validate Perl syntax, complete tests, callback names, duplicate globals, required dependencies, commandref/META when implemented, UTF-8, JSON fixtures, source-to-package byte equality, checksums, and deterministic release artifacts before publishing. Document exceptions for steps not yet available.
- Never claim the FHEM module is production-ready solely because isolated Perl syntax and parser tests pass.
- Use a focused branch named `codex/<short-description>` for **new work** unless the maintainer explicitly requests otherwise or work continues in an already-approved existing PR branch.
- Keep PRs reviewable; open drafts by default. PR descriptions must cover motivation, change scope, user-visible behavior, inspected FHEM source/side effects, tests actually run, tests not run, migration impact, and remaining risk.
- Do not merge, publish a release, rewrite history, or force-push shared branches without explicit maintainer approval.

## Context carried into this project

These requirements are **WIFFI-specific**, not inherited from the other modules:

- One shared TCP listener, logically separate devices keyed by validated/normalized device identity.
- Initial protocol targets: WIFFI-pump 2, WEATHERMAN, two PULSECOUNTER2-LAN devices.
- Expose verified WIFFI-pump 2 convenience setters for `trigger:on:`, `trigger:off:`, and `trigger:<seconds>:`; `on` means indefinitely on. All WIFFI types may expose the deliberately explicit expert `httpGet` command accepting a single validated relative path/query. This command can alter device configuration, so never present it as read-only. Use only the observed validated IPv4 TCP peer as the HTTP host and default port 80, never user-provided scheme/host/port. Disable redirects via FHEM HttpUtils `ignoreredirects => 1` (verified in mhop/fhem-mirror `fhem/FHEM/HttpUtils.pm`); bound length/timeout, reject whitespace, control characters, backslashes, fragments and malformed percent encoding; never synthesize state from HTTP replies. Cancel pending requests on undefine/modify and test concurrent sends, unknown types, redirects and hostile paths. Never expose unrestricted arbitrary absolute URLs or POST.
- Only `homematic_name` determines sensor reading names; do not preserve earlier Node-RED/MQTT alias names as implicit compatibility output.
- Sender heartbeat `Systeminfo_sec_seit_reset` should remain usable for external watchdogs; no implicit polling.
- Existing Node-RED-to-MQTT devices must remain untouched during development and one-by-one migration.
- Migrating existing FHEM devices requires separately reviewing dependent DOIF, userReadings, averages, `statistics`, DbLog readers, and historical timeseries. Do not silently change production data or automations.

## Provenance of these agent rules

Adapted and consolidated from the current default-branch versions of:

- [FHEM_Modul_Fronius_Wattpilot/AGENTS.md](https://github.com/Flachzange/FHEM_Modul_Fronius_Wattpilot/blob/main/AGENTS.md): source-of-truth discipline, framework side-effect/callback audits, reload/lifetime/ownership analysis, test-double fidelity, adversarial review, safety claims, release and PR rigor.
- [FHEMPresenceSimulation/AGENTS.md](https://github.com/Flachzange/FHEMPresenceSimulation/blob/main/AGENTS.md): simplicity/consolidation, explicit behavior contracts, strict tests, documentation and release workflow.

Wattpilot-specific charging/authentication behavior and PresenceSimulation-specific playback/probability/persistence rules are intentionally **not** copied. Requirements stated above are adapted to this project's actual code maturity and protocol.
