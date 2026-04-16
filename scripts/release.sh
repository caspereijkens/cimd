#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <tag>" >&2
    exit 2
fi

TAG="$1"

# Extract version from build.zig.zon
ZON_VERSION=$(grep -oP '(?<=\.version = ")[^"]+' build.zig.zon)

if [[ -z "$ZON_VERSION" ]]; then
    echo "error: could not parse .version from build.zig.zon" >&2
    exit 2
fi

if [[ "$TAG" != "$ZON_VERSION" ]]; then
    echo "error: tag '$TAG' does not match build.zig.zon version '$ZON_VERSION'" >&2
    exit 1
fi

echo "Version check passed: $ZON_VERSION"

git tag "$TAG"
git push -u origin "$TAG"
