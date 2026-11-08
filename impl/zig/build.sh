#!/usr/bin/env bash
# Builds bin/{opt,llc,llvm-link}. Called by the harness before every check; keep it incremental and quick.
set -euo pipefail
cd "$(dirname "$0")"
zig build -Doptimize=ReleaseSafe --prefix .
