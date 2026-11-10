#!/usr/bin/env bash
# Xcode Cloud runs this right after cloning, before it looks for the project.
# The repository holds neither the Xcode project nor what it links, so this does
# what scripts/run-sim.sh does up to `xcodebuild`: fetch nodejs-mobile and Python,
# build libgit2, assemble the engine tree, generate the project.
# Nothing is cached between cloud builds: every run starts from the clone.
# It also runs on a Mac as is, for checking a change to it: app/ci_scripts/ci_post_clone.sh
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"

# The cloud image has Homebrew and Xcode, and none of these.
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1
brew_install() {
  local attempt
  for attempt in 1 2 3; do
    brew install "$@" && return
    sleep 10
  done
  echo "brew install $* failed" >&2
  return 1
}
command -v xcodegen >/dev/null || brew_install xcodegen
command -v cmake >/dev/null || brew_install cmake
# The Node line .github/workflows/ios-build.yml uses; keg-only, so not on PATH by itself.
command -v npm >/dev/null || { brew_install node@24; export PATH="$(brew --prefix node@24)/bin:$PATH"; }

"$root/scripts/fetch-nodejs-mobile.sh"
"$root/scripts/fetch-python.sh"
"$root/scripts/build-libgit2.sh"
"$root/scripts/build-engine.sh"

cd "$root/app"
# A build Xcode Cloud distributes carries Xcode Cloud's build number whatever the
# project says. Give the project the same one, so the app and its extension agree
# with what TestFlight shows (WhatsNew reads it from the bundle).
if [ -n "${CI_BUILD_NUMBER:-}" ]; then
  sed -i '' -E "s/^( *CURRENT_PROJECT_VERSION: ).*/\\1\"$CI_BUILD_NUMBER\"/" project.yml
  grep -q "CURRENT_PROJECT_VERSION: \"$CI_BUILD_NUMBER\"" project.yml || { echo "project.yml: CURRENT_PROJECT_VERSION not found" >&2; exit 1; }
fi
xcodegen generate --quiet
# Xcode Cloud does not resolve package versions itself: it wants the pins inside the project.
pins="DshIOS.xcodeproj/project.xcworkspace/xcshareddata/swiftpm"
mkdir -p "$pins"
cp ci_scripts/Package.resolved "$pins/Package.resolved"
echo "project ready: $root/app/DshIOS.xcodeproj"
