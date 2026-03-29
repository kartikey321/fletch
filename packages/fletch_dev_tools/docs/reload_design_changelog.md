# Reload Architecture Design Changelog

This log tracks architecture and implementation changes for the high-performance
reload runtime.

---

## RLD-20260320-19

- Date: `2026-03-20`
- Title: `Restore backward-compatible core hotReload path; keep addon runtime hooks optional`
- Status: `Implemented`

### Decision

Reinstate the original core reassembly contract in `fletch` and keep addon
runtime hooks additive:

- restored `BaseContainer.hotReload(...)` and `BaseContainer.reassemble()`,
- restored `Fletch.hotReload(...)` registration of `ext.fletch.reassemble`,
- retained `configureDevHotReload(...)` as optional advanced runtime hook layer,
- updated docs/example messaging to present core `app.hotReload(...)` as default.

### Rationale

Preserve existing developer ergonomics and trust without forcing a bootstrap
API migration or changing release-vs-dev app wiring requirements.

### Impact

- Runtime behavior impact:
  - Existing apps using `app.hotReload(...)` continue to work unchanged.
  - Runtime generation extensions remain optional and opt-in via addon.
- Compatibility impact:
  - Backward compatibility restored for hot reload registration API.
- Operational/testing impact:
  - Failure mode: mixed setup registers duplicate service extension names.
  - Mitigation: addon extension registration now tolerates already-registered
    methods.
  - Test strategy note: run analyze + tests on `fletch` and `fletch_dev_tools`
    after restoration.

### Evidence

- `packages/fletch/lib/src/services/base_container.dart`
- `packages/fletch/lib/src/services/fletch.dart`
- `packages/fletch_dev_tools/lib/src/runtime/fletch_dev_hot_reload.dart`
- `packages/fletch_dev_tools/lib/src/hot_reloader.dart`
- `packages/fletch_dev_tools/lib/src/dev_server.dart`
- `packages/fletch_dev_tools/example/main_server.dart`
- `docs/site/content/development/hot-reload.md`

### Follow-ups

- Keep `configureDevHotReload(...)` docs focused on advanced use cases
  (generation drain, runtime-state hooks), not baseline setup.
- Add integration coverage for mixed mode (`app.hotReload` + addon configured)
  to validate duplicate extension tolerance.

## RLD-20260320-18

- Date: `2026-03-20`
- Title: `Decouple hot reload runtime bridge from fletch core into dev addon`
- Status: `Implemented`

### Decision

Move runtime hot-reload concepts out of `fletch` core and into a dedicated
dev addon API exposed by `fletch_dev_tools`:

- new addon entrypoint: `configureDevHotReload(...)`,
- VM extensions (`ext.fletch.reassemble`, generation activate/retire/runtimeState)
  now registered by addon code in app process,
- request generation in-flight tracking now addon-managed middleware state,
- `fletch` core removed `hotReload/reassemble` and built-in dev extension wiring.

### Rationale

Keep `fletch` as pure HTTP framework runtime and isolate development reload
control-plane concerns in tooling/addon layer.

### Impact

- Runtime behavior impact:
  - Dev hot reload runtime bridge is opt-in through addon configuration.
  - Core HTTP request lifecycle remains unchanged.
- Compatibility impact:
  - Breaking-phase architecture; no compatibility shims retained.
  - Existing `app.hotReload(...)` usage migrated to addon call.
- Operational/testing impact:
  - Failure mode: addon not configured in app process -> VM extensions absent.
  - Rollback behavior: fallback to hot restart path when runtime hooks unavailable.
  - Test strategy note: full `fletch` and `fletch_dev_tools` suites executed with
    integration fixtures migrated to addon API.

### Evidence

- `packages/fletch_dev_tools/lib/src/runtime/fletch_dev_hot_reload.dart`
- `packages/fletch_dev_tools/lib/fletch_dev_tools.dart`
- `packages/fletch/lib/src/services/base_container.dart`
- `packages/fletch/lib/src/services/fletch.dart`
- `packages/fletch_dev_tools/lib/src/process_manager.dart`
- `packages/fletch_dev_tools/test/fixtures/runtime_bridge_app.dart`
- `packages/fletch_dev_tools/test/integration/dev_server_migration_e2e_test.dart`
- `packages/fletch_dev_tools/test/integration/reload_latency_benchmark_integration_test.dart`
- `dart analyze` (`packages/fletch`, `packages/fletch_dev_tools`)
- `dart test` (`packages/fletch`, `packages/fletch_dev_tools`)

### Follow-ups

- Introduce additive API on addon to expose runtime-state snapshot for app-level
  diagnostics endpoints.
- Remove remaining historical classifier markers that reference `.hotReload(` once
  migration is fully complete across docs/examples.

## RLD-20260320-17

- Date: `2026-03-20`
- Title: `Remove legacy incremental compiler shim and stale reload snapshot artifact`
- Status: `Implemented`

### Decision

Remove remaining legacy/duplicate artifacts related to prior reload wiring:

- delete `lib/src/incremental_compiler.dart` shim export,
- export canonical compiler API directly from
  `reload_engine/compiler/incremental_compiler_session.dart`,
- delete stale historical snapshot file
  `fletch_dev_tools_02042026_1770229272.txt`.

### Rationale

The package now has a single canonical reloader/compiler implementation path
under `reload_engine/`; keeping shim/snapshot artifacts increases confusion and
maintenance risk.

### Impact

- Runtime behavior impact:
  - No behavior change; cleanup of duplicate/dead artifacts only.
- Compatibility impact:
  - No backward-compatibility guarantees in current design phase.
- Operational/testing impact:
  - Failure mode: broken exports after shim deletion.
  - Rollback behavior: revert cleanup commit if downstream tooling depends on
    removed paths.
  - Test strategy note: full package analyze + test suite run post-removal.

### Evidence

- `lib/fletch_dev_tools.dart`
- `lib/src/reload_engine/compiler/incremental_compiler_session.dart`
- `dart analyze`
- `dart test`

### Follow-ups

- Remove/flatten additional legacy analyzer APIs once classifier consumes AST
  deltas directly without `ChangeAnalyzer` intermediate mapping.

## RLD-20260320-16

- Date: `2026-03-20`
- Title: `Phase 5 benchmark expansion: route-graph reload latency scenario`
- Status: `Implemented`

### Decision

Extend the real integration benchmark harness to include a dedicated
route-graph scenario (watcher-driven edits to a route registration file)
in addition to body-only edits.

### Rationale

Route-graph reloads include route reassemble work and should be tracked
separately from body-only reload latency.

### Impact

- Runtime behavior impact:
  - No runtime behavior changes; benchmark/test-only addition.
- Compatibility impact:
  - No compatibility concerns in design phase.
- Operational/testing impact:
  - Failure mode: route fixture classification drift (missing route reassemble).
  - Rollback behavior: not applicable (measurement harness).
  - Test strategy note: benchmark output now reports two fixture classes:
    `body_only` and `route_graph`.

### Evidence

- `test/integration/reload_latency_benchmark_integration_test.dart`
- `dart test test/integration/reload_latency_benchmark_integration_test.dart -r expanded`

### Follow-ups

- Add container-shape + migration-enabled benchmark variant.
- Export benchmark samples as JSON artifact for CI trend charts.
- Promote benchmark entries to `Validated` after repeated runs on standard dev hardware.

## RLD-20260320-15

- Date: `2026-03-20`
- Title: `Phase 5 benchmark fixture: real test-project reload latency measurement`
- Status: `Implemented`

### Decision

Add an integration benchmark that boots a real temporary fixture app via
`FletchDevServer`, triggers watcher-driven file edits, and records
`reload_total_ms` for each reload through an injected metrics sink.

### Rationale

Phase 5 requires actual end-to-end timing evidence from a running project,
not only unit-level timing proxies.

### Impact

- Runtime behavior impact:
  - No runtime behavior change; test-only benchmark harness.
- Compatibility impact:
  - No compatibility concerns in design phase.
- Operational/testing impact:
  - Failure mode: benchmark edit loop or watcher sequencing flake.
  - Rollback behavior: not applicable (measurement-only harness).
  - Test strategy note: measures repeated body-only edits and reports sample
    list with computed p50/p95 in test output.

### Evidence

- `test/integration/reload_latency_benchmark_integration_test.dart`
- `dart test test/integration/reload_latency_benchmark_integration_test.dart -r expanded`

### Follow-ups

- Add route-graph and container-shape benchmark variants.
- Add machine-readable benchmark output artifact for CI trend tracking.
- Promote to `Validated` after repeated baseline runs across dev machines.

## RLD-20260320-14

- Date: `2026-03-20`
- Title: `Phase 5 baseline: RFC metrics wiring and hardening harness`
- Status: `Implemented`

### Decision

Add first-pass Phase 5 observability/hardening coverage by:

- wiring RFC metric names into server/runtime flow (classify/detect/compile/stage/activate/total timing, compile/activation/rollback counters, queue/in-flight/active-age gauges),
- propagating a shared `ReloadMetricsSink` through `FletchDevServer`,
- adding a hardening harness test for burst queue behavior and transaction-path p50/p95 envelope checks.

### Rationale

Phase 5 requires measurable telemetry and repeatable stress signals before
optimization tuning. Baseline instrumentation and a deterministic harness
provide a stable foundation for future SLO validation.

### Impact

- Runtime behavior impact:
  - Metrics are emitted at key reload phases and failure paths
    (target: 100% of non-empty batches emit `reload_total_ms` and queue depth
    gauge updates).
- Compatibility impact:
  - No backward-compatibility constraints in this design phase; constructor
    gains additive metrics injection with no shim/deprecation path.
- Operational/testing impact:
  - Failure mode: metric label drift or missing emission in edge paths.
  - Rollback behavior: rollback counter now increments on migration rollback.
  - Test strategy note: load-style queue storm and p50/p95 envelope checks run
    in automated tests.

### Evidence

- `lib/src/reload_engine/shared/reload_metrics.dart`
- `lib/src/dev_server.dart`
- `lib/src/reload_engine/runtime/reload_transaction_engine.dart`
- `test/reload_engine/phase5_hardening_test.dart`
- `dart analyze`
- `dart test`

### Follow-ups

- Add structured JSON log mode including transaction/generation IDs and
  per-phase durations.
- Add nightly chaos profile covering compiler daemon crash and runtime retire
  delay/failure injection.
- Promote Phase 5 entry to `Validated` after benchmark fixture runs capture
  stable p50/p95 evidence on representative apps.

## RLD-20260320-13

- Date: `2026-03-20`
- Title: `Phase 4 integration harness: fixture-based migration lifecycle coverage`
- Status: `Implemented`

### Decision

Add integration tests with real fixture hooks and file-backed side effects to
validate migration lifecycle behavior beyond unit stubs:

- success path (`prepare -> commit`)
- commit failure rollback (`rollback` reverse order)
- prepare timeout rollback of already-prepared hooks

### Rationale

Phase 4 required a fixture-level harness to verify hook ordering and rollback
semantics in a realistic async/file I/O environment.

### Impact

- Runtime behavior impact:
  - Migration lifecycle ordering and rollback semantics now have integration
    regression coverage (target: 100% pass on all three lifecycle scenarios).
- Compatibility impact:
  - No compatibility concerns; test-only additions.
- Operational/testing impact:
  - Failure mode: async timing and hook side-effect ordering drift.
  - Rollback behavior: integration assertions verify reverse-order rollback
    under commit failure and prepare timeout.
  - Test strategy note: file-backed fixture hooks used to assert durable phase
    traces.

### Evidence

- `test/fixtures/migration_fixture_hooks.dart`
- `test/integration/reload_migration_integration_test.dart`

### Follow-ups

- Add end-to-end `FletchDevServer` integration using a fixture app that
  exercises migration hooks through watcher-triggered reloads.
- Add failure-injection coverage for rollback hook exceptions and timeout.

## RLD-20260320-12

- Date: `2026-03-20`
- Title: `Phase 4 skeleton: migration hooks with policy, timeout, and rollback semantics`
- Status: `Implemented`

### Decision

Introduce migration lifecycle primitives and wire them into hot-reload flow for
`containerShapeChange` strategy:

- `ReloadStateMigrationHook` (`onPrepare`, `onCommit`, `onRollback`)
- `ReloadMigrationPolicy` (enabled flag + phase timeouts)
- `ReloadMigrationRunner` / `ReloadMigrationSession`
- `ReloadMigrationException` with hook/phase attribution

`FletchDevServer` now:

- executes migration prepare/commit for container-shape reloads when enabled,
- rolls back hooks on prepare/commit/activation failure,
- falls back to hot restart when container-shape changes are detected but
  migration is disabled.

### Rationale

Phase 4 requires explicit migration control to avoid unsafe container-shape hot
reloads. Disabled-by-default policy provides guardrails while hooks remain in
design iteration.

### Impact

- Runtime behavior impact:
  - Container-shape edits can run controlled migration phases before activate.
  - Failure in prepare/commit paths now aborts transaction and preserves
    previous generation as active (target: zero activation on failed
    prepare/commit paths).
- Compatibility impact:
  - Breaking-phase architecture retained; no compatibility shims/deprecations.
  - Migration is opt-in via policy + non-empty hook list.
- Operational/testing impact:
  - Failure mode: hook timeout/exception.
  - Rollback behavior: reverse-order `onRollback` on prepared hooks, best-effort
    logging on rollback failure.
  - Test strategy note: unit coverage for order, timeout, rollback behavior, and
    disabled-policy no-op.

### Evidence

- `lib/src/reload_engine/runtime/reload_migration.dart`
- `lib/src/dev_server.dart`
- `lib/src/reload_engine/reload_engine.dart`
- `test/reload_engine/reload_migration_test.dart`

### Follow-ups

- Add fixture-based integration test with real app-level migration hooks.
- Extend migration context with user-defined metadata payload.
- Add migration metrics (`prepare_ms`, `commit_ms`, `rollback_ms`, failure counts).

## RLD-20260320-11

- Date: `2026-03-20`
- Title: `Expose compiler recovery policy knobs via server and CLI`
- Status: `Implemented`

### Decision

Expose incremental compiler recovery controls as first-class runtime config:

- `compilerMaxRecoveryAttempts`
- `compilerMaxDiagnostics`
- `compilerRecoveryBackoff` (Duration / ms in CLI)

and plumb them through `FletchDevServer` and `fletch dev` CLI flags.

### Rationale

Phase 3 hardening introduced recovery behavior, but policy was fixed in code.
Teams need workload-specific tuning for noisy/slow environments without
patching source.

### Impact

- Runtime behavior impact:
  - Recovery retries and delay are now tunable (target: configure recovery
    attempts in range `0..N` and backoff in ms without code changes).
  - Diagnostics clipping limit is now configurable in normal mode.
- Compatibility impact:
  - Breaking-phase architecture retained; no compatibility shims/deprecations.
  - New CLI options are additive.
- Operational/testing impact:
  - Failure mode: invalid numeric CLI values.
  - Rollback behavior: process exits fast with explicit validation error and
    no server process side effects.
  - Test strategy note: unit tests validate constructor constraints, retry
    disabling, and backoff scheduling behavior.

### Evidence

- `lib/src/reload_engine/compiler/incremental_compiler_session.dart`
- `lib/src/dev_server.dart`
- `bin/fletch.dart`
- `test/reload_engine/incremental_compiler_session_test.dart`
- `README.md`

### Follow-ups

- Add CLI/integration tests for invalid option parsing and startup behavior.
- Consider exposing policy in project config file to avoid long CLI invocations.

## RLD-20260320-10

- Date: `2026-03-20`
- Title: `Phase 3 compiler hardening: daemon desync recovery and bounded diagnostics`
- Status: `Implemented`

### Decision

Add a dedicated compiler session module at
`reload_engine/compiler/incremental_compiler_session.dart` and route
`IncrementalCompiler` through it with:

- one-cycle daemon desync recovery for compile/accept failures,
- baseline re-bootstrap during recovery,
- bounded diagnostics in non-verbose mode,
- explicit recovery metadata in compile results for observability.

### Rationale

Phase 3 requires a robust incremental compiler control loop. A single daemon
protocol desync should not force a restart cycle or leave the next edit stuck
in a broken compiler state.

### Impact

- Runtime behavior impact:
  - Compile gate can self-recover daemon desync within one reload cycle
    (target: recover in `<= 1` cycle for thrown compile/accept errors).
  - Normal-mode diagnostics are bounded at session level to prevent noisy
    unbounded compiler output from dominating logs.
- Compatibility impact:
  - Breaking-friendly architecture phase retained; old implementation replaced
    by session module with no compatibility shims/deprecations.
  - `reload_engine` barrel now exports compiler session API.
- Operational/testing impact:
  - Failure mode: repeated daemon startup failure after desync.
  - Rollback behavior: return failed compile result and preserve active runtime
    generation (no forced restart from compile gate failure path).
  - Test strategy note: fake-client unit tests simulate compile throw,
    accept throw, baseline failure, and diagnostics clipping.

### Evidence

- `lib/src/reload_engine/compiler/incremental_compiler_session.dart`
- `lib/src/incremental_compiler.dart`
- `lib/src/dev_server.dart`
- `lib/src/reload_engine/reload_engine.dart`
- `test/reload_engine/incremental_compiler_session_test.dart`

### Follow-ups

- Add integration test that injects compiler daemon process failure mid-session.
- Add explicit recovery counters/histograms into `ReloadMetricsSink`.
- Thread per-phase retry policy from config into compiler session attempts.

## RLD-20260320-09

- Date: `2026-03-20`
- Title: `Phase 3 classifier v2 pass: dependency graph invalidation and DI/route strategy signals`
- Status: `Implemented`

### Decision

Introduce `DependencyGraphStore` under `reload_engine/classifier/` and wire
`FletchDevServer` classification to use graph-derived impact:

- maintain import/export/part reverse edges for changed Dart files,
- expand compile invalidation sets from changed files to reverse dependents,
- detect route and DI touchpoints in impacted graph nodes,
- map DI impact to `ReloadStrategy.containerShapeChange`,
- keep restart-safe precedence (`RestartRequired` still wins).

### Rationale

Phase 3 requires graph-aware invalidation and strategy selection beyond simple
per-file booleans. This provides a practical v1 graph model while preserving a
safe fallback path to restart behavior.

### Impact

- Runtime behavior impact:
  - Incremental compile gate now uses graph-expanded invalidation paths
    (target: fewer than 1 restart fallback per 100 body-only edits in local
    development scenarios).
  - Strategy mapper can now emit `containerShapeChange` when DI touchpoints are
    impacted.
- Compatibility impact:
  - Breaking by design in this phase; no backward-compatibility shims added.
  - Public reload-engine exports now include `dependency_graph.dart`.
- Operational/testing impact:
  - New unit tests cover reverse-edge invalidation expansion, package self-import
    resolution, route/DI touchpoint detection, and classifier precedence.
  - Failure mode: graph parse/update failure or stale graph may over/under-shoot
    invalidation.
  - Rollback behavior: classifier still falls back to analysis-only restart-safe
    path (`RestartRequired` precedence and changed-path fallback).
  - Test strategy note: unit-first validation for classifier/graph logic before
    compiler-session hardening integration.

### Evidence

- `lib/src/reload_engine/classifier/dependency_graph.dart`
- `lib/src/reload_engine/classifier/change_classifier.dart`
- `lib/src/dev_server.dart`
- `lib/src/reload_engine/reload_engine.dart`
- `test/reload_engine/dependency_graph_test.dart`
- `test/reload_engine/change_classifier_test.dart`

### Follow-ups

- Add persistent full-workspace graph bootstrap instead of changed-file-only
  updates for higher precision after process start.
- Replace heuristic route/DI touchpoint detection with AST/symbol-level markers.
- Add integration coverage that asserts compile invalidation expansion under
  save storms with mixed route/DI edits.

## RLD-20260320-08

- Date: `2026-03-20`
- Title: `Phase 3 kickoff: classifier extraction and submit-based intake`
- Status: `Implemented`

### Decision

Start Phase 3 by extracting strategy mapping from `FletchDevServer` into
`reload_engine/classifier/change_classifier.dart` and wiring control-plane
transaction intake through `ReloadEngine.submit(ChangeSet)` instead of direct
manual `createTransaction(...)` calls in the adapter.

### Rationale

Phase 3 requires a dedicated classifier surface and a cleaner control-plane to
engine boundary. Keeping strategy logic inline in the server would block graph-
based classifier evolution.

### Impact

- Architecture: strategy selection now lives in classifier module (`ChangeClassifier`).
- Adapter boundary: watcher/coalesced batches now start transactions via
  `submit(ChangeSet, strategy: ...)`, reducing adapter ownership of transaction
  sequencing details.
- Engine API: `ReloadEngine.submit` now accepts strategy/message metadata for
  transaction bootstrap.

### Evidence

- `lib/src/reload_engine/classifier/change_classifier.dart`
- `lib/src/reload_engine/runtime/reload_engine.dart`
- `lib/src/reload_engine/runtime/reload_transaction_engine.dart`
- `lib/src/dev_server.dart`
- `test/reload_engine/change_classifier_test.dart`
- `test/reload_engine/in_memory_reload_engine_test.dart`

### Follow-ups

- Introduce graph-aware classifier inputs (imports/symbol edges) under
  `classifier/` and migrate `ChangeClassifier` off simple boolean aggregation.
- Rename `test/reload_engine/in_memory_reload_engine_test.dart` file path to
  match `ReloadTransactionEngine`.

---

## RLD-20260320-07

- Date: `2026-03-20`
- Title: `Phase 2.7 stabilization: clean breaks before Phase 3`
- Status: `Implemented`

### Decision

Apply a no-compatibility cleanup pass before classifier-v2 work:

- replace hardcoded integration-test working directory with dynamic package-root
  resolution,
- rename transaction runtime to `ReloadTransactionEngine`,
- move reload metrics abstraction to `reload_engine/shared/`,
- remove ordinal-based stale-phase guard and rely on transition rules,
- prune terminal transactions from in-memory active transaction cache,
- add `submit(ChangeSet)` to `ReloadEngine` contract,
- add a unit test for VM extension payload envelope decoding.

### Rationale

Phase 3 should build on a clean and unambiguous engine boundary. Keeping legacy
names/locations and fragile guards would add avoidable coupling and ambiguity.

### Impact

- Architecture: clearer engine naming and shared metrics location.
- Reliability: terminal transaction cache now bounded; no unbounded growth from
  completed entries.
- Testing: runtime bridge integration test is now machine-portable; payload
  decoding has direct unit coverage.

### Evidence

- `lib/src/reload_engine/runtime/reload_transaction_engine.dart`
- `lib/src/reload_engine/runtime/reload_engine.dart`
- `lib/src/reload_engine/shared/reload_metrics.dart`
- `lib/src/reload_engine/reload_engine.dart`
- `lib/src/dev_server.dart`
- `lib/src/hot_reloader.dart`
- `test/reload_engine/in_memory_reload_engine_test.dart`
- `test/hot_reloader_payload_decoder_test.dart`
- `test/integration/runtime_generation_bridge_integration_test.dart`

### Follow-ups

- Rename `test/reload_engine/in_memory_reload_engine_test.dart` file path to
  match `ReloadTransactionEngine` naming.
- Start Phase 3 classifier extraction from `dev_server.dart` into
  `classifier/change_classifier.dart`.

---

## RLD-20260320-06

- Date: `2026-03-20`
- Title: `Fix VM extension payload decoding for runtime generation bridge`
- Status: `Implemented`

### Decision

Harden VM service extension response decoding in `HotReloader` to support
service-protocol envelope nesting (`result` / `response`) instead of assuming a
single flat `response.json['result']` shape.

### Rationale

The runtime bridge integration test failed because extension responses were
successfully returned but `ok` was not found in the parsed payload, causing
false-negative activation results.

### Impact

- Reliability: `activateGeneration` / `retireGeneration` now correctly interpret
  extension responses across response envelope variants.
- Validation: live runtime bridge integration test now passes consistently.

### Evidence

- `lib/src/hot_reloader.dart`
- `test/integration/runtime_generation_bridge_integration_test.dart`

### Follow-ups

- Consider adding a focused unit test for `_callJsonExtension` payload-shape
  decoding to guard against regressions without requiring process-based
  integration coverage.

---

## RLD-20260320-05

- Date: `2026-03-20`
- Title: `Integration tests for runtime drain bridge and save-storm queue processing`
- Status: `Implemented`

### Decision

Add integration-level coverage for the two highest-risk runtime behaviors:

- VM-extension generation drain behavior under long-lived in-flight request,
- queued/coalesced batch processing under save-storm style enqueue bursts.

### Rationale

Phase 2 correctness depends on runtime/request coupling and burst edit handling,
not only unit-level model tests.

### Impact

- Test confidence: verifies runtime extension bridge behavior in a live child
  process, including forced retire semantics.
- Reliability: verifies queued processor drains events that arrive while work
  is already in-flight and preserves unique changed paths under burst load.

### Evidence

- `test/fixtures/runtime_bridge_app.dart`
- `test/integration/runtime_generation_bridge_integration_test.dart`
- `lib/src/change_batch_processor.dart`
- `test/integration/change_batch_processor_integration_test.dart`

### Follow-ups

- Add a dev-server end-to-end integration harness that asserts transaction
  phase ordering during save storms.
- Add runtime bridge test coverage for non-forced retire path with delayed
  release timing variations.

---

## RLD-20260320-04

- Date: `2026-03-20`
- Title: `Runtime in-flight generation hooks bridged via VM service extensions`
- Status: `Implemented`

### Decision

Bridge generation activate/retire semantics into the runtime process via
dedicated VM service extensions:

- runtime (`fletch`) now tracks in-flight requests by generation id,
- runtime exposes extension endpoints for:
  - `ext.fletch.reload.activateGeneration`
  - `ext.fletch.reload.retireGeneration`
  - `ext.fletch.reload.runtimeState`
- control plane (`fletch_dev_tools`) now calls activate/retire extensions from
  `HotReloader` during generation swap.

### Rationale

`ActiveGenerationStore` in dev tools cannot observe live request flow directly
because requests are processed in the child runtime process. A VM-extension
bridge provides explicit control/runtime coordination without process coupling.

### Impact

- Runtime correctness: retire decisions can now account for real in-flight
  requests in the serving runtime when extensions are enabled.
- Operations: dev server logs when runtime generation hooks are unavailable and
  falls back to local retire behavior.
- Compatibility: additive dev-time extension API.

### Evidence

- `packages/fletch/lib/src/dev/reload_runtime_state.dart`
- `packages/fletch/lib/src/services/fletch.dart`
- `lib/src/hot_reloader.dart`
- `lib/src/dev_server.dart`
- `packages/fletch/test/unit/reload_runtime_state_test.dart`

### Follow-ups

- Add integration test covering long-lived request drain across generation
  retirement in a live child process.
- Consider making runtime hook registration opt-in independent of
  `app.hotReload(...)`.

---

## RLD-20260320-03

- Date: `2026-03-20`
- Title: `Queue-backed event intake and generation lifecycle integration in dev server`
- Status: `Implemented`

### Decision

Integrate Phase 2 runtime primitives into `FletchDevServer` and replace
drop-on-busy behavior with queued coalescing:

- add `ChangeBatchQueue` and drain-until-quiescent processing loop,
- stage/activate generation handles on successful reload/restart,
- retire previous generation through `GenerationRetireManager`,
- mark runtime readiness milestones during startup/restart lifecycle.

### Rationale

Phase 2 primitives were present but not applied in the control-plane adapter.
The previous `_busy` guard could silently drop file changes under save bursts.

### Impact

- Runtime: generation activation and retirement are now explicit in server flow.
- Reliability: no silent event drop while reload/restart work is in progress.
- Operations: startup now logs runtime readiness confirmation when hot reload
  connectivity is available.

### Evidence

- `lib/src/change_batch_queue.dart`
- `lib/src/dev_server.dart`
- `test/change_batch_queue_test.dart`

### Follow-ups

- Replace event-level path strings with canonicalized real paths.
- Add integration tests for queue behavior under concurrent bursty edits.
- Wire request-level in-flight accounting from runtime plane into retire logic.

---

## RLD-20260320-02

- Date: `2026-03-20`
- Title: `Phase 2 skeleton for generation runtime, retire/drain, readiness handshake`
- Status: `Implemented`

### Decision

Introduce dedicated runtime-generation skeleton components:

- immutable `GenerationHandle`,
- `ActiveGenerationStore` for active pointer and in-flight accounting,
- `GenerationRetireManager` for drain/force-retire behavior,
- `RuntimeReadinessCoordinator` for startup readiness handshake.

### Rationale

Phase 2 requires explicit runtime primitives before integrating full atomic
activation into serving flow.

### Impact

- Runtime: additive primitives only; no serving-path replacement yet.
- Compatibility: new internal API surface under `reload_engine/runtime`.
- Operations: readiness and retire semantics are now testable in isolation.

### Evidence

- `lib/src/reload_engine/runtime/generation_handle.dart`
- `lib/src/reload_engine/runtime/active_generation_store.dart`
- `lib/src/reload_engine/runtime/generation_retire_manager.dart`
- `lib/src/reload_engine/runtime/runtime_readiness.dart`
- `test/reload_engine/active_generation_store_test.dart`
- `test/reload_engine/generation_retire_manager_test.dart`
- `test/reload_engine/runtime_readiness_test.dart`

### Follow-ups

- Integrate `ActiveGenerationStore` into `FletchDevServer` activation path.
- Wire `GenerationRetireManager` into post-activation generation retirement.
- Use readiness coordinator to gate process start completion.

---

## RLD-20260320-01

- Date: `2026-03-20`
- Title: `Phase 1.5 explicit phase timeouts and idempotent adapter transitions`
- Status: `Implemented`

### Decision

Add explicit timeout budgets per reload phase in the dev-server adapter and
make engine transition calls idempotent for duplicate or stale phase requests.

### Rationale

Phase 1 lacked enforced timeout boundaries and could apply duplicate transition
calls when retry/fallback paths reused transaction objects.

### Impact

- Runtime: phase operations now fail fast on timeout with bounded waits.
- Reliability: duplicate phase transition requests no longer break transaction
  flow; stale transaction handles resolve to latest journaled state.
- Operations: startup now prints phase timeout budgets.

### Evidence

- `lib/src/reload_engine/runtime/reload_phase_timeouts.dart`
- `lib/src/reload_engine/runtime/in_memory_reload_engine.dart`
- `lib/src/dev_server.dart`
- `test/reload_engine/in_memory_reload_engine_test.dart`
- `test/reload_engine/reload_phase_timeouts_test.dart`

### Follow-ups

- Add dedicated timeout/fault injection integration tests at adapter level.
- Add retry policy tuning per phase (instead of single-shot timeout failure).

---

## RLD-20260319-06

- Date: `2026-03-19`
- Title: `Phase 1 transaction journal, replay recovery, and dev server adapter`
- Status: `Implemented`

### Decision

Add append-only transaction journaling with startup recovery for unfinished
transactions, and wire reload transaction lifecycle into `FletchDevServer`.

### Rationale

Phase 1 requires deterministic transaction traceability and crash-recovery
semantics before deeper runtime generation work.

### Impact

- Runtime: each reload/restart batch now maps to a formal transaction with
  tracked phase progression.
- Compatibility: internal behavior changed; new journal file generated under
  `.dart_tool/fletch_dev_tools/`.
- Operations: terminal transaction events (`committed`, `failed`, `aborted`)
  are now observable in logs.

### Evidence

- `lib/src/reload_engine/transaction/reload_transaction_journal.dart`
- `lib/src/reload_engine/runtime/in_memory_reload_engine.dart`
- `lib/src/dev_server.dart`
- `test/reload_engine/reload_transaction_journal_test.dart`
- `test/reload_engine/in_memory_reload_engine_test.dart`

### Follow-ups

- Add durable replay reconciliation policy for partially written journal lines.
- Add transaction timeout enforcement wiring in runtime adapter.

---

## RLD-20260319-05

- Date: `2026-03-19`
- Title: `Phase 0 scaffold for reload engine module and transaction models`
- Status: `Implemented`

### Decision

Introduce the initial `reload_engine` module structure, core transaction/generation
models, event stream contract, metrics sink abstraction, and a phase-0 in-memory
engine implementation for contract validation.

### Rationale

We need a concrete base to build the transaction runtime without coupling to
legacy reload flow immediately.

### Impact

- Runtime: additive scaffolding; no serving-path integration yet.
- Compatibility: new API surface added for the next-generation engine.
- Operations: enables isolated testing of transaction semantics.

### Evidence

- `lib/src/reload_engine/**`
- `test/reload_engine/reload_transaction_test.dart`
- `test/reload_engine/in_memory_reload_engine_test.dart`

### Follow-ups

- Phase 1 transaction journal + replay.
- Engine adapter into existing `FletchDevServer`.

---

## RLD-20260319-04

- Date: `2026-03-19`
- Title: `Add verbose incremental compiler mode`
- Status: `Implemented`

### Decision

Add a CLI/runtime switch (`--verbose-compiler`) to surface full incremental
compiler protocol and diagnostics.

### Rationale

Compiler protocol details are required to debug incremental compile/reject
state mismatches and to tune reload latency.

### Impact

- Runtime: richer logs when enabled.
- Compatibility: additive, no behavior change in normal mode.
- Operations: better diagnosis during reload failures.

### Evidence

- `bin/fletch.dart`
- `lib/src/dev_server.dart`
- `lib/src/incremental_compiler.dart`

### Follow-ups

- Add log redaction strategy if diagnostics include sensitive paths.

---

## RLD-20260319-03

- Date: `2026-03-19`
- Title: `Introduce frontend-server incremental compile gate`
- Status: `Implemented`

### Decision

Run a persistent incremental compiler session and compile only invalidated Dart
files before VM reload.

### Rationale

Avoid applying reload attempts when source is invalid and reduce time spent on
full compile cycles for small edits.

### Impact

- Runtime: compile gate before reload.
- Compatibility: reload flow behavior changed.
- Operations: compile diagnostics available on failure.

### Evidence

- `lib/src/incremental_compiler.dart`
- `lib/src/dev_server.dart`
- `pubspec.yaml` (`frontend_server_client` direct dependency)

### Follow-ups

- Couple compile artifact and reload activation transactionally.

---

## RLD-20260319-02

- Date: `2026-03-19`
- Title: `Batch file events and reload once per coalesced change set`
- Status: `Implemented`

### Decision

Coalesce watcher events by path and process a single batch action
(hot reload or restart) instead of reacting to each event individually.

### Rationale

Editors commonly emit multiple file events during one save. Batch handling
reduces thrash and duplicate reload attempts.

### Impact

- Runtime: fewer redundant reload/restart cycles.
- Compatibility: behavior timing changed (debounced batch semantics).
- Operations: clearer logs with per-batch path summary.

### Evidence

- `lib/src/dev_file_watcher.dart`
- `lib/src/dev_server.dart`

### Follow-ups

- Replace drop-on-busy with queued batching to prevent event loss.

---

## RLD-20260319-01

- Date: `2026-03-19`
- Title: `Add route-aware reassemble heuristic`
- Status: `Implemented`

### Decision

During hot reload-safe changes, reassemble routes only when changed files appear
to touch route registration.

### Rationale

Route reassemble is useful but not always required. Skipping it for non-routing
files reduces overhead.

### Impact

- Runtime: conditional route reassemble.
- Compatibility: path/content heuristic may misclassify edge cases.
- Operations: adds strategy visibility in logs.

### Evidence

- `lib/src/change_analyzer.dart`
- `test/change_analyzer_test.dart`

### Follow-ups

- Replace heuristic with symbol-level dependency graph classification.
