# Fletch Dev Tools Reload Architecture Docs

This folder is the source of truth for the next-generation hot reload runtime
design for `fletch_dev_tools`.

## Documents

- `reload_runtime_rfc.md`
  - Main architecture spec (goals, protocols, components, rollout plan).
- `reload_design_changelog.md`
  - Running log of design decisions and implementation-impacting changes.
- `changelog_policy.md`
  - Rules for maintaining the changelog consistently.
- `reload_implementation_plan.md`
  - Phase-by-phase execution plan with deliverables and acceptance criteria.

## How To Use

1. Read `reload_runtime_rfc.md` first.
2. Before changing architecture, add an entry to `reload_design_changelog.md`
   as `Planned`.
3. After implementation/validation, update the same entry to
   `Implemented`/`Validated` with evidence.

## Scope

This design intentionally allows breaking changes and does not preserve current
`fletch_dev_tools` reload APIs.
