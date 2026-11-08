FROM agents-in-the-cloud-workspace
# AgentsInTheCloud image version: 3
# Bump the version above whenever .agents-in-the-cloud/image/install-toolchains.sh changes.
# Provides: LLVM 23.1.5 (/opt/llvm-23.1.5), its source (/opt/llvm-project-23.1.5),
# llvm-test-suite (/opt/llvm-test-suite-23.1.5), Zig (/opt/zig-0.17.1) and Goose (/opt/goose-v2026.4), both on PATH.
# Jai can't be baked in (its download URL is private): scripts/ensure-jai.sh installs it at runtime from
# $JAI_COMPILER_URL into /persistent.
# C (gcc/clang), Rust (rustup) and Python 3 come with the base image.

RUN apt-get update \
 && apt-get install -y --no-install-recommends zstd xz-utils ca-certificates curl git unzip libc6-dev

COPY .agents-in-the-cloud/image/install-toolchains.sh /tmp/install-toolchains.sh
RUN bash /tmp/install-toolchains.sh && rm /tmp/install-toolchains.sh

# Extra packages go in their own step, after the toolchains. Editing an earlier step invalidates the cached toolchain
# layer, and rebuilding it fails here: large GitHub release downloads (LLVM, Goose) time out with 504 through the proxy.
# valgrind: `harness/run perf --instr` counts executed instructions with cachegrind (the VM has no hardware counters).
RUN apt-get update \
 && apt-get install -y --no-install-recommends valgrind
