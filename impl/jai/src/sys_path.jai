// sys::path: a port of the part of llvm/lib/Support/Path.cpp the passes use (root_name/root_path, filename,
// remove_filename, append, native, remove_dots), for the two styles posix (`win` = false) and windows_backslash.
// No `native` style: callers pick the style explicitly.

sp_is_sep :: inline (c: u8, win: bool) -> bool { return c == #char "/" || (win && c == #char "\\"); }
sp_preferred_sep :: inline (win: bool) -> u8 { return ifx win then cast(u8) #char "\\" else #char "/"; }
// find_first_of(separators(style), from)
sp_find_sep :: (s: string, from: s64, win: bool) -> s64 {
    for i: from..s.count - 1 if sp_is_sep(s[i], win) return i;
    return -1;
}

// find_first_component
sp_first_component :: (path: string, win: bool) -> string {
    if path.count == 0 return path;
    if win && path.count >= 2 && is_alpha(path[0]) && path[1] == #char ":" return slice(path, 0, 2);
    if path.count > 2 && sp_is_sep(path[0], win) && path[0] == path[1] && !sp_is_sep(path[2], win) {
        e := sp_find_sep(path, 2, win);
        return ifx e < 0 then path else slice(path, 0, e);
    }
    if sp_is_sep(path[0], win) return slice(path, 0, 1);
    e := sp_find_sep(path, 0, win);
    return ifx e < 0 then path else slice(path, 0, e);
}

// filename_pos / root_dir_start / parent_path_end (npos = -1)
sp_filename_pos :: (s: string, win: bool) -> s64 {
    if s.count > 0 && sp_is_sep(s[s.count - 1], win) return s.count - 1;
    pos := -1;
    i := s.count - 1;
    while i >= 0 { if sp_is_sep(s[i], win) { pos = i; break; } i -= 1; }
    if win && pos < 0 {
        i = s.count - 1;
        while i >= 0 { if s[i] == #char ":" { pos = i; break; } i -= 1; }
    }
    if pos < 0 || (pos == 1 && sp_is_sep(s[0], win)) return 0;
    return pos + 1;
}
sp_root_dir_start :: (s: string, win: bool) -> s64 {
    if win && s.count > 2 && s[1] == #char ":" && sp_is_sep(s[2], win) return 2;
    if s.count > 3 && sp_is_sep(s[0], win) && s[0] == s[1] && !sp_is_sep(s[2], win) return sp_find_sep(s, 2, win);
    if s.count > 0 && sp_is_sep(s[0], win) return 0;
    return -1;
}
sp_parent_path_end :: (path: string, win: bool) -> s64 {
    end_pos := sp_filename_pos(path, win);
    filename_was_sep := path.count > 0 && sp_is_sep(path[end_pos], win);
    root := sp_root_dir_start(path, win);
    while end_pos > 0 && (root < 0 || end_pos > root) && sp_is_sep(path[end_pos - 1], win) end_pos -= 1;
    if end_pos == root && !filename_was_sep return root + 1;
    return end_pos;
}

// root_name / has_root_name / root_path
sp_root_name :: (path: string, win: bool) -> string {
    if path.count == 0 return "";
    b := sp_first_component(path, win);
    has_net := b.count > 2 && sp_is_sep(b[0], win) && b[1] == b[0];
    has_drive := win && ends_with(b, ":");
    if has_net || has_drive return b;
    return "";
}
sp_has_root_name :: (path: string, win: bool) -> bool { return sp_root_name(path, win).count > 0; }
sp_root_path :: (path: string, win: bool) -> string {
    if path.count == 0 return "";
    b := sp_first_component(path, win);
    has_net := b.count > 2 && sp_is_sep(b[0], win) && b[1] == b[0];
    has_drive := win && ends_with(b, ":");
    if has_net || has_drive {
        // the next component is the single separator after {C:,//net} when there is one
        if b.count < path.count && sp_is_sep(path[b.count], win) return slice(path, 0, b.count + 1);
        return b;
    }
    if sp_is_sep(b[0], win) return b;
    return "";
}

// filename: *rbegin(path)
sp_filename :: (path: string, win: bool) -> string {
    root := sp_root_dir_start(path, win);
    end_pos := path.count;
    while end_pos > 0 && (end_pos - 1) != root && sp_is_sep(path[end_pos - 1], win) end_pos -= 1;
    if path.count > 0 && sp_is_sep(path[path.count - 1], win) && (root < 0 || end_pos - 1 > root) return ".";
    start := sp_filename_pos(slice(path, 0, end_pos), win);
    return slice(path, start, end_pos - start);
}

// remove_filename
sp_remove_filename :: (path: string, win: bool) -> string {
    e := sp_parent_path_end(path, win);
    if e < 0 return path;
    return slice(path, 0, e);
}

// append(path, style, component)
sp_append :: (path: string, comp: string, win: bool) -> string {
    if path.count > 0 && sp_is_sep(path[path.count - 1], win) {
        loc := 0;
        while loc < comp.count && sp_is_sep(comp[loc], win) loc += 1;
        return tconcat(path, slice(comp, loc, comp.count - loc));
    }
    comp_has_sep := comp.count > 0 && sp_is_sep(comp[0], win);
    if !comp_has_sep && !(path.count == 0 || sp_has_root_name(comp, win)) {
        sep: [1] u8; sep[0] = sp_preferred_sep(win);
        return tconcat(path, string.{1, sep.data}, comp);
    }
    return tconcat(path, comp);
}

// native(path, style)
sp_native :: (path: string, win: bool) -> string {
    if path.count == 0 return path;
    r := copy_string(path,, temp);
    if win {
        for i: 0..r.count - 1 if sp_is_sep(r[i], true) r[i] = #char "\\";
        if r[0] == #char "~" && (r.count == 1 || sp_is_sep(r[1], true)) fatal("sys::path::native: expanding '~' (the home directory) is not supported");
    } else {
        for i: 0..r.count - 1 if r[i] == #char "\\" r[i] = #char "/";
    }
    return r;
}

// remove_dots(path, remove_dot_dot, style): the new path (or the old one when nothing changes)
sp_remove_dots :: (path: string, remove_dot_dot: bool, win: bool) -> string {
    remaining := path;
    needs_change := false;
    comps: [..] string; comps.allocator = temp;
    root := sp_root_path(remaining, win);
    absolute := root.count > 0;
    if absolute remaining = slice(remaining, root.count, remaining.count - root.count);
    pref := sp_preferred_sep(win);
    while remaining.count {
        ns := sp_find_sep(remaining, 0, win);
        if ns < 0 ns = remaining.count;
        comp := slice(remaining, 0, ns);
        remaining = slice(remaining, ns, remaining.count - ns);
        if remaining.count {
            needs_change |= remaining[0] != pref;
            remaining = slice(remaining, 1, remaining.count - 1);
            needs_change |= remaining.count == 0;
        }
        if comp.count == 0 || comp == "." needs_change = true;
        else if remove_dot_dot && comp == ".." {
            needs_change = true;
            if comps.count && comps[comps.count - 1] != ".." comps.count -= 1;
            else if !absolute array_add(*comps, comp);
        } else array_add(*comps, comp);
    }
    buffer := ifx win then sp_native(root, true) else root;   // make_preferred
    needs_change |= root != buffer;
    if !needs_change return path;
    sb: String_Builder; sb.allocator = temp;
    append(*sb, buffer);
    for comps {
        if it_index > 0 append(*sb, pref);
        append(*sb, it);
    }
    return builder_to_string(*sb,, temp);
}
