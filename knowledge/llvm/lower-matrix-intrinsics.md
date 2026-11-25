# LowerMatrixIntrinsics (lower-matrix-intrinsics)

Facts verified against opt 23.1.5 (tests/imported/llvm/Transforms/LowerMatrixIntrinsics, plus the directory's
aarch64-only tests rerun with an x86_64 triple; source llvm/lib/Transforms/Scalar/LowerMatrixIntrinsics.cpp).

- Without a target triple TTI is NoTTIImpl: `getRegisterBitWidth(FixedWidthVector)` = 32, so the multiply's vector
  factor is `max(32 / eltbits, 1)` (1 for float and double: every multiply is lowered one element at a time), 8
  registers, nothing is a legal type. Most imported tests have no triple, so they all take that path.
- `<minimal>` (the -O0 `-enable-matrix` variant) gets no DT/AA/LI: no transpose sinking/lifting, no fusion, but
  dot products are still lowered (lowerDotProduct does not need the analyses). Non-minimal preserves LoopAnalysis and
  DominatorTree when it changes something (it updates both when it builds tiled loop nests / alias checks).
- The ShapeMap entry of `llvm.matrix.column.major.store` is the transposed shape (computeShapeInfoForInst returns
  `ShapeInfo(N, M)`); the lowering itself reads the intrinsic's own arguments, so this only shows in remarks.
- Names: `split`, `block`, `splat.splatinsert`/`splat.splat`, `col.load`, `vec.start` (a `mul` even when the index
  is 0 and the stride is not constant), `vec.gep`, `<arg>.cast` for strides of another width than the index type,
  sinking creates `<op>_t`, `mmul`, `madd`; lifting `mfadd`, `mfadd_t`; alias checks `alias_cont`, `copy`,
  `no_alias`, `store.end`, `load.end`; tiled loops `cols/rows/inner.{header,body,latch,iv,step,cond}`,
  `result.vec.<i>`, `continue`, and `llvm.loop.unroll.count` = min(10, M / tile size) on the inner loop.
- The lowered binary operators do not keep nsw/nuw/exact (IRBuilder::CreateBinOp); fast-math flags come from
  `Builder.setFastMathFlags(getFastMathFlags(I))` (I's flags, plus `contract` under -matrix-allow-contract), which
  stays set on the builder for whatever that builder creates later. The dot-product `fmul` gets no flags; only its
  `llvm.vector.reduce.fadd` gets the multiply's flags.
- A release opt (assertions off) lowers the column-major load/store intrinsics with `-matrix-default-layout=row-major`
  as row-major instead of asserting.
- Transpose sinking duplicates operands ((A+B)^t -> A^t + B^t creates new transposes that are visited next), so a deep
  chain of transposed add/multiply trees blows up exponentially in LLVM itself.
