#!/usr/bin/env bash
# Build app/DshIOS/Browser/PageController.js: the script the browser capability
# injects into the pages of a session's browser so the agent can read and drive
# them. It is page-agent's page controller (MIT) with a small wrapper,
# scripts/page-controller/entry.js; build.mjs says what is left out and why.
#
# The output is committed, so neither a local build nor Xcode Cloud runs this.
# Run it after changing entry.js or build.mjs, or to move to a newer page-agent:
# change `version` and `commit` together, rebuild, and try it in the simulator.
set -euo pipefail
version="v1.12.4"
commit="9eb6b6646500264d9034dd466a4270cb9fc1ef1e"
esbuild="0.25.10"
# The mask's animated glow (page-agent pins ^0.4.8).
aimotion="0.4.8"
root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/app/DshIOS/Browser/PageController.js"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$version" https://github.com/alibaba/page-agent.git "$work/page-agent"
actual="$(git -C "$work/page-agent" rev-parse HEAD)"
if [ "$actual" != "$commit" ]; then
  echo "page-agent $version is $actual, expected $commit" >&2
  exit 1
fi

npm install --silent --no-audit --no-fund --ignore-scripts --prefix "$work/tools" "esbuild@$esbuild" "ai-motion@$aimotion" >/dev/null
mkdir -p "$(dirname "$out")"
node "$root/scripts/page-controller/build.mjs" "$work/tools/node_modules/esbuild/lib/main.js" \
  "$work/page-agent/packages" "$work/tools/node_modules" "$out"
echo "page-controller: $out ($(wc -c < "$out" | tr -d ' ') bytes, page-agent $version)"
