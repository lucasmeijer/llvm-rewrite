# Skipped while importing llvm/test/Transforms/SCCP (llvmorg-23.1.5)

170 of 179 files imported. Regenerate with `./harness/run import-llvm Transforms/SCCP`.

- `2006-10-23-IPSCCP-Crash.ll`: target triple powerpc-unknown-linux-gnu
- `2006-12-04-PackedType.ll`: target triple powerpc-unknown-linux-gnu
- `2008-05-23-UndefCallFold.ll`: target triple i686-pc-linux-gnu
- `fp-bc-icmp-const-fold.ll`: target triple powerpc64le-unknown-linux
- `get_vector_length-intrinsic.ll` RUN `opt < %s -p sccp -S | FileCheck %s`: no -passes / -O pipeline
- `ipsccp-basic.ll` RUN `opt < %s -enable-debugify -passes=ipsccp -debugify-quiet -disable-output`: diagnostic output flag -debugify-quiet
- `ipsccp-preserve-analysis.ll` RUN `opt -disable-verify -debug-pass-manager -passes='function(require<domtree>,require<postdomtree>),ipsccp,function(require<domtree>,require<postdomtree>)' -S  %s 2>&1 | FileCheck -check-prefixes=IR,NEW-PM %s`: diagnostic output flag -debug-pass-manager
- `ipsccp-preserve-pdt.ll`: REQUIRES asserts
- `naked-return.ll`: target triple i686-pc-windows-msvc19.0.24215
- `preserve-analysis.ll` RUN `opt < %s -debug-pass-manager -passes='loop-vectorize,sccp,loop-vectorize' 2>&1 -S | FileCheck --check-prefix=NEW-PM %s`: diagnostic output flag -debug-pass-manager
- `report-changed.ll` RUN `opt -passes='require<no-op-module>,ipsccp' -disable-output < %s 2>&1 -debug-pass-manager | FileCheck %s`: redirects or chains commands
