# Goose: lifetime checker vs. slices, warning flood, off-by-file line numbers; intrinsic table done twice

- **Date / implementation / unit:** 2026-11-08 / goose / L0.design, L0.print-basic, L0.print-clang
- **What happened:** (1) The Goose compiler prints a "redundant `as i64`" warning for every widening cast and has no
  option to turn warnings off, so a build prints several hundred lines and real errors scroll away. (2) Some error
  locations point past the end of the file (`src/ir.goose:1371` in a 1100-line file); the quoted source line is
  right, the number is not. (3) `std::split`/`each_split` results made the lifetime checker reject later, unrelated
  code ("storing a reference into s, which holds a grow-shrink array", "cannot call text_lex_end, which shrinks src
  while parts is still used ... stored there at src/opt.goose:0"), both times on slices of static data. (4) Like the
  Jai agent, I needed `Intrinsic::getAttributes` for every intrinsic and wrote my own oracle-driven generator
  (`impl/goose/tools/gen_intrinsics.py`); the Jai agent wrote another one at the same time.
- **Time or effort lost:** about 15 minutes on (1)-(3) together (a filter script, rewriting two parsers by index);
  about 20 minutes on (4), duplicated work.
- **What would have helped:** a `--no-warnings` flag in Goose (or a note in NOTES.md that there is none, now added);
  for (4), one shared generated data file in `knowledge/llvm/` (intrinsic name → attribute text, produced by one
  script from the oracle) that every implementation reads, plus a rule saying where shared generated LLVM tables live.
- **What you did instead:** `impl/goose/tools/gb.sh` hides warnings; index-based parsing instead of `split`;
  a Goose-local intrinsic table generated from `opt` (declarations and undeclared calls found in `tests/`, with a
  probe attribute to drop unknown intrinsics and invalid signatures).
