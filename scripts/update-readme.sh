#!/usr/bin/env bash
# Regenerate the ## Features section of README.md from live --help output.
# Replaces content between <!-- FEATURES_START --> and <!-- FEATURES_END -->.
#
# Usage:
#   scripts/update-readme.sh          # update in place
#   scripts/update-readme.sh --check  # exit 1 if out of date (CI use)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CIMD="$ROOT/zig-out/bin/cimd"
README="$ROOT/README.md"

if [[ ! -x "$CIMD" ]]; then
  echo "error: $CIMD not found — run 'zig build' first" >&2
  exit 1
fi

# Build the features block between the markers.
new_block() {
  echo "<!-- FEATURES_START -->"
  echo "## Features"

  echo '```'
  echo "$ cimd eq --help"
  echo ""
  "$CIMD" eq --help
  echo '```'

  for sub in convert browse get types diff; do
    # Capitalise first letter for the heading.
    heading="$(echo "$sub" | awk '{print toupper(substr($0,1,1)) substr($0,2)}')"
    echo ""
    echo "### $heading"
    echo '```'
    echo "$ cimd eq $sub --help"
    echo ""
    "$CIMD" eq "$sub" --help
    echo '```'
  done

  echo "<!-- FEATURES_END -->"
}

TMPFILE="$(mktemp)"
trap 'rm -f "$TMPFILE"' EXIT

new_block > "$TMPFILE"

# Extract current block from README for comparison.
current_block="$(awk '/<!-- FEATURES_START -->/,/<!-- FEATURES_END -->/' "$README")"
new_content="$(cat "$TMPFILE")"

if [[ "$new_content" == "$current_block" ]]; then
  echo "README.md is up to date."
  exit 0
fi

if [[ "${1:-}" == "--check" ]]; then
  echo "README.md is out of date. Run: scripts/update-readme.sh"
  exit 1
fi

# Replace between markers: read new content from file via getline to handle newlines correctly.
awk -v tmpfile="$TMPFILE" '
  /<!-- FEATURES_START -->/ {
    while ((getline line < tmpfile) > 0) print line
    skip=1; next
  }
  /<!-- FEATURES_END -->/ { skip=0; next }
  !skip                   { print }
' "$README" > "$README.tmp" && mv "$README.tmp" "$README"

echo "README.md updated."
