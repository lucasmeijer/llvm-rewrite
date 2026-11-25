// SandboxVectorizer (`sandbox-vectorizer`): port of
// llvm/lib/Transforms/Vectorize/SandboxVectorizer/SandboxVectorizer.cpp (pass construction, allowFile, runImpl),
// SandboxVectorizerPassBuilder.cpp and Passes/PassRegistry.def, llvm/include/llvm/SandboxIR/PassManager.h and
// llvm/lib/SandboxIR/PassManager.cpp (setPassPipeline's parser, printPipeline, the pass managers),
// llvm/lib/SandboxIR/Region.cpp + RegionWithScore.cpp (regions as !sandboxvec / !sandboxaux metadata, the create /
// erase callbacks, the ScoreBoard), Passes/RegionsFromBBs.cpp, Passes/RegionsFromMetadata.cpp,
// Passes/SeedCollection.cpp + SeedCollector.cpp (SeedBundle, MemSeedBundle, SeedContainer, SeedCollector),
// Passes/NullPass.h, Passes/PrintInstructionCount.h, Passes/PrintRegion.h, Passes/TransactionSave.cpp,
// Passes/TransactionAlwaysAccept.h, Passes/TransactionAlwaysRevert.h and Passes/TransactionAcceptOrRevert.cpp.
// The transforming region passes are in sandbox_passes.jai, the dependency graph and scheduler in
// sandbox_sched.jai, the Tracker / callbacks / IR edits of SandboxIR in sandbox_ir.jai.
//
// Design (DESIGN.md "SandboxVectorizer"): SandboxIR is not built as a second object graph. A sandbox pass is a row of
// `Sbv_Pass` (kind tag + name + aux argument + its region-pass list + the pass object's state), the pipelines are
// rows in one table, and every "virtual" runOnFunction / runOnRegion / printPipeline is a `switch` on the kind.
// Regions are `Sbv_Region` rows (an instruction SetVector + the region's distinct MDNode + Aux + the ScoreBoard),
// alive between their construction and destruction, with their callbacks registered in sbx.callbacks.
//
// Address reuse (the seed collector): SeedContainer finds the bundle of an erased load/store through a DenseMap
// keyed by sandboxir::Instruction pointers. A seed that is erased and accepted is freed; an instruction created
// later can get its address, and erasing *that* one (e.g. when a transaction is reverted) marks the old seed used a
// second time, inflating UsedLaneCount. We cannot know whether the allocator reused the address, so every bundle
// that could have been hit counts the possible extra marks (`maybe_extra`) and the queries whose answer they could
// change (allUsed, getNumUnusedBits) fail loudly when they would.

sbv_cl: struct {
    print_pass_pipeline := false;    // -sbvec-print-pass-pipeline
    passes := "*";                   // -sbvec-passes ("*" = the default pipeline)
    allow_files := ".*";             // -sbvec-allow-files
    vec_reg_bits: u64 = 0;           // -sbvec-vec-reg-bits
    allow_non_pow2 := false;         // -sbvec-allow-non-pow2
    collect_seeds := "stores";       // -sbvec-collect-seeds
    seed_bundle_size_limit: u64 = 32;   // -sbvec-seed-bundle-size-limit
    seed_groups_limit: u64 = 256;       // -sbvec-seed-groups-limit
    stop_at: u64 = SBV_DISABLED;        // -sbvec-stop-at
    stop_bndl: u64 = SBV_DISABLED;      // -sbvec-stop-bndl
    cost_threshold: s32 = 0;            // -sbvec-cost-threshold
}
SBV_DISABLED :: 0xFFFF_FFFF_FFFF_FFFF;   // std::numeric_limits<unsigned long>::max()

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
        case "sbvec-stop-at"; sbv_cl.stop_at = cast(u64) smisc_int(name, value, has_value);
        case "sbvec-stop-bndl"; sbv_cl.stop_bndl = cast(u64) smisc_int(name, value, has_value);
        case "sbvec-cost-threshold"; sbv_cl.cost_threshold = cast(s32) smisc_int(name, value, has_value);
        case; return false;
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
    invocation_cnt: u64;        // bottom-up-vec: BottomUpInvocationCnt (for -sbvec-stop-at)
    pack_reuse_change: bool;    // pack-reuse: its Change member (never reset)
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

// ---------------------------------------------------------------- regions (Region.cpp, RegionWithScore.cpp)

Sbv_Region :: struct {
    insts: [..] Value_Id;            // SetVector
    in_set: Table(Value_Id, bool);
    md: Md_Id;                       // RegionMDN
    aux: [..] Value_Id;
    after_cost: Cost;                // ScoreBoard
    before_cost: Cost;
    cb_create: s64; cb_erase: s64;
    live: bool;
}
sbv_regions: [..] Sbv_Region;
sbv_tti: *Tti;
sbv_aar_storage: Aa_Results;
sbv_aar: *Aa_Results;

// RegionWithScore(Ctx, TTI)
sbv_region_new :: () -> s32 {
    r: Sbv_Region;
    r.insts.allocator = temp; r.aux.allocator = temp; r.in_set.allocator = temp;
    ops: [1] Md_Id;
    ops[0] = md_string("sandboxregion");
    r.md = md_tuple(ops, true);   // MDNode::getDistinct
    r.live = true;
    array_add(*sbv_regions, r);
    idx := cast(s32) sbv_regions.count - 1;
    sbv_regions[idx].cb_create = sbx_register_callback(.CREATE, .REGION, idx);
    sbv_regions[idx].cb_erase = sbx_register_callback(.ERASE, .REGION, idx);
    return idx;
}
// ~Region
sbv_region_delete :: (r: s32) {
    sbx_unregister_callback(sbv_regions[r].cb_create);
    sbx_unregister_callback(sbv_regions[r].cb_erase);
    sbv_regions[r].live = false;
}
sbv_region_contains :: (r: s32, i: Value_Id) -> bool { return table_contains(*sbv_regions[r].in_set, i); }

// Region::addRaw
sbv_region_add_raw :: (r: s32, i: Value_Id) {
    rg := *sbv_regions[r];
    if !table_contains(*rg.in_set, i) { array_add(*rg.insts, i); table_set(*rg.in_set, i, true); }
    set_metadata(i, md_kind_id("sandboxvec"), rg.md);
}
// ScoreBoard::getCost
sbv_cost :: (i: Value_Id) -> Cost { return tti_instruction_cost(sbv_tti, i, TCK_RECIP_THROUGHPUT); }
// RegionWithScore::add
sbv_region_add :: (r: s32, i: Value_Id) {
    sbv_region_add_raw(r, i);
    sbv_regions[r].after_cost = cost_add(sbv_regions[r].after_cost, sbv_cost(i));
}
// the erase callback: RegionWithScore::remove (ScoreBoard::remove, Region::remove), then removeFromAux
sbv_region_on_erase :: (r: s32, i: Value_Id) {
    c := sbv_cost(i);
    rg := *sbv_regions[r];
    if sbv_region_contains(r, i) rg.after_cost = cost_sub(rg.after_cost, c);
    else rg.before_cost = cost_add(rg.before_cost, c);
    if table_contains(*rg.in_set, i) {
        table_remove(*rg.in_set, i);
        for rg.insts if it == i { array_ordered_remove_by_index(*rg.insts, it_index); break; }
    }
    set_metadata(i, md_kind_id("sandboxvec"), NONE);
    for rg.aux if it == i {
        set_metadata(i, md_kind_id("sandboxaux"), NONE);
        array_ordered_remove_by_index(*rg.aux, it_index);
        break;
    }
}
// Region::setAux(ArrayRef<Instruction *>)
sbv_region_set_aux_list :: (r: s32, aux: [] Value_Id) {
    sbv_regions[r].aux.count = 0;
    array_add(*sbv_regions[r].aux, ..aux);
    for aux {
        ops: [1] Md_Id;
        ops[0] = md_value(const_int(ir.t_i32, cast(u64) it_index));
        set_metadata(it, md_kind_id("sandboxaux"), md_tuple(ops, false));
        sbv_region_add_raw(r, it);
    }
}
// Region::setAux(Idx, I)
sbv_region_set_aux :: (r: s32, idx: s64, i: Value_Id) {
    rg := *sbv_regions[r];
    while rg.aux.count <= idx array_add(*rg.aux, NONE);
    rg.aux[idx] = i;
    sbv_region_add_raw(r, i);
}
// Region::clearAux
sbv_region_clear_aux :: (r: s32) {
    for sbv_regions[r].aux set_metadata(it, md_kind_id("sandboxaux"), NONE);
    sbv_regions[r].aux.count = 0;
}

// RegionPassManager::runOnRegion
sbv_run_region_pipeline :: (rpm: [] s32, r: s32) -> bool {
    changed := false;
    for rp: rpm {
        p := *sbv.passes[rp];
        if p.kind == {
            case .NULL_PASS;
            case .PRINT_INSTRUCTION_COUNT;
                write_string(tprint("InstructionCount: %\n", sbv_regions[r].insts.count));
            case .PRINT_REGION;
                write_string("Region dump only available in DEBUG build!");
            case .TR_SAVE;
                sbx_save();
            case .TR_ACCEPT;
                has := sbx.changes.count > 0;
                sbx_accept();
                changed |= has;
            case .TR_REVERT;
                has := sbx.changes.count > 0;
                sbx_revert();
                changed |= has;
            case .TR_ACCEPT_OR_REVERT;
                rg := *sbv_regions[r];
                d := cost_sub(rg.after_cost, rg.before_cost);
                if cost_valid(d) && d < -cast(Cost) sbv_cl.cost_threshold {
                    has := sbx.changes.count > 0;
                    sbx_accept();
                    changed |= has;
                } else {
                    sbx_revert();
                }
            case .BOTTOM_UP_VEC; changed |= sbv_bottom_up_vec(p, r);
            case .LOAD_STORE_VEC; changed |= sbv_load_store_vec(p, r);
            case .PACK_REUSE; changed |= sbv_pack_reuse(p, r);
            case; fatal("internal: '%' is not a sandbox region pass", p.name);
        }
    }
    return changed;
}

// ---------------------------------------------------------------- seeds (SeedCollector.cpp)

Sbv_Seed_Bundle :: struct {
    seeds: [..] Value_Id;
    used: [..] bool;          // UsedLanes
    used_count: s64;          // UsedLaneCount
    unused_bits: u32;         // NumUnusedBits
    maybe_extra: s64;         // see the file header (address reuse)
}
Sbv_Seed_Container :: struct {
    is_load: bool;
    key_base: [..] Value_Id;  // MapVector<{Ptr, Ty, Opcode}, bundles>
    key_ty: [..] Type_Id;
    key_bundles: [..] [..] s32;
    lookup: Table(Value_Id, s32);   // SeedLookupMap
}
sbv_seeds: struct {
    bundles: [..] Sbv_Seed_Bundle;
    stores: Sbv_Seed_Container;
    loads: Sbv_Seed_Container;
    freed_at: Table(Value_Id, s64);   // seed -> the number of values that existed when LLVM freed its object
    cb: s64;
    active: bool;
}

sbv_bundle_is_used :: (b: *Sbv_Seed_Bundle, e: s64) -> bool { return e < b.used.count && b.used[e]; }
// SeedBundle::setUsed(ElementIdx, 1, VerifyUnused)
sbv_bundle_set_used :: (b: *Sbv_Seed_Bundle, e: s64) {
    while b.used.count <= e array_add(*b.used, false);
    b.used[e] = true;
    b.used_count += 1;
    b.unused_bits -= sbv_num_bits(b.seeds[e]);
}
sbv_bundle_first_unused :: (b: *Sbv_Seed_Bundle) -> s64 {
    for 0..b.seeds.count - 1 if !sbv_bundle_is_used(b, it) return it;
    return b.seeds.count;
}
// SeedBundle::allUsed; `matters_if_all_used`: whether a false answer while every lane is used changes what LLVM
// does (it does in SeedContainer::iterator::skipUsed, not in the slicing loops, which then find nothing to do)
sbv_bundle_all_used :: (b: *Sbv_Seed_Bundle, matters_if_all_used: bool) -> bool {
    n := b.seeds.count;
    if b.maybe_extra > 0 {
        if b.used_count < n && b.used_count + b.maybe_extra >= n
            fatal("sandbox-vectorizer: whether a seed bundle is used up depends on allocator address reuse (see sandbox_vectorizer.jai)");
        if b.used_count >= n && matters_if_all_used
            fatal("sandbox-vectorizer: whether a seed bundle is used up depends on allocator address reuse (see sandbox_vectorizer.jai)");
    }
    return b.used_count == n;
}
sbv_bundle_unused_bits :: (b: *Sbv_Seed_Bundle) -> u32 {
    if b.maybe_extra > 0 fatal("sandbox-vectorizer: the unused bits of a seed bundle depend on allocator address reuse (see sandbox_vectorizer.jai)");
    return b.unused_bits;
}

// SeedContainer::erase (the SeedCollector's erase callback)
sbv_seeds_on_erase :: (i: Value_Id) {
    o := inst_op(i);
    if o != .STORE && o != .LOAD return;
    c := ifx o == .STORE then *sbv_seeds.stores else *sbv_seeds.loads;
    found, bi := table_find(*c.lookup, i);
    if found {
        b := *sbv_seeds.bundles[bi];
        for b.seeds if it == i { sbv_bundle_set_used(b, it_index); break; }
        return;
    }
    // `i` was created after the seeds were collected: it may sit at the address of a seed freed before it existed
    for kb: c.key_bundles for bi2: kb {
        b := *sbv_seeds.bundles[bi2];
        for s: b.seeds {
            found2, at := table_find(*sbv_seeds.freed_at, s);
            if found2 && cast(s64) i >= at { b.maybe_extra += 1; break; }
        }
    }
}
// a seed's sandboxir object is freed (erase without tracking, or an accepted erase)
sbv_note_freed :: (i: Value_Id, value_count: s64) {
    if !sbv_seeds.active return;
    c := ifx inst_op(i) == .STORE then *sbv_seeds.stores else *sbv_seeds.loads;
    if inst_op(i) != .STORE && inst_op(i) != .LOAD return;
    if table_contains(*c.lookup, i) table_set(*sbv_seeds.freed_at, i, value_count);
}

// MemSeedBundle::insert: llvm::upper_bound with Utils::atLowerAddress
sbv_bundle_insert :: (b: *Sbv_Seed_Bundle, i: Value_Id) {
    first := 0;
    len := b.seeds.count;
    while len > 0 {
        half := len >> 1;
        mid := first + half;
        if sbv_at_lower_address(i, b.seeds[mid]) len = half;
        else { first = mid + 1; len = len - half - 1; }
    }
    array_insert_at(*b.seeds, i, first);
    b.unused_bits += sbv_num_bits(i);
}

// SeedContainer::insert
sbv_seeds_insert :: (c: *Sbv_Seed_Container, i: Value_Id, allow_diff_types: bool) {
    base := get_underlying_object(load_store_pointer_operand(i));
    ty: Type_Id = NONE;
    if !allow_diff_types ty = scalar_type(sbv_expected_type(i));
    k := -1;
    for c.key_base if it == base && c.key_ty[it_index] == ty { k = it_index; break; }
    if k < 0 {
        array_add(*c.key_base, base); array_add(*c.key_ty, ty);
        kb: [..] s32; kb.allocator = temp;
        array_add(*c.key_bundles, kb);
        k = c.key_base.count - 1;
    }
    kb := *c.key_bundles[k];
    if kb.count == 0 || cast(u64) sbv_seeds.bundles[kb.*[kb.count - 1]].seeds.count == sbv_cl.seed_bundle_size_limit {
        b: Sbv_Seed_Bundle;
        b.seeds.allocator = temp; b.used.allocator = temp;
        array_add(*b.seeds, i);
        b.unused_bits = sbv_num_bits(i);
        array_add(*sbv_seeds.bundles, b);
        array_add(kb, cast(s32) sbv_seeds.bundles.count - 1);
    } else {
        sbv_bundle_insert(*sbv_seeds.bundles[kb.*[kb.count - 1]], i);
    }
    table_set(*c.lookup, i, kb.*[kb.count - 1]);
}

// isValidMemSeed
sbv_is_valid_mem_seed :: (i: Value_Id) -> bool {
    if !inst_is_simple(i) return false;
    ty := sbv_expected_type(i);
    k := type_kind(ty);
    if k == .X86_FP80 || k == .PPC_FP128 return false;
    if k == .SVECTOR return false;
    if k == .VECTOR return is_valid_vector_element_type(type_elem(ty));
    return is_valid_vector_element_type(ty);
}

sbv_container_init :: (c: *Sbv_Seed_Container, is_load: bool) {
    c.* = .{};
    c.is_load = is_load;
    c.key_base.allocator = temp; c.key_ty.allocator = temp; c.key_bundles.allocator = temp;
    c.lookup.allocator = temp;
}

// SeedCollector::SeedCollector
sbv_seed_collector_new :: (bb: Value_Id, collect_stores: bool, collect_loads: bool, allow_diff_types: bool) {
    sbv_temp_array(*sbv_seeds.bundles);
    sbv_container_init(*sbv_seeds.stores, false);
    sbv_container_init(*sbv_seeds.loads, true);
    sbv_seeds.freed_at = .{}; sbv_seeds.freed_at.allocator = temp;
    sbv_seeds.active = false;
    if !collect_stores && !collect_loads return;
    sbv_seeds.active = true;
    sbv_seeds.cb = sbx_register_callback(.ERASE, .SEED_COLLECTOR, 0);
    for i: block_insts(bb) {
        o := inst_op(i);
        if o == .STORE && collect_stores && sbv_is_valid_mem_seed(i) sbv_seeds_insert(*sbv_seeds.stores, i, allow_diff_types);
        if o == .LOAD && collect_loads && sbv_is_valid_mem_seed(i) sbv_seeds_insert(*sbv_seeds.loads, i, allow_diff_types);
        if sbv_seeds.stores.key_base.count + sbv_seeds.loads.key_base.count > cast(s64) sbv_cl.seed_groups_limit break;
    }
}
sbv_seed_collector_delete :: () {
    if sbv_seeds.active sbx_unregister_callback(sbv_seeds.cb);
    sbv_seeds.active = false;
}

// SeedContainer::iterator: (key, index in the key's bundles); key == number of keys is end()
Sbv_Seed_It :: struct { key: s64; idx: s64; }
sbv_it_skip_used :: (c: *Sbv_Seed_Container, it: *Sbv_Seed_It) {
    while it.key < c.key_bundles.count && it.idx < c.key_bundles[it.key].count &&
          sbv_bundle_all_used(*sbv_seeds.bundles[c.key_bundles[it.key][it.idx]], true)
        sbv_it_advance_raw(c, it);
}
sbv_it_advance_raw :: (c: *Sbv_Seed_Container, it: *Sbv_Seed_It) {
    it.idx += 1;
    if it.idx >= c.key_bundles[it.key].count {
        it.idx = 0;
        it.key += 1;
    }
}
sbv_it_begin :: (c: *Sbv_Seed_Container) -> Sbv_Seed_It {
    it := Sbv_Seed_It.{0, 0};
    if c.key_bundles.count == 0 return .{c.key_bundles.count, 0};
    sbv_it_skip_used(c, *it);
    return it;
}

// SeedBundle::getSlice
sbv_bundle_get_slice :: (b: *Sbv_Seed_Bundle, start: s64, max_bits: u32, force_pow2: bool) -> [] Value_Id {
    bit_count: u32 = 0;
    num: s64 = 0;
    num_pow2: s64 = 0;
    for k: start..b.seeds.count - 1 {
        if sbv_bundle_is_used(b, start + num) break;
        bits := sbv_num_bits(b.seeds[k]);
        if bit_count + bits > max_bits break;
        num += 1;
        bit_count += bits;
        if force_pow2 && sbv_is_pow2(bit_count) num_pow2 = num;
    }
    if force_pow2 num = num_pow2;
    if num > 1 { r: [] Value_Id; r.data = b.seeds.data + start; r.count = num; return r; }
    return .[];
}

sbv_vec_reg_bits_for :: () -> u32 {
    if sbv_cl.vec_reg_bits != 0 return cast(u32) sbv_cl.vec_reg_bits;
    // getLoadStoreVecRegBitWidth(AS): X86 ignores the address space; the default is 128
    if sbv_tti.kind == .X86 return cast(u32) tti_register_bit_width(sbv_tti, RGK_FIXED_WIDTH_VECTOR);
    return 128;
}

// SeedCollection::runOnFunction
sbv_seed_collection :: (f: Value_Id, p: *Sbv_Pass) -> bool {
    change := false;
    collect_stores := find_index_from_left(sbv_cl.collect_seeds, "stores") >= 0;
    collect_loads := find_index_from_left(sbv_cl.collect_seeds, "loads") >= 0;
    for bb: fn_blocks(f) {
        sbv_seed_collector_new(bb, collect_stores, collect_loads, p.allow_diff_types);
        defer sbv_seed_collector_delete();
        // `for (auto &SeedRange : {SC.getStoreSeeds(), SC.getLoadSeeds()})`: both ranges, and so both begin()s,
        // are made before any seed is used
        begins: [2] Sbv_Seed_It;
        begins[0] = sbv_it_begin(*sbv_seeds.stores);
        begins[1] = sbv_it_begin(*sbv_seeds.loads);
        for range: 0..1 {
            c := ifx range == 0 then *sbv_seeds.stores else *sbv_seeds.loads;
            it := begins[range];
            while it.key < c.key_bundles.count {
                bi := c.key_bundles[it.key][it.idx];
                change |= sbv_slice_bundle(bi, p);
                sbv_it_advance_raw(c, *it);
                sbv_it_skip_used(c, *it);
            }
        }
    }
    return change;
}

// the body of SeedCollection::runOnFunction for one bundle
sbv_slice_bundle :: (bi: s32, p: *Sbv_Pass) -> bool {
    change := false;
    b := *sbv_seeds.bundles[bi];
    first := sbv_bundle_first_unused(b);
    if first >= b.seeds.count fatal("sandbox-vectorizer: a used-up seed bundle is visited (LLVM reads past its end)");
    elm_bits := sbv_num_bits_type(sbv_element_type(sbv_expected_type(b.seeds[first])));
    if elm_bits == 0 fatal("sandbox-vectorizer: a zero-sized seed element (LLVM divides by zero)");
    vec_reg_bits := sbv_vec_reg_bits_for();
    divide_by_2 :: (n: u32) -> u32 { fl := sbv_floor_pow2(n); if fl == n return fl / 2; return fl; }
    slice_elms := min(vec_reg_bits / elm_bits, sbv_bundle_unused_bits(b) / elm_bits);
    while slice_elms >= 2 {
        b = *sbv_seeds.bundles[bi];
        if sbv_bundle_all_used(b, false) break;
        offset := sbv_bundle_first_unused(b);
        oe := b.seeds.count;
        while offset + 1 < oe {
            b = *sbv_seeds.bundles[bi];
            if sbv_bundle_is_used(b, offset) { offset += 1; continue; }
            if sbv_bundle_all_used(b, false) break;
            slice := sbv_bundle_get_slice(b, offset, slice_elms * elm_bits, !sbv_cl.allow_non_pow2);
            if slice.count == 0 { offset += 1; continue; }
            slice_copy := sbv_copy(slice);
            r := sbv_region_new();
            sbv_region_set_aux_list(r, slice_copy);
            change |= sbv_run_region_pipeline(p.rpm, r);
            sbv_region_clear_aux(r);
            sbv_region_delete(r);
            offset += 1;
        }
        slice_elms = divide_by_2(slice_elms);
    }
    return change;
}

// RegionsFromBBs::runOnFunction
sbv_regions_from_bbs :: (f: Value_Id, p: *Sbv_Pass) -> bool {
    regions: [..] s32; regions.allocator = temp;
    for bb: fn_blocks(f) {
        r := sbv_region_new();
        array_add(*regions, r);
        for i: block_insts(bb) sbv_region_add(r, i);
    }
    for regions sbv_run_region_pipeline(p.rpm, it);
    for regions sbv_region_delete(it);
    return false;
}

// RegionsFromMetadata::runOnFunction (Region::createRegionsFromMD)
sbv_regions_from_metadata :: (f: Value_Id, p: *Sbv_Pass) -> bool {
    regions: [..] s32; regions.allocator = temp;
    md_of: [..] Md_Id; md_of.allocator = temp;   // MDNToRegion (lookups only)
    kind := md_kind_id("sandboxvec");
    aux_kind := md_kind_id("sandboxaux");
    for bb: fn_blocks(f) for i: block_insts(bb) {
        r: s32 = -1;
        m := get_metadata(i, kind);
        if m != NONE {
            for md_of if it == m { r = regions[it_index]; break; }
            if r < 0 { r = sbv_region_new(); array_add(*regions, r); array_add(*md_of, m); }
            sbv_region_add_raw(r, i);
        }
        am := get_metadata(i, aux_kind);
        if am != NONE {
            if r < 0 {
                print_stderr("No region specified for Aux: '%'\n", inst_to_string(i));
                print_stderr("LLVM ERROR: No region specified for Aux!\n");
                exit(1);
            }
            ap := ir.mds[md_op(am, 0)].value;
            sbv_region_set_aux(r, ap_sext_value(const_ap(ap)), i);
        }
    }
    changed := false;
    for regions changed |= sbv_run_region_pipeline(p.rpm, it);
    for regions sbv_region_delete(it);
    return changed;
}

sandbox_vectorizer_run :: (f: Value_Id) -> Preserved {
    sbv_build();
    sbx_init();
    t := tti_get(f);
    sbv_tti = t;
    sbv_aar_storage = aa_results_for(f);   // AM.getResult<AAManager>(F)
    sbv_aar = *sbv_aar_storage;
    get_scev(f);         // AM.getResult<ScalarEvolutionAnalysis>(F)
    if sbv_cl.print_pass_pipeline { sbv_print_pipeline(); return PRESERVE_ALL; }
    if sbv_cl.allow_files != ".*" && !sbv_allow_file(ir.source_filename) return PRESERVE_ALL;
    if tti_number_of_registers(t, tti_register_class_for_type(t, true)) == 0 return PRESERVE_ALL;
    if fn_has_fn_attr(f, .NoImplicitFloat) return PRESERVE_ALL;
    sbv_temp_array(*sbv_regions);
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
