#!/usr/bin/env bash
#
# Rebuild libjndcrash.so from source with 16 KB page alignment and repack the
# AAR. Upstream's prebuilt AAR ships 4 KB-aligned LOAD segments, which makes
# Android show the "isn't 16 KB compatible" warning on launch (and would stop
# the library loading on a 16 KB-page device).
#
# The prebuilt AAR is still used for its Java classes; only the four .so files
# are replaced. Output goes to .native/, never over the tracked AAR.
#
# .native/ is deliberately outside every Gradle buildDir: `gradlew clean` wipes
# app/build, which would delete the AAR out from under the build.
#
# Usage:
#   scripts/build-jndcrash-aar.sh [output.aar]
#
# Environment:
#   ANDROID_NDK_HOME  NDK to build with (required unless local.properties has
#                     sdk.dir, in which case the newest installed NDK is used)
#   JNDCRASH_SRC      existing jndcrash checkout (optional; otherwise cloned)
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREBUILT_AAR="$REPO_ROOT/app/libs/jndcrash-release.aar"
OUT_AAR="${1:-$REPO_ROOT/.native/jndcrash-release.aar}"

# Psiphon's fork, pinned. Its CMakeLists already sets
# -Wl,-z,max-page-size=16384, so a source build is aligned by default.
JNDCRASH_REPO="https://github.com/Psiphon-Inc/jndcrash.git"
JNDCRASH_REF="3b530d63a63ba5b6c92ed81728e479bce73f5764"

ABIS="arm64-v8a armeabi-v7a x86 x86_64"
MIN_API="${JNDCRASH_MIN_API:-16}"

die() { echo "error: $*" >&2; exit 1; }

[ -f "$PREBUILT_AAR" ] || die "prebuilt AAR not found at $PREBUILT_AAR"

# clang needs a writable TMPDIR; some sandboxes hand out a read-only one, which
# surfaces only as "clang: error: unable to make temporary file".
if [ ! -w "${TMPDIR:-/nonexistent}" ]; then
  export TMPDIR="$REPO_ROOT/.native/tmp"
  mkdir -p "$TMPDIR"
fi

# --- locate the NDK ---------------------------------------------------------
if [ -z "${ANDROID_NDK_HOME:-}" ]; then
  SDK_DIR=""
  [ -f "$REPO_ROOT/local.properties" ] && \
    SDK_DIR=$(sed -n 's/^sdk\.dir=//p' "$REPO_ROOT/local.properties" | head -1)
  [ -n "$SDK_DIR" ] || SDK_DIR="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
  [ -n "$SDK_DIR" ] || die "set ANDROID_NDK_HOME (no sdk.dir in local.properties)"
  ANDROID_NDK_HOME=$(ls -d "$SDK_DIR"/ndk/* 2>/dev/null | sort -V | tail -1)
fi
[ -d "${ANDROID_NDK_HOME:-}" ] || die "NDK not found: ${ANDROID_NDK_HOME:-unset}"
TOOLCHAIN="$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake"
[ -f "$TOOLCHAIN" ] || die "no cmake toolchain in $ANDROID_NDK_HOME"

# --- locate ninja and cmake -------------------------------------------------
# Resolve ninja first: the SDK's cmake package ships cmake and ninja side by
# side, so putting ninja's directory on PATH also makes cmake resolve there.
# Looking up cmake first picks a system cmake with no ninja beside it.
NINJA=$(command -v ninja || true)
if [ -z "$NINJA" ]; then
  for candidate in "$(dirname "$ANDROID_NDK_HOME")"/../cmake/*/bin/ninja; do
    if [ -x "$candidate" ]; then NINJA="$candidate"; break; fi
  done
fi
[ -n "$NINJA" ] && export PATH="$(dirname "$NINJA"):$PATH"

CMAKE=$(command -v cmake || true)
if [ -z "$CMAKE" ]; then
  for candidate in "$(dirname "$ANDROID_NDK_HOME")"/../cmake/*/bin/cmake; do
    if [ -x "$candidate" ]; then CMAKE="$candidate"; break; fi
  done
fi
[ -n "$CMAKE" ] || die "cmake not found (sdkmanager \"cmake;3.22.1\")"

if [ -n "$NINJA" ]; then
  GENERATOR="Ninja"
else
  # works anywhere, but slower and a different code path; safety net only
  echo "warning: ninja not found, falling back to Unix Makefiles" >&2
  GENERATOR="Unix Makefiles"
fi

# --- fetch the source -------------------------------------------------------
SRC="${JNDCRASH_SRC:-$REPO_ROOT/scripts/.jndcrash-src}"
if [ ! -f "$SRC/CMakeLists.txt" ]; then
  echo "cloning jndcrash into $SRC"
  mkdir -p "$(dirname "$SRC")"
  git clone --quiet --recurse-submodules "$JNDCRASH_REPO" "$SRC"
  git -C "$SRC" checkout --quiet "$JNDCRASH_REF"
  git -C "$SRC" submodule update --init --recursive --quiet
fi

# --- build each ABI ---------------------------------------------------------
BUILD_ROOT="$REPO_ROOT/.native/build"
BUILD_LOG="$BUILD_ROOT/build.log"
mkdir -p "$BUILD_ROOT"
: > "$BUILD_LOG"
for abi in $ABIS; do
  echo "building libjndcrash.so for $abi"
  if ! cmake -S "$SRC" -B "$BUILD_ROOT/$abi" -G "$GENERATOR" \
        -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
        -DANDROID_ABI="$abi" \
        -DANDROID_PLATFORM="android-$MIN_API" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_SHARED_LINKER_FLAGS="-Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384" \
        >>"$BUILD_LOG" 2>&1 \
     || ! cmake --build "$BUILD_ROOT/$abi" --target jndcrash >>"$BUILD_LOG" 2>&1; then
    tail -40 "$BUILD_LOG" >&2
    die "jndcrash build failed for $abi (full log: $BUILD_LOG)"
  fi
done

# --- strip ------------------------------------------------------------------
STRIP=""
for candidate in "$ANDROID_NDK_HOME"/toolchains/llvm/prebuilt/*/bin/llvm-strip; do
  if [ -x "$candidate" ]; then STRIP="$candidate"; break; fi
done

for abi in $ABIS; do
  so="$BUILD_ROOT/$abi/libjndcrash.so"
  [ -f "$so" ] || die "no libjndcrash.so produced for $abi"
  if [ -n "$STRIP" ]; then
    "$STRIP" --strip-unneeded "$so"
  else
    echo "warning: no llvm-strip in $ANDROID_NDK_HOME; libs stay unstripped" >&2
  fi
done

# --- repack -----------------------------------------------------------------
mkdir -p "$(dirname "$OUT_AAR")"
python3 - "$PREBUILT_AAR" "$OUT_AAR" "$BUILD_ROOT" $ABIS <<'PY'
import os, shutil, sys, zipfile
prebuilt, out, build_root = sys.argv[1], sys.argv[2], sys.argv[3]
abis = sys.argv[4:]
tmp = out + ".tmp"
with zipfile.ZipFile(prebuilt) as zin, zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as zout:
    for item in zin.infolist():
        data = zin.read(item.filename)
        if item.filename.startswith("jni/") and item.filename.endswith("libjndcrash.so"):
            abi = item.filename.split("/")[1]
            if abi in abis:
                data = open(os.path.join(build_root, abi, "libjndcrash.so"), "rb").read()
        zi = zipfile.ZipInfo(item.filename, date_time=item.date_time)
        zi.compress_type = zipfile.ZIP_DEFLATED
        zi.external_attr = item.external_attr
        zout.writestr(zi, data)
shutil.move(tmp, out)
print("wrote", out, "(%d bytes)" % os.path.getsize(out))
PY
