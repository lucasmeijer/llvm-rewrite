#!/usr/bin/env bash
# Builds bin/{opt,llc,llvm-link}. Called by the harness before every check; keep it incremental and quick.
# The compiler is installed on demand from $JAI_COMPILER_URL by scripts/ensure-jai.sh (never commit that URL).
#
# JAI_BUILD selects the backend (NOTES.md "Build modes"):
#   x64 (default)  Jai's x64 backend, bounds checks and stack traces on; ~3 s per tool. Used by `check`.
#   optimized      LLVM backend, -o settings (build_optimized.jai); ~2 min per tool, ~5-8x faster binaries.
#                  impl/jai/perf.env selects it for `harness/run perf`.
# Every build is cached in bin/.cache/<mode>-<hash of the sources>/, so switching modes back and forth (perf, then
# check) only copies a binary unless the sources changed. The three tools build in parallel.
set -euo pipefail
cd "$(dirname "$0")"
JAI="$(../../scripts/ensure-jai.sh)"
MODE="${JAI_BUILD:-x64}"
case "$MODE" in
  x64|optimized) ;;
  *) echo "build.sh: unknown JAI_BUILD=$MODE (expected x64 or optimized)" >&2; exit 1 ;;
esac
mkdir -p bin bin/.cache
HASH="$( (cat build.sh build_optimized.jai; find src -name '*.jai' -print0 | sort -z | xargs -0 cat; "$JAI" -version 2>&1) | sha1sum | cut -c1-16)"
KEY="$MODE-$HASH"
if [ "$(cat bin/.stamp 2>/dev/null)" = "$KEY" ] && [ -x bin/opt ] && [ -x bin/llc ] && [ -x bin/llvm-link ]; then
  exit 0
fi
CACHE="bin/.cache/$KEY"
if [ ! -f "$CACHE/.complete" ]; then
  rm -rf "$CACHE" && mkdir -p "$CACHE"
  pids=()
  for tool in opt llc llvm-link; do
    src="$PWD/src/${tool//-/_}.jai"
    if [ "$MODE" = x64 ]; then
      "$JAI" -quiet -x64 "$src" -exe "$tool" -output_path "$PWD/$CACHE/" &
    else
      "$JAI" -quiet build_optimized.jai - "$src" "$tool" "$PWD/$CACHE/" &
    fi
    pids+=($!)
  done
  for p in "${pids[@]}"; do wait "$p"; done
  for tool in opt llc llvm-link; do [ -x "$CACHE/$tool" ] || { echo "build.sh: $tool was not built" >&2; exit 1; }; done
  rm -rf "$CACHE/.build"
  touch "$CACHE/.complete"
  # keep the 4 newest cache entries per mode
  ls -1dt bin/.cache/"$MODE"-* 2>/dev/null | tail -n +5 | xargs -r rm -rf
fi
touch "$CACHE"
for tool in opt llc llvm-link; do
  cp -f "$CACHE/$tool" "bin/$tool.tmp" && mv -f "bin/$tool.tmp" "bin/$tool"
done
echo "$KEY" > bin/.stamp
rm -rf src/.build bin/.build .build
