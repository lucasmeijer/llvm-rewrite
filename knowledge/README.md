# Knowledge

Verified facts about LLVM 23.1.5's behaviour that any implementation needs. One file per topic in `llvm/`.

- Read the topic files for your area before starting work there.
- Curate, don't just append: correct or delete claims that turn out wrong, merge duplicates, keep files short.
- State how you verified each fact: a test ID, an LLVM source file and line, or a command you ran.
- Facts about one implementation go in `impl/<lang>/NOTES.md` instead.
- When a topic has settled into a procedure, promote it into a skill in `.agents/skills/`.

Topics so far:

- [llvm/tools-and-flags.md](llvm/tools-and-flags.md): behaviour of opt/llc/clang flags the harness relies on
- [llvm/clang-ir-generation.md](llvm/clang-ir-generation.md): how the corpus IR is produced, and why
