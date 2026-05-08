#!/usr/bin/env sh
# Install local git hooks via lefthook. Idempotent — safe to re-run.
#
# Usage: ./scripts/install-hooks.sh
#
# Requires: lefthook (https://lefthook.dev/) on $PATH.

set -eu

if ! command -v lefthook >/dev/null 2>&1; then
    {
        echo "error: lefthook is not installed or not on PATH"
        echo ""
        echo "Install it via:"
        echo "  macOS    brew install lefthook"
        echo "  Windows  winget install evilmartians.lefthook"
        echo "  Linux    https://lefthook.dev/installation/"
    } >&2
    exit 1
fi

repo_root=$(git rev-parse --show-toplevel)
cd "$repo_root"

lefthook install
