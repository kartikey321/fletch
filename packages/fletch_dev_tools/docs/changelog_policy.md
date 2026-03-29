# Reload Design Changelog Policy

This file defines how to maintain `reload_design_changelog.md`.

## Why

The reload architecture is in active design and will change frequently.
We need a durable decision history with rationale, impact, and validation
status.

## Entry Format

Each entry must include:

1. `ID`
   - Format: `RLD-YYYYMMDD-XX`
   - Example: `RLD-20260319-01`
2. `Date` (ISO format)
3. `Title`
4. `Status`
   - `Planned`, `Implemented`, `Validated`, `Rejected`, `Superseded`
5. `Decision`
6. `Rationale`
7. `Impact`
   - Runtime behavior impact
   - Compatibility impact
   - Operational/testing impact
8. `Evidence`
   - Link to file(s), tests, benchmark output, or logs
9. `Follow-ups`

## Update Rules

1. Never delete history.
2. If a decision changes, add a new entry and mark the old one `Superseded`.
3. Keep entries append-only in reverse chronological order (newest first).
4. When code lands, update entry status to `Implemented`.
5. When tested with measurable proof, update status to `Validated`.

## Compatibility Rules

Because this architecture phase explicitly allows breaking changes:

- Breaking changes are allowed.
- Each entry must still state blast radius and migration effects.
- If migration is not available yet, mark it explicitly.

## Minimal Quality Bar

No decision entry is complete unless it includes:

- At least one measurable target (latency, reliability, or correctness).
- One failure mode and rollback behavior.
- A test strategy note.

