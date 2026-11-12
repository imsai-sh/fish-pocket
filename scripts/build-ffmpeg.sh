#!/usr/bin/env bash
# Build the pinned FFmpeg into vendor/ffmpeg/FFmpeg.xcframework: one dynamic
# framework (device + simulator) holding FFmpeg's libraries and the ffmpeg and
# ffprobe programs as functions (native/ffmpeg: tool.c, the patch, the prefix).
#
# Licence: LGPL 2.1 or later only. No --enable-gpl, no --enable-nonfree, no
# external libraries but the system's: H.264/HEVC encoding goes through
# VideoToolbox, AAC through FFmpeg's own encoder or AudioToolbox. A dynamic
# framework keeps FFmpeg replaceable apart from the app, and the source with
# the patch is public (THIRD_PARTY_NOTICES.md).
#
# Like Python's, the framework depends on DshRoot instead of libSystem, so
# FFmpeg opens files in the engine's filesystem view; it is left unsigned for
# the app's build to sign.
set -euo pipefail
version="9.0.2"
sha256="8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e"
root="$(cd "$(dirname "$0")/.." && pwd)"
native="$root/native/ffmpeg"
dir="$root/vendor/ffmpeg"
tarball="$dir/ffmpeg-$version.tar.xz"
src="$dir/ffmpeg-$version"
jobs="$(sysctl -n hw.ncpu)"

mkdir -p "$dir"
if [ ! -f "$tarball" ]; then
  curl -fL --retry 3 -o "$tarball.part" "https://ffmpeg.org/releases/ffmpeg-$version.tar.xz"
  mv "$tarball.part" "$tarball"
fi
echo "$sha256  $tarball" | shasum -a 256 -c -
rm -rf "$src" "$dir/build" && tar xf "$tarball" -C "$dir"
patch -s -d "$src" -p1 < "$native/ffmpeg.patch"

# What it can read, write and do: everything FFmpeg decodes, demuxes and
# parses, all of its filters, and the encoders and muxers agents ask for.
components=(
  --disable-everything
  --enable-decoders --enable-demuxers --enable-parsers --enable-bsfs --enable-filters
  --enable-protocol=file,pipe,fd,concat,concatf,subfile,data,crypto
  --enable-encoder=aac,aac_at,alac,alac_at,flac,pcm_s16le,pcm_s24le,pcm_f32le,pcm_s16be,opus,vorbis,ac3,mp2
  --enable-encoder=wrapped_avframe,h264_videotoolbox,hevc_videotoolbox,prores_videotoolbox,mpeg4,mjpeg,png,apng,gif,bmp,tiff,ppm,pgm,rawvideo,ffv1,prores_ks,dnxhd
  --enable-encoder=srt,subrip,ass,ssa,webvtt,mov_text,text
  --enable-muxer=mp4,mov,ipod,m4v,matroska,webm,avi,mpegts,flv,ogg,opus,wav,aiff,caf,adts,mp3,flac,ac3,image2,image2pipe,gif,apng,null,framemd5,md5,hash,framehash,segment,stream_segment,hls,srt,ass,webvtt,ffmetadata,rawvideo,h264,hevc,data,tee,nut,matroska_audio,mjpeg,f32le,s16le
)

# slice  sdk  minimum-version flag
slices=(
  "ios-arm64 iphoneos -miphoneos-version-min=17.0"
  "ios-arm64-simulator iphonesimulator -mios-simulator-version-min=17.0"
)
frameworks=()
for entry in "${slices[@]}"; do
  read -r slice sdk minimum <<<"$entry"
  build="$dir/build/$slice"
  out="$dir/$slice"
  sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
  cc="$(xcrun --sdk "$sdk" -f clang)"
  flags="-arch arm64 $minimum -DDSH_EMBEDDED -fmacro-prefix-map=$src=ffmpeg -fmacro-prefix-map=$build=ffmpeg"
  rm -rf "$out"
  mkdir -p "$build"
  (
    cd "$build"
    "$src/configure" --enable-cross-compile --target-os=darwin --arch=aarch64 \
      --cc="$cc" --sysroot="$sysroot" --extra-cflags="$flags" --extra-ldflags="-arch arm64 $minimum" \
      --enable-static --disable-shared --enable-pic --disable-debug --disable-doc \
      --disable-autodetect --enable-videotoolbox --enable-audiotoolbox --enable-zlib \
      --disable-avdevice --disable-network --disable-ffplay --enable-ffmpeg --enable-ffprobe \
      "${components[@]}" >configure.log
    grep -q '^License: LGPL version 2.1 or later' configure.log || { echo "ffmpeg: not LGPL-only" >&2; tail -20 configure.log >&2; exit 1; }
    # `ffmpeg -version` prints the configure line: keep the build machine's paths out of it.
    sed -i '' "s#$root/##g" config.h
    libs=(libavfilter/libavfilter.a libavformat/libavformat.a libavcodec/libavcodec.a libswscale/libswscale.a libswresample/libswresample.a libavutil/libavutil.a)
    make -j "$jobs" "${libs[@]}" >make.log 2>&1 || { tail -40 make.log >&2; exit 1; }

    # The programs' objects, compiled with the prefix (the libraries were not).
    printf 'print-%%:\n\t@echo $($*)\n' >print.mk
    tools=(ffmpeg ffprobe)
    for tool in "${tools[@]}"; do
      objects=($(make -s -f Makefile -f print.mk "print-OBJS-$tool"))
      make -j "$jobs" ECFLAGS="-include $native/fftools-prefix.h" "${objects[@]}" >>make.log 2>&1 || { tail -40 make.log >&2; exit 1; }
      # One object per program with only its entry points left global: both
      # define program_name and their own copies of cmdutils' globals.
      exported=(-exported_symbol "_dsh_${tool}_main")
      [ "$tool" = ffmpeg ] && exported+=(-exported_symbol _dsh_ffmpeg_signal)
      xcrun --sdk "$sdk" ld -r -arch arm64 "${exported[@]}" -o "$tool-tool.o" "${objects[@]}"
    done
    "$cc" -arch arm64 $minimum -isysroot "$sysroot" -O2 -I"$src" -I. -c "$native/tool.c" -o tool.o

    # Every library FFmpeg's configure found it needs (system frameworks, zlib).
    extralibs="$(sed -n -E 's/^EXTRALIBS(-[a-z]+)?=//p' ffbuild/config.mak | tr '\n' ' ')"
    mkdir -p "$out/FFmpeg.framework"
    # shellcheck disable=SC2086
    "$cc" -arch arm64 $minimum -isysroot "$sysroot" -dynamiclib \
      -install_name @rpath/FFmpeg.framework/FFmpeg -compatibility_version 1 -current_version 1 \
      -Wl,-exported_symbol,_dsh_ffmpeg_run -Wl,-exported_symbol,_dsh_ffmpeg_interrupt -Wl,-dead_strip -Wl,-x \
      tool.o ffmpeg-tool.o ffprobe-tool.o "${libs[@]}" $extralibs \
      -o "$out/FFmpeg.framework/FFmpeg"
  )
  binary="$out/FFmpeg.framework/FFmpeg"
  ! strings "$binary" | grep -qF "$root" || { echo "ffmpeg ($slice): the binary mentions $root" >&2; exit 1; }
  install_name_tool -change /usr/lib/libSystem.B.dylib @rpath/DshRoot.framework/DshRoot "$binary" 2>/dev/null
  otool -L "$binary" | grep -q '@rpath/DshRoot.framework/DshRoot' || { echo "ffmpeg ($slice): not pointed at DshRoot" >&2; exit 1; }
  codesign --remove-signature "$binary"
  plist="$out/FFmpeg.framework/Info.plist"
  platform=$([ "$sdk" = iphoneos ] && echo iPhoneOS || echo iPhoneSimulator)
  /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string io.github.imsai-sh.fish-pocket.ffmpeg" \
    -c "Add :CFBundleName string FFmpeg" -c "Add :CFBundleExecutable string FFmpeg" \
    -c "Add :CFBundlePackageType string FMWK" -c "Add :CFBundleShortVersionString string $version" \
    -c "Add :CFBundleVersion string $version" -c "Add :MinimumOSVersion string 17.0" \
    -c "Add :CFBundleSupportedPlatforms array" -c "Add :CFBundleSupportedPlatforms:0 string $platform" "$plist" >/dev/null
  # LGPL: the licence travels with the library.
  cp "$src/COPYING.LGPLv2.1" "$out/FFmpeg.framework/LICENSE"
  frameworks+=(-framework "$out/FFmpeg.framework")
  echo "ffmpeg ($slice): $(du -k "$binary" | cut -f1) KB"
done

rm -rf "$dir/FFmpeg.xcframework"
xcodebuild -create-xcframework "${frameworks[@]}" -output "$dir/FFmpeg.xcframework" >/dev/null
echo "ffmpeg $version ready: $dir/FFmpeg.xcframework"
