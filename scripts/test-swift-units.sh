#!/bin/bash
# Checks of the app's rules that need no app around them: each test in app/UnitTests is built
# with the plain Foundation sources it names and run on this Mac.
set -euo pipefail
cd "$(dirname "$0")/.."
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

run() {
  local name="$1"; shift
  xcrun swiftc -parse-as-library -o "$out/$name" "$@" "app/UnitTests/$name.swift"
  "$out/$name"
}

run BrowserOwnershipTests app/DshIOS/Browser/BrowserOwnership.swift
run CallFarewellTests app/DshIOS/Call/CallFarewell.swift
