#!/usr/bin/env bash
# Installs the pinned toolchains for llvm-rewrite workspaces. Run as root at image build time
# (see .agents-in-the-cloud/Dockerfile). Paths are hardcoded in harness/lrh/config.py.
set -euo pipefail

LLVM_VERSION=23.1.5
LLVM_SHA256=c3107384835f788768f614db610e87fba7077f125ca950eb02a78bab0a308065
ZIG_VERSION=0.17.1
ZIG_SHA256=3581863e3cbcfd0fce0efc682ce7e9e93da96668a977791d356a26d2a7e9b17a

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# --- LLVM release binaries, pruned to what the harness and agents use (the full tarball is 12 GB).
name="LLVM-${LLVM_VERSION}-Linux-X64"
curl -fsSL -o "$tmp/llvm.tar.zst" \
  "https://github.com/llvm/llvm-project/releases/download/llvmorg-${LLVM_VERSION}/${name}.tar.zst"
echo "${LLVM_SHA256}  $tmp/llvm.tar.zst" | sha256sum -c -
dest="/opt/llvm-${LLVM_VERSION}"
rm -rf "$dest" && mkdir -p "$dest"
tools=(clang clang-23 clang++ clang-cpp opt llc lli llvm-as llvm-dis llvm-link llvm-reduce llvm-extract
       llvm-diff llvm-mc llvm-objdump llvm-symbolizer llvm-nm llvm-ar llvm-config lld ld.lld)
members=("${name}/lib/clang")
for t in "${tools[@]}"; do members+=("${name}/bin/$t"); done
zstd -d --long=31 -c "$tmp/llvm.tar.zst" | tar -xf - -C "$dest" --strip-components=1 "${members[@]}"
rm "$tmp/llvm.tar.zst"
"$dest/bin/opt" --version | grep -q "LLVM version ${LLVM_VERSION}"

# --- LLVM source at the same tag (llvm/ only), for reading pass implementations and importing tests.
src="/opt/llvm-project-${LLVM_VERSION}"
rm -rf "$src"
git clone -q --depth 1 --branch "llvmorg-${LLVM_VERSION}" --filter=blob:none --sparse \
  https://github.com/llvm/llvm-project.git "$src"
git -C "$src" sparse-checkout set llvm
git config --system --add safe.directory "$src"

# --- llvm-test-suite at the matching tag (SingleSource + MultiSource only, no history).
ts="/opt/llvm-test-suite-${LLVM_VERSION}"
rm -rf "$ts"
git clone -q --depth 1 --branch "llvmorg-${LLVM_VERSION}" https://github.com/llvm/llvm-test-suite.git "$tmp/ts"
mkdir -p "$ts"
mv "$tmp/ts/SingleSource" "$tmp/ts/MultiSource" "$tmp/ts/LICENSE.TXT" "$ts/"

# --- Zig.
curl -fsSL -o "$tmp/zig.tar.xz" "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz"
echo "${ZIG_SHA256}  $tmp/zig.tar.xz" | sha256sum -c -
rm -rf "/opt/zig-${ZIG_VERSION}" && mkdir -p "/opt/zig-${ZIG_VERSION}"
tar -xJf "$tmp/zig.tar.xz" -C "/opt/zig-${ZIG_VERSION}" --strip-components=1
ln -sf "/opt/zig-${ZIG_VERSION}/zig" /usr/local/bin/zig

chmod -R a+rX "$dest" "$src" "$ts" "/opt/zig-${ZIG_VERSION}"
echo "toolchains installed"
