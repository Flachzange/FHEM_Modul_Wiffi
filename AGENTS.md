# AGENTS.md — Reusable FHEM module engineering rules

This is the reusable foundation for coding agents developing FHEM Perl modules. Apply it to code, tests, issues, reviews, documentation and releases. Prefer a small, idiomatic, evidence-driven implementation.

**Load project rules as well:** Before working in any repository, read any applicable root-level `AGENTS-*.md` supplements and apply them alongside this file. Those additional filenames are **not assumed to be loaded automatically** by coding agents. Project-specific requirements belong in the supplement; generic FHEM framework guidance belongs here. For a conflict about verified FHEM behavior, check core sources and reconcile the instructions rather than silently overriding a framework requirement.

## Source of truth

- Treat the current files on the active repository branch as authoritative. Inspect the relevant module sources, tests, CI and documentation and trace affected paths before editing. Do not use old branches, generated archives, chat excerpts, cached copies or prior releases as authoritative code.
- Verify the repository's actual module types, callback prefixes, licensing and distribution layout before introducing changes. Preserve existing public interfaces unless an explicit change is approved.

## Evidence and communication

1. Do not guess device firmware, protocol, FHEM callback, or Perl library semantics. Check actual source, manufacturer documentation, or reproducible captures/tests.
2. Distinguish verified specifications, observed device behavior, third-party reports, hypotheses, and unresolved questions. Cite source revision, firmware, and inspection date where practical.
3. An observed payload is evidence of its shape, **not** proof of invariance across models or firmware.
4. Treat existing implementation as something to audit, not as proof of correctness.
5. Never infer a unit, scaling, update interval, writability, or meaning from a field name alone. Keep ambiguities explicit.
6. Document new or changed protocol assumptions with the evidence and limits, preferably in a maintained protocol-evidence section or document. Do not assert features that were not tested.
7. Never turn an unknown or malformed state into a valid default (for example, do not silently map invalid data to zero or `off`).
8. Be precise about what the module, FHEM core, or an upstream device can guarantee. Do not claim end-to-end safety from unit tests alone.

## Transport and protocol fundamentals

- TCP is a **byte stream**, not a packet/message protocol. A read may contain a partial telegram, several telegrams, or a delimiter split across reads.
- For stream protocols, frame data per connection using verified device behavior. Never parse arbitrary partial input or silently accept an unvalidated remainder.
- Bound input size, simultaneous connections, timeouts and potentially repetitive malformed-input diagnostics according to realistic operational risks.
- Use supported FHEM nonblocking I/O facilities; avoid sleep, blocking retries, ad hoc socket loops and needless background polling.

## FHEM runtime engineering rules

- Verify uncertain FHEM behavior against current FHEM source/commandref. Never invent attribute semantics, callbacks, event rules, TCP helpers, or lifecycle guarantees.
- Follow the applicable framework call path, not just the module wrapper: `TcpServer_Open`, `TcpServer_Accept`, `TcpServer_Close`, `HttpUtils_NonblockingGet`, `CommandDefine`, `CommandAttr`, `CommandDelete`, `InternalTimer`, `RemoveInternalTimer`, and reading-update functions.
- Record the inspected FHEM source revision/date and relevant side effects (return values, events, logging, timers, cleanup, security) in a PR when these functions matter.
- Treat `$hash->{STATE}` and public readings as *presentations*, not authoritative transient socket/lifecycle state. FHEM can apply `stateFormat` or restore stale readings. Keep transient ownership/state in dedicated internals.
- Update authoritative internal state **before** publishing FHEM readings or events: event processing may reenter module callbacks.
- Preserve configured device attributes and FHEM ownership across applicable and realistic define/modify, autocreate, rename, rereadcfg, reload, disable/enable, undefine/delete, shutdown, and restart sequences.
- Do not assume a callback return value is propagated by FHEM: inspect the actual caller. Recover or remain coherent even if a later callback fails after an earlier framework mutation.
- Classify every new internal state value by lifetime: local operation, device hash, FHEM process, or persistence across restart. Do not rely on stale restored readings or a mutable device name for durable ownership.
- Use stable ownership evidence (for example FUUID) before any persistent overwrite/deletion/migration. Never adopt data merely because an old name is reused.
- Prefer `readingsBeginUpdate`/`readingsBulkUpdate`/`readingsEndUpdate` for coherent per-telegram changes; verify how event-on-change/update attributes interact with value timestamps and downstream consumers.
- Keep public diagnostic readings minimal. Avoid publishing redundant copies of raw JSON, protocol metadata, and internal counters as readings without a real user-facing need.
- For externally distributed FHEM modules, explicitly check that users can identify the installed module revision in FHEM. `FHEM::Meta` with an embedded version and `FVERSION` is a supported pattern; verify actual `InitMod`/`SetInternals` behavior against FHEM when adopting it. Module version and connected-device firmware version are different; do not create redundant version readings or claim a version is installed without verifying its code.
- New dependencies require justification, documentation, and CI coverage. Do not introduce a generic framework or many single-purpose helpers where one clear path suffices.

## Verified FHEM core behavior (source-backed, not a live test)

The following details were confirmed against [`mhop/fhem-mirror/fhem/fhem.pl`](https://github.com/mhop/fhem-mirror/blob/master/fhem/fhem.pl) (content blob `4430a7967aa318c310535082852f77d4ca3482f8`) and [`TcpServerUtils.pm`](https://github.com/mhop/fhem-mirror/blob/master/fhem/FHEM/TcpServerUtils.pm) (blob `678e1c5bd363fd7a2e5fc74df14484886862203d`), inspected 2026-10-14. Reverify against the **installed FHEM revision** before relying on version-sensitive behavior.

- `DoSet` calls module `SetFn` in **list context**. When a successful setter has produced no event, FHEM normally synthesizes a command event; return a true second `skipTrigger` value when that event would falsely imply a state change. Distinguish asynchronous command acceptance from confirmed hardware telemetry. In Perl, `return wantarray ? (undef, 1) : undef` preserves a scalar success contract while returning two values to FHEM.
- `CommandAttr`/`CommandDeleteAttr` invoke `AttrFn` **before** writing/removing the attribute. Derive side effects from the callback's `set`/`del` request and requested value, not an assumed new `AttrVal`; return a meaningful error only if the operation truly must be vetoed.
- `CommandDefine` and `CommandModify` pass the module's definition arguments to `DefFn` without enforcing module-specific counts. Check required **and surplus** arguments before modifying resources, particularly on `modify`.
- `CommandDelete` leaves the device defined if `UndefFn` or `DeleteFn` refuses removal. `CommandModify` restores the old `DEF` after a failed `DefFn`, **not arbitrary module INTERNALS**. Keep resource ownership and internal configuration consistent on failed changes.
- For modules using `TcpServerUtils`, `TcpServer_Accept` applies a configured `allowfrom` filter and creates temporary children in FHEM's registries. `TcpServer_Open` may update `state` before bind success; `TcpServer_Close` closes the listener but can leave stale `SERVERSOCKET` metadata. Use actual bind/close results and the FHEM lifecycle, not presentation state, for socket ownership.
- FHEMWEB module hooks were verified against `01_FHEMWEB.pm` blob `9b8380ec138b7699efecacfce1aafe85b7abf93c` (inspected 2026-10-14): defining `FW_detailFn` normally suppresses the standard DeviceOverview unless the module also sets `FW_deviceOverview`; setting `FW_addDetailToSummary` makes FHEMWEB render the detail function's returned HTML as an additional row below the device in room overview. Use these hooks deliberately rather than replacing normal `stateFormat`/`devStateIcon` rendering when only a small module-specific link or detail block is needed.

These are FHEM framework contracts, **not** instructions to add new retries, counters, timers or guards where the module does not need them. Put project-specific behavior in the relevant `AGENTS-*.md` supplement.

## Issue triage: practical value before added complexity

Before opening an issue **or recommending a defensive change**, inspect the current code, relevant real-world usage and existing issues. Decide whether any work is justified **before** inventing a fix:

- **Evidence and impact:** State whether the behavior is reproduced, directly supported by code/framework contracts, or merely hypothetical. Describe a concrete consequence in the affected FHEM deployment, its likelihood, and who is affected. Do not turn every conceivable failure path into a ticket.
- **Existing behavior and alternatives:** Check whether the system already handles the case acceptably, whether the proposed restriction could break a useful workflow, and whether doing nothing or documenting a limitation is better. Do not assume more guarding automatically means more safety.
- **Cost versus benefit:** Estimate additional state, callbacks, timers, configuration, tests, maintenance and operator burden against expected value. Prefer the smallest intervention with a meaningful outcome; decline defensive machinery whose complexity exceeds the realistic risk.
- **Exceptions:** Address actual defects and credible security, safety, data-loss or resource-exhaustion risks even when uncommon. State the risk and evidence proportionately; absence of an observed incident alone is not grounds to dismiss a high-impact vulnerability.
- **Decision and duplication:** Search existing tickets first. File a focused issue only for a justified, actionable change; otherwise leave a brief finding in the current review or mark an existing ticket `not planned` with rationale. Do not create meta-issues or mandatory scoring templates for this check.
- **Maintainer decision:** Where the correct behavior is a product/operational tradeoff, discuss the concrete benefit, downside and simplest alternative before proceeding. Do not interpret a speculative audit finding as approval to implement it.

## Development simplicity and scope

- **Do not optimize for every hypothetical edge case.** Build for verified requirements, realistic failure scenarios, and meaningful correctness/security risks. Do not introduce speculative fallbacks, guards, state variables, retries, compatibility paths, or helper layers merely because a case is imaginable; each added complexity must have a concrete justification.
- Prefer clear, direct, idiomatic Perl, descriptive naming, and straightforward control flow. Retain necessary input validation, resource limits, error handling, and FHEM lifecycle cleanup; simplicity does not justify weakening correctness or safety.
- Prefer extending/consolidating existing code paths rather than stacking helper functions and parallel implementations. Every new function must have a distinct, reviewable responsibility.
- Avoid speculative compatibility layers, migration aliases, duplicated readings, or generated fields. A breaking interface change must be explicit, documented, tested, and approved in scope.
- User-specific FHEM computed readings (`userReadings`), DOIF logic, unit conversions, moving averages, statistics, and DbLog migration belong in migration documentation, not silently in a generic device or protocol module.
- Keep the module event-driven. New recurring timers require a demonstrated feature need, ownership/cleanup review, and explicit approval.
- Default to protocol correctness and maintainability over one-off accommodations for a single device capture.

## Security and privacy

- Treat all external input as untrusted. Validate lengths, schema, identifier formats, numeric representations, and command inputs before using them for FHEM commands or dynamic device names.
- Favor restricting listeners to trusted networks and allowlists. A source-IP check is not cryptographic authentication; document that limitation.
- Do not log entire captured telegrams by default. Never publish real network addresses, identifiers, wireless SSIDs, tokens, private endpoints, or unredacted raw payloads in committed fixtures, error reports, docs, or CI output.
- Use reserved test-network addresses, synthetic MACs, and minimum synthetic payloads in public tests. Redact before copying from a production capture.
- Error logs should identify failure type safely without uncontrolled dumping of untrusted input.

## Tests: fidelity over green checks

- Use the actual test command documented for the repository; keep it synchronized with CI and do not claim that tests verify behavior which their stubs omit.
- Before presenting a module implementation as ready, add integration-oriented tests that exercise real or faithfully modeled relevant FHEM callback, transport and lifecycle behavior. Track any framework stubs' provenance and limitations.
- A stub must reproduce *all relevant side effects* for the claim being tested (event publication, return handling, timer ownership, socket/FD registration, `%defs`, `%selectlist`, `CommandDelete`, etc.). A no-op stub must never be cited as evidence for behavior it omits.
- Test lifecycle/failure injection as applicable, including startup, port bind failure, modify/reload, rereadcfg, disable/enable, missing device, socket I/O errors, undefine/delete, shutdown, and restart.
- Use negative controls when practical: prove a test fails with a known bad frame, stale timer, conflicting identity, or dropped cleanup.
- Confirm meaningful behavior in real test FHEM before making production claims. Record which integration, hardware, configuration-backend and lifecycle cases were not executed.

## Mandatory repository-wide post-implementation review

**Required after every implementation, bug fix, refactor, test change, or documentation update, before reporting the task as finished.** A green CI run and review of only changed lines are not sufficient. Take a separate, critical review pass against the **current branch head after the change**; the goal is to uncover design and integration weaknesses, not merely to confirm the implementation.

1. **Review the complete implementation, not just the diff.** Re-read all relevant FHEM modules and inspect applicable tests, fixtures, CI, `README.md`, commandref/docs, this `AGENTS.md` and applicable `AGENTS-*.md` supplements. Trace callers/callees end-to-end, including relevant code untouched by the current issue.
2. **Audit coherence, straightforwardness, and maintainability.** Challenge the architecture and separation of module responsibilities, data flow, shared invariants, names, API signatures, value semantics, INTERNALS vs. Readings, defaults, error/log levels and code style. Identify duplicated or contradictory logic/state, dead/obsolete code, unnecessary helpers, workarounds, inconsistent conventions, misleading comments, magic values and overengineering. Prefer one clear path to parallel special cases. Challenge each defensive branch: which verified requirement or realistic failure does it address, and could the same behavior be achieved more simply?
3. **Check FHEM and Perl conventions against evidence.** Verify callback signatures/ownership and lifecycle (`define`, `modify`, `rename`, `undef`, `rereadcfg`, restart), `AttrList`/`SetFn`, applicable `TcpServerUtils`/`HttpUtils`, `%defs`/`%selectlist`, return values, timer cleanup, nonblocking I/O, Reading/state events, DbLog and reentrant callbacks. For uncertain framework behavior inspect actual FHEM source rather than treating guesses as established rules.
4. **Actively seek realistic failure modes and regressions.** Trace valid, malformed, missing, optional and null values; relevant size/resource limits; device identity and lifecycle changes; meaningful network failures, reentrant callbacks and shutdown. Look for incorrect resource ownership, extra events/database writes, security/privacy mistakes and missing or inconsistent error logs. Confirm older features still work with the new change.
5. **Reconcile the full repository.** Ensure code, requirements, tests, CI commands, examples, README, protocol evidence, documentation and contributor guidance agree on current behavior. Check for contradictions introduced by the change; correct outdated rules and remove duplicates rather than appending another explanation. Respect established project decisions and distinguish framework requirements from project preferences.
6. **Fix, verify, and re-review.** Resolve in-scope confirmed defects before completion; rerun focused tests **and the full CI suite** and repeat the relevant whole-code review after any correction. Record unrelated or uncertain problems as evidence-backed follow-up issues instead of broadening scope with speculative rewrites.
7. **Make review evidence visible.** In the PR/issue completion note say that the repository-wide consistency review was done, what code/docs/tests were examined, which findings were fixed, what tests actually passed, and what risks or real-FHEM verifications remain. If a full pass or tests could not be done, state the gap; **never claim it occurred without evidence**. Do not close an issue with unmet acceptance criteria.

This quality gate applies after every change, not just a release. Keep verified, reusable FHEM framework findings in this file and project-only constraints in the appropriate `AGENTS-*.md` supplement.

## Documentation, interface and release workflow

- A user-visible change updates the relevant module sources, `README.md`, examples, tests, and changelog when introduced. Add German and English FHEM commandref documentation before release; keep both synchronized.
- When a version is introduced, keep source version, embedded META, changelog, README, release artifacts, and tests consistent. Do **not** bump versions for docs-only/tests-only work.
- Validate Perl syntax, complete tests, callback names, duplicate globals, required dependencies, commandref/META when implemented, UTF-8, JSON fixtures, source-to-package byte equality, checksums, and deterministic release artifacts before publishing. Document exceptions for steps not yet available.
- Never claim the FHEM module is production-ready solely because isolated Perl syntax and parser tests pass.
- Use a focused branch named `codex/<short-description>` for **new work** unless the maintainer explicitly requests otherwise or work continues in an already-approved existing PR branch.
- Keep PRs reviewable; open drafts by default. PR descriptions must cover motivation, change scope, user-visible behavior, inspected FHEM source/side effects, tests actually run, tests not run, migration impact, and remaining risk.
- Do not merge, publish a release, rewrite history, or force-push shared branches without explicit maintainer approval.

## Rule provenance

Adapted and consolidated from the current default-branch versions of:

- [FHEM_Modul_Fronius_Wattpilot/AGENTS.md](https://github.com/Flachzange/FHEM_Modul_Fronius_Wattpilot/blob/main/AGENTS.md): source-of-truth discipline, framework side-effect/callback audits, reload/lifetime/ownership analysis, test-double fidelity, adversarial review, safety claims, release and PR rigor.
- [FHEMPresenceSimulation/AGENTS.md](https://github.com/Flachzange/FHEMPresenceSimulation/blob/main/AGENTS.md): simplicity/consolidation, explicit behavior contracts, strict tests, documentation and release workflow.

These are reusable FHEM development and review practices, not claims that every FHEM module needs a TCP collector, specific device commands or the same integration tests. Project-specific behavior belongs in a supplement.

