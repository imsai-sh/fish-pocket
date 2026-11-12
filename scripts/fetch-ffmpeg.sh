#!/usr/bin/env bash
# Put FFmpeg.xcframework into vendor/ffmpeg: download the copy this repository's
# GitHub release holds, checked against its sha256, instead of compiling FFmpeg
# on every clean build. It is the same framework scripts/build-ffmpeg.sh makes;
# compiling it takes a minute or two on a Mac and longer on fewer cores.
#
# The release is tied to what goes into the framework: build-ffmpeg.sh and
# native/ffmpeg except binding.c, which the app compiles itself. When any of them
# differs from what the pinned release was built from, the download would be
# stale, so this compiles from source instead and says so.
#
# Publishing a new one (after changing those files or FFmpeg's version):
#   scripts/fetch-ffmpeg.sh --package   builds from source, zips, prints the
#                                       release tag and the zip's sha256;
#   gh release create <tag> <zip> ...   (see CLAUDE.md), then pin both below.
set -euo pipefail
inputs="c79aea98"
sha256="b06b0ca8fe743ef55ea165064ad7db66889089b29ceeebb4f9f2a5870a44ea76"
root="$(cd "$(dirname "$0")/.." && pwd)"
dir="$root/vendor/ffmpeg"
version="$(sed -n 's/^version="\(.*\)"$/\1/p' "$root/scripts/build-ffmpeg.sh")"

# What the framework is built from, in a fixed order.
current="$(cd "$root" && cat scripts/build-ffmpeg.sh native/ffmpeg/ffmpeg.patch native/ffmpeg/fftools-prefix.h \
  native/ffmpeg/tool.c native/ffmpeg/dsh_ffmpeg.h | shasum -a 256 | cut -c1-8)"
tag="ffmpeg-$version-$current"

if [ "${1:-}" = --package ]; then
  "$root/scripts/build-ffmpeg.sh"
  zip="$dir/dist/FFmpeg.xcframework.zip"
  rm -rf "$dir/dist" && mkdir -p "$dir/dist"
  ditto -c -k --keepParent "$dir/FFmpeg.xcframework" "$zip"
  echo "tag:    $tag"
  echo "zip:    $zip"
  echo "sha256: $(shasum -a 256 "$zip" | cut -d' ' -f1)"
  exit 0
fi

if [ "$current" != "$inputs" ]; then
  echo "ffmpeg: build inputs changed since the published release ($inputs, now $current): compiling from source" >&2
  exec "$root/scripts/build-ffmpeg.sh"
fi

zip="$dir/$tag.zip"
mkdir -p "$dir"
if [ ! -f "$zip" ]; then
  curl -fL --retry 3 -o "$zip.part" "https://github.com/imsai-sh/fish-pocket/releases/download/$tag/FFmpeg.xcframework.zip"
  mv "$zip.part" "$zip"
fi
echo "$sha256  $zip" | shasum -a 256 -c -
rm -rf "$dir/FFmpeg.xcframework"
ditto -x -k "$zip" "$dir"
echo "ffmpeg $version ready: $dir/FFmpeg.xcframework (release $tag)"
