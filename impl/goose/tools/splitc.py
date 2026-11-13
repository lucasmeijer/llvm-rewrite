#!/usr/bin/env python3
"""Split the one C file `goose -o prog.c` writes into N translation units that compile in parallel.

Usage: splitc.py prog.c outdir N   -> writes outdir/part-<k>.c for k in 0..N-1, prints their paths.

clang -O2 on opt's single 64 MB translation unit takes ~4 minutes on one core; split, the parts compile in
parallel (NOTES.md "Build"). The generated C has a fixed layout (goose v2026.4 codegen):

    runtime header, types, data          (statics: the data stacks, the globals struct, string constants)
    /* ---- prototypes ---- */           one `static ...;` line per program function
    /* ---- code ---- */                 one top-level function definition after another, then `int main`

Every part gets the whole prelude and every `GS_INLINE` (always_inline) definition, and its own share of the other
definitions. Program functions that have a prototype lose `static` (they become hidden external symbols, so a part
can call a function another part defines), and the five mutable statics of the prelude (data stack table, globals
pointer, the globals struct, the init flag) are defined in part 0 and declared `extern` in the others. Anything that
doesn't fit this layout makes the script exit 3, and build.sh falls back to compiling the file whole.
"""
import os
import re
import sys

PROTO = "/* ---- prototypes ---- */"
CODE = "/* ---- code ---- */"
FN_START = re.compile(r"^static (?:GS_INLINE |GS_NOINLINE )?[^=;{]*?\b([A-Za-z_][A-Za-z_0-9]*)\(")
MUTABLE_STATIC = re.compile(r"^static ((?:GS_TLS )?[A-Za-z_][A-Za-z_0-9]* \**[A-Za-z_][A-Za-z_0-9]*;)$")


def fail(msg):
    sys.stderr.write(f"splitc: {msg}\n")
    sys.exit(3)


TOKEN = re.compile(r'//[^\n]*|/\*.*?\*/|"(?:\\.|[^"\\\n])*"|\'(?:\\.|[^\'\\\n])*\'|^[ \t]*#(?:[^\n]*\\\n)*[^\n]*|[{};]',
                   re.M | re.S)
CONST_DATA = re.compile(r"^static (?:GS_ALIGN\w* )?const [A-Za-z_][A-Za-z_0-9 ]* [A-Za-z_][A-Za-z_0-9]*(?:\[[0-9]*\])*\s*(?:=|$)")
FN_DECL = re.compile(r"^static [^=(]*\b[A-Za-z_][A-Za-z_0-9]*\s*\((?!\*)")


def file_scope_statics(text):
    """Every file-scope declaration in `text` that starts with `static` and isn't a function or const data:
    the mutable state. Found with a real (if small) tokenizer, independently of the line-based rewrite below,
    so that a static the rewrite misses (indented, multi-line, initialized) fails the split instead of being
    silently duplicated into every part."""
    found = []
    depth, start = 0, 0
    for m in TOKEN.finditer(text):
        t = m.group(0)
        if t not in ("{", "}", ";"):
            if depth == 0 and (t.startswith("#") or t.lstrip().startswith("#")):
                start = m.end()   # a preprocessor line ends the statement before it
            continue
        if depth == 0 and t in (";", "{"):
            stmt = re.sub(r"/\*.*?\*/|//[^\n]*", " ", text[start:m.start()], flags=re.S)
            stmt = " ".join(stmt.split())
            if stmt.startswith("static ") and not FN_DECL.match(stmt) and not CONST_DATA.match(stmt):
                found.append(stmt)
        if t == "{":
            depth += 1
        elif t == "}":
            depth -= 1
            if depth < 0:
                fail("unbalanced braces in the prelude")
        if depth == 0:
            start = m.end()
    return found


def main():
    src, outdir, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
    with open(src, encoding="utf-8", errors="surrogateescape") as f:
        lines = f.read().split("\n")
    try:
        p = lines.index(PROTO)
        c = lines.index(CODE)
    except ValueError:
        fail("section markers not found")
    if lines.count(PROTO) != 1 or lines.count(CODE) != 1 or not p < c:
        fail("unexpected section markers")

    # Prelude: rewrite the mutable top-level statics; everything else (types, const data, runtime static
    # functions) is copied into every part as it is.
    prelude = []
    nmut = 0
    for ln in lines[:p]:
        if ln.startswith("static ") and "const " not in ln and "(" not in ln:
            m = MUTABLE_STATIC.match(ln)
            if not m:
                fail(f"unexpected top-level static: {ln[:120]}")
            prelude.append("GS_SPLIT_DEF " + m.group(1))
            nmut += 1
        elif ln.startswith("static ") and "(*" in ln and ln.index("(") == ln.index("(*"):
            fail(f"top-level static function pointer: {ln[:120]}")
        else:
            prelude.append(ln)
    if nmut == 0:
        fail("no mutable statics found (layout changed?)")
    statics = file_scope_statics("\n".join(lines[:p]))
    if len(statics) != nmut:
        fail(f"found {len(statics)} mutable file-scope statics but rewrote {nmut}: {statics[:5]}")

    # Prototypes: one per line. GS_INLINE ones stay static (every part defines them); the rest become external.
    protos = []
    external = set()
    for ln in lines[p + 1:c]:
        if not ln or ln.startswith("/*"):
            protos.append(ln)
            continue
        m = FN_START.match(ln)
        if not m or not ln.endswith(");"):
            fail(f"unexpected prototype line: {ln[:120]}")
        if ln.startswith("static GS_INLINE "):
            protos.append(ln)
        else:
            external.add(m.group(1))
            protos.append("GS_SPLIT_FN " + ln[len("static "):])

    # Code: split into top-level definitions. Bodies are indented, so a definition starts at a line beginning
    # with `static ` or `int main(` and runs to the next one.
    items = []  # (name, kind, text) with kind "inline" | "ext" | "local"
    cur = None
    for ln in lines[c + 1:]:
        if ln.startswith("static ") or ln.startswith("int main("):
            if cur is not None:
                items.append(cur)
            if ln.startswith("int main("):
                cur = ["main", "local", [ln]]
                continue
            m = FN_START.match(ln)
            if not m or not ln.endswith("{"):
                fail(f"unexpected top-level line in code: {ln[:120]}")
            name = m.group(1)
            if ln.startswith("static GS_INLINE "):
                cur = [name, "inline", [ln]]
            elif name in external:
                cur = [name, "ext", ["GS_SPLIT_FN " + ln[len("static "):]]]
            else:
                cur = [name, "local", [ln]]
        elif cur is None:
            if ln.strip():
                fail(f"code before the first definition: {ln[:120]}")
        else:
            if ln and not ln[0].isspace() and ln != "}" and not ln.startswith("#") and not ln.startswith("/*"):
                fail(f"unexpected column-0 line inside a definition: {ln[:120]}")
            cur[2].append(ln)
    if cur is not None:
        items.append(cur)
    for name, kind, text in items:
        if kind == "inline" and any(x.lstrip().startswith("static ") for x in text[1:]):
            fail(f"GS_INLINE function {name} has a local static (every part would get its own copy)")
    if not items or items[-1][0] != "main":
        fail("main is not the last definition")

    inline_text = "\n".join("\n".join(t) for _, k, t in items if k == "inline")
    # Functions without a prototype (gs_init_globals, gs_program_init, main) stay static, all in part 0.
    local = [i for i in items if i[1] == "local"]
    ext = [i for i in items if i[1] == "ext"]
    total = sum(len(x) + 1 for _, _, t in ext for x in t)
    # Part 0 also holds the locals; give it a smaller share of the rest. Contiguous ranges keep each module's
    # functions together, so clang still inlines within a module.
    parts = [[] for _ in range(n)]
    local_size = sum(len(x) + 1 for _, _, t in local for x in t)
    target = (total + local_size) / n
    k, acc = 0, local_size
    for it in ext:
        sz = sum(len(x) + 1 for x in it[2])
        if acc >= target * (k + 1) and k < n - 1:
            k += 1
        parts[k].append(it)
        acc += sz

    os.makedirs(outdir, exist_ok=True)
    head = "\n".join(prelude)
    proto_text = "\n".join(protos)
    paths = []
    for k in range(n):
        defs = (
            "#define GS_SPLIT_FN __attribute__((visibility(\"hidden\")))\n"
            + ("#define GS_SPLIT_DEF\n" if k == 0 else "#define GS_SPLIT_DEF extern\n")
        )
        body = [defs, head, PROTO, proto_text, CODE, inline_text]
        if k == 0:
            body += ["\n".join(t) for _, _, t in local]
        body += ["\n".join(t) for _, _, t in parts[k]]
        path = os.path.join(outdir, f"part-{k}.c")
        text = "\n".join(body) + "\n"
        old = None
        if os.path.exists(path):
            with open(path, encoding="utf-8", errors="surrogateescape") as f:
                old = f.read()
        if old != text:
            with open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
                f.write(text)
        paths.append(path)
    print("\n".join(paths))


if __name__ == "__main__":
    main()
