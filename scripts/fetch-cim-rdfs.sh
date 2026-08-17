#!/usr/bin/env bash
#
# Fetch the official CGMES RDFS profiles from ENTSO-E and regenerate the
# `parent_edges` body of src/cim/cim_types.zig via the Zig `gen-cim-types`
# tool. This is the single entry point for refreshing the CIM type table.
#
# Usage (from the repo root):
#   scripts/fetch-cim-rdfs.sh
#
# Review the diff before committing: the generated table is sorted and
# deduplicated, but the checked-in table is curated.
#
# Requires: curl, jq, zig. Run from the repository root.

set -euo pipefail

REPO="entsoe/application-profiles-library"
# The repository's main branch exposes the current CGMES vocabulary artifacts
# directly under CGMES/RDFS.
DIR="CGMES/RDFS"
TARGET="src/cim/cim_types.zig"

# Profiles whose classes the table covers. Dynamics and DiagramLayout are
# intentionally excluded because they add hundreds of classes irrelevant to
# cimd's current type filters.
WANT='Equipment|EquipmentBoundary|SteadyStateHypothesis|StateVariables|Topology|Operation'

dest="$(mktemp -d)"
trap 'rm -rf "$dest"' EXIT

curl -fsSL "https://api.github.com/repos/$REPO/contents/$DIR" \
| jq -r --arg want "($WANT)-AP" \
    '.[] | select((.name | test("\\.rdf$")) and (.name | test($want))) | .download_url' \
| while read -r url; do
    echo "fetching $(basename "$url")" >&2
    curl -fsSL "$url" -o "$dest/$(basename "$url")"
  done

shopt -s nullglob
files=("$dest"/*.rdf)
if [ "${#files[@]}" -eq 0 ]; then
  echo "error: no RDFS files downloaded (check the profile filter / network)" >&2
  exit 1
fi

generated="$dest/parent_edges.zig"
updated="$dest/cim_types.zig"

zig build gen-cim-types -- "${files[@]}" > "$generated"
if [ ! -s "$generated" ]; then
  echo "error: generator produced no parent_edges body" >&2
  exit 1
fi

if ! awk -v generated="$generated" '
  BEGIN {
    while ((getline line < generated) > 0) {
      body = body line "\n"
    }
    close(generated)
  }

  /^const parent_edges = \[_\]ParentEdge\{$/ {
    print
    printf "%s", body
    in_parent_edges = 1
    next
  }

  in_parent_edges && /^};$/ {
    print
    in_parent_edges = 0
    replaced = 1
    next
  }

  !in_parent_edges {
    print
  }

  END {
    if (in_parent_edges || !replaced) {
      exit 1
    }
  }
' "$TARGET" > "$updated"; then
  echo "error: could not replace parent_edges in $TARGET" >&2
  exit 1
fi

cp "$updated" "$TARGET"
zig fmt "$TARGET"
echo "updated $TARGET" >&2
