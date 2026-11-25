// GCOVProfiling ("insert-gcov-profiling"): a port of llvm/lib/Transforms/Instrumentation/GCOVProfiling.cpp
// (GCOVOptions::getDefault, GCOVProfiler, GCOVFunction / GCOVBlock / GCOVLines and the .gcno writer, the counters,
// insertCounterWriteout, insertReset, emitGlobalConstructor) with the CFGMST of pass_pgo_instr_gen.jai. The pass writes
// <cu>.gcno files into the current directory (or where an !llvm.gcov node says). Not ported (fail loudly): the
// XCOFF variant (emitModuleInitFunctionPtrs), notes files named "-" (raw_fd_ostream's stdout). The Filter/Exclude
// regexes are only settable through clang's GCOVOptions, so opt always runs with both empty.

gcov_cl: struct {
    default_version := "0000";   // -default-gcov-version
    atomic_counter: bool;        // -gcov-atomic-counter
};

gcov_parse_cl_opt :: (name: string, value: string, has_value: bool) -> bool {
    if name == {
        case "default-gcov-version";
            if !has_value fatal("opt: for the --% option: requires a value!", name);
            gcov_cl.default_version = copy_string(value);
        case "gcov-atomic-counter";
            if !has_value || value == "true" || value == "1" gcov_cl.atomic_counter = true;
            else if value == "false" || value == "0" gcov_cl.atomic_counter = false;
            else fatal("opt: for the --% option: '%' is invalid value for boolean argument! Try 0 or 1", name, value);
        case; return false;
    }
    return true;
}

gcov_exec_blocks: [..] Value_Id;   // ExecBlocks

// GCOVProfilerPass::run
gcov_run :: () -> Preserved {
    // GCOVOptions::getDefault
    if gcov_cl.default_version.count != 4 {   // reportFatalUsageError
        write_string(tprint("LLVM ERROR: Invalid -default-gcov-version: %\n", gcov_cl.default_version), to_standard_error = true);
        exit(1);
    }
    // GCOVProfiler::runOnModule
    cu_node := named_md_find("llvm.dbg.cu");
    if cu_node < 0 return PRESERVE_ALL;   // (EmitNotes and EmitData are always on by default)
    gcov_exec_blocks.count = 0;
    has_exec_or_fork := gcov_add_flush_before_fork_and_exec();
    // createRegexesFromString(Options.Filter / Exclude): both empty by default
    gcov_emit_profile_notes(cu_node, has_exec_or_fork);
    printer_note_ir_changed();
    return PRESERVE_NONE;
}

// AddFlushBeforeForkAndExec
gcov_add_flush_before_fork_and_exec :: () -> bool {
    t: *Tli = null;
    forks: [..] Value_Id; forks.allocator = temp;
    execs: [..] Value_Id; execs.allocator = temp;
    for f: ir.m_functions {
        if !t t = tli_for(f);
        for i: fn_insts(f) {
            if inst_op(i) != .CALL continue;
            callee := call_called_function(i);
            if callee == NONE continue;
            ok, lf := tli_lookup_fn(callee);
            if !ok continue;
            if lf == .fork array_add(*forks, i);
            else if lf == .execl || lf == .execle || lf == .execlp || lf == .execv || lf == .execvp || lf == .execve ||
                    lf == .execvpe || lf == .execvP array_add(*execs, i);
        }
    }
    for c: forks {
        parent := inst_block(c);
        next := inst_next(c);
        ft := type_func(ir.t_i32, .[], false);
        fork_fn := san_get_or_insert_function("__gcov_fork", ft, msan_tli_attr_list(t, .[], true, true));
        set_op(c, nops(c) - 1, fork_fn);
        inst(c).ty2 = ft;
        split_basic_block(parent, next, "");
        set_metadata(block_terminator(parent), 0, get_metadata(c, 0));
    }
    for e: execs {
        parent := inst_block(e);
        next := inst_next(e);
        ft := type_func(ir.t_void, .[], false);
        b: Irb; irb_set_before(*b, e);
        wf: San_Callee; wf.fty = ft; wf.callee = san_get_or_insert_function("llvm_writeout_files", ft);
        san_call(*b, wf, .[]);
        loc := get_metadata(e, 0);
        irb_set_before(*b, next);
        rf: San_Callee; rf.fty = ft; rf.callee = san_get_or_insert_function("llvm_reset_counters", ft);
        rc := san_call(*b, rf, .[]);
        set_metadata(rc, 0, loc);
        array_add(*gcov_exec_blocks, parent);
        split_basic_block(parent, next, "");
        set_metadata(block_terminator(parent), 0, loc);
    }
    return forks.count > 0 || execs.count > 0;
}


GCOV_ARC_ON_TREE :: 1;
GCOV_TAG_FUNCTION :: 0x01000000;
GCOV_TAG_BLOCKS :: 0x01410000;
GCOV_TAG_ARCS :: 0x01430000;
GCOV_TAG_LINES :: 0x01450000;

// Length + NUL-terminated string + 0~3 padding NULs.
gcov_words_of_string :: (s: string) -> u32 { return cast(u32) (s.count / 4) + 2; }

Gcov_Lines :: struct { filename: string; lines: [..] u32; }
Gcov_Arc :: struct { dst: u32; flags: u32; }   // dst = the successor GCOVBlock's Number
Gcov_Block :: struct {
    number: u32;
    out_edges: [..] Gcov_Arc;
    lines: [..] Gcov_Lines;
}
// GCOVFunction: blocks[0] is EntryBlock (Number 0), blocks[1] ReturnBlock (1), blocks[2..] the function's blocks in
// order (the MapVector Blocks), Number = index.
Gcov_Func :: struct {
    sp: Md_Id;
    end_line: u32;
    ident: u32;
    func_checksum: u32;
    blocks: [..] Gcov_Block;
    block_of: Table(Value_Id, u32);
}

// The profiler's state (GCOVProfiler members that live across compile units)
Gcov :: struct {
    version: s32;
    version_str: [4] u8;
    big_endian: bool;
    out: [..] u8;
    file_checksums: [..] u32;
    funcs: [..] *Gcov_Func;
    exec_blocks: Table(Value_Id, bool);
}

gcov_write :: (g: *Gcov, i: u32) {
    if g.big_endian { for k: 0..3 array_add(*g.out, cast(u8) ((i >> (8 * (3 - k))) & 0xFF)); }
    else for k: 0..3 array_add(*g.out, cast(u8) ((i >> (8 * k)) & 0xFF));
}
gcov_write_string :: (g: *Gcov, s: string) {
    gcov_write(g, gcov_words_of_string(s) - 1);
    for cast([] u8) s array_add(*g.out, it);
    for 1..4 - s.count % 4 array_add(*g.out, 0);
}

gcov_get_function_name :: (sp: Md_Id) -> string {
    ln := md_str_of(di_op(sp, 3));
    if ln.count return ln;
    return md_str_of(di_op(sp, 2));
}

// DIScope::getFilename / getDirectory
gcov_scope_file :: (s: Md_Id) -> Md_Id { if s == NONE return NONE; return discope_file(s); }
gcov_scope_filename :: (s: Md_Id) -> string { f := gcov_scope_file(s); if f == NONE return ""; return md_str_of(di_op(f, 0)); }
gcov_scope_directory :: (s: Md_Id) -> string { f := gcov_scope_file(s); if f == NONE return ""; return md_str_of(di_op(f, 1)); }

// getFilename(const DIScope *SP, VFS): the relative path if it exists, else directory + filename
gcov_get_filename :: (sp: Md_Id) -> string {
    rel := gcov_scope_filename(sp);
    if gcov_fs_exists(rel) return rel;
    return sp_append(sp_append("", gcov_scope_directory(sp), false), rel, false);
}

// ---------------------------------------------------------------- the real file system (vfs::getRealFileSystem)

gcov_libc :: #system_library "libc";
gcov_c_stat :: (path: *u8, buf: *u8) -> s32 #foreign gcov_libc "stat";
gcov_c_getcwd :: (buf: *u8, size: u64) -> *u8 #foreign gcov_libc "getcwd";
gcov_c_getenv :: (name: *u8) -> *u8 #foreign gcov_libc "getenv";
gcov_c_open :: (path: *u8, flags: s32, mode: u32) -> s32 #foreign gcov_libc "open";
gcov_c_write :: (fd: s32, buf: *u8, n: u64) -> s64 #foreign gcov_libc "write";
gcov_c_close :: (fd: s32) -> s32 #foreign gcov_libc "close";
gcov_c_strerror :: (e: s32) -> *u8 #foreign gcov_libc "strerror";
gcov_c_errno :: () -> *s32 #foreign gcov_libc "__errno_location";

// sys::fs::status: (ok, st_dev, st_ino)
gcov_fs_status :: (path: string) -> bool, u64, u64 {
    buf: [256] u8;
    if gcov_c_stat(temp_c_string(path), buf.data) != 0 return false, 0, 0;
    return true, (cast(*u64) buf.data).*, (cast(*u64) (buf.data + 8)).*;
}
// sys::fs::exists (an empty path does not exist)
gcov_fs_exists :: (path: string) -> bool { ok := gcov_fs_status(path); return ok; }

// sys::fs::current_path: $PWD if it is absolute and names the same directory as ".", else getcwd
gcov_current_path :: () -> bool, string {
    pwd := gcov_c_getenv("PWD");
    if pwd {
        p := to_string(pwd);
        if p.count && p[0] == #char "/" {
            ok1, d1, i1 := gcov_fs_status(p);
            ok2, d2, i2 := gcov_fs_status(".");
            if ok1 && ok2 && d1 == d2 && i1 == i2 return true, copy_string(p,, temp);
        }
    }
    buf := NewArray(4096, u8,, temp);
    if !gcov_c_getcwd(buf.data, cast(u64) buf.count) return false, "";
    return true, copy_string(to_string(buf.data),, temp);
}

// ---------------------------------------------------------------- GCOVFunction

gcov_func_create :: (f: Value_Id, sp: Md_Id, end_line: u32, ident: u32) -> *Gcov_Func {
    gf := New(Gcov_Func,, temp);
    gf.sp = sp; gf.end_line = end_line; gf.ident = ident;
    gf.blocks.allocator = temp; gf.block_of.allocator = temp;
    array_add(*gf.blocks, .{number = 0});
    array_add(*gf.blocks, .{number = 1});
    i: u32 = 2;
    for bb: fn_blocks(f) {
        array_add(*gf.blocks, .{number = i});
        table_set(*gf.block_of, bb, i);
        i += 1;
    }
    for * gf.blocks { it.out_edges.allocator = temp; it.lines.allocator = temp; }
    // hash_value(getFunctionName(SP) + SP->getLine()): xxh3 of the bytes ^ the release-build execution seed
    s := tprint("%1%2", gcov_get_function_name(sp), di_int(sp, 0));
    gf.func_checksum = cast,no_check(u32) (xxh3_64bits(cast([] u8) s) ^ 0xff51afd7ed558ccd);
    return gf;
}
gcov_func_block :: (gf: *Gcov_Func, bb: Value_Id) -> *Gcov_Block {
    found, n := table_find(*gf.block_of, bb);
    assert(found);
    return *gf.blocks[n];
}
// GCOVBlock::getFile
gcov_block_get_file :: (b: *Gcov_Block, filename: string) -> *Gcov_Lines {
    if b.lines.count == 0 || b.lines[b.lines.count - 1].filename != filename {
        l: Gcov_Lines; l.filename = filename; l.lines.allocator = temp;
        array_add(*b.lines, l);
    }
    return *b.lines[b.lines.count - 1];
}

// GCOVBlock::writeOut
gcov_block_write_out :: (g: *Gcov, b: *Gcov_Block) {
    len: u32 = 3;
    for b.lines len += 1 + gcov_words_of_string(it.filename) + cast(u32) it.lines.count;
    gcov_write(g, GCOV_TAG_LINES);
    gcov_write(g, len);
    gcov_write(g, b.number);
    for b.lines {
        gcov_write(g, 0);
        gcov_write_string(g, it.filename);
        for l: it.lines gcov_write(g, l);
    }
    gcov_write(g, 0);
    gcov_write(g, 0);
}

// GCOVFunction::writeOut
gcov_func_write_out :: (g: *Gcov, gf: *Gcov_Func, cfg_checksum: u32) {
    gcov_write(g, GCOV_TAG_FUNCTION);
    filename := gcov_get_filename(gf.sp);
    name := gcov_get_function_name(gf.sp);
    block_len := 3 + gcov_words_of_string(name);
    block_len += 1 + gcov_words_of_string(filename) + 4;
    gcov_write(g, block_len);
    gcov_write(g, gf.ident);
    gcov_write(g, gf.func_checksum);
    gcov_write(g, cfg_checksum);
    gcov_write_string(g, name);
    gcov_write(g, ifx di_int(gf.sp, 4) & DI_FLAG_ARTIFICIAL then cast(u32) 1 else 0);
    gcov_write_string(g, filename);
    gcov_write(g, cast(u32) di_int(gf.sp, 0));   // start_line
    gcov_write(g, 0);                            // start_column
    gcov_write(g, gf.end_line);
    gcov_write(g, 0);                            // end_column
    gcov_write(g, GCOV_TAG_BLOCKS);
    gcov_write(g, 1);
    gcov_write(g, cast(u32) gf.blocks.count);    // Blocks.size() + 2
    write_arcs :: (g: *Gcov, b: *Gcov_Block) {
        if b.out_edges.count == 0 return;
        gcov_write(g, GCOV_TAG_ARCS);
        gcov_write(g, cast(u32) b.out_edges.count * 2 + 1);
        gcov_write(g, b.number);
        for b.out_edges { gcov_write(g, it.dst); gcov_write(g, it.flags); }
    }
    write_arcs(g, *gf.blocks[0]);
    for k: 2..gf.blocks.count-1 write_arcs(g, *gf.blocks[k]);
    for k: 2..gf.blocks.count-1 gcov_block_write_out(g, *gf.blocks[k]);
}

// mangleName
gcov_mangle_name :: (cu: Md_Id, notes: bool) -> string {
    gn := named_md_find("llvm.gcov");
    if gn >= 0 {
        for n: ir.named_md[gn].ops {
            nn := md_nops(n);
            three := nn == 3;
            if !three && nn != 2 continue;
            o := md_op(n, ifx three then cast(u32) 2 else 1);
            if o != cu continue;   // dyn_cast<MDNode>(...) != CU
            if three {
                nf := md_op(n, 0); df := md_op(n, 1);
                if !md_is_string(nf) || !md_is_string(df) continue;
                return ifx notes then md_str_of(nf) else md_str_of(df);
            }
            gf := md_op(n, 0);
            if !md_is_string(gf) continue;
            return gcov_replace_extension(md_str_of(gf), ifx notes then "gcno" else "gcda");
        }
    }
    filename := gcov_replace_extension(gcov_scope_filename(cu), ifx notes then "gcno" else "gcda");
    fname := sp_filename(filename, false);
    ok, cwd := gcov_current_path();
    if !ok return fname;
    return sp_append(cwd, fname, false);
}
// sys::path::replace_extension (posix)
gcov_replace_extension :: (path: string, ext: string) -> string {
    p := path;
    pos := -1;
    for i: 0..p.count-1 if p[i] == #char "." pos = i;
    if pos >= 0 && pos >= sp_filename_pos(p, false) p.count = pos;
    if ext.count > 0 && ext[0] != #char "." return tconcat(p, ".", ext);
    return tconcat(p, ext);
}

// functionHasLines: the first instruction with a non-zero line gives EndLine
gcov_function_has_lines :: (f: Value_Id) -> bool, u32 {
    for bb: fn_blocks(f) for i: block_insts(bb) {
        loc := get_metadata(i, 0);
        if loc == NONE continue;
        if diloc_line(loc) == 0 continue;
        return true, cast(u32) diloc_line(loc);
    }
    return false, 0;
}

gcov_is_using_scope_based_eh :: (f: Value_Id) -> bool {
    pers := fn_personality(f);
    if pers == NONE return false;
    return is_scoped_eh_personality(classify_eh_personality(pers));
}

// getInstrBB
gcov_get_instr_bb :: (g: *Gcov, m: *Cfg_Mst, ei: s64) -> Value_Id {
    e := m.edges[ei];
    if e.in_mst || e.removed return NONE;
    src := e.src; dest := e.dest;
    if src == NONE return dest;
    if dest == NONE return src;
    can_instrument :: (bb: Value_Id) -> Value_Id { return ifx block_first_insertion_pt(bb) == NONE then NONE else bb; }
    ti := block_terminator(src);
    if num_successors(ti) <= 1 && !table_contains(*g.exec_blocks, src) return can_instrument(src);
    if !e.is_critical return can_instrument(dest);
    succ_num: u32 = 0;
    for k: 0..num_successors(ti)-1 if get_successor(ti, k) == dest { succ_num = k; break; }
    instr_bb: Value_Id = NONE;
    if inst_op(ti) != .INDIRECTBR {
        o: Crit_Edge_Options;
        instr_bb = split_critical_edge(ti, succ_num, *o);
    }
    if instr_bb == NONE return NONE;
    mst_add_edge(m, src, instr_bb, 0);
    ne := mst_add_edge(m, instr_bb, dest, 0);
    m.edges[ne].in_mst = true;
    m.edges[ei].removed = true;
    return can_instrument(instr_bb);
}

Gcov_Edge :: struct { e: Mst_Edge; place: Value_Id; src_number: u32; dst_number: u32; }

// emitProfileNotes
gcov_emit_profile_notes :: (cu_node: s64, has_exec_or_fork: bool) {
    g: Gcov;
    g.out.allocator = temp; g.file_checksums.allocator = temp; g.funcs.allocator = temp; g.exec_blocks.allocator = temp;
    for gcov_exec_blocks table_set(*g.exec_blocks, it, true);
    for k: 0..3 g.version_str[k] = gcov_cl.default_version[k];
    {
        c3 := cast(s32) g.version_str[0]; c2 := cast(s32) g.version_str[1]; c1 := cast(s32) g.version_str[2];
        g.version = ifx c3 >= #char "A" then (c3 - #char "A") * 100 + (c2 - #char "0") * 10 + c1 - #char "0"
                    else (c3 - #char "0") * 10 + c1 - #char "0";
    }
    // Emit .gcno files that are compatible with GCC 11.1.
    if g.version < 111 {
        g.version = 111;
        for k: 0..3 g.version_str[k] = "B11*"[k];
    }
    emit_gcda := true;
    cus: [..] Md_Id; cus.allocator = temp;
    for ir.named_md[cu_node].ops array_add(*cus, it);
    for cu: cus {
        if !is_di(cu, .COMPILE_UNIT) fatal("insert-gcov-profiling: an llvm.dbg.cu operand that is not a DICompileUnit");
        // Skip module skeleton (and module) CUs.
        if di_int(cu, 7) != 0 continue;
        edge_destinations: [..] u8; edge_destinations.allocator = temp;
        counters_by_sp: [..] Value_Id; counters_by_sp.allocator = temp;
        g.big_endian = dl.big_endian;
        function_ident: u32 = 0;
        fns: [..] Value_Id; fns.allocator = temp;
        for ir.m_functions array_add(*fns, it);
        for f: fns {
            sp := get_metadata(f, 0);
            if sp == NONE || !is_di(sp, .SUBPROGRAM) continue;
            has_lines, end_line := gcov_function_has_lines(f);
            if !has_lines continue;   // (isFunctionInstrumented: no filters)
            // TODO in LLVM: functions using scope-based EH are not supported.
            if gcov_is_using_scope_based_eh(f) continue;
            if fn_has_fn_attr(f, .NoProfile) continue;
            if fn_has_fn_attr(f, .SkipProfile) continue;
            line := cast(u32) di_int(sp, 0);
            filename := gcov_get_filename(sp);
            bpi := get_bpi(f);
            bfi := get_bfi(f);
            split_indirectbr_critical_edges(f, false, bpi, bfi);
            mst: Cfg_Mst;
            mst.f = f; mst.bpi = bpi; mst.bfi = bfi;
            cfg_mst_build(*mst);
            places: [..] Value_Id; places.allocator = temp;
            n := mst.edges.count;
            for k: 0..n-1 {
                if has_exec_or_fork mst.edges[k].in_mst = false;
                p := gcov_get_instr_bb(*g, *mst, k);
                while places.count < mst.edges.count array_add(*places, NONE);
                places[k] = p;
            }
            while places.count < mst.edges.count array_add(*places, NONE);
            entry_block := fn_entry(f);
            gf := gcov_func_create(f, sp, end_line, function_ident);
            function_ident += 1;
            array_add(*g.funcs, gf);
            // erase_if(Removed || (!InMST && !Place)), then stable_partition by Place
            edges: [..] Gcov_Edge; edges.allocator = temp;
            for e, k: mst.edges {
                if e.removed || (!e.in_mst && places[k] == NONE) continue;
                if places[k] != NONE array_add(*edges, .{e = e, place = places[k]});
            }
            measured := edges.count;
            for e, k: mst.edges {
                if e.removed || (!e.in_mst && places[k] == NONE) continue;
                if places[k] == NONE array_add(*edges, .{e = e, place = NONE});
            }
            block_number :: (gf: *Gcov_Func, bb: Value_Id, if_none: u32) -> u32 {
                if bb == NONE return if_none;
                return gcov_func_block(gf, bb).number;
            }
            for * edges {
                if it_index >= measured break;
                it.src_number = block_number(gf, it.e.src, 0);
                it.dst_number = block_number(gf, it.e.dest, 1);
            }
            // stable_sort of the measured edges by (SrcNumber, DstNumber): insertion sort is stable
            for i: 1..measured-1 {
                x := edges[i];
                j := i - 1;
                while j >= 0 && (edges[j].src_number > x.src_number || (edges[j].src_number == x.src_number && edges[j].dst_number > x.dst_number)) {
                    edges[j + 1] = edges[j];
                    j -= 1;
                }
                edges[j + 1] = x;
            }
            for edges {
                src := ifx it.e.src == NONE then *gf.blocks[0] else gcov_func_block(gf, it.e.src);
                dst := block_number(gf, it.e.dest, 1);
                array_add(*src.out_edges, .{dst, ifx it.place != NONE then cast(u32) 0 else GCOV_ARC_ON_TREE});
            }
            // Artificial functions such as global initializers
            if !(di_int(sp, 4) & DI_FLAG_ARTIFICIAL) array_add(*gcov_block_get_file(gcov_func_block(gf, entry_block), filename).lines, line);
            for bb: fn_blocks(f) {
                blk := gcov_func_block(gf, bb);
                for succ: blk.out_edges {
                    idx := succ.dst;
                    while true {
                        array_add(*edge_destinations, cast(u8) (idx & 255));
                        idx >>= 8;
                        if idx == 0 break;
                    }
                }
                for i: block_insts(bb) {
                    loc := get_metadata(i, 0);
                    if loc == NONE continue;
                    // Artificial lines such as calls to the global constructors.
                    if diloc_line(loc) == 0 || di_int(loc, 2) != 0 continue;
                    if line == cast(u32) diloc_line(loc) continue;
                    line = cast(u32) diloc_line(loc);
                    scope := diloc_scope(loc);
                    if sp != di_local_scope_subprogram(scope) continue;
                    array_add(*gcov_block_get_file(blk, gcov_get_filename(scope)).lines, cast(u32) diloc_line(loc));
                }
                line = 0;
            }
            if emit_gcda {
                counter_ty := type_array(cast(u64) measured, ir.t_i64);
                counters := gv_create(counter_ty, false, .INTERNAL, const_null_value(counter_ty), "__llvm_gcov_ctr", NONE, 0, dl.globals_as);
                if triple_parse(ir.triple).obj == .XCOFF fatal("insert-gcov-profiling: XCOFF targets (the __llvm_gcov_ctr_section and __llvm_covinit) are not supported");
                array_add(*counters_by_sp, counters);
                for k: 0..measured-1 {
                    place := edges[k].place;
                    b: Irb; irb_set_at(*b, place, block_first_insertion_pt(place), true);
                    v := ce_gep(counter_ty, counters, .[const_int(ir.t_i64, 0), const_int(ir.t_i64, cast(u64) k)], F_INBOUNDS);
                    ins: Value_Id;
                    if gcov_cl.atomic_counter {
                        ins = new_atomicrmw(*b, RMW_ADD, v, const_int(ir.t_i64, 1), dl_type_store_size(ir.t_i64), ORD_MONOTONIC, SYNC_SYSTEM);
                    } else {
                        old := irb_load(*b, ir.t_i64, v, dl_abi_align(ir.t_i64), false, "gcov_ctr");
                        set_no_sanitize_metadata(old);
                        nc := irb_binop(*b, .ADD, old, const_int(ir.t_i64, 1));
                        ins = irb_store(*b, nc, v, dl_abi_align(ir.t_i64));
                    }
                    set_no_sanitize_metadata(ins);
                }
            }
        }
        stamp := jam_crc_update(0xFFFF_FFFF, edge_destinations);
        array_add(*g.file_checksums, stamp);
        // Options.EmitNotes
        g.out.count = 0;
        if g.big_endian {
            for cast([] u8) "gcno" array_add(*g.out, it);
            for k: 0..3 array_add(*g.out, g.version_str[k]);
        } else {
            for cast([] u8) "oncg" array_add(*g.out, it);
            for k: 0..3 array_add(*g.out, g.version_str[3 - k]);
        }
        gcov_write(*g, stamp);
        gcov_write_string(*g, ".");   // unuseful current_working_directory
        gcov_write(*g, 0);            // unuseful has_unexecuted_blocks
        for g.funcs gcov_func_write_out(*g, it, stamp);
        gcov_write(*g, 0);
        gcov_write(*g, 0);
        notes_file := gcov_mangle_name(cu, true);
        if notes_file == "-" fatal("insert-gcov-profiling: a coverage notes file named '-' (stdout) is not supported");
        O_WRONLY :: 1; O_CREAT :: 0x40; O_TRUNC :: 0x200; O_CLOEXEC :: 0x80000;
        fd := gcov_c_open(temp_c_string(notes_file), O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0x1b6);
        if fd < 0 {
            ctx_emit_error(tconcat("failed to open coverage notes file for writing: ", to_string(gcov_c_strerror(gcov_c_errno().*))));
            continue;
        }
        written: s64 = 0;
        while written < g.out.count {
            w := gcov_c_write(fd, g.out.data + written, cast(u64) (g.out.count - written));
            if w <= 0 fatal("insert-gcov-profiling: writing % failed", notes_file);
            written += w;
        }
        gcov_c_close(fd);
        if emit_gcda {
            gcov_emit_global_constructor(*g, counters_by_sp, cus);
            emit_gcda = false;
        }
    }
}

// createInternalFunction
gcov_create_internal_function :: (ft: Type_Id, name: string, mangled_type: string) -> Value_Id {
    f := fn_create_with_default_attr(ft, .INTERNAL, name, 0);
    glob(f).unnamed_addr = 2;
    fn_add_fn_attr_kind(f, .NoUnwind);
    if mangled_type.count san_set_kcfi_type(f, mangled_type);
    return f;
}

// StructType::create(Elements, Name)
gcov_struct_create :: (elts: [] Type_Id, name: string) -> Type_Id {
    t := type_named_struct("");
    set_struct_body(t, elts, false);
    ctx_set_struct_name(t, name);
    return t;
}

// emitGlobalConstructor
gcov_emit_global_constructor :: (g: *Gcov, counters_by_sp: [] Value_Id, cus: [] Md_Id) {
    writeout := gcov_insert_counter_writeout(g, counters_by_sp, cus);
    reset := gcov_insert_reset(counters_by_sp);
    ft := type_func(ir.t_void, .[], false);
    f := gcov_create_internal_function(ft, "__llvm_gcov_init", "_ZTSFvvE");
    fn_add_fn_attr_kind(f, .NoInline);
    bb := create_block(f, "entry");
    b: Irb; irb_set_end(*b, bb);
    ift := type_func(ir.t_void, .[ir.t_ptr, ir.t_ptr], false);
    init: San_Callee; init.fty = ift; init.callee = san_get_or_insert_function("llvm_gcov_init", ift);
    san_call(*b, init, .[writeout, reset]);
    irb_insert(*b, new_inst(.RET, ir.t_void, 0));
    append_to_global_ctors(f, 0);
}

// insertCounterWriteout
gcov_insert_counter_writeout :: (g: *Gcov, counters_by_sp: [] Value_Id, cus: [] Md_Id) -> Value_Id {
    vft := type_func(ir.t_void, .[], false);
    wf := module_get_function("__llvm_gcov_writeout");
    if wf == NONE wf = gcov_create_internal_function(vft, "__llvm_gcov_writeout", "_ZTSFvvE");
    fn_add_fn_attr_kind(wf, .NoInline);
    bb := create_block(wf, "entry");
    b: Irb; irb_set_end(*b, bb);
    t := tli_for(wf);
    i32 := ir.t_i32; ptr := ir.t_ptr;
    sf_ty := type_func(ir.t_void, .[ptr, i32, i32], false);
    start_file: San_Callee; start_file.fty = sf_ty;
    start_file.callee = san_get_or_insert_function("llvm_gcda_start_file", sf_ty, msan_tli_attr_list(t, .[1, 2], false));
    ef_ty := type_func(ir.t_void, .[i32, i32, i32], false);
    emit_function: San_Callee; emit_function.fty = ef_ty;
    emit_function.callee = san_get_or_insert_function("llvm_gcda_emit_function", ef_ty, msan_tli_attr_list(t, .[0, 1, 2], false));
    ea_ty := type_func(ir.t_void, .[i32, ptr], false);
    emit_arcs: San_Callee; emit_arcs.fty = ea_ty;
    emit_arcs.callee = san_get_or_insert_function("llvm_gcda_emit_arcs", ea_ty, msan_tli_attr_list(t, .[0], false));
    summary_info: San_Callee; summary_info.fty = vft; summary_info.callee = san_get_or_insert_function("llvm_gcda_summary_info", vft);
    end_file: San_Callee; end_file.fty = vft; end_file.callee = san_get_or_insert_function("llvm_gcda_end_file", vft);
    // (CUNodes is non-null: emitProfileNotes only runs with one)
    sfa_ty := gcov_struct_create(.[ptr, i32, i32], "start_file_args_ty");
    efa_ty := gcov_struct_create(.[i32, i32, i32], "emit_function_args_ty");
    eaa_ty := gcov_struct_create(.[i32, ptr], "emit_arcs_args_ty");
    fi_ty := gcov_struct_create(.[sfa_ty, i32, ptr, ptr], "file_info");
    v0 := cast(u32) g.version_str[0]; v1 := cast(u32) g.version_str[1]; v2 := cast(u32) g.version_str[2]; v3 := cast(u32) g.version_str[3];
    version_be := (v0 << 24) | (v1 << 16) | (v2 << 8) | v3;
    file_infos: [..] Value_Id; file_infos.allocator = temp;
    for cu, i: cus {
        if di_int(cu, 7) != 0 continue;
        filename_gcda := gcov_mangle_name(cu, false);
        cfg_checksum: u32 = 0;
        if g.file_checksums.count {
            if i >= g.file_checksums.count fatal("insert-gcov-profiling: compile unit % has no checksum (LLVM reads FileChecksums out of bounds)", i);
            cfg_checksum = g.file_checksums[i];
        }
        sfa := const_aggregate(.C_STRUCT, sfa_ty, .[irb_create_global_string(filename_gcda), const_int(i32, version_be), const_int(i32, cfg_checksum)]);
        efs: [..] Value_Id; efs.allocator = temp;
        eas: [..] Value_Id; eas.allocator = temp;
        for gv, j: counters_by_sp {
            func_checksum: u32 = ifx g.funcs.count then g.funcs[j].func_checksum else 0;
            array_add(*efs, const_aggregate(.C_STRUCT, efa_ty, .[const_int(i32, cast(u64) j), const_int(i32, func_checksum), const_int(i32, cfg_checksum)]));
            arcs := type_count(glob(gv).value_type);
            array_add(*eas, const_aggregate(.C_STRUCT, eaa_ty, .[const_int(i32, arcs), gv]));
        }
        n := cast(u64) counters_by_sp.count;
        efa_arr_ty := type_array(n, efa_ty);
        efa_gv := gv_create(efa_arr_ty, true, .INTERNAL, const_aggregate(.C_ARRAY, efa_arr_ty, efs), tprint("__llvm_internal_gcov_emit_function_args.%", i), NONE, 0, dl.globals_as);
        eaa_arr_ty := type_array(n, eaa_ty);
        glob(efa_gv).unnamed_addr = 2;
        eaa_gv := gv_create(eaa_arr_ty, true, .INTERNAL, const_aggregate(.C_ARRAY, eaa_arr_ty, eas), tprint("__llvm_internal_gcov_emit_arcs_args.%", i), NONE, 0, dl.globals_as);
        glob(eaa_gv).unnamed_addr = 2;
        array_add(*file_infos, const_aggregate(.C_STRUCT, fi_ty, .[sfa, const_int(i32, n), efa_gv, eaa_gv]));
    }
    if file_infos.count == 0 {
        irb_insert(*b, new_inst(.RET, ir.t_void, 0));
        return wf;
    }
    fia_ty := type_array(cast(u64) file_infos.count, fi_ty);
    fia_gv := gv_create(fia_ty, true, .INTERNAL, const_aggregate(.C_ARRAY, fia_ty, file_infos), "__llvm_internal_gcov_emit_file_info", NONE, 0, dl.globals_as);
    glob(fia_gv).unnamed_addr = 2;
    file_loop_header := create_block(wf, "file.loop.header");
    counter_loop_header := create_block(wf, "counter.loop.header");
    file_loop_latch := create_block(wf, "file.loop.latch");
    exit_bb := create_block(wf, "exit");
    irb_br(*b, file_loop_header);
    irb_set_end(*b, file_loop_header);
    iv := irb_phi(*b, i32, 2, "file_idx");
    phi_add_incoming(iv, const_int(i32, 0), bb);
    zero := const_int(i32, 0);
    fip := irb_gep(*b, fia_ty, fia_gv, .[zero, iv], "", F_INBOUNDS);
    sfp := irb_struct_gep(*b, fi_ty, fip, 0, "start_file_args");
    a0 := irb_load(*b, ptr, irb_struct_gep(*b, sfa_ty, sfp, 0), dl_abi_align(ptr), false, "filename");
    a1 := irb_load(*b, i32, irb_struct_gep(*b, sfa_ty, sfp, 1), dl_abi_align(i32), false, "version");
    a2 := irb_load(*b, i32, irb_struct_gep(*b, sfa_ty, sfp, 2), dl_abi_align(i32), false, "stamp");
    sfc := san_call(*b, start_file, .[a0, a1, a2]);
    ak := tli_ext_attr_for_i32_param(false);
    if ak != .NONE_ATTR call_add_param_attr_kind(sfc, 2, ak);
    num_ctrs := irb_load(*b, i32, irb_struct_gep(*b, fi_ty, fip, 1), dl_abi_align(i32), false, "num_ctrs");
    efa := irb_load(*b, ptr, irb_struct_gep(*b, fi_ty, fip, 2), dl_abi_align(ptr), false, "emit_function_args");
    eaa := irb_load(*b, ptr, irb_struct_gep(*b, fi_ty, fip, 3), dl_abi_align(ptr), false, "emit_arcs_args");
    enter := irb_icmp(*b, ICMP_SLT, zero, num_ctrs);
    irb_cond_br(*b, enter, counter_loop_header, file_loop_latch);
    irb_set_end(*b, counter_loop_header);
    jv := irb_phi(*b, i32, 2, "ctr_idx");
    phi_add_incoming(jv, zero, file_loop_header);
    efp := irb_gep(*b, efa_ty, efa, .[jv], "", F_INBOUNDS);
    e0 := irb_load(*b, i32, irb_struct_gep(*b, efa_ty, efp, 0), dl_abi_align(i32), false, "ident");
    e1 := irb_load(*b, i32, irb_struct_gep(*b, efa_ty, efp, 1), dl_abi_align(i32), false, "func_checkssum");
    e2 := irb_load(*b, i32, irb_struct_gep(*b, efa_ty, efp, 2), dl_abi_align(i32), false, "cfg_checksum");
    efc := san_call(*b, emit_function, .[e0, e1, e2]);
    if ak != .NONE_ATTR { call_add_param_attr_kind(efc, 0, ak); call_add_param_attr_kind(efc, 1, ak); call_add_param_attr_kind(efc, 2, ak); }
    eap := irb_gep(*b, eaa_ty, eaa, .[jv], "", F_INBOUNDS);
    c0 := irb_load(*b, i32, irb_struct_gep(*b, eaa_ty, eap, 0), dl_abi_align(i32), false, "num_counters");
    c1 := irb_load(*b, ptr, irb_struct_gep(*b, eaa_ty, eap, 1), dl_abi_align(ptr), false, "counters");
    eac := san_call(*b, emit_arcs, .[c0, c1]);
    if ak != .NONE_ATTR call_add_param_attr_kind(eac, 0, ak);
    next_jv := irb_binop(*b, .ADD, jv, const_int(i32, 1));
    clc := irb_icmp(*b, ICMP_SLT, next_jv, num_ctrs);
    irb_cond_br(*b, clc, counter_loop_header, file_loop_latch);
    phi_add_incoming(jv, next_jv, counter_loop_header);
    irb_set_end(*b, file_loop_latch);
    san_call(*b, summary_info, .[]);
    san_call(*b, end_file, .[]);
    next_iv := irb_binop(*b, .ADD, iv, const_int(i32, 1), "next_file_idx");
    flc := irb_icmp(*b, ICMP_SLT, next_iv, const_int(i32, cast(u64) file_infos.count));
    irb_cond_br(*b, flc, file_loop_header, exit_bb);
    phi_add_incoming(iv, next_iv, file_loop_latch);
    irb_set_end(*b, exit_bb);
    irb_insert(*b, new_inst(.RET, ir.t_void, 0));
    return wf;
}

// insertReset
gcov_insert_reset :: (counters_by_sp: [] Value_Id) -> Value_Id {
    ft := type_func(ir.t_void, .[], false);
    rf := module_get_function("__llvm_gcov_reset");
    if rf == NONE rf = gcov_create_internal_function(ft, "__llvm_gcov_reset", "_ZTSFvvE");
    fn_add_fn_attr_kind(rf, .NoInline);
    entry := create_block(rf, "entry");
    b: Irb; irb_set_end(*b, entry);
    for gv: counters_by_sp {
        gvt := glob(gv).value_type;
        size := type_count(gvt) * dl_type_size_bits(scalar_type(type_elem(gvt))) / 8;
        irb_memset(*b, gv, const_null_value(ir.t_i8), const_int(ir.t_i64, size), glob(gv).align, false);
    }
    rt := fn_ret_type(rf);
    if rt == ir.t_void irb_insert(*b, new_inst(.RET, ir.t_void, 0));
    else if type_kind(rt) == .INT {
        r := new_inst(.RET, ir.t_void, 1); set_op(r, 0, const_int(rt, 0));
        irb_insert(*b, r);
    } else fatal("invalid return type for __llvm_gcov_reset");
    return rf;
}
