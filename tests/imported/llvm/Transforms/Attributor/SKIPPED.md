# Skipped while importing llvm/test/Transforms/Attributor (llvmorg-23.1.5)

174 of 192 files imported. Regenerate with `./harness/run import-llvm Transforms/Attributor`.

- `do-not-replace-addrspacecast-with-constantpointernull.ll`: in a AMDGPU target directory
- `nofpclass-amdgcn-exp.ll`: in a AMDGPU target directory
- `nofpclass-amdgcn-fract.ll`: in a AMDGPU target directory
- `nofpclass-amdgcn-log.ll`: in a AMDGPU target directory
- `nofpclass-amdgcn-rcp.ll`: in a AMDGPU target directory
- `nofpclass-amdgcn-rsq.ll`: in a AMDGPU target directory
- `nofpclass-amdgcn-trig-preop.ll`: in a AMDGPU target directory
- `tag-invariant-loads.ll`: in a AMDGPU target directory
- `thiscall.ll`: target triple i386-pc-windows-msvc19.11.0
- `fp-bc-icmp-const-fold.ll`: target triple powerpc64le-unknown-linux
- `naked-return.ll`: target triple i686-pc-windows-msvc19.0.24215
- `address_space_info.ll`: REQUIRES amdgpu-registered-target
- `allow_list.ll`: REQUIRES asserts
- `depgraph.ll` RUN `opt -passes=attributor-cgscc -disable-output -attributor-dump-dep-graph -attributor-depgraph-dot-filename-prefix=%t < %s 2>/dev/null`: uses lit substitution -attributor-depgraph-dot-filename-prefix=%t
- `depgraph.ll` RUN `FileCheck %s -input-file=%t_0.dot --check-prefix=DOT`: not an opt invocation
- `heap_to_stack_gpu.ll`: target triple amdgcn-amd-amdhsa
- `memory_locations_gpu.ll`: target triple amdgcn-amd-amdhsa
- `phi_bug_pointer_info.ll`: REQUIRES asserts
- `openmp_opt_constant_type_crash.ll`: target triple amdgcn-amd-amdhsa
- `undefined_behavior.ll` RUN `opt -aa-pipeline=basic-aa -passes=attributor -attributor-manifest-internal  -attributor-annotate-decl-cs  -pass-remarks=attributor -disable-output < %s 2>&1 | FileCheck %s --check-prefixes=REMARKS,REMARKS-TUNIT --implicit-check-not=remark`: diagnostic output flag -pass-remarks=attributor
- `undefined_behavior.ll` RUN `opt -aa-pipeline=basic-aa -passes=attributor-cgscc -attributor-manifest-internal  -attributor-annotate-decl-cs -pass-remarks=attributor -disable-output < %s 2>&1 | FileCheck %s --check-prefixes=REMARKS,REMARKS-CGSCC --implicit-check-not=remark`: diagnostic output flag -pass-remarks=attributor
- `value-simplify-gpu.ll`: target triple amdgcn-amd-amdhsa
