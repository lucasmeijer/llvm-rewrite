#!/usr/bin/env bash
# Builds an assertions-enabled opt 23.1.5 (for -debug-only=<type> traces) into
# /persistent/llvm-rewrite/llvm-23.1.5-assert/bin/opt. ~12 min on 16 cores. Its output is identical to the release opt.
# The llvm/ sources come from /opt/llvm-project-23.1.5; cmake/, third-party/ and libc/ (needed by the build) from a
# sparse clone of the llvmorg-23.1.5 tag. The build dir is kept so that temporary LLVM_DEBUG prints added to
# src/llvm/... rebuild in about a minute (`ninja opt`); restore the file afterwards.
set -euo pipefail
R=/persistent/llvm-rewrite/llvm-assert-src
mkdir -p "$R" && cd "$R"
if [ ! -d src ]; then
  git clone --depth 1 --branch llvmorg-23.1.5 --filter=blob:none --sparse https://github.com/llvm/llvm-project.git src
  (cd src && git sparse-checkout set cmake third-party libc)
fi
rsync -a --exclude=/test --exclude=/unittests /opt/llvm-project-23.1.5/llvm/ src/llvm/
mkdir -p build && cd build
cmake -G Ninja ../src/llvm -DCMAKE_BUILD_TYPE=Release -DLLVM_ENABLE_ASSERTIONS=ON -DLLVM_TARGETS_TO_BUILD=X86 \
  -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_BENCHMARKS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF -DLLVM_ENABLE_ZLIB=OFF \
  -DLLVM_ENABLE_ZSTD=OFF -DLLVM_ENABLE_LIBXML2=OFF -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++
nice ninja -j"$(nproc)" opt
mkdir -p /persistent/llvm-rewrite/llvm-23.1.5-assert/bin
cp bin/opt /persistent/llvm-rewrite/llvm-23.1.5-assert/bin/opt
