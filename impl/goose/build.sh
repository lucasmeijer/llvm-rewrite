#!/usr/bin/env bash
# Builds bin/{opt,llc,llvm-link}. Called by the harness before every check; keep it incremental and quick.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p bin
for tool in opt llc llvm-link; do
  # goose build is content-hashed under GOOSE_HOME, but skip it entirely when nothing changed.
  if [ ! -x "bin/$tool" ] || [ -n "$(find src -name "*.goose" -newer "bin/$tool" -print -quit)" ]; then
    goose build --cc /opt/llvm-23.1.5/bin/clang -o "bin/$tool" "src/${tool}.goose" >/dev/null
  fi
done
