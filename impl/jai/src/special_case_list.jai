// SpecialCaseList and GlobPattern: ports of llvm/lib/Support/SpecialCaseList.cpp and llvm/lib/Support/GlobPattern.cpp
// (the -dfsan-abilist, -sanitizer-coverage-allowlist / -ignorelist and sanitizer ignore-list files).
//
// GlobMatcher's RadixTrees (prefix/suffix and substring trees) are only a filter in front of GlobPattern::match:
// the result is the highest-index glob that matches, so it is computed here by matching every glob.
// RegexMatcher (`#!special-case-list-v1` files) uses llvm::Regex: only patterns without regex metacharacters
// (after `*` became `.*`) are supported; anything else fails loudly.
// SlashAgnostic is only set on Windows hosts (sys::path::Style::native), so it is always false here.

Glob_Bracket :: struct { next_offset: s64; bytes: [4] u64; }
Glob_Sub :: struct { pat: string; brackets: [..] Glob_Bracket; }
Glob_Pattern :: struct {
    pattern: string;
    prefix_size: s64;
    suffix_size: s64;
    subs: [..] Glob_Sub;
}

glob_bv_get :: inline (bv: [4] u64, c: u8) -> bool { return (bv[c >> 6] >> (c & 63)) & 1 != 0; }
glob_bv_set :: inline (bv: *[4] u64, c: u8) { bv.*[c >> 6] |= (cast(u64) 1) << (c & 63); }

// expand: character ranges to a bitmap ("" = ok, else the error)
glob_expand :: (s_in: string, original: string) -> ([4] u64, string) {
    bv: [4] u64;
    s := s_in;
    while true {
        if s.count < 3 break;
        start := s[0]; end := s[2];
        if s[1] != #char "-" { glob_bv_set(*bv, start); s = advance(s, 1); continue; }
        if start > end return bv, tconcat("invalid glob pattern: ", original);
        c := cast(s64) start;
        while c <= cast(s64) end { glob_bv_set(*bv, cast(u8) c); c += 1; }
        s = advance(s, 3);
    }
    for c: cast([] u8) s glob_bv_set(*bv, c);
    return bv, "";
}

glob_find_first_of :: (s: string, chars: string, from: s64 = 0) -> s64 {
    for i: from..s.count - 1 for c: cast([] u8) chars if s[i] == c return i;
    return -1;
}
glob_find_last_of :: (s: string, chars: string) -> s64 {
    for < i: 0..s.count - 1 for c: cast([] u8) chars if s[i] == c return i;
    return -1;
}
glob_find_char :: (s: string, c: u8, from: s64) -> s64 {
    for i: from..s.count - 1 if s[i] == c return i;
    return -1;
}

// parseBraceExpansions(S, MaxSubPatterns)
glob_parse_brace_expansions :: (s: string, max_sub_patterns: s64) -> ([..] string, string) {
    subs: [..] string;
    array_add(*subs, s);
    if max_sub_patterns < 0 || glob_find_char(s, #char "{", 0) < 0 return subs, "";
    Brace :: struct { start: s64; length: s64; terms: [..] string; }
    bes: [..] Brace; bes.allocator = temp;
    cur := -1;
    term_begin := 0;
    i := 0;
    while i < s.count {
        c := s[i];
        if c == #char "[" {
            i = glob_find_char(s, #char "]", i + 2);
            if i < 0 return subs, "invalid glob pattern, unmatched '['";
        } else if c == #char "{" {
            if cur >= 0 return subs, "nested brace expansions are not supported";
            b: Brace; b.start = i; b.terms.allocator = temp;
            array_add(*bes, b);
            cur = bes.count - 1;
            term_begin = i + 1;
        } else if c == #char "," {
            if cur >= 0 { array_add(*bes[cur].terms, slice(s, term_begin, i - term_begin)); term_begin = i + 1; }
        } else if c == #char "}" {
            if cur >= 0 {
                if bes[cur].terms.count == 0 return subs, "empty or singleton brace expansions are not supported";
                array_add(*bes[cur].terms, slice(s, term_begin, i - term_begin));
                bes[cur].length = i - bes[cur].start + 1;
                cur = -1;
            }
        } else if c == #char "\\" {
            i += 1;
            if i == s.count return subs, "invalid glob pattern, stray '\\'";
        }
        i += 1;
    }
    if cur >= 0 return subs, "incomplete brace expansion";
    n: u64 = 1;
    for b: bes {
        if n > 0xFFFF_FFFF_FFFF_FFFF / cast(u64) b.terms.count { n = 0xFFFF_FFFF_FFFF_FFFF; break; }
        n *= cast(u64) b.terms.count;
    }
    if n > cast(u64) max_sub_patterns return subs, "too many brace expansions";
    for < bi: 0..bes.count - 1 {
        b := bes[bi];
        orig := subs;
        empty: [..] string;
        subs = empty;
        for term: b.terms for o: orig {
            // std::string(Orig).replace(Start, Length, Term)
            array_add(*subs, sprint("%1%2%3", slice(o, 0, b.start), term, slice(o, b.start + b.length, o.count - b.start - b.length)));
        }
    }
    return subs, "";
}

// SubGlobPattern::create
glob_sub_create :: (s: string) -> (Glob_Sub, string) {
    p: Glob_Sub;
    p.pat = copy_string(s);
    i := 0;
    while i < s.count {
        if s[i] == #char "[" {
            i += 1;
            j := glob_find_char(s, #char "]", i + 1);
            if j < 0 return p, "invalid glob pattern, unmatched '['";
            chars := slice(s, i, j - i);
            invert := s[i] == #char "^" || s[i] == #char "!";
            if invert chars = advance(chars, 1);
            bv, err := glob_expand(chars, s);
            if err.count return p, err;
            if invert for k: 0..3 bv[k] = ~bv[k];
            array_add(*p.brackets, .{j + 1, bv});
            i = j;
        } else if s[i] == #char "\\" {
            i += 1;
            if i == s.count return p, "invalid glob pattern, stray '\\'";
        }
        i += 1;
    }
    return p, "";
}

// GlobPattern::create(S, MaxSubPatterns) (-1 = no brace expansion), SlashAgnostic = false
glob_pattern_create :: (s_in: string, max_sub_patterns: s64) -> (Glob_Pattern, string) {
    pat: Glob_Pattern;
    pat.pattern = copy_string(s_in);
    s := pat.pattern;
    pat.prefix_size = glob_find_first_of(s, "?*[{\\");
    if pat.prefix_size < 0 { pat.prefix_size = s.count; return pat, ""; }
    s = advance(s, pat.prefix_size);
    suffix_start := glob_find_last_of(s, "?*[]{}\\");
    assert(suffix_start >= 0);
    if s[suffix_start] == #char "\\" suffix_start += 1;
    if suffix_start < s.count suffix_start += 1;
    pat.suffix_size = s.count - suffix_start;
    s = slice(s, 0, suffix_start);
    subs, err := glob_parse_brace_expansions(s, max_sub_patterns);
    if err.count return pat, err;
    for sp: subs {
        g, e := glob_sub_create(sp);
        if e.count return pat, e;
        array_add(*pat.subs, g);
    }
    return pat, "";
}

glob_prefix :: (p: *Glob_Pattern) -> string { return slice(p.pattern, 0, p.prefix_size); }
glob_suffix :: (p: *Glob_Pattern) -> string { return slice(p.pattern, p.pattern.count - p.suffix_size, p.suffix_size); }

// GlobPattern::match
glob_pattern_match :: (p: *Glob_Pattern, s_in: string) -> bool {
    s := s_in;
    pre := glob_prefix(p);
    if !begins_with(s, pre) return false;
    s = advance(s, pre.count);
    suf := glob_suffix(p);
    if !ends_with(s, suf) return false;
    s.count -= suf.count;
    if p.subs.count == 0 && s.count == 0 return true;
    for *g: p.subs if glob_sub_match(g, s) return true;
    return false;
}

// SubGlobPattern::match
glob_sub_match :: (g: *Glob_Sub, str: string) -> bool {
    pat := g.pat;
    p := 0; segment_begin := -1; s := 0; saved_s := 0;
    b := 0; saved_b := 0;
    while s != str.count {
        matched := false;
        if p == pat.count {
        } else if pat[p] == #char "*" {
            p += 1;
            segment_begin = p;
            saved_s = s;
            saved_b = b;
            continue;
        } else if pat[p] == #char "[" {
            if glob_bv_get(g.brackets[b].bytes, str[s]) {
                p = g.brackets[b].next_offset;
                b += 1;
                s += 1;
                continue;
            }
        } else if pat[p] == #char "\\" {
            p += 1;
            if pat[p] == str[s] { p += 1; s += 1; continue; }
        } else if pat[p] == str[s] || pat[p] == #char "?" {
            p += 1; s += 1;
            continue;
        }
        if segment_begin < 0 return false;
        p = segment_begin;
        saved_s += 1;
        s = saved_s;
        b = saved_b;
    }
    for i: p..pat.count - 1 if pat[i] != #char "*" return false;
    return true;
}

// ---------------------------------------------------------------- SpecialCaseList

Scl_Rule :: struct { name: string; line: u32; glob: Glob_Pattern; }
Scl_Matcher :: struct {
    use_globs := true;
    remove_dot_slash: bool;
    warn_dot_slash: bool;
    warned: bool;
    rules: [..] Scl_Rule;   // globs, or (v1) regexes as literal strings with `.*`
}
Scl_Entry :: struct { prefix: string; category: string; m: Scl_Matcher; }
Scl_Section :: struct { name: string; file_idx: u32; m: Scl_Matcher; entries: [..] Scl_Entry; }
Special_Case_List :: struct { sections: [..] Scl_Section; }

// Matcher::insert ("" = ok)
scl_matcher_insert :: (m: *Scl_Matcher, pattern: string, line: u32) -> string {
    r: Scl_Rule; r.name = copy_string(pattern); r.line = line;
    if m.use_globs {
        if pattern.count == 0 return "Supplied glob was blank";
        g, err := glob_pattern_create(pattern, 1024);
        if err.count return err;
        r.glob = g;
    } else {
        if pattern.count == 0 return "Supplied regex was blank";
        // RegexMatcher: `*` -> `.*`, anchored; only literal patterns are supported (no llvm::Regex port)
        for c: cast([] u8) pattern {
            if c == #char "." || c == #char "^" || c == #char "$" || c == #char "|" || c == #char "(" || c == #char ")" ||
               c == #char "[" || c == #char "]" || c == #char "{" || c == #char "}" || c == #char "+" || c == #char "?" || c == #char "\\"
                fatal("special case list: the regex '%' (a #!special-case-list-v1 file) needs llvm::Regex, which is not ported", pattern);
        }
    }
    array_add(*m.rules, r);
    return "";
}

// RegexMatcher on a literal-with-`.*` pattern: `*` matches any string
scl_literal_star_match :: (pat: string, s: string) -> bool {
    g: Glob_Sub; g.pat = pat;   // no brackets, no escapes, no '?': GlobPattern semantics are the same
    for c: cast([] u8) pat if c == #char "?" return false;
    return glob_sub_match(*g, s);
}

// Matcher::matchInternal: the line of the last matching rule, 0 = none
scl_matcher_match_internal :: (m: *Scl_Matcher, q: string) -> u32 {
    if m.use_globs {
        // GlobMatcher::match: the highest-index matching glob
        for < *r: m.rules if glob_pattern_match(*r.glob, q) return r.line;
        return 0;
    }
    for < *r: m.rules if scl_literal_star_match(r.name, q) return r.line;
    return 0;
}

// sys::path::remove_leading_dotslash (posix)
remove_leading_dotslash :: (p_in: string) -> string {
    p := p_in;
    while p.count > 2 && p[0] == #char "." && p[1] == #char "/" {
        p = advance(p, 2);
        while p.count > 0 && p[0] == #char "/" p = advance(p, 1);
    }
    return p;
}

// Matcher::match
scl_matcher_match :: (m: *Scl_Matcher, q: string) -> u32 {
    if !m.remove_dot_slash return scl_matcher_match_internal(m, q);
    if !m.warn_dot_slash return scl_matcher_match_internal(m, remove_leading_dotslash(q));
    fixed := remove_leading_dotslash(q);
    fixed_matched := scl_matcher_match_internal(m, fixed);
    if fixed == q return fixed_matched;
    orig := scl_matcher_match_internal(m, q);
    if orig > fixed_matched {
        if !m.warned {
            m.warned = true;
            rule := "";
            for m.rules if it.line == orig { rule = it.name; break; }
            print_to_stderr("warning: Deprecated behaviour: pattern '%' matches '%', update it to match '%' instead (further warnings suppressed).\n", rule, q, fixed);
        }
    }
    return ifx orig > fixed_matched then orig else fixed_matched;
}

// SpecialCaseList::addSection ("" = ok)
scl_add_section :: (l: *Special_Case_List, s: string, file_idx: u32, line: u32, use_globs: bool) -> string {
    sec: Scl_Section;
    sec.name = copy_string(s);
    sec.file_idx = file_idx;
    sec.m.use_globs = use_globs;
    err := scl_matcher_insert(*sec.m, sec.name, line);
    array_add(*l.sections, sec);
    if err.count return tprint("malformed section at line %: '%': %", line, s, err);
    return "";
}

// SpecialCaseList::parse ("" = ok)
scl_parse :: (l: *Special_Case_List, file_idx: u32, buf: string) -> string {
    version: u64 = 2;
    header := buf;
    if begins_with(header, "#!special-case-list-v") {
        header = advance(header, 21);
        // consumeUnsignedInteger(Header, 10, Version): leaves Version alone when there are no digits
        if header.count && header[0] >= #char "0" && header[0] <= #char "9" {
            v: u64 = 0;
            while header.count && header[0] >= #char "0" && header[0] <= #char "9" { v = v * 10 + cast(u64)(header[0] - #char "0"); header = advance(header, 1); }
            version = v;
        }
    }
    use_globs := version >= 2;
    remove_dot_slash := version >= 3;
    warn_dot_slash := version >= 4 && !(version >= 5);
    err := scl_add_section(l, "*", file_idx, 1, true);
    if err.count return err;
    cur := l.sections.count - 1;
    // line_iterator(MB, SkipBlanks = true, CommentMarker = '#')
    line_no: u32 = 0;
    pos := 0;
    while pos < buf.count {
        e := pos;
        while e < buf.count && buf[e] != #char "\n" e += 1;
        raw := slice(buf, pos, e - pos);
        pos = e + 1;
        line_no += 1;
        if raw.count && raw[raw.count - 1] == #char "\r" raw.count -= 1;
        if raw.count == 0 continue;                       // blank
        if raw[0] == #char "#" continue;                  // comment
        line := trim(raw);
        if line.count == 0 continue;
        if line[0] == #char "[" {
            if line[line.count - 1] != #char "]" return tprint("malformed section header on line %: %", line_no, line);
            err = scl_add_section(l, slice(line, 1, line.count - 2), file_idx, line_no, use_globs);
            if err.count return err;
            cur = l.sections.count - 1;
            continue;
        }
        colon := find_index_from_left(line, #char ":");
        prefix := line; postfix := "";
        if colon >= 0 { prefix = slice(line, 0, colon); postfix = advance(line, colon + 1); }
        if postfix.count == 0 return tprint("malformed line %: '%'", line_no, line);
        is_path := prefix == "src" || prefix == "!src" || prefix == "mainfile" || prefix == "source";
        eq := find_index_from_left(postfix, #char "=");
        pattern := postfix; category := "";
        if eq >= 0 { pattern = slice(postfix, 0, eq); category = advance(postfix, eq + 1); }
        sec := *l.sections[cur];
        ent: *Scl_Entry = null;
        for *sec.entries if it.prefix == prefix && it.category == category { ent = it; break; }
        if !ent {
            ne: Scl_Entry;
            ne.prefix = copy_string(prefix); ne.category = copy_string(category);
            ne.m.use_globs = use_globs;
            if is_path { ne.m.remove_dot_slash = remove_dot_slash; ne.m.warn_dot_slash = warn_dot_slash; }
            array_add(*sec.entries, ne);
            ent = *sec.entries[sec.entries.count - 1];
        }
        err = scl_matcher_insert(*ent.m, pattern, line_no);
        if err.count return tprint("malformed % in line %: '%': %", ifx use_globs then "glob" else "regex", line_no, pattern, err);
    }
    return "";
}

// SpecialCaseList::createOrDie(Paths, RealFileSystem)
scl_create_or_die :: (paths: [] string) -> *Special_Case_List {
    l := New(Special_Case_List);
    for path, i: paths {
        text, ok := read_entire_file(path, log_errors = false);
        if !ok fatal("can't open file '%': No such file or directory", path);
        err := scl_parse(l, cast(u32) i, text);
        if err.count fatal("error parsing file '%': %", path, err);
    }
    return l;
}

// SpecialCaseList::inSection(Section, Prefix, Query, Category)
scl_in_section :: (l: *Special_Case_List, section: string, prefix: string, query: string, category := "") -> bool {
    for < *s: l.sections {
        if scl_matcher_match(*s.m, section) == 0 continue;
        for *e: s.entries {
            if e.prefix != prefix || e.category != category continue;
            if scl_matcher_match(*e.m, query) return true;
            break;
        }
    }
    return false;
}
