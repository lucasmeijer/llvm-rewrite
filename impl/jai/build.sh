#!/usr/bin/env bash
# Builds bin/{opt,llc,llvm-link}. Called by the harness before every check; keep it incremental and quick.
# The compiler is installed on demand from $JAI_COMPILER_URL by scripts/ensure-jai.sh (never commit that URL).
set -euo pipefail
cd "$(dirname "$0")"
JAI="$(../../scripts/ensure-jai.sh)"
mkdir -p bin
for tool in opt llc llvm-link; do
  src="src/${tool//-/_}.jai"
  if [ ! -x "bin/$tool" ] || [ -n "$(find src -name "*.jai" -newer "bin/$tool" -print -quit)" ]; then
    "$JAI" -quiet -x64 "$src" -exe "$tool" -output_path "$PWD/bin/"
  fi
done
rm -rf src/.build bin/.build
