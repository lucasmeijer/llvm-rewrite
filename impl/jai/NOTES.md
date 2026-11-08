# impl/jai notes

- The compiler (beta 0.2.030) isn't in the workspace image, because its download URL is private. `build.sh` calls
  `scripts/ensure-jai.sh`, which installs it once into `/persistent/toolchains/jai` from the `JAI_COMPILER_URL`
  environment variable. Never write that URL into the repo, reports or logs. If it's missing, stop and say so in a
  challenge report.
- Docs: `/persistent/toolchains/jai/how_to/*.jai` (numbered tutorials), `README.txt`, `CHANGELOG.txt`, and the module
  sources in `/persistent/toolchains/jai/modules`. Training data for Jai is thin and the language changes between
  betas, so check against the how_to files and modules rather than relying on memory.
- `build.sh` compiles each `src/<tool>.jai` with the x64 backend (`-x64`): about 0.5 s for `opt`. The LLVM backend
  with `-o` takes ~6.5 s per tool but the result parses+prints sqlite3.ll in 0.26 s vs 1.5 s for the x64 build
  (LLVM's opt: 0.36 s). `perf` numbers from the default build are therefore ~5-9x LLVM for parse+print; that's the
  backend, not the algorithms (scaling exponents are all ~1.0). Switch build.sh to `-o` when speed matters.

## Layout of the code

- `src/opt.jai` `#load`s the shared core: `ir.jai` (tables, use lists, RAUW, interning), `apfloat.jai` (bignum,
  APFloat decimal printing/parsing), `datalayout.jai`, `lexer.jai`, `parser.jai`, `printer.jai`, `intrinsics.jai`.
  `llc.jai` and `llvm_link.jai` are still stubs; they should `#load` the same files.
- Generated tables (do not edit, rerun the script): `gen_attrs.jai` (`gen/gen_attrs.py`, attribute kinds in
  TableGen order from Attributes.td), `gen_cc.jai` (`gen/gen_cc.py`, calling conventions), `gen_intrinsics.jai`
  (`gen/gen_intrinsics.py`: intrinsic names and overloadedness from Intrinsics.td/IntrinsicsX86.td, and the
  attributes the oracle prints for every intrinsic declaration in `opt -S` of any file in `tests/`; a return
  `range(iN ...)` is stored as `range(i@ ...)` and gets the return width at run time). An intrinsic that isn't in
  the table fails loudly: add a test that uses it and rerun the script.

## Pass infrastructure status (see DESIGN.md §9-10)

- Passes: dce, adce (+ `-adce-remove-loops`, `-adce-remove-control-flow`), bdce, break-crit-edges; printers
  print<domtree>, print<postdomtree>, print<demanded-bits>; require<>/invalidate<> for domtree, postdomtree,
  demanded-bits. L1.analysis.domtree is COMPLETE. L1.dce: all checks that only need dce/adce/bdce pass; the rest need
  simplifycfg, sroa, gvn, licm (loop-mssa), instcombine, debugify, redundant-dbg-inst-elim, debug-info metadata,
  `--preserve-ll-uselistorder` printing or `--enable-knowledge-retention` (AssumeBundleBuilder), and fail loudly.
- Cross-checked beyond the corpus: dce, adce, adce -adce-remove-loops, bdce and break-crit-edges output, and
  print<domtree>/print<postdomtree> (also after break-crit-edges and adce with cached trees), are identical to LLVM's
  on every imported test that round-trips (6635 files), except BDCE on `InstCombine/known-bits.ll` (assume-based
  known bits).
- **Sweep beyond the unit's tests** (found 6 bugs the unit tests didn't): for every round-tripping imported file,
  run our opt and LLVM's with the same pipeline and compare canonicalized IR (`llvm-as | llvm-dis`) or, for
  printers, stderr (sorted for demanded-bits):
  `grep ::roundtrip impl/jai/passing.txt | sed 's/::roundtrip//' | grep imported | xargs -P8 -I{} cmp.sh "-passes=adce" {}`
  where cmp.sh runs both tools into a temp dir and prints OK/DIFF/JAI-FAIL. Do this for every new pass.
- **known_bits.jai is a partial computeKnownBits**: no assumptions/dominating conditions, no isKnownNonZero, no
  mul/div/rem/intrinsics/abs/min/max, no getKnownBitsFromAndXorOr idioms, no adjustKnownBitsForSelectArm, no
  computeKnownBitsAddSub dom-condition refinement. print<demanded-bits> matches LLVM (unordered) on 6538 of 6635
  files; the rest are these gaps or intrinsic-name upgrades. Note that missing known bits is *not* always
  conservative for BDCE: an operand with fewer known bits can look dead (`and 0, %phi`). Replace the file with the
  full ValueTracking port when InstSimplify/InstCombine need it.
- TLI: only what DCE/ADCE need (MemoryBuiltins' new/delete/strdup tables, allockind, isMathLibCallNoop with host
  libm + fenv via `#foreign`, "no-builtins"/"no-builtin-<f>"). Its `getLibFunc` prototype checks are simplified.
- Debug info: salvageDebugInfo/dbg-record dropping are no-ops because the parser rejects debug records.
- Perf (x64 build, sqlite3.ll, `-disable-output`): parse 1.01 s (LLVM 0.28 s); dce +0.0 s (LLVM +0.0), adce +0.23 s
  (LLVM +0.01), bdce +0.31 s (LLVM +0.03), require<domtree>,require<postdomtree> +0.01 s. ADCE/BDCE cost is in
  `Table` lookups and temp APInt allocation (every APInt op allocates); no `@perf` benchmark times these passes, so
  nothing in `harness/run perf` covers them yet.

## Jai traps hit so far

- **`cast(T) x << y` casts the whole shift**: `cast(u64) 1 << 63` computes `1 << 63` as s64 and then fails the
  cast check; `cast(u64) a << 32` with a u32 `a` shifts in 32 bits (silently 0). Write `(cast(u64) 1) << n`.
- `x := NONE` gives `x` type s64 (NONE is an untyped constant); write `x: Value_Id = NONE`.
- `for * CONST_ARRAY` iterates a temporary copy: a pointer into a `::` constant array dangles. Copy constant tables
  into a `[..]` array before handing out pointers (passes.jai `pass_table`).
- Procedure names are global across all `#load`ed files and only type-checked when used: a duplicate name added by
  another agent shows up as an "ambiguous overload" error in code that didn't change.
- `table_find` returns `(found, value)`; `found, x := table_find(...)` order matters (we got it backwards twice).

- `for i: 0..n-1` with an unsigned `n == 0` underflows and loops ~4 billion times (and then hits a bounds check).
  Loops over `u32` counts are written `if n > 0 for i: 0..n-1`, or the bound is cast to `s64`.
- `Basic` already defines `is_alpha`, `is_digit`, `is_alnum` (and its `is_alnum` includes `_`!). The lexer uses its
  own `c_isalpha` / `c_isdigit` / `c_isalnum` / `c_isxdigit` with C semantics.
- `is_constant` is a compiler builtin name; declaring a procedure with that name gives a baffling "'(' expected".
- A parameter named like a procedure (`print_type: bool`) shadows the procedure inside the body.
- `ifx c then #char "a" else #char "b"` is `s64`, not `u8`: cast the first branch.
- `NewArray(n, T,, allocator = temp)` / `alloc_string(n,, allocator = temp)`: the allocator goes through the `,,`
  context syntax, not a parameter.
- `Hash_Table.table_find` returns `(found: bool, value)` in this beta (bool first).
- Interning keys are built in shared scratch buffers (`tmp_key` for constants, `type_key`, `md_key`,
  `attr_key_buf`). Never build one key and then call something that interns another kind of thing before the
  lookup (that bug made all `blockaddress` constants of a function the same).

## Design debts

- Instruction payloads live in one fixed-width `Inst_Row` (alignment, orderings, types, attribute list, u32-pool
  indices) instead of per-opcode side tables; fine for now (~64 bytes per instruction).
- Specialized metadata (`!DILocation(...)` and the other `DI*` nodes), debug records (`#dbg_value`), `uselistorder`
  directives, funclet instructions, `callbr`, and the `extractelement`/`insertelement`/`shufflevector`/`ptrauth`
  constant expressions are rejected with an error. These are most of the remaining L0.print-imported errors
  (debug info alone is ~200 files).
- No AutoUpgrade (llvm/lib/IR/AutoUpgrade.cpp) beyond intrinsic attributes: old intrinsic signatures
  (`llvm.lifetime.start` with a size, `llvm.masked.load` with an alignment argument, ...), missing or wrong name
  mangling (`@llvm.smin(` → `@llvm.smin.i32`), and module-flag upgrades are the bulk of the remaining
  L0.print-imported diffs. Constant folding of constant expressions is minimal (no-op GEPs,
  casts of poison/undef/null); real folding belongs with InstSimplify/ConstantFolding.
- Erased values keep their rows (`v_kind = DEAD`); nothing is compacted.
