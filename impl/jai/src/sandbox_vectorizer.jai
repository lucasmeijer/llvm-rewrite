// SandboxVectorizer (`sandbox-vectorizer`), the framework part: port of
// llvm/lib/Transforms/Vectorize/SandboxVectorizer/SandboxVectorizer.cpp (pass construction, allowFile, runImpl),
// SandboxVectorizerPassBuilder.cpp and Passes/PassRegistry.def, llvm/include/llvm/SandboxIR/PassManager.h
// (setPassPipeline's parser, printPipeline), llvm/lib/SandboxIR/Region.cpp (regions as !sandboxvec / !sandboxaux
// metadata, createRegionsFromMD), Passes/RegionsFromBBs.cpp, Passes/RegionsFromMetadata.cpp,
// Passes/SeedCollection.cpp + SeedCollector.cpp (seed grouping; see below), Passes/NullPass.h,
// Passes/PrintInstructionCount.h, Passes/PrintRegion.h and the transaction passes (tr-save / tr-accept / tr-revert /
// tr-accept-or-revert are no-ops while no region pass changes the IR).
//
// Design (DESIGN.md "SandboxVectorizer"): SandboxIR is not built as a second object graph. A sandbox pass is a row of
// `Sbv_Pass` (kind tag + name + aux argument + its region-pass list), the pipelines are rows in one table, and every
// "virtual" runOnFunction / runOnRegion / printPipeline is a `switch` on the kind. Regions are `Sbv_Region` rows (an
// instruction SetVector + the region's distinct MDNode + Aux); the SandboxIR callbacks that add new instructions to
// every live region are not needed until a region pass creates instructions.
//
// Not ported (fail loudly when reached): the region passes that transform IR (bottom-up-vec, load-store-vec,
// pack-reuse: DependencyGraph, Scheduler, Legality, InstrMaps, the Tracker's revert), and seed collection when a seed
// bundle has two or more seeds (getSlice / MemSeedBundle offset sorting).

sbv_cl: struct {
    print_pass_pipeline := false;    // -sbvec-print-pass-pipeline
    passes := "*";                   // -sbvec-passes ("*" = the default pipeline)
    allow_files := ".*";             // -sbvec-allow-files
    vec_reg_bits: u64 = 0;           // -sbvec-vec-reg-bits
    allow_non_pow2 := false;         // -sbvec-allow-non-pow2
    collect_seeds := "stores";       // -sbvec-collect-seeds
    seed_bundle_size_limit: u64 = 32;   // -sbvec-seed-bundle-size-limit
    seed_groups_limit: u64 = 256;       // -sbvec-seed-groups-limit
}
// cl::opts of the unported passes: accepted (they only matter once those passes run, which fails loudly)
sbv_takes_unported_opt :: (name: string) -> bool {
    return name == "sbvec-stop-at" || name == "sbvec-stop-bndl" || name == "sbvec-cost-threshold" ||
           name == "sbvec-allow-reuse" || name == "sbvec-allow-diff-types";
}

sbv_parse_cl_opt :: (name: string, value: string, has_value: bool) -> bool {
    if name == {
        case "sbvec-print-pass-pipeline"; sbv_cl.print_pass_pipeline = smisc_bool(name, value, has_value);
        case "sbvec-passes"; sbv_cl.passes = copy_string(value);
        case "sbvec-allow-files"; sbv_cl.allow_files = copy_string(value);
        case "sbvec-vec-reg-bits"; sbv_cl.vec_reg_bits = cast(u64) smisc_int(name, value, has_value);
        case "sbvec-allow-non-pow2"; sbv_cl.allow_non_pow2 = smisc_bool(name, value, has_value);
        case "sbvec-collect-seeds"; sbv_cl.collect_seeds = copy_string(value);
        case "sbvec-seed-bundle-size-limit"; sbv_cl.seed_bundle_size_limit = cast(u64) smisc_int(name, value, has_value);
        case "sbvec-seed-groups-limit"; sbv_cl.seed_groups_limit = cast(u64) smisc_int(name, value, has_value);
        case;
            if sbv_takes_unported_opt(name) return true;
            return false;
    }
    return true;
}

Sbv_Kind :: enum u8 {
    // function passes (FUNCTION_PASS_WITH_PARAMS)
    SEED_COLLECTION; REGIONS_FROM_BBS; REGIONS_FROM_METADATA;
    // region passes (REGION_PASS)
    NULL_PASS; PACK_REUSE; PRINT_INSTRUCTION_COUNT; PRINT_REGION; TR_SAVE; TR_ACCEPT; TR_REVERT; TR_ACCEPT_OR_REVERT;
    BOTTOM_UP_VEC; LOAD_STORE_VEC;
}
Sbv_Pass :: struct {
    kind: Sbv_Kind;
    name: string;
    allow_diff_types: bool;     // seed-collection(enable-diff-types)
    rpm: [..] s32;              // a function pass's region pass manager ("rpm")
}

sbv: struct {
    built: bool;
    passes: [..] Sbv_Pass;      // every pass of the pipeline (heap: the pipeline lives for the run)
    fpm: [..] s32;              // the function pass manager ("fpm")
}

SBV_REGION_PASSES :: struct { name: string; kind: Sbv_Kind; }.[
    .{"null", .NULL_PASS}, .{"pack-reuse", .PACK_REUSE}, .{"print-instruction-count", .PRINT_INSTRUCTION_COUNT},
    .{"print-region", .PRINT_REGION}, .{"tr-save", .TR_SAVE}, .{"tr-accept", .TR_ACCEPT}, .{"tr-revert", .TR_REVERT},
    .{"tr-accept-or-revert", .TR_ACCEPT_OR_REVERT}, .{"bottom-up-vec", .BOTTOM_UP_VEC}, .{"load-store-vec", .LOAD_STORE_VEC},
];

sbv_usage_exit :: (msg: string) {
    print_stderr("%", msg);
    exit(1);
}

// SandboxVectorizerPassBuilder::createRegionPass / createFunctionPass (-1 = not registered)
sbv_create_pass :: (function_level: bool, name: string, args: string, aux: string) -> s32 {
    p: Sbv_Pass;
    p.name = copy_string(name);
    p.rpm.allocator = context.default_allocator;
    if function_level {
        if name == "seed-collection" p.kind = .SEED_COLLECTION;
        else if name == "regions-from-bbs" p.kind = .REGIONS_FROM_BBS;
        else if name == "regions-from-metadata" p.kind = .REGIONS_FROM_METADATA;
        else return -1;
        if p.kind == .SEED_COLLECTION && aux.count {
            if aux != "enable-diff-types" {
                print_stderr("LLVM ERROR: SeedCollection only supports 'enable-diff-types' aux argument!\n\n");
                exit(1);
            }
            p.allow_diff_types = true;
        }
        array_add(*sbv.passes, p);
        idx := cast(s32) sbv.passes.count - 1;
        rpm := sbv_parse_pipeline(args, false);   // RPM("rpm", Pipeline, createRegionPass)
        sbv.passes[idx].rpm = rpm;
        return idx;
    }
    found := false;
    for SBV_REGION_PASSES if it.name == name { p.kind = it.kind; found = true; break; }
    if !found return -1;
    // (Args must be empty: an assert, compiled out of release builds; region passes ignore their aux argument)
    array_add(*sbv.passes, p);
    return cast(s32) sbv.passes.count - 1;
}

// PassManager::setPassPipeline
sbv_parse_pipeline :: (pipeline_in: string, function_level: bool) -> [..] s32 {
    out: [..] s32; out.allocator = context.default_allocator;
    if pipeline_in.count == 0 return out;
    p := tconcat(pipeline_in, "\0");
    add :: (out: *[..] s32, name: string, args: string, aux: string, function_level: bool) {
        if name.count == 0 sbv_usage_exit("Found empty pass name.\n");
        idx := sbv_create_pass(function_level, name, args, aux);
        if idx < 0 sbv_usage_exit(tprint("Pass '%' not registered!\n", name));
        array_add(out, idx);
    }
    State :: enum { SCAN_NAME; SCAN_ARGS; ARGS_ENDED; SCAN_AUX; AUX_ENDED; }
    state := State.SCAN_NAME;
    pass_begin := 0; args_begin := 0; aux_begin := 0;
    pass_name := ""; aux := "";
    nested_args := 0; nested_aux := 0;
    for idx: 0..p.count - 1 {
        c := p[idx];
        if state == {
            case .SCAN_NAME;
                if c == #char "<" { pass_name = slice(p, pass_begin, idx - pass_begin); args_begin = idx + 1; nested_args += 1; state = .SCAN_ARGS; continue; }
                if c == #char "(" { pass_name = slice(p, pass_begin, idx - pass_begin); aux_begin = idx + 1; nested_aux += 1; state = .SCAN_AUX; aux = ""; continue; }
                if c == #char ">" || c == #char ")" sbv_usage_exit(tprint("Unexpected '%' in pass pipeline.\n", slice(p, idx, 1)));
                if c == 0 || c == #char "," {
                    add(*out, slice(p, pass_begin, idx - pass_begin), "", aux, function_level);
                    pass_begin = idx + 1;
                }
            case .SCAN_ARGS;
                if c == #char "<" { nested_args += 1; continue; }
                if c == #char ">" {
                    nested_args -= 1;
                    if nested_args == 0 { add(*out, pass_name, slice(p, args_begin, idx - args_begin), aux, function_level); state = .ARGS_ENDED; }
                    else if nested_args < 0 sbv_usage_exit("Unexpected '>' in pass pipeline.\n");
                    continue;
                }
                if c == 0 sbv_usage_exit(tprint("Missing '>' in pass pipeline. End-of-string reached while reading arguments for pass '%'.\n", pass_name));
            case .ARGS_ENDED;
                if c == 0 || c == #char "," { pass_begin = idx + 1; aux = ""; state = .SCAN_NAME; }
                else sbv_usage_exit("Expected delimiter or end-of-string after pass arguments.\n");
            case .SCAN_AUX;
                if c == #char "(" { nested_aux += 1; continue; }
                if c == #char ")" {
                    nested_aux -= 1;
                    if nested_aux == 0 { aux = slice(p, aux_begin, idx - aux_begin); state = .AUX_ENDED; }
                    else if nested_aux < 0 sbv_usage_exit("Unexpected ')' in pass pipeline.\n");
                    continue;
                }
                if c == 0 sbv_usage_exit(tprint("Missing ')' in pass pipeline. End-of-string reached while reading arguments for pass '%'.\n", pass_name));
            case .AUX_ENDED;
                if c == 0 { add(*out, pass_name, "", aux, function_level); state = .SCAN_NAME; }
                else if c == #char "," { add(*out, pass_name, "", aux, function_level); pass_begin = idx + 1; aux = ""; state = .SCAN_NAME; }
                else if c == #char "<" { nested_args += 1; args_begin = idx + 1; state = .SCAN_ARGS; }
                else sbv_usage_exit("Expected delimiter, begin-of-args or end-of-string after pass aux argument.\n");
        }
    }
    return out;
}

// SandboxVectorizerPass::SandboxVectorizerPass
sbv_build :: () {
    if sbv.built return;
    sbv.built = true;
    sbv.passes.allocator = context.default_allocator;
    pipeline := ifx sbv_cl.passes == "*" then "seed-collection<tr-save,bottom-up-vec,load-store-vec,tr-accept-or-revert>" else sbv_cl.passes;
    sbv.fpm = sbv_parse_pipeline(pipeline, true);
}

// FunctionPassManager::printPipeline
sbv_print_pipeline :: () {
    sb: String_Builder; sb.allocator = temp;
    append(*sb, "fpm\n");
    for fp: sbv.fpm {
        append(*sb, sbv.passes[fp].name); append(*sb, "\n");
        append(*sb, "rpm\n");
        for rp: sbv.passes[fp].rpm { append(*sb, sbv.passes[rp].name); append(*sb, "\n"); }
    }
    write_string(builder_to_string(*sb,, allocator = temp));
}

// ---------------------------------------------------------------- -sbvec-allow-files (llvm::Regex subset)

// A backtracking matcher for the POSIX ERE subset the option is used with: literals, '.', '[...]' (ranges,
// '^' negation), '*', '+', '?', '^', '$'. Groups, alternation, intervals and escapes fail loudly.
sbv_regex_search :: (re: string, s: string) -> bool {
    for re if it == #char "(" || it == #char ")" || it == #char "|" || it == #char "{" || it == #char "}" || it == #char "\\"
        fatal("sandbox-vectorizer: -sbvec-allow-files regex '%' uses a construct that is not supported yet", re);
    for start: 0..s.count if sbv_regex_match_here(re, 0, s, start) return true;
    return false;
}
// one atom at re[ri]: (end of the atom, does it match s[si])
sbv_regex_atom :: (re: string, ri: s64, s: string, si: s64) -> (s64, bool) {
    if re[ri] == #char "[" {
        k := ri + 1;
        neg := false;
        if k < re.count && re[k] == #char "^" { neg = true; k += 1; }
        matched := false;
        first := true;
        while k < re.count && (re[k] != #char "]" || first) {
            first = false;
            lo := re[k]; hi := lo;
            if k + 2 < re.count && re[k + 1] == #char "-" && re[k + 2] != #char "]" { hi = re[k + 2]; k += 2; }
            if si < s.count && s[si] >= lo && s[si] <= hi matched = true;
            k += 1;
        }
        if k >= re.count fatal("sandbox-vectorizer: unterminated '[' in -sbvec-allow-files regex");
        return k + 1, si < s.count && (matched != neg);
    }
    if re[ri] == #char "." return ri + 1, si < s.count;
    return ri + 1, si < s.count && s[si] == re[ri];
}
sbv_regex_match_here :: (re: string, ri: s64, s: string, si: s64) -> bool {
    if ri == re.count return true;
    if re[ri] == #char "^" { if si != 0 return false; return sbv_regex_match_here(re, ri + 1, s, si); }
    if re[ri] == #char "$" && ri + 1 == re.count return si == s.count;
    end, _ := sbv_regex_atom(re, ri, s, si);
    q: u8 = 0;
    if end < re.count && (re[end] == #char "*" || re[end] == #char "+" || re[end] == #char "?") q = re[end];
    if q == 0 {
        _, ok := sbv_regex_atom(re, ri, s, si);
        return ok && sbv_regex_match_here(re, end, s, si + 1);
    }
    // greedy: count how many characters the atom matches, then back off
    n := 0;
    while true {
        _, ok := sbv_regex_atom(re, ri, s, si + n);
        if !ok break;
        n += 1;
        if q == #char "?" break;
    }
    min := ifx q == #char "+" then 1 else 0;
    k := n;
    while k >= min {
        if sbv_regex_match_here(re, end + 1, s, si + k) return true;
        k -= 1;
    }
    return false;
}

// SandboxVectorizerPass::allowFile
sbv_allow_file :: (path: string) -> bool {
    af := sbv_cl.allow_files;
    delim := 0;
    while true {
        last := ifx delim != 0 then delim + 1 else delim;
        rest := slice(af, last, af.count - last);
        di := find_index_from_left(rest, #char ",");
        name := ifx di >= 0 then slice(rest, 0, di) else rest;
        if name.count == 0 return false;
        if sbv_regex_search(tconcat(".*", name, "$"), path) return true;
        if di < 0 return false;
        delim = last + di;
    }
    return false;
}

// ---------------------------------------------------------------- regions (Region.cpp)

Sbv_Region :: struct {
    insts: [..] Value_Id;      // SetVector
    md: Md_Id;                 // RegionMDN
    aux: [..] Value_Id;
}
sbv_region_new :: () -> Sbv_Region {
    r: Sbv_Region;
    r.insts.allocator = temp; r.aux.allocator = temp;
    ops: [1] Md_Id;
    ops[0] = md_string("sandboxregion");
    r.md = md_tuple(ops, true);   // MDNode::getDistinct
    return r;
}
// Region::addRaw
sbv_region_add :: (r: *Sbv_Region, i: Value_Id) {
    for r.insts if it == i { set_metadata(i, md_kind_id("sandboxvec"), r.md); return; }
    array_add(*r.insts, i);
    set_metadata(i, md_kind_id("sandboxvec"), r.md);
}

// ---------------------------------------------------------------- passes

sbv_run_region_pipeline :: (rpm: [] s32, r: *Sbv_Region) -> bool {
    changed := false;
    for rp: rpm {
        p := *sbv.passes[rp];
        if p.kind == {
            case .NULL_PASS; #through;
            case .TR_SAVE; #through;
            case .TR_ACCEPT; #through;
            case .TR_REVERT; #through;
            case .TR_ACCEPT_OR_REVERT;
                // no region pass ported here changes the IR, so there is nothing to accept or revert
            case .PRINT_INSTRUCTION_COUNT;
                write_string(tprint("InstructionCount: %\n", r.insts.count));
            case .PRINT_REGION;
                write_string("Region dump only available in DEBUG build!");
            case .BOTTOM_UP_VEC; #through;
            case .LOAD_STORE_VEC; #through;
            case .PACK_REUSE;
                fatal("sandbox-vectorizer: the region pass '%' is not supported yet", p.name);
            case; fatal("internal: '%' is not a sandbox region pass", p.name);
        }
    }
    return changed;
}

// SeedCollection::runOnFunction / SeedCollector: seeds are grouped by (getUnderlyingObject(ptr), element type,
// opcode) in a MapVector; only a bundle with two or more seeds can yield a slice for the region pipeline.
sbv_seed_collection :: (f: Value_Id, p: *Sbv_Pass) -> bool {
    collect_stores := find_index_from_left(sbv_cl.collect_seeds, "stores") >= 0;
    collect_loads := find_index_from_left(sbv_cl.collect_seeds, "loads") >= 0;
    if !collect_stores && !collect_loads return false;
    Key :: struct { base: Value_Id; ty: Type_Id; opc: Opcode; }
    for bb: fn_blocks(f) {
        keys: [..] Key; keys.allocator = temp;
        counts: [..] s64; counts.allocator = temp;
        for i: block_insts(bb) {
            o := inst_op(i);
            is_store := o == .STORE && collect_stores;
            is_load := o == .LOAD && collect_loads;
            if is_store || is_load {
                // isValidMemSeed
                ty := load_store_type(i);
                k := type_kind(ty);
                valid := inst_is_simple(i) && k != .X86_FP80 && k != .PPC_FP128 && k != .SVECTOR;
                if valid {
                    elt := ifx k == .VECTOR then type_elem(ty) else ty;
                    valid = is_valid_vector_element_type(elt);
                }
                if valid {
                    base := get_underlying_object(load_store_pointer_operand(i));
                    kt: Type_Id = NONE;
                    if !p.allow_diff_types kt = ifx is_vector_type(ty) then type_elem(ty) else ty;
                    key := Key.{base, kt, o};
                    idx := -1;
                    for keys if it.base == key.base && it.ty == key.ty && it.opc == key.opc { idx = it_index; break; }
                    if idx < 0 { array_add(*keys, key); array_add(*counts, 0); idx = keys.count - 1; }
                    counts[idx] += 1;
                    // SeedContainer::insert: a seed joins the last bundle unless it is full (SeedBundleSizeLimit)
                    if sbv_cl.seed_bundle_size_limit > 1 && (counts[idx] - 1) % cast(s64) sbv_cl.seed_bundle_size_limit != 0
                        fatal("sandbox-vectorizer: seed collection with a seed bundle of two or more seeds (vectorizing a seed slice) is not supported yet");
                }
            }
            // totalNumSeedGroups() > SeedGroupsLimit
            if cast(u64) keys.count > sbv_cl.seed_groups_limit break;
        }
    }
    return false;
}

sbv_regions_from_bbs :: (f: Value_Id, p: *Sbv_Pass) -> bool {
    regions: [..] Sbv_Region; regions.allocator = temp;
    for bb: fn_blocks(f) {
        r := sbv_region_new();
        for i: block_insts(bb) sbv_region_add(*r, i);
        array_add(*regions, r);
    }
    for * r: regions sbv_run_region_pipeline(p.rpm, r);
    return false;
}

sbv_regions_from_metadata :: (f: Value_Id, p: *Sbv_Pass) -> bool {
    regions: [..] Sbv_Region; regions.allocator = temp;
    md_of: [..] Md_Id; md_of.allocator = temp;   // MDNToRegion (lookups only)
    kind := md_kind_id("sandboxvec");
    aux_kind := md_kind_id("sandboxaux");
    for bb: fn_blocks(f) for i: block_insts(bb) {
        r := -1;
        m := get_metadata(i, kind);
        if m != NONE {
            for md_of if it == m { r = it_index; break; }
            if r < 0 { array_add(*regions, sbv_region_new()); array_add(*md_of, m); r = regions.count - 1; }
            sbv_region_add(*regions[r], i);
        }
        am := get_metadata(i, aux_kind);
        if am != NONE {
            if r < 0 {
                print_stderr("No region specified for Aux: '%'\n", inst_to_string(i));
                print_stderr("LLVM ERROR: No region specified for Aux!\n");
                exit(1);
            }
            ap := ir.mds[md_op(am, 0)].value;
            idx := ap_sext_value(const_ap(ap));
            rr := *regions[r];
            while rr.aux.count <= idx array_add(*rr.aux, NONE);
            rr.aux[idx] = i;
            sbv_region_add(rr, i);
        }
    }
    changed := false;
    for * r: regions changed |= sbv_run_region_pipeline(p.rpm, r);
    return changed;
}

sandbox_vectorizer_run :: (f: Value_Id) -> Preserved {
    sbv_build();
    t := tti_get(f);
    aa_results_for(f);   // AM.getResult<AAManager>(F)
    get_scev(f);         // AM.getResult<ScalarEvolutionAnalysis>(F)
    if sbv_cl.print_pass_pipeline { sbv_print_pipeline(); return PRESERVE_ALL; }
    if sbv_cl.allow_files != ".*" && !sbv_allow_file(ir.source_filename) return PRESERVE_ALL;
    if tti_number_of_registers(t, tti_register_class_for_type(t, true)) == 0 return PRESERVE_ALL;
    if fn_has_fn_attr(f, .NoImplicitFloat) return PRESERVE_ALL;
    changed := false;
    for fp: sbv.fpm {
        p := *sbv.passes[fp];
        if p.kind == {
            case .SEED_COLLECTION; changed |= sbv_seed_collection(f, p);
            case .REGIONS_FROM_BBS; changed |= sbv_regions_from_bbs(f, p);
            case .REGIONS_FROM_METADATA; changed |= sbv_regions_from_metadata(f, p);
            case; fatal("internal: '%' is not a sandbox function pass", p.name);
        }
    }
    if !changed return PRESERVE_ALL;
    return preserved_cfg();
}
