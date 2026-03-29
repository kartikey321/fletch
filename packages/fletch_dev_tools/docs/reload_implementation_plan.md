# Reload Runtime Implementation Plan

- Project: `fletch_dev_tools`
- Plan Version: `v1`
- Date: `2026-03-19`
- Source RFC: `docs/reload_runtime_rfc.md`
- Changelog Policy: `docs/changelog_policy.md`
- Active Decision Log: `docs/reload_design_changelog.md`

## 1. Purpose

This plan translates the reload runtime RFC into executable implementation
phases with measurable outcomes.

The plan assumes:

1. Breaking changes are allowed.
2. Existing reload APIs may be replaced.
3. Correctness and transaction safety are prioritized over preserving current
   behavior.

## 2. Delivery Principles

1. No phase closes without passing acceptance criteria.
2. Every architecture-impacting change must be logged in
   `reload_design_changelog.md`.
3. Each phase produces:
   - code artifacts,
   - tests,
   - metrics/logging hooks,
   - explicit rollback strategy.

## 3. Milestone Map

1. Milestone A: Transaction foundation
2. Milestone B: Generation runtime and atomic activation
3. Milestone C: Classifier v2 and graph invalidation
4. Milestone D: State migration hooks and hardening
5. Milestone E: Performance tuning and release readiness

## 4. Phase Plan

## Phase 0: Baseline and Scaffolding

### Objective

Create the minimal skeleton for the new reload engine without changing runtime
activation behavior yet.

### Deliverables

1. New module layout:
   - `lib/src/reload_engine/`
   - `lib/src/reload_engine/transaction/`
   - `lib/src/reload_engine/runtime/`
   - `lib/src/reload_engine/compiler/`
   - `lib/src/reload_engine/classifier/`
2. Core model types:
   - `ReloadTransaction`
   - `GenerationId`
   - `ReloadStrategy`
   - `ReloadPhase`
3. Structured event model:
   - `ReloadEvent` stream
4. Metrics interface abstraction (no backend lock-in).

### Acceptance Criteria

1. `dart analyze` clean.
2. Unit tests for model serialization/state transitions pass.
3. Event stream contract documented.

### Risks

1. Over-coupling to existing `FletchDevServer`.

### Mitigation

1. Build adapter layer; do not embed new logic directly in legacy classes.

---

## Phase 1: Transaction Engine

### Objective

Implement deterministic transaction orchestration:

`Detect -> Classify -> Compile -> Stage -> Activate -> Retire`.

### Deliverables

1. Transaction state machine with idempotent transitions.
2. Transaction journal (append-only local store).
3. Recovery logic:
   - on startup, replay unfinished transactions as `aborted`.
4. Timeouts per phase:
   - classify timeout
   - compile timeout
   - stage timeout
   - activate timeout
   - retire timeout

### Acceptance Criteria

1. Invalid transition attempts are rejected and logged.
2. Duplicate transaction messages do not cause duplicate activation.
3. Crash recovery test passes (simulated mid-transaction kill).

### Test Plan

1. Unit tests for all transition edges.
2. Integration test with fake compiler and fake runtime plane.

### Risks

1. State machine complexity introduces hidden dead states.

### Mitigation

1. Generate transition table and assert full coverage in tests.

---

## Phase 2: Runtime Generation System

### Objective

Replace mutable in-place reload behavior with immutable generation activation.

### Deliverables

1. `GenerationHandle` with immutable route/middleware/container snapshot.
2. Atomic active generation pointer swap.
3. In-flight request accounting by generation.
4. Retire/drain logic with timeout and forced retire metrics.
5. Runtime readiness handshake:
   - mark "started" only after generation is active and listener is reachable.

### Acceptance Criteria

1. Successful activation causes zero dropped requests in integration test.
2. Failed staging or activation leaves old generation active.
3. Process-start success is gated by readiness handshake.

### Test Plan

1. Concurrency integration tests with sustained request load.
2. Activation failure injection tests.

### Risks

1. Request handling path overhead regression.

### Mitigation

1. Benchmark baseline before and after generation pointer adoption.

---

## Phase 3: Compiler and Invalidation Pipeline v2

### Objective

Upgrade from file-heuristic compile gate to graph-aware invalidation and
strategy selection.

### Deliverables

1. Dependency graph store:
   - file nodes
   - import/export edges
   - route registration and DI touchpoints
2. Invalidation planner:
   - changed file set -> affected subgraph
3. Strategy mapper:
   - `BodyOnlyHotSwap`
   - `RouteGraphChange`
   - `ContainerShapeChange`
   - `RestartRequired`
4. Compiler session hardening:
   - robust reject/accept flow
   - recovery on daemon desync
   - bounded diagnostics in normal mode

### Acceptance Criteria

1. Body-only edit compiles and activates without restart.
2. Route graph edit triggers route regeneration path.
3. Syntax error does not restart runtime by default.
4. Compiler protocol desync self-recovers within one cycle.

### Test Plan

1. Golden scenario tests for each strategy class.
2. Negative tests for malformed source and generated artifact changes.

### Risks

1. Graph precision bugs can misclassify reload strategy.

### Mitigation

1. Keep safe fallback to `RestartRequired` with explicit reason logging.

---

## Phase 4: State Migration Hooks

### Objective

Enable controlled in-memory state transitions for container/shape changes.

### Deliverables

1. Migration hook interface:
   - `onPrepare`
   - `onCommit`
   - `onRollback`
2. Hook execution policy:
   - ordering
   - timeout behavior
   - failure semantics
3. Safety guardrails:
   - migration disabled by default unless explicitly configured.

### Acceptance Criteria

1. Migration success path validated with fixture app.
2. Migration failure rolls back to previous generation.
3. Timeout/failure emits explicit rollback events.

### Test Plan

1. Integration tests with synthetic mutable state fixture.
2. Rollback correctness assertions on failed `onPrepare`.

### Risks

1. User migration code can block activation path.

### Mitigation

1. Enforce strict migration timeout and rollback.

---

## Phase 5: Observability, Performance, and Hardening

### Objective

Meet SLOs and prepare for stable release.

### Deliverables

1. Metrics implementation for all RFC-defined counters/histograms.
2. Structured logging with transaction/generation IDs.
3. Load test harness:
   - save storms
   - long-lived requests
   - compiler crash injection
4. Performance tuning passes.

### Acceptance Criteria

1. Target SLOs met in benchmark suite:
   - p50 reload < 150ms
   - p95 reload < 300ms (body-only scenario)
2. No silent event drops under bursty edit simulation.
3. Rollback and recovery scenarios pass in chaos test suite.

### Test Plan

1. Automated perf regression job.
2. Chaos tests in CI nightly profile.

### Risks

1. Metrics overhead skews reload latency.

### Mitigation

1. Low-overhead sampling and lazy payload construction.

## 5. Work Breakdown Structure (Engineering Tasks)

## WBS-A: Engine Foundation

1. Create engine module and model types.
2. Add transaction state machine + event bus.
3. Add journal persistence abstraction.

## WBS-B: Runtime Plane

1. Build generation builder interface.
2. Implement active generation atomic pointer.
3. Implement drain/retire manager.
4. Add readiness/liveness signaling.

## WBS-C: Control Plane

1. Replace busy-drop watcher path with queue/coalescer.
2. Integrate classifier v2 and invalidation planner.
3. Integrate compiler daemon via transaction phases.

## WBS-D: Migration and Safety

1. Introduce migration hook interfaces.
2. Add rollback trigger path.
3. Add timeout/failure guards.

## WBS-E: Validation and Tooling

1. Add integration fixture apps.
2. Add load + chaos scenarios.
3. Add metrics dashboards and log schema docs.

## 6. Acceptance Matrix

| Capability | Phase | Must Pass Test |
| --- | --- | --- |
| Transaction rollback | 1 | Simulated compile failure leaves old generation active |
| Atomic activation | 2 | Concurrent request load with zero dropped requests |
| No restart on syntax error | 3 | Syntax error edit does not restart runtime |
| Migration safety | 4 | Failed migration triggers rollback |
| SLO compliance | 5 | p50/p95 latency thresholds met |

## 7. Changelog Integration Workflow

For each implementation PR:

1. Add `Planned` changelog entry with scope and target phase.
2. Merge code and update entry to `Implemented`.
3. After test/benchmark evidence, update to `Validated`.
4. If superseded, add new entry and mark old one `Superseded`.

## 8. Suggested Branching Strategy

1. `feature/reload-engine-phase-0`
2. `feature/reload-engine-phase-1-transaction`
3. `feature/reload-engine-phase-2-generation`
4. `feature/reload-engine-phase-3-classifier`
5. `feature/reload-engine-phase-4-migration`
6. `feature/reload-engine-phase-5-hardening`

## 9. Exit Criteria for v1 Runtime

The new runtime is ready when:

1. Phases 0-5 are completed and validated.
2. SLO targets are met consistently across benchmark fixtures.
3. Rollback/recovery behavior is deterministic in chaos tests.
4. Documentation and changelog reflect final architecture.

