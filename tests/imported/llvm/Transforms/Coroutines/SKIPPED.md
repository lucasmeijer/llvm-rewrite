# Skipped while importing llvm/test/Transforms/Coroutines (llvmorg-23.1.5)

155 of 168 files imported. Regenerate with `./harness/run import-llvm Transforms/Coroutines`.

- `coro-alloca-outside-frame.ll` RUN `opt < %s -passes='cgscc(coro-split),simplifycfg,early-cse' -S -o %t.ll`: writes to a file
- `coro-alloca-outside-frame.ll` RUN `FileCheck --input-file=%t.ll %s`: not an opt invocation
- `coro-async-notail-wasm.ll`: REQUIRES webassembly-registered-target
- `coro-catchswitch.ll`: target triple i686-pc-windows-msvc
- `coro-elide-stat.ll`: REQUIRES asserts
- `coro-pgo-setbranchweights.ll`: uses split-file
- `coro-split-dbg-labels.ll`: REQUIRES object-emission
- `coro-split-musttail-ppc64le.ll` RUN `opt < %s -passes='cgscc(coro-split),simplifycfg,early-cse' -S -mtriple=powerpc64le-unknown-linux-gnu -mcpu=pwr9 | FileCheck %s`: non-x86_64 target powerpc64le-unknown-linux-gnu
- `coro-split-musttail-ppc64le.ll` RUN `opt < %s -passes='cgscc(coro-split),simplifycfg,early-cse' -S -mtriple=powerpc64le-unknown-linux-gnu -mcpu=pwr10 --code-model=medium | FileCheck %s`: non-x86_64 target powerpc64le-unknown-linux-gnu
- `coro-split-musttail-ppc64le.ll` RUN `opt < %s -passes='cgscc(coro-split),simplifycfg,early-cse' -S -mtriple=powerpc64le-unknown-linux-gnu -mcpu=pwr10 --code-model=medium -mattr=+longcall | FileCheck %s`: non-x86_64 target powerpc64le-unknown-linux-gnu
- `coro-split-musttail-ppc64le.ll` RUN `opt < %s -passes='cgscc(coro-split),simplifycfg,early-cse' -S -mtriple=ppc32-- | FileCheck %s`: non-x86_64 target ppc32--
- `coro-split-musttail10.ll`: REQUIRES webassembly-registered-target
- `coro-split-musttail8.ll`: REQUIRES webassembly-registered-target
- `coro-split-musttail9.ll`: REQUIRES webassembly-registered-target
- `declare-value.ll`: target triple arm64-unknown
- `remarks.ll` RUN `opt < %s --disable-output -S -passes='default<O1>' --pass-remarks="coro-split|coro-elide" --pass-remarks-missed="coro-split|coro-elide" --pass-remarks-with-hotness 2>&1 | FileCheck %s`: cannot tokenize: No closing quotation
- `smoketest.ll` RUN `opt < %s -disable-output -passes='default<O0>' -debug-pass-manager 2>&1 | FileCheck %s --check-prefixes=CHECK-ALL`: diagnostic output flag -debug-pass-manager
- `smoketest.ll` RUN `opt < %s -disable-output -passes='default<O1>' -debug-pass-manager 2>&1 | FileCheck %s --check-prefixes=CHECK-ALL,CHECK-OPT`: diagnostic output flag -debug-pass-manager
- `smoketest.ll` RUN `opt < %s -disable-output -passes='default<O2>' -debug-pass-manager 2>&1 | FileCheck %s --check-prefixes=CHECK-ALL,CHECK-OPT`: diagnostic output flag -debug-pass-manager
- `smoketest.ll` RUN `opt < %s -disable-output -passes='default<O3>' -debug-pass-manager 2>&1 | FileCheck %s --check-prefixes=CHECK-ALL,CHECK-OPT`: diagnostic output flag -debug-pass-manager
- `smoketest.ll` RUN `opt < %s -disable-output -debug-pass-manager -passes='module(coro-early),function(coro-elide),cgscc(coro-split),module(coro-cleanup)' 2>&1 | FileCheck %s --check-prefixes=CHECK-ALL,CHECK-OPT`: diagnostic output flag -debug-pass-manager
- `swift-async-dbg.ll` RUN `opt -mtriple='arm64-' %s -S -passes='module(coro-early),cgscc(coro-split,simplifycfg)' -o - | FileCheck %s`: non-x86_64 target arm64-
- `swift-async-dbg.ll` RUN `opt -mtriple='i386-' %s -S -passes='module(coro-early),cgscc(coro-split,simplifycfg)' -o - | FileCheck %s --check-prefix=NOENTRY`: non-x86_64 target i386-
- `swift-async-dbg.ll` RUN `opt -mtriple='armv7-' %s -S -passes='module(coro-early),cgscc(coro-split,simplifycfg)' -o - | FileCheck %s --check-prefix=NOENTRY`: non-x86_64 target armv7-
