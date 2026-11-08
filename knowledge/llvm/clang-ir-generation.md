# How the corpus IR is generated

`./harness/run from-c` turns one C file into three tests (see `harness/lrh/gen.py:CONFIGS`):

| Dir | clang flags | Why |
| --- | --- | --- |
| `O0/` | `-O0 -Xclang -disable-O0-optnone` | Unoptimized IR for -O0 codegen. Without the flag every function gets `optnone`, and opt skips most passes on it. |
| `O2/` | `-O2` | Fully optimized IR: phis, selects, vectors, intrinsics. Exercises the backend on realistic input. |
| `pipeline/` | `-O2 -Xclang -disable-llvm-passes` | Exactly what clang feeds into the -O2 pipeline. |

Facts:

- clang `-O0` marks every function `noinline` (and `optnone` unless disabled). So -O0 IR is the wrong input for testing
  `opt -O2`: nothing gets inlined. That's why `pipeline/` uses `-O2 -Xclang -disable-llvm-passes`. Verified on
  `tests/e2e/src/basic/sum_squares.c`, where `square` stayed a call under `opt -O2` with -O0 IR.
- IR from `-O2 -disable-llvm-passes` has TBAA metadata, `lifetime.start/end` markers and no `noinline`. It is not
  mem2reg'd.
- clang 23 rejects implicit `int` and implicit function declarations by default. Old llvm-test-suite code needs
  `-Wno-error=implicit-int` and similar (see `gen.py:CFLAGS`).
- The UB guard compares `-O0`, `-O2` and `-O1 -fsanitize=address,undefined` builds. It caught real UB in
  hand-written tests (signed overflow in `x * d`, a float-to-int conversion out of range, left shift of a negative
  value), and x87 constant-folding differences in long double arithmetic.
