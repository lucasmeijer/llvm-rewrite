#!/usr/bin/env bash
# Builds bin/{opt,llc,llvm-link}. Called by the harness before every check; keep it incremental and quick.
# NOTES.md "Build" has the measurements behind this script.
#
# Up to date check: a SHA-256 of every input (all of src/, this script, tools/splitc.py, the goose and clang
# versions, the mode and the stack reserve), taken before the build and checked again after it. A tool whose
# stamp matches is skipped; a build whose inputs changed while it ran is not stamped or cached, so the next call
# rebuilds. Finished binaries are also kept by that hash in $GOOSE_BUILD_CACHE, so switching between the check
# and perf builds (different reserves), branches or worktrees with the same sources costs a copy.
#
# GOOSE_BUILD selects how the C is compiled:
#   split (default)  goose writes the C (one ~64 MB file for opt, ~50 s single-threaded), tools/splitc.py cuts it
#                    into up to GOOSE_BUILD_JOBS (default: nproc) translation units, compiled in parallel with
#                    clang -O2 -flto=thin and linked with lld's parallel ThinLTO. Parts are cached by content.
#                    ~25 s of C compile instead of ~4-5 min; runtime within a few % of whole (NOTES.md "Build").
#   whole            `goose build`, as the goose docs describe it: the C in one translation unit, clang -O2.
#                    What perf.env asks for, so timings stay comparable with the history.
#
# GOOSE_STACK_RESERVE (default 2G) is the address space reserved per data stack (`goose --stack-reserve`).
# The program has ~490 data stacks (one per global resizable array), so the default reserves ~1 TB of address
# space, more than valgrind gives a client (~128 GB, of which it needs room for itself): under `perf --instr` every
# run would die with "cannot reserve data stack address space". perf.env sets 128M (NOTES.md).
set -euo pipefail
cd "$(dirname "$0")"
here="$PWD"
mkdir -p bin
exec 9> bin/.lock
flock 9   # one build at a time per worktree

reserve="${GOOSE_STACK_RESERVE:-2G}"
mode="${GOOSE_BUILD:-split}"
case "$mode" in split|whole) ;; *) echo "build.sh: unknown GOOSE_BUILD=$mode (expected split or whole)" >&2; exit 1 ;; esac
cc=/opt/llvm-23.1.5/bin/clang
jobs="${GOOSE_BUILD_JOBS:-$(nproc)}"
cache="${GOOSE_BUILD_CACHE:-$HOME/.cache/llvm-rewrite-goose}"
mkdir -p "$cache/bin" "$cache/obj"

tool_versions="$(goose version) | $("$cc" --version | head -1)"
inputs_hash() {  # $1 = tool
  {
    echo "tool=$1 mode=$mode reserve=$reserve cc=$cc $tool_versions"
    (cd src && find . -type f ! -name '*~' ! -name '.*' -print0 | LC_ALL=C sort -z | xargs -0 sha256sum)
    sha256sum build.sh tools/splitc.py
  } | sha256sum | cut -c1-32
}

# cc_cached <src.c> <out.o> <flags...>: compile, reusing an object compiled from the same text with the same flags.
cc_cached() {
  local src=$1 out=$2; shift 2
  local key; key=$( { echo "$cc $* $tool_versions"; cat "$src"; } | sha256sum | cut -c1-40)
  local obj="$cache/obj/$key.o"
  if [ ! -f "$obj" ]; then
    "$cc" "$@" -c "$src" -o "$obj.$$.tmp"
    mv -f "$obj.$$.tmp" "$obj"
  fi
  touch "$obj"
  ln -f "$obj" "$out" 2>/dev/null || cp -f "$obj" "$out"
}
export -f cc_cached
export cc cache tool_versions

build_split() {  # $1 = tool, $2 = output path
  local tool=$1 out=$2 w="bin/.build/$1"
  rm -rf "$w"; mkdir -p "$w/obj"
  goose -O2 --stack-reserve "$reserve" -o "$w/$tool.c" "src/$tool.goose" >/dev/null
  goose --emit-runtime "$w/goose_runtime.c" >/dev/null
  local objs=()
  cc_cached "$w/goose_runtime.c" "$w/obj/goose_runtime.o" -O2; objs+=("$w/obj/goose_runtime.o")
  if [ -f "src/$tool.build" ]; then
    # The sidecar may name the program's own C and nothing else (goose's packages.md §3); fail loudly otherwise.
    local side; side=$(sed -e 's://.*$::' "src/$tool.build" | tr -d ' \t\n')
    [[ "$side" =~ ^(c_sources=\[(\"[A-Za-z0-9_./-]+\"(,\"[A-Za-z0-9_./-]+\")*)?\];)?$ ]] ||
      { echo "build.sh: src/$tool.build has more than c_sources; build it with GOOSE_BUILD=whole" >&2; exit 1; }
    local f
    for f in $(grep -o '"[^"]*"' <<< "$side" | tr -d '"'); do
      cc_cached "src/$f" "$w/obj/side-${f//\//_}.o" -O2 -fPIC; objs+=("$w/obj/side-${f//\//_}.o")
    done
  fi
  local size n parts
  size=$(stat -c %s "$w/$tool.c")
  n=$(( size / 2000000 )); [ "$n" -lt 1 ] && n=1; [ "$n" -gt "$jobs" ] && n=$jobs
  local rc=0
  parts=$(python3 tools/splitc.py "$w/$tool.c" "$w/parts" "$n") || rc=$?
  if [ "$rc" -eq 3 ]; then
    echo "build.sh: tools/splitc.py could not split $tool.c (goose's C layout changed?); compiling it whole" >&2
    parts="$w/$tool.c"
  elif [ "$rc" -ne 0 ]; then
    exit "$rc"
  fi
  # -w: the generated C trips -Wparentheses-equality ~100 times; goose's own build shows those too, nobody reads them.
  printf '%s\n' $parts | xargs -P "$jobs" -I{} bash -c 'cc_cached "$1" "${1%.c}.o" -O2 -flto=thin -w' _ {}
  local p pobjs=()
  for p in $parts; do pobjs+=("${p%.c}.o"); done
  # ThinLTO puts back the inlining across parts (and internalizes the hidden symbols again); its backends run
  # in parallel too. Without it the split binary was 25% slower on instcombine-heavy inputs (NOTES.md "Build").
  mkdir -p "$cache/thinlto"
  "$cc" -O2 -flto=thin -fuse-ld=lld -Wl,--thinlto-jobs="$jobs" -Wl,--thinlto-cache-dir="$cache/thinlto" \
    -Wl,--thinlto-cache-policy=prune_after=48h:cache_size_bytes=4g \
    "${pobjs[@]}" "${objs[@]}" -o "$out" -lm -pthread -ldl
}

build_whole() {  # $1 = tool, $2 = output path
  goose build --stack-reserve "$reserve" --cc "$cc" -o "$2" "src/$1.goose" >/dev/null
}

for tool in opt llc llvm-link; do
  h=$(inputs_hash "$tool")
  if [ -x "bin/$tool" ] && [ "$(cat "bin/.$tool.stamp" 2>/dev/null || true)" = "$h" ]; then continue; fi
  rm -f "bin/.$tool.stamp"
  if [ -x "$cache/bin/$h/$tool" ]; then
    cp -f "$cache/bin/$h/$tool" "bin/$tool.tmp"
    touch "$cache/bin/$h"
  else
    "build_$mode" "$tool" "bin/$tool.tmp"
  fi
  mv -f "bin/$tool.tmp" "bin/$tool"
  if [ "$(inputs_hash "$tool")" != "$h" ]; then
    echo "build.sh: inputs changed during the build of $tool; it will be rebuilt next time" >&2
    continue
  fi
  if [ ! -x "$cache/bin/$h/$tool" ]; then
    mkdir -p "$cache/bin/$h.$$"; cp -f "bin/$tool" "$cache/bin/$h.$$/$tool"
    mv -T "$cache/bin/$h.$$" "$cache/bin/$h" 2>/dev/null || rm -rf "$cache/bin/$h.$$"
  fi
  echo "$h" > "bin/.$tool.stamp"
done
rm -f bin/.stack-reserve   # the old mtime-based scheme's stamp

# Keep the cache bounded: objects and binaries unused for two days go.
find "$cache/obj" -name '*.o' -mtime +2 -delete 2>/dev/null || true
find "$cache/bin" -mindepth 1 -maxdepth 1 -type d -mtime +2 -exec rm -rf {} + 2>/dev/null || true
