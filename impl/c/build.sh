#!/usr/bin/env bash
# Builds bin/{opt,llc,llvm-link}. Called by the harness before every check; keep it incremental and quick.
set -euo pipefail
cd "$(dirname "$0")"
CC=/opt/llvm-23.1.5/bin/clang
CFLAGS=(-std=c11 -O2 -g -Wall -Wextra -Werror)
mkdir -p bin
for tool in opt llc llvm-link; do
  src="src/${tool}.c"
  if [ ! bin/$tool -nt "$src" ] || [ -n "$(find src -newer bin/$tool -print -quit)" ]; then
    "$CC" "${CFLAGS[@]}" -o "bin/$tool" "$src"
  fi
done
