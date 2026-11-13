// `--preserve-ll-uselistorder`: the `uselistorder` directives of the textual printer. A port of orderValue,
// orderModule, predictValueUseListOrder, predictUseListOrder, printUseListOrder and printUseLists from
// llvm/lib/IR/AsmWriter.cpp.
//
// LLVM 23 differences the port has to undo: a blockaddress has no operands (ours uses its function and block), and
// ConstantData has no use list (it is never ordered, so it never gets a directive).

preserve_ll_uselistorder := false;   // -preserve-ll-uselistorder

Ulo_Order :: struct {
    ids: Table(Value_Id, u32);   // OrderMap (MapVector): 1-based ids
    order: [..] Value_Id;        // its insertion order
}
Ulo_Entry :: struct { v: Value_Id; shuffle: [..] u32; }
Ulo_State :: struct {
    computed: bool;
    module_level: [..] Ulo_Entry;            // ULOM[nullptr]
    per_fn: Table(Value_Id, [..] Ulo_Entry); // ULOM[F]
}
ulo: Ulo_State;

ulo_id :: (om: *Ulo_Order, v: Value_Id) -> u32 { _, id := table_find(*om.ids, v); return id; }

// orderValue
ulo_order_value :: (v: Value_Id, om: *Ulo_Order) {
    if v == NONE || ulo_id(om, v) != 0 return;
    k := vkind(v);
    if is_constant_kind(k) {
        if is_constant_data_kind(k) return;
        if !is_global_value(k) && k != .C_BLOCKADDR {
            n := nops(v);
            if n > 0 for i: 0..n-1 {
                o := op(v, i);
                if o == NONE continue;
                ok := vkind(o);
                if ok != .BLOCK && !is_global_value(ok) ulo_order_value(o, om);
            }
        }
    }
    array_add(*om.order, v);
    table_set(*om.ids, v, cast(u32) om.order.count);
}

// orderModule
ulo_order_module :: () -> Ulo_Order {
    om: Ulo_Order;
    om.ids.allocator = temp; om.order.allocator = temp;
    order_constant_value :: (v: Value_Id, om: *Ulo_Order) {
        if v != NONE && (is_constant_kind(vkind(v)) || vkind(v) == .INLINE_ASM) ulo_order_value(v, om);
    }
    for g: ir.m_globals {
        if glob(g).has_init {
            init := op(g, 0);
            if !is_global_value(vkind(init)) ulo_order_value(init, *om);
        }
        ulo_order_value(g, *om);
    }
    for a: ir.m_aliases {
        x := op(a, 0);
        if !is_global_value(vkind(x)) ulo_order_value(x, *om);
        ulo_order_value(a, *om);
    }
    for a: ir.m_ifuncs {
        x := op(a, 0);
        if !is_global_value(vkind(x)) ulo_order_value(x, *om);
        ulo_order_value(a, *om);
    }
    for f: ir.m_functions {
        n := nops(f);
        if n > 0 for i: 0..n-1 {
            o := op(f, i);
            if o != NONE && !is_global_value(vkind(o)) ulo_order_value(o, *om);
        }
        ulo_order_value(f, *om);
        if is_declaration(f) continue;
        na := glob(f).nargs;
        if na > 0 for ai: 0..na-1 ulo_order_value(fn_arg(f, cast(u32) ai), *om);
        for bb: fn_blocks(f) {
            ulo_order_value(bb, *om);
            for i: block_insts(bb) {
                x := inst(i).records;
                while x != 0 {
                    rec := ir.dbg_records[x - 1];
                    if rec.kind != .LABEL {
                        vals: [..] Value_Id; vals.allocator = temp;
                        dbgr_values_of_loc(rec.loc, *vals);
                        if rec.kind == .ASSIGN && rec.addr != NONE dbgr_values_of_loc(rec.addr, *vals);
                        for vals order_constant_value(it, *om);
                    }
                    x = rec.next;
                }
                m := nops(i);
                if m > 0 for k: 0..m-1 {
                    o := op(i, k);
                    if o == NONE continue;
                    // skipMetadataWrapper
                    if vkind(o) == .MD_VALUE {
                        md := ir.v_aux[o];
                        if md != NONE && ir.mds[md].kind == .VALUE o = ir.mds[md].value;
                    }
                    ok := vkind(o);
                    if (is_constant_kind(ok) && !is_global_value(ok)) || ok == .INLINE_ASM ulo_order_value(o, *om);
                }
                ulo_order_value(i, *om);
            }
        }
    }
    return om;
}

// the uses of v as LLVM 23 has them (a blockaddress is not a user)
ulo_uses :: (v: Value_Id, out: *[..] Use_Id) {
    u := ir.v_first_use[v];
    while u != NONE {
        if vkind(ir.u_user[u]) != .C_BLOCKADDR array_add(out, u);
        u = ir.u_next[u];
    }
}

// predictValueUseListOrder
ulo_predict_value :: (v: Value_Id, id_in: u32, om: *Ulo_Order) -> [..] u32 {
    Entry :: struct { u: Use_Id; idx: u32; uid: u32; opno: u32; }
    uses: [..] Use_Id; uses.allocator = temp;
    ulo_uses(v, *uses);
    list: [..] Entry; list.allocator = temp;
    for u: uses {
        uid := ulo_id(om, ir.u_user[u]);
        if uid != 0 array_add(*list, .{u, cast(u32) list.count, uid, u - ir.v_ops[ir.u_user[u]]});
    }
    none: [..] u32; none.allocator = temp;
    if list.count < 2 return none;
    gets_reversed := vkind(v) != .BLOCK;
    id := id_in;
    if vkind(v) == .C_BLOCKADDR id = ulo_id(om, op(v, 1));
    less :: (l: Entry, r: Entry, gets_reversed: bool, id: u32) -> bool {
        if l.u == r.u return false;
        if l.uid < r.uid { if gets_reversed && r.uid <= id return true; return false; }
        if r.uid < l.uid { if gets_reversed && l.uid <= id return false; return true; }
        if gets_reversed && l.uid <= id return l.opno < r.opno;
        return l.opno > r.opno;
    }
    // llvm::sort with a total order on distinct uses: any correct sort gives the same result
    for i: 1..list.count-1 {
        x := list[i]; j := i;
        while j > 0 && less(x, list[j-1], gets_reversed, id) { list[j] = list[j-1]; j -= 1; }
        list[j] = x;
    }
    sorted := true;
    for i: 1..list.count-1 if list[i].idx < list[i-1].idx { sorted = false; break; }
    if sorted return none;
    shuffle: [..] u32; shuffle.allocator = temp;
    for list array_add(*shuffle, it.idx);
    return shuffle;
}

// predictUseListOrder
ulo_compute :: () {
    ulo = .{};
    ulo.computed = true;
    ulo.module_level.allocator = temp;
    ulo.per_fn.allocator = temp;
    om := ulo_order_module();
    for v, k: om.order {
        if !has_uses(v) continue;
        uses: [..] Use_Id; uses.allocator = temp;
        ulo_uses(v, *uses);
        if uses.count < 2 continue;
        sh := ulo_predict_value(v, cast(u32)(k + 1), *om);
        if sh.count == 0 continue;
        f: Value_Id = NONE;
        kind := vkind(v);
        if kind == .INST f = block_fn(inst_block(v));
        else if kind == .ARGUMENT f = value_function(v);
        else if kind == .BLOCK f = block_fn(v);
        if f == NONE { array_add(*ulo.module_level, .{v, sh}); continue; }
        p := table_find_pointer(*ulo.per_fn, f);
        if !p {
            e: [..] Ulo_Entry; e.allocator = temp;
            table_set(*ulo.per_fn, f, e);
            p = table_find_pointer(*ulo.per_fn, f);
        }
        array_add(p, .{v, sh});
    }
}

// printUseLists(F) (F = NONE: the global use-lists)
print_use_lists :: (f: Value_Id) {
    if !preserve_ll_uselistorder return;
    if !ulo.computed ulo_compute();
    entries: [] Ulo_Entry;
    if f == NONE entries = ulo.module_level;
    else { p := table_find_pointer(*ulo.per_fn, f); if !p return; entries = p.*; }
    if entries.count == 0 return;
    out("\n; uselistorder directives\n");
    for entries {
        if f != NONE out("  ");
        out("uselistorder ");
        write_operand(it.v, true);
        out(", { ");
        for s, i: it.shuffle { if i > 0 out(", "); out_u64(s); }
        out(" }\n");
    }
}
