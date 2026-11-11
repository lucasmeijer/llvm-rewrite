# Skipped while importing llvm/test/Transforms/RelLookupTableConverter (llvmorg-23.1.5)

4 of 6 files imported. Regenerate with `./harness/run import-llvm Transforms/RelLookupTableConverter`.

- `no_relative_lookup_table.ll` RUN `opt < %s -passes=rel-lookup-table-converter -mtriple=i386-unknown-unknown -relocation-model=pic -S | FileCheck %s`: non-x86_64 target i386-unknown-unknown
- `nvptx.ll`: REQUIRES nvptx-registered-target
- `unnamed_addr.ll`: REQUIRES aarch64-registered-target
