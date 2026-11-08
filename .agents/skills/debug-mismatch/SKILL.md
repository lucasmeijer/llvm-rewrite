---
name: debug-mismatch
description: Systematically find why your implementation's output differs from LLVM's on a failing test (IR diff, pipeline divergence, or wrong program output). Use when a check fails and the cause isn't obvious.
---

# Debugging a mismatch

Start with `./harness/run show <test-id> --impl <lang>`. Artifacts are in `.harness-out/<lang>/<path>/<check>/`.

## roundtrip fails (printer/parser)

`diff.txt` shows text differences against `opt -S`. Typical causes: number formatting (floats print as hex
`0x…` unless exactly representable in decimal), quoting/escaping of names and strings, attribute group numbering
and order, metadata numbering and order, comments (`; Function Attrs:`, `; preds = …`), blank lines. The LLVM printer is
`llvm/lib/IR/AsmWriter.cpp`. Read it rather than guessing.

## opt fails (pass output)

1. Multi-pass pipelines (`-O2`, `function(a,b,c)`): `./harness/run bisect <test> --impl <lang>` finds the first
   bisectable pass whose output differs. Reproduce with `-opt-bisect-limit=N` on both tools.
2. Single pass: reduce the input. Copy `input`/`expected.ll` to a scratch file, delete functions and instructions
   that don't matter, and recheck with `/opt/llvm-23.1.5/bin/opt <args> -S` against your opt. `llvm-reduce` can
   automate this with an interestingness script that returns 0 while the outputs still differ:
   `llvm-reduce --test=./interesting.sh in.ll`.
3. Compare *why* LLVM did what it did: read the pass source around the transform that differs.
4. Land the reduced case as a new test (skill `write-test`) when it isolates something the existing tests don't.

## isel-ir fails

These are llc's IR-level passes before isel (pre-isel-intrinsic-lowering, expand-ir-insts, atomic-expand, at -O2
loop-reduce and codegenprepare, …). llc still uses the legacy pass manager. List the passes with
`/opt/llvm-23.1.5/bin/llc -O2 -debug-pass=Structure -stop-before=x86-isel in.ll -o /dev/null`, and see each step's
output with `-print-after-all`.

## run fails (behaviour)

1. `message.txt` says which stage failed: llc, link (bad assembly), run (crash, timeout) or a stdout/exit-code
   mismatch.
2. Compare against LLVM's assembly: `/opt/llvm-23.1.5/bin/llc <llc args> input.ll -o ref.s` vs `.harness-out/…/out.s`.
3. Narrow down: function tests isolate single functions. For e2e programs, compile individual functions with LLVM
   (`llvm-extract`) and link them with yours to bisect which function is miscompiled.
4. Debug the binary: `gdb` / `lldb` are available. Assemble with `clang -g -no-pie out.s`.
5. ABI mismatches (struct passing, varargs, `signext`/`zeroext`, stack alignment, red zone) are the usual suspects.
   See skill `codegen`.
