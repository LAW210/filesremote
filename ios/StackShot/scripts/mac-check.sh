#!/bin/bash
# Everything CI does, on your Mac, for free.
#
# This mirrors .github/workflows/ios-tests.yml step for step — same SwiftLint
# invocation, same xcodegen, same build-and-test against a simulator. Running it
# before you push means a red result costs you nothing instead of a macOS runner
# minute billed at ten times the Linux rate.
#
#     ios/StackShot/scripts/mac-check.sh
#
# Exit status is non-zero if anything CI would fail on fails here.
#
# Requires: Xcode 16.x (the project format current xcodegen emits does not open in
# 15.4), plus `brew install xcodegen swiftlint`.

set -o pipefail
cd "$(dirname "$0")/.." || exit 1

fail() { printf '\n\033[31m✗ %s\033[0m\n' "$1"; exit 1; }
step() { printf '\n\033[1m▸ %s\033[0m\n' "$1"; }

command -v xcodegen >/dev/null || fail "xcodegen not found — brew install xcodegen"
command -v swiftlint >/dev/null || fail "swiftlint not found — brew install swiftlint"

step "SwiftLint"
# Warnings are informational here exactly as in CI; only errors fail the job, and
# swiftlint's exit status already reflects that distinction.
swiftlint lint --quiet || fail "SwiftLint reported an error-severity violation"
echo "  no error-severity violations"

step "Generating the Xcode project"
xcodegen generate || fail "xcodegen failed"

step "Choosing a simulator"
# Whatever iPhone this machine actually has, rather than a hardcoded name that
# rotates between Xcode releases.
DEVICE_ID=$(xcrun simctl list devices available --json | python3 -c "
import json, sys
data = json.load(sys.stdin)
devices = [d for devs in data['devices'].values() for d in devs
           if d.get('isAvailable') and d['name'].startswith('iPhone')]
if not devices:
    sys.exit('no available iPhone simulator — open Xcode > Settings > Platforms')
print(devices[0]['udid'])
") || fail "could not find an iPhone simulator"
echo "  $DEVICE_ID"

step "Building and running the tests"
xcodebuild \
  -project StackShot.xcodeproj \
  -scheme StackShot \
  -destination "platform=iOS Simulator,id=$DEVICE_ID" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  test 2>&1 | tail -40
[ "${PIPESTATUS[0]}" -eq 0 ] || fail "build or tests failed — scroll up for the failing case"

printf '\n\033[32m✓ Everything CI checks passes locally.\033[0m\n'
echo "The engine build is a separate, manual job — see .github/workflows/engine-build.yml."
