# llvm-rewrite

A data-oriented rewrite of LLVM from textual IR to x86-64 assembly, including the full optimization pipeline and
whole-program optimization. Several implementations (`impl/c`, `impl/rust`, `impl/zig`, `impl/goose`, `impl/jai`) are checked against LLVM 23.1.5
by one shared harness: IR must match exactly up to instruction selection, and compiled programs must behave identically.

- [AGENTS.md](AGENTS.md): how to work in this repo
- [docs/plan.md](docs/plan.md): goals and decisions
- [docs/roadmap.md](docs/roadmap.md): units of work, with test-based exit criteria
- [docs/testing.md](docs/testing.md): the harness and the test format

```bash
./harness/run status                       # scoreboard
./harness/run check --impl rust --unit L0.print-basic
```
