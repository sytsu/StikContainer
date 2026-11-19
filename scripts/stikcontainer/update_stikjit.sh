#!/bin/bash
# Replaces StikJIT/StikJIT.xcframework with the prebuilt framework from a StikJIT release
# (github.com/StikDebug/StikJIT), records the release in StikJIT/VERSION and commits the
# change. Does nothing when the bundled framework is already that release or newer.
#
# usage: update_stikjit.sh <stikjit-tag>
set -euo pipefail

tag=$1
repo=${STIKJIT_REPO:-StikDebug/StikJIT}
here=$(cd "$(dirname "$0")" && pwd)
current=$("$here/stikjit_version.py")

if ! "$here/stikjit_version.py" --newer "$tag" "$current"; then
  echo "bundled StikJIT $current is already at or past $tag"
  exit 0
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

echo "updating StikJIT $current -> $tag"
curl -fsSL --retry 3 -o "$work/StikJIT.xcframework.zip" \
  "https://github.com/$repo/releases/download/$tag/StikJIT.xcframework.zip"
unzip -q "$work/StikJIT.xcframework.zip" -d "$work/new"

new="$work/new/StikJIT.xcframework"
for f in Info.plist ios-arm64/StikJIT.framework/StikJIT ios-arm64/StikJIT.framework/Info.plist; do
  if [ ! -f "$new/$f" ]; then
    echo "::error::StikJIT $tag's StikJIT.xcframework.zip has no $f"
    exit 1
  fi
done

rm -rf StikJIT/StikJIT.xcframework
cp -R "$new" StikJIT/StikJIT.xcframework
echo "$tag" > StikJIT/VERSION
echo "bundled StikJIT is now $tag"

git add -A StikJIT
if git diff --cached --quiet; then
  echo "StikJIT $tag is identical to the bundled framework"
else
  git commit --quiet -m "Update StikJIT to $tag"
fi
