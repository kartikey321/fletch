# RFC: High-Performance Transactional Reload Runtime

- Project: `fletch_dev_tools`
- Status: `Draft`
- Last Updated: `2026-03-19`
- Owners: `fletch_dev_tools maintainers`
- Compatibility Policy: `Breaking changes allowed in this phase`

## 1. Executive Summary

This RFC defines a new reload architecture for `fletch_dev_tools` that treats
reload as a transactional runtime operation rather than a best-effort watcher
action.

The design is inspired by proven properties from Phoenix/BEAM ecosystems:

- code transitions should be safe and explicit,
- failures should be isolated,
- the old working version should continue serving if a new version fails.

The end state is a two-plane system:

1. Control plane:
   - watches changes,
   - compiles incrementally,
   - classifies changes,
   - executes a reload transaction.
2. runtime plane:
   - serves HTTP traffic,
   - applies generation swaps atomically,
   - supports rollback/drain semantics.

## 2. Problem Statement

The current design has useful pieces (watching, VM reload, incremental compile
gate), but it is still tool-centric rather than runtime-centric.

### 2.1 Current Pain Points

1. Reload success can be inferred from process lifecycle instead of service
   readiness.
2. Syntax/compile error flows can still push the system into unnecessary restart
   paths.
3. Event handling can lose intent under bursty saves (busy-drop behavior).
4. Route reassembly is heuristic and file-content based.
5. No explicit generation model for old/new code coexistence and in-flight
   request safety.
6. No formal transaction log or deterministic recovery semantics.

### 2.2 Required Outcomes

1. Correctness first: no broken code activation.
2. Fast path for common body-only edits.
3. Reliable fallback/rollback behavior.
4. Observable and testable internals with measurable SLOs.

## 3. Goals and Non-Goals

### 3.1 Goals

1. Sub-150ms p50 end-to-end safe reload for body-only changes.
2. Zero dropped requests on successful activation.
3. No activation on compile/classification failure.
4. Deterministic rollback to last known good generation.
5. Append-only architecture changelog and decision traceability.

### 3.2 Non-Goals (for this RFC phase)

1. Maintaining backward compatibility with current reload APIs.
2. Solving distributed multi-node hot upgrade in v1 (single-node first).
3. Full BEAM-style remote code replacement semantics (future extension).

## 4. External Inspiration (Phoenix/BEAM)

This design borrows principles, not implementation details.

### 4.1 BEAM / Erlang lessons

From Erlang code loading docs:

1. Atomic module loading semantics (`all-or-nothing`) are critical.
2. `prepare_loading/1` and `finish_loading/1` separate pre-validation and final
   activation windows, minimizing inactive time.
3. Two-version behavior and purge semantics protect in-flight execution.

Design takeaways:

- We need a prepare -> activate split.
- We need generation isolation and safe retirement, not immediate destructive
  replacement.

### 4.2 Phoenix lessons

Phoenix code reloading emphasizes:

1. explicit reloader pipeline in development,
2. recompile then apply, rather than blind runtime mutation,
3. quick feedback loops with live development ergonomics.

Design takeaways:

- Keep dev feedback tight.
- Keep compile and activation as explicit phases with clear diagnostics.

## 5. Core Architecture

## 5.1 Planes

### 5.1.1 Control Plane

Responsibilities:

1. file event ingestion and coalescing,
2. dependency graph maintenance,
3. change classification,
4. incremental compile orchestration,
5. transaction coordination,
6. metrics/log emission.

Process model:

- separate isolate/process from serving runtime.
- can crash/restart without killing the active server generation.

### 5.1.2 Runtime Plane

Responsibilities:

1. socket binding and request serving,
2. generation activation/deactivation,
3. in-flight request accounting,
4. health/readiness contract.

## 5.2 Generations

A `Generation` is an immutable runtime snapshot:

1. route graph
2. middleware pipeline
3. DI container blueprint + resolved factories
4. code artifact metadata
5. activation timestamp
6. schema version for optional state migration hooks

At any time:

- exactly one generation is `Active`,
- zero or one generation is `Staging`,
- zero or one generation is `Retiring`.

## 5.3 Transaction Lifecycle

`Detect -> Classify -> Compile -> Stage -> Validate -> Activate -> Retire -> Commit`

If any step fails before `Activate`:

- abort transaction,
- keep current active generation untouched,
- emit `ReloadFailed` with failure reason and diagnostics.

## 6. Change Classification Model

Classification drives strategy selection:

1. `BodyOnlyHotSwap`
   - function/method body only
   - no signature/shape changes
2. `RouteGraphChange`
   - route registration map changed
3. `ContainerShapeChange`
   - DI registrations/contracts changed
4. `EntryOrRuntimeConfigChange`
   - entrypoint, runtime args, env-sensitive bootstrap changes
5. `GeneratedOrBuildArtifactChange`
   - `.g.dart`, pubspec/dependency graph impact

Strategy mapping:

1. `BodyOnlyHotSwap` -> compile delta + targeted activate
2. `RouteGraphChange` -> compile delta + route table regeneration + activate
3. `ContainerShapeChange` -> compile delta + migration hook path
4. `EntryOrRuntimeConfigChange` -> controlled runtime restart
5. `GeneratedOrBuildArtifactChange` -> controlled runtime restart

## 7. Compile System

## 7.1 Compiler Daemon

Use a persistent incremental compiler daemon:

1. baseline compile at startup
2. recompile with invalidated URI set for each transaction
3. accept/reject protocol per compile attempt
4. artifact metadata recorded in transaction journal

## 7.2 Dependency Graph

Graph nodes:

1. source files
2. generated files
3. module-level symbols (optional phase 2)

Graph edges:

1. import/export
2. route registration references
3. DI registration references

Invalidation rules:

1. changed source invalidates node
2. transitive invalidation to dependents until boundary
3. boundary rules configurable by strategy type

## 7.3 Compile Gate Semantics

Compilation must pass before stage/activate.

On compile error:

1. reject compile result,
2. preserve active generation,
3. publish diagnostics,
4. do not restart by default for syntax-only failures.

## 8. Runtime Activation Model

## 8.1 Atomic Pointer Swap

Runtime holds `AtomicReference<GenerationHandle>`:

1. build `Generation N+1` off-path,
2. verify readiness and invariants,
3. atomically swap active pointer.

## 8.2 In-flight Safety

Each request captures generation handle at dispatch time.

Retirement policy:

1. mark old generation as `Retiring`,
2. stop routing new requests to old generation,
3. wait drain timeout (configurable),
4. force retire if timeout exceeded (with metric).

## 8.3 Route and Middleware Regeneration

Never mutate active route table in place.
Always create a new route graph for staged generation.

## 9. State and Migration

## 9.1 State Classes

1. Stateless code state:
   - safe to swap immediately.
2. Request-local ephemeral state:
   - scoped by generation.
3. In-memory app state:
   - requires optional migration hooks.
4. External durable state:
   - unaffected by reload transaction.

## 9.2 Migration Hook API (proposed)

```dart
abstract class ReloadMigration {
  Future<void> onPrepare(GenerationContext oldGen, GenerationContext newGen);
  Future<void> onCommit(GenerationContext oldGen, GenerationContext newGen);
  Future<void> onRollback(GenerationContext oldGen, GenerationContext failedGen);
}
```

Execution rules:

1. `onPrepare` runs before activation.
2. `onCommit` runs after activation succeeds.
3. `onRollback` runs on activation failure.

## 10. Control/Runtime Protocol

Define explicit message protocol to decouple orchestration and serving:

## 10.1 Messages

1. `PrepareReload(transactionId, changedFiles, strategy)`
2. `CompilePassed(transactionId, artifactRef, diagnostics)`
3. `CompileFailed(transactionId, diagnostics)`
4. `StageReady(transactionId, generationId, readiness)`
5. `Activate(transactionId, generationId)`
6. `ActivationResult(transactionId, success, reason)`
7. `RetireGeneration(generationId, timeoutMs)`
8. `RetireResult(generationId, drained, inflightCount)`

## 10.2 Idempotency

All transaction messages must be idempotent with `(transactionId, generationId)`
keys to survive retries and process restarts.

## 10.3 Timeouts

Each phase has a timeout budget:

1. classify timeout
2. compile timeout
3. stage timeout
4. activate timeout
5. retire timeout

Timeout breach handling:

1. abort phase
2. rollback if needed
3. publish terminal transaction error.

## 11. Health, Readiness, and Correctness Contracts

## 11.1 Child Process Startup

A process is not considered started until:

1. VM service is reachable (if reload enabled),
2. runtime readiness endpoint/handshake succeeds,
3. active generation is initialized.

## 11.2 Readiness API (proposed)

Runtime plane exposes internal readiness event:

```json
{
  "type": "RuntimeReady",
  "generationId": "gen-0001",
  "listenAddress": "127.0.0.1:3011",
  "timestamp": "..."
}
```

## 11.3 Failure Semantics

1. Compile fail -> stay on current generation.
2. Stage fail -> stay on current generation.
3. Activate fail -> rollback to previous active generation.
4. Runtime crash during activation -> recover from journal and last committed
   generation.

## 12. Performance Model and SLOs

## 12.1 Targets

1. Detect+coalesce decision: p50 < 20ms, p95 < 60ms
2. Incremental compile (single-file body edit): p50 < 80ms, p95 < 180ms
3. Stage+activate: p50 < 10ms, p95 < 40ms
4. End-to-end safe reload: p50 < 150ms, p95 < 300ms
5. Restart path (when required): p50 < 900ms, p95 < 1800ms

## 12.2 Performance Techniques

1. long-lived compiler daemon
2. immutable route graph generation
3. lock-free active generation pointer
4. batched file event intake with backpressure
5. bounded logging in normal mode; verbose mode opt-in

## 13. Event Ingestion Model

Current drop-on-busy behavior must be replaced with queued coalescing.

Proposed algorithm:

1. write all watcher events into lock-free queue
2. periodic drain (debounce window)
3. de-duplicate by canonical path
4. merge with pending transaction invalidation set when safe
5. process until queue quiescence

Guarantee:

- no silent event drop.

## 14. Observability

## 14.1 Metrics

Counters:

1. `reload_transactions_total{status,strategy}`
2. `reload_compile_failures_total`
3. `reload_activation_failures_total`
4. `reload_rollbacks_total`

Histograms:

1. `reload_detect_ms`
2. `reload_classify_ms`
3. `reload_compile_ms`
4. `reload_stage_ms`
5. `reload_activate_ms`
6. `reload_total_ms`

Gauges:

1. `reload_inflight_requests`
2. `reload_generation_active_age_ms`
3. `reload_queue_depth`

## 14.2 Structured Logs

Every transaction log line includes:

1. `transaction_id`
2. `generation_from`
3. `generation_to`
4. `strategy`
5. `phase`
6. `duration_ms`
7. `status`

## 15. Security and Safety Considerations

1. Never execute unvalidated generated artifacts.
2. Bound verbose output to avoid accidental secret leakage.
3. Validate file path canonicalization to avoid path traversal edge cases.
4. Treat runtime control protocol as local privileged interface.

## 16. Test Strategy

## 16.1 Unit

1. classifier correctness matrix
2. transaction state machine transitions
3. queue/coalescer behavior under bursts
4. generation pointer atomicity invariants

## 16.2 Integration

1. body-only edit -> compile delta -> activate
2. route change -> graph regenerate -> activate
3. compile error -> no activation, old generation remains live
4. activation failure -> rollback and continue serving
5. restart-required class -> controlled restart path

## 16.3 Load and Chaos

1. high-frequency save storms
2. compile daemon crash mid-transaction
3. runtime plane crash during retire
4. delayed drains with many long-lived requests

## 16.4 Regression Suite

A fixed benchmark app with scripted edit scenarios:

1. body-only route handler edit
2. middleware insertion
3. DI container contract change
4. syntax error and recovery
5. generated file churn

## 17. Rollout Plan

## Phase 0: RFC and Instrumentation Baseline

1. finalize RFC
2. define metrics schema
3. implement changelog policy

## Phase 1: Transaction Engine Skeleton

1. transaction IDs and phase machine
2. journal + replay support
3. compile gate integration

## Phase 2: Generation Runtime

1. immutable generation build path
2. atomic activation + retire
3. in-flight accounting

## Phase 3: Classifier v2 + Graph Invalidation

1. move from file heuristics to symbol-aware classification
2. precise route/DI impact detection

## Phase 4: Migration Hooks + Hardening

1. container migration hooks
2. chaos tests
3. SLO tuning and optimization

## 18. Open Questions

1. Should runtime/control plane run in same OS process with isolates, or
   separate processes for stronger fault isolation?
2. Should we support optional "aggressive mode" that auto-restarts on compile
   errors for teams that prefer forced synchronization?
3. What is the default retire timeout for long-lived streaming endpoints?
4. Should state migration hooks be opt-in per module or global?
5. Should compile daemon be shared across workspaces or per workspace?

## 19. Proposed Initial API Surface (draft)

```dart
class ReloadEngineConfig {
  final Duration debounceWindow;
  final Duration compileTimeout;
  final Duration stageTimeout;
  final Duration activateTimeout;
  final Duration retireTimeout;
  final bool verboseCompiler;
}

abstract class ReloadEngine {
  Future<void> start();
  Future<void> stop();
  Stream<ReloadEvent> get events;
}

class ReloadEvent {
  final String transactionId;
  final String phase;
  final bool success;
  final String? message;
}
```

## 20. Decision Log Integration

All changes to this RFC must be paired with an entry in:

- `docs/reload_design_changelog.md`

Follow update rules in:

- `docs/changelog_policy.md`

## 21. References

1. Erlang `code` module documentation (atomic loading, prepare/finish loading):
   - https://www.erlang.org/docs/24/man/code
2. Phoenix changelog note on code reloader behavior improvements:
   - https://hexdocs.pm/phoenix/1.6.10/changelog.html

