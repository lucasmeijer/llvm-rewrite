# Skipped while importing llvm/test/Instrumentation/HeapProfiler (llvmorg-23.1.5)

11 of 12 files imported. Regenerate with `./harness/run import-llvm Instrumentation/HeapProfiler`.

- `no-instrumentation.ll`: REQUIRES asserts
- `shadow.ll` RUN `cat %s > %t.pic.ll`: not an opt invocation
- `shadow.ll` RUN `echo -e '!llvm.module.flags = !{!0}\n!0 = !{i32 7, !"PIC Level", i32 1}' >> %t.pic.ll`: not an opt invocation
- `shadow.ll` RUN `opt < %t.pic.ll -passes='function(memprof),module(memprof-module)' -S | FileCheck --check-prefixes=PIC %s`: uses lit substitution %t.pic.ll
