# Agent Development Guide

A file for [guiding coding agents](https://agents.md/).

## Commands

- **Build:** `zig build`
- **Test (Zig):** `zig build test`
- **Formatting (Zig)**: `zig fmt .`

## Directory Structure

- Shared Zig core: `src/`

## Tools
- When investigating a bug using real data, use cimd as the main tool and pipe
  it into jq. Note any shortcomings in the api so we can add those.

## Style
- When in doubt, follow docs/TIGER_STYLE.md, also in this repo.

## Zig version
The Zig version can be found in build.zig.zon under `.minimum_zig_version`.

