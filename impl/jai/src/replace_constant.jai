// convertUsersOfConstantsToInstructions and ConstantExpr::getAsInstruction.
// Ported from llvm/lib/IR/ReplaceConstant.cpp and llvm/lib/IR/Constants.cpp (ConstantExpr::getAsInstruction).

// ConstantExpr::getAsInstruction: an unlinked instruction computing the constant expression
ce_get_as_instruction :: (c: Value_Id) -> Value_Id {
    e := cexpr(c);
    opc := e.op;
    n := nops(c);
    if opc == .TRUNC || opc == .ZEXT || opc == .SEXT || opc == .FPTRUNC || opc == .FPEXT || opc == .UITOFP || opc == .SITOFP ||
       opc == .FPTOUI || opc == .FPTOSI || opc == .PTRTOINT || opc == .PTRTOADDR || opc == .INTTOPTR || opc == .BITCAST ||
       opc == .ADDRSPACECAST
        return create_cast(opc, op(c, 0), vtype(c));
    if opc == .GEP {
        // GetElementPtrInst::Create(SrcElementTy, Ops[0], Ops.slice(1)) + setNoWrapFlags (inrange is not kept)
        i := new_inst(.GEP, vtype(c), n);
        inst(i).ty2 = e.ty2;
        inst(i).flags = e.flags;
        for k: 0..n-1 set_op(i, k, op(c, k));
        return i;
    }
    if opc == .ADD || opc == .SUB || opc == .MUL || opc == .XOR || opc == .SHL || opc == .LSHR || opc == .ASHR ||
       opc == .AND || opc == .OR || opc == .UDIV || opc == .SDIV {
        // BinaryOperator::Create + the nuw / nsw / exact flags (SubclassOptionalData)
        i := create_binop(opc, op(c, 0), op(c, 1));
        inst(i).flags = e.flags;
        return i;
    }
    fatal("ConstantExpr::getAsInstruction: '%' constant expressions are not supported", opcode_name(opc));
    return NONE;
}

Rc_Cache_Entry :: struct { c: Value_Id; bb: Value_Id; insts: [..] Value_Id; }

// convertUsersOfConstantsToInstructions(Consts, RestrictToFunc = nullptr, RemoveDeadConstants = true, IncludeSelf = false)
convert_users_of_constants_to_instructions :: (consts: [] Value_Id) -> bool {
    is_expandable_user :: (u: Value_Id) -> bool {
        k := vkind(u);
        return k == .C_EXPR || k == .C_ARRAY || k == .C_STRUCT || k == .C_VECTOR;
    }
    // expandUser(InsertPt, C, NewInsts)
    expand_user :: (bb: Value_Id, pt: Value_Id, head: bool, c: Value_Id, new_insts: *[..] Value_Id) {
        new_insts.count = 0;
        k := vkind(c);
        if k == .C_EXPR {
            ci := ce_get_as_instruction(c);
            insert_at_position(ci, bb, pt, head);
            array_add(new_insts, ci);
        } else if k == .C_STRUCT || k == .C_ARRAY {
            v := const_poison(vtype(c));
            for x: 0..nops(c)-1 {
                // InsertValueInst::Create(V, Op, Idx, "", InsertPt)
                iv := new_inst(.INSERTVALUE, vtype(c), 2);
                set_op(iv, 0, v); set_op(iv, 1, op(c, x));
                inst(iv).idx = cast(u32) ir.u32_pool.count; inst(iv).nidx = 1;
                array_add(*ir.u32_pool, x);
                insert_at_position(iv, bb, pt, head);
                array_add(new_insts, iv);
                v = iv;
            }
        } else if k == .C_VECTOR {
            v := const_poison(vtype(c));
            for x: 0..nops(c)-1 {
                ie := new_inst(.INSERTELEMENT, vtype(c), 3);
                set_op(ie, 0, v); set_op(ie, 1, op(c, x)); set_op(ie, 2, const_int(ir.t_i32, x));
                insert_at_position(ie, bb, pt, head);
                array_add(new_insts, ie);
                v = ie;
            }
        } else {
            fatal("convertUsersOfConstantsToInstructions: not an expandable user");
        }
    }

    stack: [..] Value_Id; stack.allocator = temp;
    for c: consts {
        u := ir.v_first_use[c];
        while u != NONE { usr := ir.u_user[u]; if is_expandable_user(usr) array_add(*stack, usr); u = ir.u_next[u]; }
    }
    // SetVector<Constant *> ExpandableUsers
    expandable: [..] Value_Id; expandable.allocator = temp;
    exp_set: Table(Value_Id, bool); exp_set.allocator = temp;
    while stack.count {
        c := pop(*stack);
        if table_contains(*exp_set, c) continue;
        table_add(*exp_set, c, true);
        array_add(*expandable, c);
        u := ir.v_first_use[c];
        while u != NONE { usr := ir.u_user[u]; if is_expandable_user(usr) array_add(*stack, usr); u = ir.u_next[u]; }
    }
    // SetVector<Instruction *> InstructionWorklist
    worklist: [..] Value_Id; worklist.allocator = temp;
    wl_set: Table(Value_Id, bool); wl_set.allocator = temp;
    for c: expandable {
        u := ir.v_first_use[c];
        while u != NONE {
            usr := ir.u_user[u];
            if vkind(usr) == .INST && !table_contains(*wl_set, usr) { table_add(*wl_set, usr, true); array_add(*worklist, usr); }
            u = ir.u_next[u];
        }
    }
    changed := false;
    cache: [..] Rc_Cache_Entry; cache.allocator = temp;   // ConstantToInstructionMap
    new_insts: [..] Value_Id; new_insts.allocator = temp;
    while worklist.count {
        i := pop(*worklist);
        table_remove(*wl_set, i);
        loc := get_metadata(i, 0);
        for k: 0..nops(i)-1 {
            bb := inst(i).parent; pt := i; head := false;
            if inst_op(i) == .PHI {
                bb = phi_block(i, k);
                pt = block_first_insertion_pt(bb);
                head = true;
                assert(pt != NONE, "Unexpected empty basic block");
            }
            c := op(i, k);
            if c == NONE || !table_contains(*exp_set, c) continue;
            changed = true;
            slot := -1;
            for cache if it.c == c && it.bb == bb { slot = it_index; break; }
            if slot < 0 {
                e: Rc_Cache_Entry; e.c = c; e.bb = bb; e.insts.allocator = temp;
                array_add(*cache, e);
                slot = cache.count - 1;
            }
            ni := *cache[slot].insts;
            if ni.count == 0 || comes_before(pt, ni.*[0]) {
                expand_user(bb, pt, head, c, *new_insts);
                ni.count = 0;
                for new_insts array_add(ni, it);
            }
            for ni.* {
                set_metadata(it, 0, loc);
                if !table_contains(*wl_set, it) { table_add(*wl_set, it, true); array_add(*worklist, it); }
            }
            set_op(i, k, ni.*[ni.count - 1]);
        }
    }
    for c: consts remove_dead_constant_users(c);
    return changed;
}
