# impl/goose notes

- Goose is [aardappel/goose](https://github.com/aardappel/goose), installed at `/opt/goose-v2026.4` (`goose` on PATH).
  It's a very new language, so you have almost no prior knowledge of it. Read the docs before writing code:
  `/opt/goose-v2026.4/docs/` has `tutorial.md`, `reference.md`, `goose_spec.md`, `stdlib.md`,
  `command_line.md`, and "Goose for C++ and Rust Programmers Translating Common Patterns.md". There are also
  31 programs in `/opt/goose-v2026.4/samples/`.
- Goose's memory model shapes the design: there's no heap, no allocator, no GC. All dynamic data lives on
  compiler-managed data stacks, with at most one growable value on top of each stack, freed at scope exit.
  Recursive functions can't keep growable data across a recursive call. An IR whose functions, blocks and
  instructions grow and change during optimization has to be designed around this (pools, `slot_pool`,
  `slice_pool`, relative references), and that's the core question for this implementation's `DESIGN.md`.
- `build.sh` runs `goose build --cc /opt/llvm-23.1.5/bin/clang -o bin/<tool> src/<tool>.goose`. Build products live
  under `~/.goose` (`GOOSE_HOME`). `goose build --debug` turns on overflow, range and tag checks. Use it when
  chasing a crash.
- The binaries are placeholders that exit with "not implemented yet". Unit `L0.design` (writing `DESIGN.md`) comes first.
