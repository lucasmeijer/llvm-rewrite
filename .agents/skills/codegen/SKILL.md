---
name: codegen
description: Conventions and checklists for backend work (instruction selection, register allocation, frame lowering, x86-64 SysV ABI, assembly emission). Use for L1, L2 and L5 units.
---

# Backend work

The backend is judged by behaviour (`::run`), not by matching llc's assembly. Correctness first, then quality, and
quality only in L5, where it's measured.

## Output

- AT&T syntax, GNU assembler directives, for `x86_64-unknown-linux-gnu`. The harness links with
  `clang -no-pie -O1 out.s [driver.c] -lm`, so absolute addressing is allowed. RIP-relative addressing works too, and
  it's what llc emits.
- Emit everything the module needs: functions (`.globl`, `.type @function`, `.size`), globals in the right sections
  (`.data`, `.bss`, `.rodata`, `.tbss`/`.tdata` for TLS), alignment, linkage (`internal` → local symbols, `weak`,
  `linkonce_odr` → `.weak` or comdat sections), `.section .note.GNU-stack,"",@progbits`.
- For reference, `/opt/llvm-23.1.5/bin/llc -O0 in.ll -o -` shows how LLVM does it. Copying its *conventions* is fine
  and often the quickest path. Matching its output exactly isn't required.

## SysV ABI checklist

- Integer/pointer args: rdi, rsi, rdx, rcx, r8, r9, then the stack (8-byte slots, right to left). FP args: xmm0–7.
  Return in rax(/rdx) and xmm0(/xmm1). x86_fp80 is passed in memory and returned in st(0).
- Varargs calls: `al` = upper bound on the number of vector registers used. A varargs callee saves the register save
  area (`va_start`/`va_arg` lowering).
- The stack is 16-byte aligned at the call instruction, and there's a 128-byte red zone below rsp in leaf functions
  (if you use it).
- Callee-saved: rbx, rbp, r12–r15. Everything else, all xmm included, is caller-saved.
- IR has already done the struct classification (clang lowered aggregates to scalars, `byval`, `sret`). Honour the
  attributes: `byval` (copy onto the stack), `sret` (pointer in rdi, returned in rax), `signext`/`zeroext` (extend to
  32 bits), `inreg`, `noundef` (no effect).
- i128 goes in a register pair. Struct returns of `{i64,i64}` / `{double,double}` / mixed use rax:rdx / xmm0:xmm1 /
  rax:xmm0 as the IR types dictate.

## Lowering scope by layer

- **L1 (-O0 input):** allocas, loads/stores, integer and FP arithmetic of every width (legalize i1/i8/i16/i128,
  x86_fp80), compares, branches, switch, calls (direct, indirect, varargs), GEP, casts, intrinsics clang emits at -O0
  (memcpy/memset/memmove, va_*, stacksave/restore, bit ops, overflow ops, fabs and friends), globals and constant
  expressions, TLS, atomics, indirectbr, setjmp/longjmp (returns_twice).
- **L2 (-O2 input):** phis (and critical edges), select, vectors and shuffles (SSE2 baseline), more intrinsics (ctlz
  with zero-undef flags, umin/smax, fshl, vector reductions), tail calls, `switch` lowering to jump tables or trees.
- Unsupported constructs: exit nonzero with "unsupported: <what>". Never emit something that might be wrong.
