FROM agents-in-the-cloud-workspace
# AgentsInTheCloud image version: 1
# Bump the version above whenever .agents-in-the-cloud/image/install-toolchains.sh changes.
# Provides: LLVM 23.1.5 (/opt/llvm-23.1.5), its source (/opt/llvm-project-23.1.5),
# llvm-test-suite (/opt/llvm-test-suite-23.1.5) and Zig (/opt/zig-0.17.1, on PATH).
# C (gcc/clang), Rust (rustup) and Python 3 come with the base image.

RUN apt-get update \
 && apt-get install -y --no-install-recommends zstd xz-utils ca-certificates curl git

COPY .agents-in-the-cloud/image/install-toolchains.sh /tmp/install-toolchains.sh
RUN bash /tmp/install-toolchains.sh && rm /tmp/install-toolchains.sh
