# GVNHoist and GVNSink

Facts about LLVM 23.1.5's `gvn-hoist` (lib/Transforms/Scalar/GVNHoist.cpp) and `gvn-sink` (GVNSink.cpp), found while
porting them (impl/jai, L1.extra.gvn-hoist-sink). Verified with the unit tests (tests/imported/llvm/Transforms/GVNHoist,
GVNSink), `sweep --passes gvn-hoist|gvn-sink` (whole files, `--per-function`, `--with-test-flags`,
`function(sroa),...` on tests/perf/compile, `default<O2> -enable-gvn-hoist|-enable-gvn-sink`) and the assertions
build's `-debug-only=gvn-sink`.

## GVNHoist

- Value numbers come from `GVNPass::ValueTable` with MemDep set and no MemorySSA: loads and stores get fresh numbers
  (they are keyed by the numbers of their pointer / stored value instead), read-only calls are numbered through
  MemDep. The table is cleared between rounds only when loads, stores or calls were hoisted; at most
  `-gvn-hoist-max-chain-length` - 1 = 9 rounds run (the counter is incremented and tested before the first round).
- `DFSNumber` numbers blocks in depth-first order and instructions *per block* (1, 2, ... restarting in every block);
  a hoisted instruction takes the terminator's number and the terminator's number is incremented.
- The order in which the VN maps are walked (`DenseMap` iteration, then an unstable `llvm::sort` by `rank`) does not
  reach the output: each VN's CHI args in a block are pushed contiguously and later `stable_sort`ed by VN. The
  hoisting list is however built by iterating `OutValue`, a `DenseMap<BasicBlock *, ...>` (block address order);
  hoists into different blocks are independent in every test we have (no sweep difference with creation order),
  but not in general: `hoist()` checks operand availability when it gets to an entry ("The order in which hoistings
  are done may influence the availability of operands"), so an instruction whose operand is hoisted into another
  block in the same round depends on that order.
- Load keys are `(VN of the pointer, Type *)`, so two loads of different types from one address sort by type address
  (and are hoisted into a common block in that order). Primitive types live inside LLVMContextImpl, derived types
  in its BumpPtrAllocator, so creation order is not their address order.
- `Repl->moveBefore(Terminator)` adopts the terminator's debug records; `dropLocation()` follows.
- Under `-O2 -enable-gvn-hoist` the pass runs right after `early-cse<memssa>` (and after `assume-simplify` with
  knowledge retention); `-enable-gvn-sink` adds `gvn-sink` and `simplifycfg<switch-range-to-icmp>` there.

## GVNSink

- The value number of an instruction is a function of its *users*: `InstructionUseExpr` collects one user per use,
  sorts them **by address** (`llvm::sort(operands())` on `Value *`) and hashes their value numbers in that order (plus
  opcode, type, memory-use order, volatility, shuffle mask). Two corresponding instructions in sibling blocks whose
  users are, e.g., a local instruction and a shared phi get equal numbers only if the heap happened to place the
  users in the same relative order: InstCombine/phi-of-insertvalues.ll `@test3_extrause2` gets VN 3 and 4 for the two
  symmetric `insertvalue`s (assertions build trace). Creation order reproduces LLVM in about two thirds of the corpus
  files where this matters and in none of tests/perf/compile after `default<O2>`; impl/jai fails loudly there.
- `ExpressionNumbering` is keyed by the (fresh) expression pointer, so it never hits: the number is decided by
  `HashNumbering` (hash equality).
- `VNums` is a `DenseMap<uint32_t, unsigned>`; `max_element(VNums, less_second)` returns the *first* maximum in bucket
  order (hash = `Val * 37`, 64 buckets to start), not the first inserted.
- Block order everywhere is the RPOT order (`RPOTOrder`), with blocks without predecessors other than the entry left
  out; `sinkBB` bails out when a predecessor is not in it.
- `calculateCost` computes in `unsigned` and stores to `int`: `NumPHIs - NumOrigPHIs` wraps when sinking made a phi
  redundant, which gives a large negative cost.
- New phis are named `<operand name>.sink` (`.sink` for an unnamed operand) and inserted at `begin()` (before debug
  records); the sunk instruction moves to `getFirstInsertionPt()` (head bit: its own records stay behind).
- GVNSink preserves nothing.
