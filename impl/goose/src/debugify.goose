// The `debugify` and `check-debugify` module passes (synthetic mode) and opt's -enable-debugify, -debugify-each and
// -strip-debug. Ported from llvm/lib/Transforms/Utils/Debugify.cpp (isFunctionSkipped, findTerminatingInstruction,
// applyDebugifyMetadata, stripDebugifyMetadata, diagnoseMisSizedDbgValue, checkDebugifyMetadata,
// NewPMDebugifyPass::run, NewPMCheckDebugifyPass::run, DebugifyEachInstrumentation::registerCallbacks) with the
// DIBuilder calls it makes (llvm/lib/IR/DIBuilder.cpp: createFile, createCompileUnit, createSubroutineType,
// createFunction, createBasicType, createAutoVariable, createExpression, insertDbgValueIntrinsic,
// finalizeSubprogram) and llvm/tools/opt (NewPMDriver.cpp: -enable-debugify / -debugify-each; optdriver.cpp:
// -strip-debug).
//
// Not ported (fail loudly): the "original debuginfo" mode (-verify-each-debuginfo-preserve,
// -verify-debuginfo-preserve), -debugify-export, -debugify-func-limit, mir-debugify.
import std;
import ir;
import irutil;
import calls;
import instinfo;
import gen_iids;
import gen_attrs;
import dinfo;
import datalayout;
import instsimplify;
import autoupgrade;
import cfgutil;
import flags;
import printer;

let DW_ATE_UNSIGNED_DBG: i64 = 7;
let DW_LANG_C_DBG: i64 = 2;
let SPFLAG_LOCAL_TO_UNIT: i64 = 4;
let SPFLAG_DEFINITION: i64 = 8;
let SPFLAG_OPTIMIZED: i64 = 16;

fn dbgify_quiet() -> bool { flag_bool("debugify-quiet", false) }
fn dbgify_out(s: const u8[:]) { if !dbgify_quiet() { errs(s); } }
// -debugify-level: locations | location+variables (the default)
fn dbgify_locations_only() -> bool {
    let lv = flag_str("debugify-level");
    if lv.len == 0 || lv == "location+variables" { return false; }
    if lv == "locations" { return true; }
    fatal(str("opt: for the --debugify-level option: Cannot find option named '", lv, "'!"));
    return false;
}

// ---------------------------------------------------------------------------------------------
// Module-level metadata helpers

fn dbgify_named_md_find(m: i32, name: const u8[:]) -> i64 {
    for k in named_mds.len { if named_mds[k].module == m && sbytes(named_mds[k].name) == name { return k; } }
    return -1;
}
// Module::getOrInsertNamedMetadata
fn dbgify_named_md_get_or_insert(m: i32, name: const u8[:]) -> i64 {
    let k = dbgify_named_md_find(m, name);
    if k >= 0 { return k; }
    let nm = intern(name);
    named_mds.push(NamedMd { name: nm, ops: md_ops.len as i32, nops: 0, module: m });
    return named_mds.len - 1;
}
// NamedMDNode::addOperand
fn dbgify_named_md_add(k: i64, md: i32) {
    let at = md_ops.len as i32;
    let o = named_mds[k].ops;
    let n = named_mds[k].nops;
    for j in n { md_ops.push(md_ops[o + j]); }
    md_ops.push(md);
    named_mds[k].ops = at;
    named_mds[k].nops = n + 1;
}
// Module::getModuleFlag(Key): the flag's value metadata or -1
fn dbgify_module_flag(m: i32, key: const u8[:]) -> i32 {
    let k = dbgify_named_md_find(m, "llvm.module.flags");
    if k < 0 { return -1; }
    for j in named_mds[k].nops {
        let f = md_ops[named_mds[k].ops + j];
        if f < 0 || mds[f].kind != MK_TUPLE || mds[f].nops < 3 { continue; }
        let id = md_op(f, 1);
        if id >= 0 && mds[id].kind == MK_STRING && sbytes(mds[id].extra) == key { return md_op(f, 2); }
    }
    return -1;
}

// isFunctionSkipped: F.isDeclaration() || !F.hasExactDefinition()
fn dbgify_function_skipped(f: i32) -> bool {
    if func_is_decl(f) { return true; }
    let g = glob_of(f);
    let lk = globs[g].linkage as i64;
    if lk == LK_AVAILABLE_EXTERNALLY { return true; }               // isDeclarationForLinker
    if lk == LK_WEAK_ODR || lk == LK_LINKONCE_ODR { return true; }  // mayBeDerefined
    // isInterposable(CheckNoIPA = true)
    if func_has_fn_attr(f, AK_NoIPA) { return true; }
    if lk == LK_WEAK_ANY || lk == LK_LINKONCE_ANY || lk == LK_COMMON || lk == LK_EXTERN_WEAK { return true; }
    let si = dbgify_module_flag(globs[g].module, "SemanticInterposition");
    if si >= 0 && mds[si].kind == MK_VALUE && vals[mds[si].extra].kind == VK_CINT && cint_lo(mds[si].extra) != 0 &&
       globs[g].dso_local == 0 { return true; }
    if func_has_fn_attr(f, AK_NoBuiltin) { return true; }            // isNobuiltinFnDef
    return false;
}

// findTerminatingInstruction(BB)
fn dbgify_terminating_inst(bb: i32) -> i32 {
    let mt = cu_terminating_musttail_call(bb);
    if mt >= 0 { return mt; }
    let dc = cu_terminating_deoptimize_call(bb);
    if dc >= 0 { return dc; }
    return block_terminator(bb);
}

// getAllocSizeInBits(M, Ty)
fn dbgify_alloc_size_bits(ty: i32) -> i64 {
    if !ty_is_sized(ty) { return 0; }
    if ty_kind(ty) == TK_SVEC { fatal("debugify: the size of a scalable vector type is not supported yet"); }
    return dl_alloc_size(ty) * 8;
}

// A DI node of `kind` from (field name, metadata) pairs; integer fields equal to their default are left unset
// like the parser does (so uniquing matches).
var dbgify_slots: i32[>..<];
fn dbgify_slots_begin(kind: i64) {
    di_init();
    dbgify_slots.resize(0);
    for k in dik_count[kind] { dbgify_slots.push(-1); }
}
fn dbgify_set(kind: i64, name: const u8[:], md: i32) { dbgify_slots[di_field_index(kind, name)] = md; }
fn dbgify_set_int(kind: i64, name: const u8[:], v: i64) {
    let fi = di_field_index(kind, name);
    let f = di_fields[dik_start[kind] as i64 + fi];
    if f.has_default != 0 && v == f.def { dbgify_slots[fi] = -1; } else { dbgify_slots[fi] = md_int(v); }
}
fn dbgify_set_str(kind: i64, name: const u8[:], s: const u8[:]) {
    var buf: u8[>..] = [];
    buf.append(s);
    dbgify_slots[di_field_index(kind, name)] = if buf.len > 0 { md_string(buf) } else { -1 };
}
fn dbgify_node(kind: i64, distinct: bool) -> i32 { md_get(MK_DI, kind as i32, dbgify_slots, distinct) }

// ---------------------------------------------------------------------------------------------
// applyDebugifyMetadata

var dbgify_tcache_size: i64[>..<];
var dbgify_tcache_ty: i32[>..<];
var dbgify_next_var: i64 = 1;
var dbgify_retained: i32[>..<];

// getCachedDIType(Ty): DIB.createBasicType("ty<size>", Size, DW_ATE_unsigned)
fn dbgify_cached_di_type(ty: i32) -> i32 {
    let size = dbgify_alloc_size_bits(ty);
    for k in dbgify_tcache_size.len { if dbgify_tcache_size[k] == size { return dbgify_tcache_ty[k]; } }
    dbgify_slots_begin(DIK_BASICTYPE);
    dbgify_set_str(DIK_BASICTYPE, "name", str("ty", size));
    dbgify_set(DIK_BASICTYPE, "size", md_value(c_int(T_I64, size)));
    dbgify_set_int(DIK_BASICTYPE, "encoding", DW_ATE_UNSIGNED_DBG);
    let t = dbgify_node(DIK_BASICTYPE, false);
    dbgify_tcache_size.push(size);
    dbgify_tcache_ty.push(t);
    return t;
}

// insertDbgVal(TemplateInst, InsertPt): a #dbg_value appended to the records of the instruction at InsertPt
fn dbgify_insert_dbg_val(tmpl: i32, before: i32, sp: i32, file: i32) {
    let name = str(dbgify_next_var);
    dbgify_next_var++;
    var v = tmpl;
    if vals[tmpl].ty == T_VOID { v = c_int(T_I32, 0); }
    let loc = inst_get_md(tmpl, 0);
    let line = di_int(loc, "line");
    let ty = dbgify_cached_di_type(vals[v].ty);
    // createAutoVariable(SP, Name, File, Line, Ty, AlwaysPreserve=true)
    dbgify_slots_begin(DIK_LOCALVARIABLE);
    dbgify_set(DIK_LOCALVARIABLE, "scope", sp);
    dbgify_set_str(DIK_LOCALVARIABLE, "name", name);
    dbgify_set(DIK_LOCALVARIABLE, "file", file);
    dbgify_set_int(DIK_LOCALVARIABLE, "line", line);
    dbgify_set(DIK_LOCALVARIABLE, "type", ty);
    let var_ = dbgify_node(DIK_LOCALVARIABLE, false);
    dbgify_retained.push(var_);
    // insertDbgValueIntrinsic(V, LocalVar, createExpression(), Loc, InsertPt)
    let r = new_dbgrec(DR_VALUE);
    dbgrecs[r].loc = md_value(v);
    dbgrecs[r].dvar = var_;
    dbgrecs[r].expr = md_get(MK_DIEXPR, -1, [], false);
    dbgrecs[r].dl = loc;
    inst_add_dbg(before, r);
}

// DILocation::get(Ctx, Line, 1, SP, nullptr, false, AtomGroup, AtomRank)
fn dbgify_location(line: i64, sp: i32, atom_group: i64, atom_rank: i64) -> i32 {
    dbgify_slots_begin(DIK_LOCATION);
    dbgify_set_int(DIK_LOCATION, "line", line);
    dbgify_set_int(DIK_LOCATION, "column", 1);
    dbgify_set(DIK_LOCATION, "scope", sp);
    dbgify_set_int(DIK_LOCATION, "atomGroup", atom_group);
    dbgify_set_int(DIK_LOCATION, "atomRank", atom_rank);
    return dbgify_node(DIK_LOCATION, false);
}

fn glob_set_dbg(f: i32, sp: i32) {
    let g = glob_of(f);
    let at = globs[g].md;
    let n = globs[g].nmd;
    for k in n { if md_att[at + 2 * k] == 0 { md_att[at + 2 * k + 1] = sp; return; } }
    let nat = md_att.len as i32;
    md_att.push(0);
    md_att.push(sp);
    for k in n { md_att.push(md_att[at + 2 * k]); md_att.push(md_att[at + 2 * k + 1]); }
    globs[g].md = nat;
    globs[g].nmd = n + 1;
}

// applyDebugifyMetadata(M, Functions, Banner, ApplyToMF = nullptr); `only` = -1 for all functions
fn apply_debugify_metadata(m: i32, only: i32, banner: const u8[:]) -> bool {
    if dbgify_named_md_find(m, "llvm.dbg.cu") >= 0 {
        dbgify_out(str(banner, "Skipping module with debug info\n"));
        return false;
    }
    let atoms = flag_bool("debugify-atoms", false);
    let loc_only = dbgify_locations_only();
    dbgify_tcache_size.resize(0);
    dbgify_tcache_ty.resize(0);
    var next_line: i64 = 1;
    dbgify_next_var = 1;
    // DIB.createFile(M.getName(), "/")
    dbgify_slots_begin(DIK_FILE);
    dbgify_set(DIK_FILE, "filename", md_string(sbytes(modules[m].module_id)));
    dbgify_set_str(DIK_FILE, "directory", "/");
    let file = dbgify_node(DIK_FILE, false);
    // DIB.createCompileUnit(DW_LANG_C, File, "debugify", isOptimized=true, "", 0): distinct, added to llvm.dbg.cu
    dbgify_slots_begin(DIK_COMPILEUNIT);
    dbgify_set(DIK_COMPILEUNIT, "file", file);
    dbgify_set(DIK_COMPILEUNIT, "language", md_int(DW_LANG_C_DBG));
    dbgify_set_str(DIK_COMPILEUNIT, "producer", "debugify");
    dbgify_set_int(DIK_COMPILEUNIT, "isOptimized", 1);
    dbgify_set_int(DIK_COMPILEUNIT, "runtimeVersion", 0);
    dbgify_set_int(DIK_COMPILEUNIT, "emissionKind", 1);
    let cu = dbgify_node(DIK_COMPILEUNIT, true);
    dbgify_named_md_add(dbgify_named_md_get_or_insert(m, "llvm.dbg.cu"), cu);
    var f = modules[m].first_func;
    while f >= 0 {
        let nf = globs[glob_of(f)].next;
        if (only >= 0 && f != only) || dbgify_function_skipped(f) { f = nf; continue; }
        var inserted = false;
        // createSubroutineType(getOrCreateTypeArray({}))
        dbgify_slots_begin(DIK_SUBROUTINETYPE);
        dbgify_set(DIK_SUBROUTINETYPE, "types", md_get(MK_TUPLE, -1, [], false));
        let sp_type = dbgify_node(DIK_SUBROUTINETYPE, false);
        var spflags = SPFLAG_DEFINITION | SPFLAG_OPTIMIZED;
        let lk = globs[glob_of(f)].linkage as i64;
        if lk == LK_PRIVATE || lk == LK_INTERNAL { spflags |= SPFLAG_LOCAL_TO_UNIT; }
        // createFunction(CU, Name, Name, File, NextLine, SPType, NextLine, FlagZero, SPFlags, ..., UseKeyInstructions)
        var fname: u8[>..] = [];
        fname.append(val_name(f));
        dbgify_slots_begin(DIK_SUBPROGRAM);
        dbgify_set_str(DIK_SUBPROGRAM, "name", fname);
        dbgify_set_str(DIK_SUBPROGRAM, "linkageName", fname);
        dbgify_set(DIK_SUBPROGRAM, "file", file);
        dbgify_set_int(DIK_SUBPROGRAM, "line", next_line);
        dbgify_set(DIK_SUBPROGRAM, "type", sp_type);
        dbgify_set_int(DIK_SUBPROGRAM, "scopeLine", next_line);
        dbgify_set(DIK_SUBPROGRAM, "spFlags", md_int(spflags));
        dbgify_set(DIK_SUBPROGRAM, "unit", cu);
        dbgify_set_int(DIK_SUBPROGRAM, "keyInstructions", if atoms { 1 } else { 0 });
        let sp = dbgify_node(DIK_SUBPROGRAM, true);
        glob_set_dbg(f, sp);
        dbgify_retained.resize(0);
        var bb = globs[glob_of(f)].first_block;
        while bb >= 0 {
            var i = block_first(bb);
            while i >= 0 {
                let ag: i64 = if atoms { next_line } else { 0 };
                let ar: i64 = if atoms { 1 } else { 0 };
                let line = next_line;
                next_line++;
                inst_set_md(i, 0, dbgify_location(line, sp, ag, ar));
                i = inst_next(i);
            }
            if !loc_only && !inst_is_eh_pad(dbgify_first_non_phi(bb)) {
                let last = dbgify_terminating_inst(bb);
                var pt = block_first_insertion_pt_dbg(bb);
                var x = block_first(bb);
                while x != last {
                    let nx = inst_next(x);
                    if vals[x].ty != T_VOID {
                        if iop(x) != OP_PHI && !inst_is_eh_pad(x) { pt = nx; }
                        dbgify_insert_dbg_val(x, pt, sp, file);
                        inserted = true;
                    }
                    x = nx;
                }
            }
            bb = blocks[block_of(bb)].next;
        }
        if !loc_only && !inserted {
            let term = dbgify_terminating_inst(globs[glob_of(f)].first_block);
            dbgify_insert_dbg_val(term, term, sp, file);
        }
        // DIBuilder::finalizeSubprogram: retainedNodes = the tracked variables (the temporary !{} otherwise,
        // which prints as nothing)
        if dbgify_retained.len > 0 {
            let t = md_get(MK_TUPLE, -1, dbgify_retained, false);
            md_ops[mds[sp].ops + di_field_index(DIK_SUBPROGRAM, "retainedNodes")] = t;
        }
        f = nf;
    }
    let nmd = dbgify_named_md_get_or_insert(m, "llvm.debugify");
    dbgify_named_md_add(nmd, md_get(MK_TUPLE, -1, [md_value(c_int(T_I32, next_line - 1))], false));
    dbgify_named_md_add(nmd, md_get(MK_TUPLE, -1, [md_value(c_int(T_I32, dbgify_next_var - 1))], false));
    if dbgify_module_flag(m, "Debug Info Version") < 0 {
        // M.addModuleFlag(Module::Warning, "Debug Info Version", DEBUG_METADATA_VERSION)
        let k = dbgify_named_md_get_or_insert(m, "llvm.module.flags");
        let fl = md_get(MK_TUPLE, -1, [md_value(c_int(T_I32, 2)), md_string("Debug Info Version"), md_value(c_int(T_I32, 3))], false);
        dbgify_named_md_add(k, fl);
    }
    return true;
}

// BasicBlock::getFirstNonPHIIt
fn dbgify_first_non_phi(bb: i32) -> i32 {
    var i = block_first(bb);
    while i >= 0 && iop(i) == OP_PHI { i = inst_next(i); }
    return i;
}
// BasicBlock::getFirstInsertionPt (the instruction; never end() in a block with a terminator)
fn block_first_insertion_pt_dbg(bb: i32) -> i32 {
    var i = block_first(bb);
    while i >= 0 && (iop(i) == OP_PHI || inst_is_eh_pad(i)) { i = inst_next(i); }
    return i;
}

// ---------------------------------------------------------------------------------------------
// checkDebugifyMetadata

// DIVariable::getSizeInBits
fn dbgify_var_size_bits(v: i32) -> i64 {
    var t = di_slot(v, "type");
    while t >= 0 && mds[t].kind == MK_DI {
        let k = di_kind(t);
        if k == DIK_BASICTYPE || k == DIK_DERIVEDTYPE || k == DIK_COMPOSITETYPE || k == DIK_SUBROUTINETYPE ||
           k == DIK_STRINGTYPE || k == DIK_FIXEDPOINTTYPE || k == DIK_SUBRANGETYPE {
            if k != DIK_SUBROUTINETYPE {
                let s = di_slot(t, "size");
                if s >= 0 {
                    if mds[s].kind == MK_VALUE && vals[mds[s].extra].kind == VK_CINT {
                        let sz = cint_lo(mds[s].extra) as! i64;
                        if sz != 0 { return sz; }
                    } else { fatal("check-debugify: a non-constant DIType size is not supported yet"); }
                }
            }
            if k == DIK_DERIVEDTYPE { t = di_slot(t, "baseType"); continue; }
        }
        break;
    }
    return -1;
}
// DIVariable::getSignedness() == Signed
fn dbgify_var_is_signed(v: i32) -> bool {
    let t = di_slot(v, "type");
    if t < 0 || mds[t].kind != MK_DI || di_kind(t) != DIK_BASICTYPE { return false; }
    let e = di_int(t, "encoding");
    return e == 5 || e == 6;   // DW_ATE_signed, DW_ATE_signed_char
}
// diagnoseMisSizedDbgValue(M, DVR)
fn dbgify_mis_sized(r: i32, fv: i32) -> bool {
    let ex = dbgrecs[r].expr;
    if ex >= 0 && mds[ex].nops != 0 { return false; }
    var lm = dbgrecs[r].loc;
    if lm < 0 { return false; }
    if mds[lm].kind == MK_DIARGLIST { if mds[lm].nops == 0 { return false; } lm = md_op(lm, 0); }
    if mds[lm].kind != MK_VALUE { return false; }
    let v = mds[lm].extra;
    let ty = vals[v].ty;
    let vsize = dbgify_alloc_size_bits(ty);
    let var_size = dbgify_var_size_bits(dbgrecs[r].dvar);
    if vsize == 0 || var_size < 0 { return false; }
    var bad = false;
    if ty_kind(ty) == TK_INT { if dbgify_var_is_signed(dbgrecs[r].dvar) { bad = vsize < var_size; } }
    else { bad = vsize != var_size; }
    if bad && !dbgify_quiet() {
        errs(str("ERROR: dbg.value operand has size ", vsize, ", but its variable has size ", var_size, ": "));
        slots_begin_all_metadata(fv);
        let mark = out.len;
        put_dbgrec(r);
        errbuf.append(out[mark..]);
        out.resize(mark);
        slots_reset_all();
        errs("\n");
    }
    return bad;
}

fn dbgify_parse_uint(s: const u8[:]) -> i64 {
    if s.len == 0 { return -1; }
    var v: i64 = 0;
    for c in s {
        if c < '0' || c > '9' { return -1; }
        v = v * 10 + (c - '0') as i64;
        if v > 0xFFFFFFFF { return -1; }
    }
    return v;
}

// checkDebugifyMetadata(M, Functions, NameOfWrappedPass, Banner, Strip, StatsMap = nullptr); `only` = -1 for all
fn check_debugify_metadata(m: i32, only: i32, pass_name: const u8[:], banner: const u8[:], strip: bool) -> bool {
    let nk = dbgify_named_md_find(m, "llvm.debugify");
    if nk < 0 {
        dbgify_out(str(banner, ": Skipping module without debugify metadata\n"));
        return false;
    }
    let n0 = md_op(md_ops[named_mds[nk].ops], 0);
    let n1 = md_op(md_ops[named_mds[nk].ops + 1], 0);
    let orig_lines = cint_lo(mds[n0].extra) as! i64;
    let orig_vars = cint_lo(mds[n1].extra) as! i64;
    var has_errors = false;
    var missing_lines: bool[>..<] = [];
    for k in orig_lines { missing_lines.push(true); }
    var missing_vars: bool[>..<] = [];
    for k in orig_vars { missing_vars.push(true); }
    var f = modules[m].first_func;
    while f >= 0 {
        let nf = globs[glob_of(f)].next;
        if (only >= 0 && f != only) || dbgify_function_skipped(f) { f = nf; continue; }
        var bb = globs[glob_of(f)].first_block;
        while bb >= 0 {
            var i = block_first(bb);
            while i >= 0 {
                let dl = inst_get_md(i, 0);
                if dl >= 0 && di_int(dl, "line") != 0 {
                    let l = di_int(dl, "line");
                    if l - 1 < orig_lines { missing_lines[l - 1] = false; }
                } else if iop(i) != OP_PHI && dl < 0 && !dbgify_quiet() {
                    errs(str("WARNING: Instruction with empty DebugLoc in function ", val_name(f), " --"));
                    errs_inst_module_slots(i, f);
                    errs("\n");
                }
                i = inst_next(i);
            }
            bb = blocks[block_of(bb)].next;
        }
        bb = globs[glob_of(f)].first_block;
        while bb >= 0 {
            var i = block_first(bb);
            while i >= 0 {
                var r = inst_first_dbg(i);
                while r >= 0 {
                    let k = dbgrecs[r].kind as i64;
                    if k == DR_VALUE || k == DR_ASSIGN {
                        let var_ = dbgify_parse_uint(di_str(dbgrecs[r].dvar, "name"));
                        let bad = dbgify_mis_sized(r, f);
                        // MissingVars.reset(Var - 1) with Var = ~0U when the name is not a number
                        if !bad && var_ >= 1 && var_ <= orig_vars { missing_vars[var_ - 1] = false; }
                        if !bad && !(var_ >= 1 && var_ <= orig_vars) { fatal("check-debugify: a variable name that is not a debugify variable number"); }
                        if bad { has_errors = true; }
                    }
                    r = dbgrecs[r].next;
                }
                i = inst_next(i);
            }
            bb = blocks[block_of(bb)].next;
        }
        f = nf;
    }
    for k in missing_lines.len { if missing_lines[k] { dbgify_out(str("WARNING: Missing line ", k + 1, "\n")); } }
    for k in missing_vars.len { if missing_vars[k] { dbgify_out(str("WARNING: Missing variable ", k + 1, "\n")); } }
    dbgify_out(banner);
    if pass_name.len > 0 { dbgify_out(str(" [", pass_name, "]")); }
    dbgify_out(str(": ", if has_errors { "FAIL" } else { "PASS" }, "\n"));
    if strip { return strip_debugify_metadata(m); }
    return false;
}

// stripDebugifyMetadata(M)
fn strip_debugify_metadata(m: i32) -> bool {
    var changed = false;
    var w = 0;
    for k in named_mds.len {
        let nm = named_mds[k];
        let s = sbytes(nm.name);
        if nm.module == m && (s == "llvm.debugify" || s == "llvm.mir.debugify") { changed = true; continue; }
        named_mds[w] = nm;
        w++;
    }
    named_mds.resize(w);
    if strip_debug_info() { changed = true; }
    // the dead llvm.dbg.value prototype (never created: debug records are used)
    let k = dbgify_named_md_find(m, "llvm.module.flags");
    if k < 0 { return changed; }
    let o = named_mds[k].ops;
    let n = named_mds[k].nops;
    let at = md_ops.len as i32;
    var kept = 0;
    for j in n {
        let fl = md_ops[o + j];
        let key = md_op(fl, 1);
        if key >= 0 && mds[key].kind == MK_STRING && sbytes(mds[key].extra) == "Debug Info Version" { changed = true; continue; }
        md_ops.push(fl);
        kept++;
    }
    if kept == 0 {
        var w2 = 0;
        for j in named_mds.len { if j != k { named_mds[w2] = named_mds[j]; w2++; } }
        named_mds.resize(w2);
    } else {
        named_mds[k].ops = at;
        named_mds[k].nops = kept as i32;
    }
    return changed;
}

// NewPMDebugifyPass::run (synthetic mode): preserves the CFG analyses
fn debugify_run(m: i32) { apply_debugify_metadata(m, -1, "ModuleDebugify: "); }
// NewPMCheckDebugifyPass::run (synthetic mode, Strip = false)
fn check_debugify_run(m: i32) { check_debugify_metadata(m, -1, "", "CheckModuleDebugify", false); }
