#!/usr/bin/env bash
# Builds bin/{opt,llc,llvm-link}. Called by the harness before every check; keep it incremental and quick.
set -euo pipefail
cd "$(dirname "$0")"
export PATH="$HOME/.cargo/bin:$PATH"
cargo build --release --quiet
mkdir -p bin
for tool in opt llc llvm-link; do cp -f "target/release/$tool" "bin/$tool"; done
