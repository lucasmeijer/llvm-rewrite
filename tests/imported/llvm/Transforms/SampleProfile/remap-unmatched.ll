; @origin: llvm/test/Transforms/SampleProfile/remap-unmatched.ll (llvmorg-23.1.5)
; @opt: -passes=sample-profile -sample-profile-file=tests/imported/llvm/Transforms/SampleProfile/Inputs/remap.prof -sample-profile-remapping-file=tests/imported/llvm/Transforms/SampleProfile/Inputs/remap.map
; This test should not crash.
; RUN: opt %s -passes=sample-profile -sample-profile-file=%S/Inputs/remap.prof -sample-profile-remapping-file=%S/Inputs/remap.map

define void @foo() #0 {
  ret void
}

attributes #0 = { "use-sample-profile" }
