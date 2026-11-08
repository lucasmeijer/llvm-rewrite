# Skipped while importing llvm/test/Transforms/MergedLoadStoreMotion (llvmorg-23.1.5)

14 of 14 files imported. Regenerate with `./harness/run import-llvm Transforms/MergedLoadStoreMotion`.

- `st_sink_split_bb.ll` RUN `opt -debug-pass-manager -aa-pipeline=basic-aa -passes='require<memdep>,mldst-motion' -S < %s 2>&1 | FileCheck %s --check-prefixes=CHECK-NO,CHECK-INV-NO`: diagnostic output flag -debug-pass-manager
- `st_sink_split_bb.ll` RUN `opt -debug-pass-manager -aa-pipeline=basic-aa -passes='require<memdep>,mldst-motion<split-footer-bb>' -S < %s 2>&1 | FileCheck %s --check-prefixes=CHECK-YES,CHECK-INV-YES`: diagnostic output flag -debug-pass-manager
