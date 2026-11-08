# mem2reg (PromoteMemToReg) and SROA: facts that decide the output

Verified against LLVM 23.1.5 with the imported tests in tests/imported/llvm/Transforms/{Mem2Reg,SROA} and by
diffing `-passes=mem2reg` / `-passes=sroa` on all tests/e2e and tests/function O0 and pipeline inputs plus the
tests/perf/compile programs (identical after llvm-as | llvm-dis). Sources: lib/Transforms/Utils/
PromoteMemoryToRegister.cpp, lib/Transforms/Scalar/SROA.cpp, include/llvm/ADT/DenseMap.h.

## BasicBlock numbers matter
- `PromoteMem2Reg` sorts IDF blocks by `BasicBlock::getNumber()` (PHI name versions `%x.0`, `%x.1` follow it) and
  keys `NewPhiNodes` by `(BB number, alloca index)`. A block's number is assigned from the function's
  `NextBlockNum` counter when its parent is set (`BasicBlock::setParent`); LLParser creates blocks at their first
  *reference* (forward references included) and inserts them into the function right away, so numbers are
  first-reference order, not layout order. Only `SimplifyCFG` calls `renumberBlocks()`.

## DenseMap order is observable
- PHI simplification (`NewPhiNodes.remove_if(simplifyInstruction)`) and the "add poison for unreachable preds"
  loop iterate `NewPhiNodes` in bucket order. LLVM 23's DenseMap is linear probing, power-of-two buckets
  (minimum 64), grow when `(N+1)*4 >= Buckets*3`, tombstone-free erase (Knuth R), and `remove_if` rehashes in
  place (same size) afterwards. Integer hash `x*37`; pair hash `mix((h1<<32)|h2)` with
  `mix(x) = (x * 0xbf58476d1ce4e5b9) ^ (>> 31)` truncated to 32 bits.
- `Allocas` removal swaps the last alloca into the hole, so alloca indices (and so PHI order in a block, newest
  first because each PHI is inserted at `BB->begin()`) depend on which allocas were promoted early.

## Details that are easy to get wrong
- Single-store/single-block fast paths run before the IDF path; `rewriteSingleStoreAlloca` needs
  `isGuaranteedNotToBePoison(stored value)` (CtxI = null) when the value is not an instruction.
- Loads with `!noundef` of an uninitialized alloca become `store i1 true, ptr poison` before the load;
  `!nonnull !noundef` loads get `icmp ne` + `llvm.assume` unless `isKnownNonZero`.
- A dbg.declare at a PHI is converted only if the PHI type covers the variable fragment
  (`valueCoversEntireFragment`: alloc size of the type vs DIVariable size / fragment); the dbg_value gets a
  line-0 DILocation with the declare's scope and inlinedAt (`getDebugValueLoc`). The PHI's own `!dbg` is the
  merged location of incoming store locations (`DILocation::getMergedLocation`).
- `opt` skips non-required passes on `optnone` functions (OptNoneInstrumentation), after OptBisect has counted
  the pass.
- SROA names: the slice rewriter's IRBuilder prefixes every *named* instruction with
  `<newalloca>.<slice begin offset>.`; a `StringRef` name that is empty (unnamed load) still gets the prefix, a
  literal `""` does not. The builder used for PHI/select speculation, FCA splitting and pre-splitting has an
  empty prefix. `getNewAllocaSlicePtr` strips `.sroa.N.M.` components and `.sroa_*` suffixes from the old
  pointer's name.
- The GEP that adjusts a pointer uses the index width of the *target* pointer type (`i16` for an addrspace with
  16-bit indices), not the alloca's.
- `DataLayout::getTypeAllocSize` of arrays multiplies in bytes, so `[2^61 x i8]` does not overflow (computing via
  bits does).
- Speculating loads through selects/PHIs: `isSafeToLoadUnconditionally` ignores dereferenceability in functions
  with sanitize_address/thread/hwaddress and falls back to scanning the block for an earlier access.
- `sroa` without parameters means `sroa<modify-cfg>`; with modify-cfg, unspeculatable select loads/stores split
  the CFG (`.then`/`.else`/`.cont` blocks named after the head block; `swapSuccessors` also swaps branch weights).
- SROA preserves the dominator tree (DomTreeUpdater, lazy) even when it changes the CFG; the IDF used by its
  mem2reg only depends on the tree's shape, not its child order.
