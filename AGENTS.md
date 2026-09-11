# Agent Development Guide

A file for [guiding coding agents](https://agents.md/).

## Commands

- **Build:** `zig build`
- **Test (Zig):** `zig build test`
- **Formatting (Zig)**: `zig fmt .`

## Directory Structure

- Shared Zig core: `src/`
- `src/cim/` is a self-contained CIM library (parsing, get, refs, diff) kept
  ready to split off into its own package. It must not import anything outside
  itself, exit the process, or do I/O, and application code must reach it only
  through `src/cim/cim.zig` -- `src/cim/test_boundary.zig` enforces all four.
  Need something the API does not expose? Add it to `cim.zig`; do not import
  the internal file.
- Everything else in `src/` is the cimd application on top: `cli.zig`,
  `main.zig`, `browse.zig`, `model_set.zig`, `io/`, plus `validate.zig` +
  `shacl/`, which is a separate concern.

## Tools
- When investigating a bug using real data, use cimd as the main tool and pipe
  it into jq. Note any shortcomings in the api so we can add those.

## Style
- Keep comments sparse: explain only WHY difficult or surprising code needs
  to be that way. Never narrate WHAT the code does, restate names or assertions,
  or repeat test names. Use one or two short sentences; delete comments that
  add no information the code cannot convey. This takes precedence over
  TIGER_STYLE.md's broader commentary guidance.
- Reserve first: reserve all the memory an operation needs before mutating
  anything, then mutate on a path that cannot fail, ending the reservation
  phase with `errdefer comptime unreachable;`. `ensureUnusedCapacity` then
  `appendAssumeCapacity`, never `append` in a loop with a known bound.
  The rule is about containing failure, not about sizing: a perfectly sized
  reservation taken mid-mutation still breaks it, a loose one taken up front
  does not. Sizing is a separate, worthwhile concern -- reserve from the count
  the work actually produced, not from a bound that happens to be in scope --
  but do not let it stand in for the rule. See
  https://matklad.github.io/2025/08/16/reserve-first.html and
  docs/INGESTION_DESIGN.md section 5.
- When in doubt, follow docs/TIGER_STYLE.md, also in this repo.

## Zig version
The Zig version can be found in build.zig.zon under `.minimum_zig_version`.
