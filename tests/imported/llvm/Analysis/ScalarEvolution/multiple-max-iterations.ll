; @origin: llvm/test/Analysis/ScalarEvolution/multiple-max-iterations.ll (llvmorg-23.1.5)
; @opt: '-passes=require<scalar-evolution>' -scalar-evolution-max-iterations=42 -scalar-evolution-max-iterations=42
; Ensure we can pass -scalar-evolution-max-iterations multiple times
; RUN: opt -S -passes='require<scalar-evolution>' -scalar-evolution-max-iterations=42 -scalar-evolution-max-iterations=42 < %s
