#!/bin/bash
# Puts the StikContainer patch on top of an upstream LiveContainer commit and,
# when a StikJIT release is given, moves the bundled StikJIT.xcframework to it.
#
# usage: prepare_sources.sh <upstream-commit> [<stikjit-tag>]
#
# Run it from the repository root, with the patch branch checked out and the upstream
# commit already fetched. Run a copy kept outside the work tree: the rebase rewrites
# this file. Exits 2 when the patch does not apply cleanly; the work tree is then left
# as it was.
set -euo pipefail

base=$(git rev-parse --verify "$1^{commit}")
stikjit=${2:-}
here=$(cd "$(dirname "$0")" && pwd)

# Replay only the fork's own commits, which start with the design doc. A plain rebase
# would also replay old upstream commits whenever upstream rewrites its history.
first=$(git log --format=%H --grep='^Add built-in JIT design doc$' -n 1 HEAD)
if [ -z "$first" ]; then
  echo "::error::Could not find the fork's first commit (\"Add built-in JIT design doc\")"
  exit 1
fi

echo "rebasing $(git rev-list --count "$first^..HEAD") fork commits onto $base"
if ! git rebase --quiet --onto "$base" "$first^"; then
  git rebase --abort
  exit 2
fi

if [ -n "$stikjit" ]; then
  "$here/update_stikjit.sh" "$stikjit"
fi

git log --oneline -5
