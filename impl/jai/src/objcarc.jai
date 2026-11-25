// ObjC ARC shared machinery: a port of
//   llvm/lib/Analysis/ObjCARCInstKind.cpp        ARCInstKind, GetFunctionClass, GetARCInstKind and the kind predicates
//   llvm/include/llvm/Analysis/ObjCARCInstKind.h  GetBasicARCInstKind
//   llvm/lib/Analysis/ObjCARCAnalysisUtils.cpp    IsPotentialRetainableObjPtr(Op, AA), -enable-objc-arc-opts
//   llvm/include/llvm/Analysis/ObjCARCAnalysisUtils.h  ModuleHasARC, GetUnderlyingObjCPtr(Cached), GetRCIdentityRoot,
//                                                  IsNullOrUndef, IsNoopInstruction, IsPotentialRetainableObjPtr,
//                                                  GetCallSiteClass, IsObjCIdentifiedObject, ARCMDKindCache
//   llvm/include/llvm/Analysis/ObjCARCUtil.h      attached-call bundle helpers
//   llvm/lib/Analysis/ObjCARCAliasAnalysis.cpp    objc-arc-aa (aa.jai's .OBJC_ARC kind calls the procedures here)
//   llvm/lib/Transforms/ObjCARC/ARCRuntimeEntryPoints.h, llvm/lib/Transforms/ObjCARC/ObjCARC.cpp (+ ObjCARC.h)
//                                                  entry points, EraseInstruction,
//                                                  getEquivalentPHIs, createCallInstWithColors, BundledRetainClaimRVs
//   llvm/lib/Transforms/ObjCARC/ProvenanceAnalysis.cpp, llvm/lib/Transforms/ObjCARC/DependencyAnalysis.cpp,
//   llvm/lib/Transforms/ObjCARC/PtrState.cpp (BlotMapVector.h: pass_objcarc.jai)
//
// Data-oriented: the analyses are plain structs (`Arc_Pa` = ProvenanceAnalysis, `Arc_Ptr_State` = PtrState with the
// TopDown/BottomUp "subclasses" as separate procedures), the SmallPtrSets of PtrState are insertion-ordered arrays
// (see NOTES.md "ObjC ARC" for why their pointer order never reaches the output).

Arc_Kind :: enum u8 {
    Retain; RetainRV; UnsafeClaimRV; RetainBlock; Release; Autorelease; AutoreleaseRV; AutoreleasepoolPush;
    AutoreleasepoolPop; NoopCast; FusedRetainAutorelease; FusedRetainAutoreleaseRV; LoadWeakRetained; StoreWeak;
    InitWeak; LoadWeak; MoveWeak; CopyWeak; DestroyWeak; StoreStrong; IntrinsicUser; CallOrUser; Call; User; None;
}
arc_bit :: inline (k: Arc_Kind) -> u32 { return (cast(u32) 1) << cast(u32) k; }

// -enable-objc-arc-opts
arc_cl: struct {
    enable_arc_opts := true;           // ObjCARCAnalysisUtils.cpp -enable-objc-arc-opts
    max_ptr_states: s64 = 4095;        // ObjCARCOpts.cpp -arc-opt-max-ptr-states
    use_claim_rv: s64 = -1;            // ObjCARCContract.cpp -arc-contract-use-objc-claim-rv (boolOrDefault: -1 unset)
};
objcarc_parse_cl_opt :: (name: string, value: string, has_value: bool) -> bool {
    if name == {
        case "enable-objc-arc-opts"; arc_cl.enable_arc_opts = smisc_bool(name, value, has_value);
        case "arc-opt-max-ptr-states"; arc_cl.max_ptr_states = smisc_int(name, value, has_value);
        case "arc-contract-use-objc-claim-rv"; arc_cl.use_claim_rv = ifx smisc_bool(name, value, has_value) then 1 else 0;
        case; return false;
    }
    return true;
}

IID_OBJC_AUTORELEASE :: #run iid_by_name("llvm.objc.autorelease");
IID_OBJC_AUTORELEASEPOOLPOP :: #run iid_by_name("llvm.objc.autoreleasePoolPop");
IID_OBJC_AUTORELEASEPOOLPUSH :: #run iid_by_name("llvm.objc.autoreleasePoolPush");
IID_OBJC_AUTORELEASERETURNVALUE :: #run iid_by_name("llvm.objc.autoreleaseReturnValue");
IID_OBJC_COPYWEAK :: #run iid_by_name("llvm.objc.copyWeak");
IID_OBJC_DESTROYWEAK :: #run iid_by_name("llvm.objc.destroyWeak");
IID_OBJC_INITWEAK :: #run iid_by_name("llvm.objc.initWeak");
IID_OBJC_LOADWEAK :: #run iid_by_name("llvm.objc.loadWeak");
IID_OBJC_LOADWEAKRETAINED :: #run iid_by_name("llvm.objc.loadWeakRetained");
IID_OBJC_MOVEWEAK :: #run iid_by_name("llvm.objc.moveWeak");
IID_OBJC_RELEASE :: #run iid_by_name("llvm.objc.release");
IID_OBJC_RETAIN :: #run iid_by_name("llvm.objc.retain");
IID_OBJC_RETAINAUTORELEASE :: #run iid_by_name("llvm.objc.retainAutorelease");
IID_OBJC_RETAINAUTORELEASERETURNVALUE :: #run iid_by_name("llvm.objc.retainAutoreleaseReturnValue");
IID_OBJC_RETAINAUTORELEASEDRETURNVALUE :: #run iid_by_name("llvm.objc.retainAutoreleasedReturnValue");
IID_OBJC_CLAIMAUTORELEASEDRETURNVALUE :: #run iid_by_name("llvm.objc.claimAutoreleasedReturnValue");
IID_OBJC_RETAINBLOCK :: #run iid_by_name("llvm.objc.retainBlock");
IID_OBJC_STORESTRONG :: #run iid_by_name("llvm.objc.storeStrong");
IID_OBJC_STOREWEAK :: #run iid_by_name("llvm.objc.storeWeak");
IID_OBJC_CLANG_ARC_USE :: #run iid_by_name("llvm.objc.clang.arc.use");
IID_OBJC_CLANG_ARC_NOOP_USE :: #run iid_by_name("llvm.objc.clang.arc.noop.use");
IID_OBJC_UNSAFECLAIMAUTORELEASEDRETURNVALUE :: #run iid_by_name("llvm.objc.unsafeClaimAutoreleasedReturnValue");
IID_OBJC_RETAINEDOBJECT :: #run iid_by_name("llvm.objc.retainedObject");
IID_OBJC_UNRETAINEDOBJECT :: #run iid_by_name("llvm.objc.unretainedObject");
IID_OBJC_UNRETAINEDPOINTER :: #run iid_by_name("llvm.objc.unretainedPointer");
IID_OBJC_RETAIN_AUTORELEASE :: #run iid_by_name("llvm.objc.retain.autorelease");
IID_OBJC_SYNC_ENTER :: #run iid_by_name("llvm.objc.sync.enter");
IID_OBJC_SYNC_EXIT :: #run iid_by_name("llvm.objc.sync.exit");
IID_OBJC_ARC_ANNOTATION_TOPDOWN_BBSTART :: #run iid_by_name("llvm.objc.arc.annotation.topdown.bbstart");
IID_OBJC_ARC_ANNOTATION_TOPDOWN_BBEND :: #run iid_by_name("llvm.objc.arc.annotation.topdown.bbend");
IID_OBJC_ARC_ANNOTATION_BOTTOMUP_BBSTART :: #run iid_by_name("llvm.objc.arc.annotation.bottomup.bbstart");
IID_OBJC_ARC_ANNOTATION_BOTTOMUP_BBEND :: #run iid_by_name("llvm.objc.arc.annotation.bottomup.bbend");
IID_ARC_RETURNADDRESS :: #run iid_by_name("llvm.returnaddress");
IID_ARC_ADDRESSOFRETURNADDRESS :: #run iid_by_name("llvm.addressofreturnaddress");
IID_ARC_FRAMEADDRESS :: #run iid_by_name("llvm.frameaddress");
IID_ARC_STACKSAVE :: #run iid_by_name("llvm.stacksave");
IID_ARC_STACKRESTORE :: #run iid_by_name("llvm.stackrestore");
IID_ARC_VASTART :: #run iid_by_name("llvm.va_start");
IID_ARC_VACOPY :: #run iid_by_name("llvm.va_copy");
IID_ARC_VAEND :: #run iid_by_name("llvm.va_end");
IID_ARC_PREFETCH :: #run iid_by_name("llvm.prefetch");
IID_ARC_STACKPROTECTOR :: #run iid_by_name("llvm.stackprotector");
IID_ARC_EH_RETURN_I32 :: #run iid_by_name("llvm.eh.return.i32");
IID_ARC_EH_RETURN_I64 :: #run iid_by_name("llvm.eh.return.i64");
IID_ARC_EH_TYPEID_FOR :: #run iid_by_name("llvm.eh.typeid.for");
IID_ARC_EH_DWARF_CFA :: #run iid_by_name("llvm.eh.dwarf.cfa");
IID_ARC_EH_SJLJ_LSDA :: #run iid_by_name("llvm.eh.sjlj.lsda");
IID_ARC_EH_SJLJ_FUNCTIONCONTEXT :: #run iid_by_name("llvm.eh.sjlj.functioncontext");
IID_ARC_INIT_TRAMPOLINE :: #run iid_by_name("llvm.init.trampoline");
IID_ARC_ADJUST_TRAMPOLINE :: #run iid_by_name("llvm.adjust.trampoline");

// ---------------------------------------------------------------- ObjCARCInstKind.cpp

// GetFunctionClass
arc_function_class :: (f: Value_Id) -> Arc_Kind {
    id := fn_iid(f);
    if id == {
        case IID_OBJC_AUTORELEASE; return .Autorelease;
        case IID_OBJC_AUTORELEASEPOOLPOP; return .AutoreleasepoolPop;
        case IID_OBJC_AUTORELEASEPOOLPUSH; return .AutoreleasepoolPush;
        case IID_OBJC_AUTORELEASERETURNVALUE; return .AutoreleaseRV;
        case IID_OBJC_COPYWEAK; return .CopyWeak;
        case IID_OBJC_DESTROYWEAK; return .DestroyWeak;
        case IID_OBJC_INITWEAK; return .InitWeak;
        case IID_OBJC_LOADWEAK; return .LoadWeak;
        case IID_OBJC_LOADWEAKRETAINED; return .LoadWeakRetained;
        case IID_OBJC_MOVEWEAK; return .MoveWeak;
        case IID_OBJC_RELEASE; return .Release;
        case IID_OBJC_RETAIN; return .Retain;
        case IID_OBJC_RETAINAUTORELEASE; return .FusedRetainAutorelease;
        case IID_OBJC_RETAINAUTORELEASERETURNVALUE; return .FusedRetainAutoreleaseRV;
        case IID_OBJC_RETAINAUTORELEASEDRETURNVALUE; return .RetainRV;
        case IID_OBJC_RETAINBLOCK; return .RetainBlock;
        case IID_OBJC_STORESTRONG; return .StoreStrong;
        case IID_OBJC_STOREWEAK; return .StoreWeak;
        case IID_OBJC_CLANG_ARC_USE; return .IntrinsicUser;
        case IID_OBJC_UNSAFECLAIMAUTORELEASEDRETURNVALUE; return .UnsafeClaimRV;
        case IID_OBJC_RETAINEDOBJECT; return .NoopCast;
        case IID_OBJC_UNRETAINEDOBJECT; return .NoopCast;
        case IID_OBJC_UNRETAINEDPOINTER; return .NoopCast;
        case IID_OBJC_RETAIN_AUTORELEASE; return .FusedRetainAutorelease;
        case IID_OBJC_SYNC_ENTER; return .User;
        case IID_OBJC_SYNC_EXIT; return .User;
        case IID_OBJC_CLANG_ARC_NOOP_USE; #through;
        case IID_OBJC_ARC_ANNOTATION_TOPDOWN_BBSTART; #through;
        case IID_OBJC_ARC_ANNOTATION_TOPDOWN_BBEND; #through;
        case IID_OBJC_ARC_ANNOTATION_BOTTOMUP_BBSTART; #through;
        case IID_OBJC_ARC_ANNOTATION_BOTTOMUP_BBEND; return .None;
    }
    return .CallOrUser;
}

arc_is_inert_intrinsic :: (id: Intrinsic_Id) -> bool {
    if id == {
        case IID_ARC_RETURNADDRESS; #through; case IID_ARC_ADDRESSOFRETURNADDRESS; #through;
        case IID_ARC_FRAMEADDRESS; #through; case IID_ARC_STACKSAVE; #through; case IID_ARC_STACKRESTORE; #through;
        case IID_ARC_VASTART; #through; case IID_ARC_VACOPY; #through; case IID_ARC_VAEND; #through;
        case IID_OBJECTSIZE; #through; case IID_ARC_PREFETCH; #through; case IID_ARC_STACKPROTECTOR; #through;
        case IID_ARC_EH_RETURN_I32; #through; case IID_ARC_EH_RETURN_I64; #through; case IID_ARC_EH_TYPEID_FOR; #through;
        case IID_ARC_EH_DWARF_CFA; #through; case IID_ARC_EH_SJLJ_LSDA; #through; case IID_ARC_EH_SJLJ_FUNCTIONCONTEXT; #through;
        case IID_ARC_INIT_TRAMPOLINE; #through; case IID_ARC_ADJUST_TRAMPOLINE; #through;
        case IID_LIFETIME_START; #through; case IID_LIFETIME_END; #through;
        case IID_INVARIANT_START; #through; case IID_INVARIANT_END; #through;
        case IID_DBG_DECLARE; #through; case IID_DBG_VALUE; #through; case IID_DBG_LABEL;
            return true;
    }
    return false;
}
arc_is_use_only_intrinsic :: (id: Intrinsic_Id) -> bool { return id == IID_MEMCPY || id == IID_MEMMOVE || id == IID_MEMSET; }

// GetBasicARCInstKind
arc_basic_kind :: (v: Value_Id) -> Arc_Kind {
    if is_inst(v) && inst_op(v) == .CALL {
        f := call_called_function(v);
        if f != NONE return arc_function_class(f);
        return .CallOrUser;
    }
    if is_inst(v) && inst_op(v) == .INVOKE return .CallOrUser;
    return .User;
}

// IsPotentialRetainableObjPtr(const Value *Op)
arc_is_potential_retainable :: (o: Value_Id) -> bool {
    if is_const(o) || (is_inst(o) && inst_op(o) == .ALLOCA) return false;
    if vkind(o) == .ARGUMENT {
        if arg_has_pass_pointee_by_value_copy(o) || arg_has_attr(o, .Nest) || arg_has_attr(o, .StructRet) return false;
    }
    return is_ptr_type(vtype(o));
}
// IsPotentialRetainableObjPtr(const Value *Op, AAResults &AA)
arc_is_potential_retainable_aa :: (o: Value_Id, aar: *Aa_Results) -> bool {
    if !arc_is_potential_retainable(o) return false;
    if arc_points_to_constant_memory(aar, o) return false;
    if is_inst(o) && inst_op(o) == .LOAD && arc_points_to_constant_memory(aar, op(o, 0)) return false;
    return true;
}
// AAResults::pointsToConstantMemory(P)
arc_points_to_constant_memory :: (aar: *Aa_Results, p: Value_Id) -> bool {
    return aa_mod_ref_mask(aa_query_new(aar), mloc_before_or_after(p)) == MR_NO;
}

// GetCallSiteClass
arc_call_site_class :: (cb: Value_Id) -> Arc_Kind {
    n := call_num_args(cb);
    if n > 0 for k: 0..n-1 if arc_is_potential_retainable(call_arg(cb, k))
        return ifx call_only_reads_memory(cb) then .User else .CallOrUser;
    return ifx call_only_reads_memory(cb) then .None else .Call;
}

// GetARCInstKind
arc_inst_kind :: (v: Value_Id) -> Arc_Kind {
    if !is_inst(v) return .None;
    o := inst_op(v);
    if o == {
        case .CALL;
            f := call_called_function(v);
            if f != NONE {
                c := arc_function_class(f);
                if c != .CallOrUser return c;
                id := fn_iid(f);
                if arc_is_inert_intrinsic(id) return .None;
                if arc_is_use_only_intrinsic(id) return .User;
            }
            return arc_call_site_class(v);
        case .INVOKE; return arc_call_site_class(v);
        case .BITCAST; #through; case .GEP; #through; case .SELECT; #through; case .PHI; #through; case .RET; #through;
        case .BR; #through; case .CONDBR; #through; case .SWITCH; #through; case .INDIRECTBR; #through; case .ALLOCA; #through;
        case .VAARG; #through; case .ADD; #through; case .FADD; #through; case .SUB; #through; case .FSUB; #through;
        case .MUL; #through; case .FMUL; #through; case .SDIV; #through; case .UDIV; #through; case .FDIV; #through;
        case .SREM; #through; case .UREM; #through; case .FREM; #through; case .SHL; #through; case .LSHR; #through;
        case .ASHR; #through; case .AND; #through; case .OR; #through; case .XOR; #through; case .SEXT; #through;
        case .ZEXT; #through; case .TRUNC; #through; case .INTTOPTR; #through; case .FCMP; #through; case .FPTRUNC; #through;
        case .FPEXT; #through; case .FPTOUI; #through; case .FPTOSI; #through; case .UITOFP; #through; case .SITOFP; #through;
        case .INSERTELEMENT; #through; case .EXTRACTELEMENT; #through; case .SHUFFLEVECTOR; #through; case .EXTRACTVALUE;
            return .None;
        case .ICMP;
            if arc_is_potential_retainable(op(v, 1)) return .User;
            return .None;
    }
    n := nops(v);
    if n > 0 for k: 0..n-1 { x := op(v, k); if x != NONE && arc_is_potential_retainable(x) return .User; }
    return .None;
}

arc_is_user :: (k: Arc_Kind) -> bool { return k == .User || k == .CallOrUser || k == .IntrinsicUser; }
arc_is_retain :: (k: Arc_Kind) -> bool { return k == .Retain || k == .RetainRV; }
arc_is_autorelease :: (k: Arc_Kind) -> bool { return k == .Autorelease || k == .AutoreleaseRV; }
arc_is_forwarding :: (k: Arc_Kind) -> bool {
    return k == .Retain || k == .RetainRV || k == .UnsafeClaimRV || k == .Autorelease || k == .AutoreleaseRV || k == .NoopCast;
}
arc_is_noop_on_null :: (k: Arc_Kind) -> bool {
    return k == .Retain || k == .RetainRV || k == .UnsafeClaimRV || k == .Release || k == .Autorelease ||
           k == .AutoreleaseRV || k == .RetainBlock;
}
arc_is_noop_on_global :: (k: Arc_Kind) -> bool {
    return k == .Retain || k == .RetainRV || k == .UnsafeClaimRV || k == .Release || k == .Autorelease ||
           k == .AutoreleaseRV || k == .RetainBlock || k == .FusedRetainAutorelease || k == .FusedRetainAutoreleaseRV;
}
arc_is_always_tail :: (k: Arc_Kind) -> bool { return k == .Retain || k == .RetainRV || k == .UnsafeClaimRV || k == .AutoreleaseRV; }
arc_is_never_tail :: (k: Arc_Kind) -> bool { return k == .Autorelease; }
arc_is_no_throw :: (k: Arc_Kind) -> bool {
    return k == .Retain || k == .RetainRV || k == .UnsafeClaimRV || k == .Release || k == .Autorelease ||
           k == .AutoreleaseRV || k == .AutoreleasepoolPush || k == .AutoreleasepoolPop;
}
arc_can_interrupt_rv :: (k: Arc_Kind) -> bool {
    return k == .AutoreleasepoolPop || k == .CallOrUser || k == .Call || k == .Autorelease || k == .AutoreleaseRV ||
           k == .FusedRetainAutorelease || k == .FusedRetainAutoreleaseRV;
}
// CanDecrementRefCount(ARCInstKind)
arc_kind_can_decrement_ref_count :: (k: Arc_Kind) -> bool {
    if k == {
        case .Retain; #through; case .RetainRV; #through; case .Autorelease; #through; case .AutoreleaseRV; #through;
        case .NoopCast; #through; case .FusedRetainAutorelease; #through; case .FusedRetainAutoreleaseRV; #through;
        case .IntrinsicUser; #through; case .User; #through; case .None;
            return false;
    }
    return true;
}

// ---------------------------------------------------------------- ObjCARCAnalysisUtils.h

// ModuleHasARC
arc_module_has_arc :: () -> bool {
    NAMES :: string.["llvm.objc.retain", "llvm.objc.release", "llvm.objc.autorelease",
        "llvm.objc.retainAutoreleasedReturnValue", "llvm.objc.retainBlock", "llvm.objc.autoreleaseReturnValue",
        "llvm.objc.autoreleasePoolPush", "llvm.objc.loadWeakRetained", "llvm.objc.loadWeak", "llvm.objc.destroyWeak",
        "llvm.objc.initWeak", "llvm.objc.copyWeak", "llvm.objc.retainedObject", "llvm.objc.unretainedObject",
        "llvm.objc.unretainedPointer", "llvm.objc.clang.arc.noop.use", "llvm.objc.clang.arc.use"];
    for NAMES {
        g := lookup_global(it);
        if g != NONE && vkind(g) == .FUNCTION return true;
    }
    return false;
}

// CallInst::getArgOperand(0)
arc_arg0 :: inline (c: Value_Id) -> Value_Id { return call_arg(c, 0); }

// GetUnderlyingObjCPtr
arc_underlying_objc_ptr :: (v_in: Value_Id) -> Value_Id {
    v := v_in;
    while true {
        v = get_underlying_object(v);
        if !arc_is_forwarding(arc_basic_kind(v)) break;
        v = arc_arg0(v);
    }
    return v;
}
// GetRCIdentityRoot
arc_rc_identity_root :: (v_in: Value_Id) -> Value_Id {
    v := v_in;
    while true {
        v = arc_strip(v);
        if !arc_is_forwarding(arc_basic_kind(v)) break;
        v = arc_arg0(v);
    }
    return v;
}
// GetArgRCIdentityRoot
arc_arg_rc_identity_root :: (i: Value_Id) -> Value_Id { return arc_rc_identity_root(arc_arg0(i)); }
// IsNullOrUndef: ConstantPointerNull or UndefValue (incl. poison)
arc_is_null_or_undef :: (v: Value_Id) -> bool {
    k := vkind(v);
    return (k == .C_NULL && is_ptr_type(vtype(v))) || k == .C_UNDEF || k == .C_POISON;
}
// IsNoopInstruction
arc_is_noop_instruction :: (i: Value_Id) -> bool {
    if !is_inst(i) return false;
    o := inst_op(i);
    return o == .BITCAST || (o == .GEP && gep_has_all_zero_indices(i));
}

// IsObjCIdentifiedObject
arc_is_objc_identified_object :: (v: Value_Id) -> bool {
    if is_inst(v) {
        o := inst_op(v);
        if o == .CALL || o == .INVOKE || o == .ALLOCA return true;
    }
    if vkind(v) == .ARGUMENT || is_const(v) return true;
    if is_inst(v) && inst_op(v) == .LOAD {
        p := arc_rc_identity_root(op(v, 0));
        if vkind(p) == .GLOBAL_VAR {
            g := glob(p);
            if g.is_const return true;
            if begins_with(vname(p), "\x01l_objc_msgSend_fixup_") return true;
            s := g.section;
            if contains(s, "__message_refs") || contains(s, "__objc_classrefs") || contains(s, "__objc_superrefs") ||
               contains(s, "__objc_methname") || contains(s, "__cstring") return true;
        }
    }
    return false;
}

// ARCMDKindCache
arc_md_imprecise_release :: () -> u32 { return md_kind_id("clang.imprecise_release"); }
arc_md_copy_on_escape :: () -> u32 { return md_kind_id("clang.arc.copy_on_escape"); }
arc_md_no_objc_arc_exceptions :: () -> u32 { return md_kind_id("clang.arc.no_objc_arc_exceptions"); }

// ---------------------------------------------------------------- ObjCARCUtil.h

// hasAttachedCallOpBundle
arc_has_attached_call_bundle :: (cb: Value_Id) -> bool {
    if inst(cb).ty2 == NONE return false;
    if func_ret(inst(cb).ty2) == ir.t_void return false;
    return call_bundle_index(cb, "clang.arc.attachedcall") >= 0;
}
// getAttachedARCFunction (NONE when there is no bundle)
arc_attached_function :: (cb: Value_Id) -> Value_Id {
    k := call_bundle_index(cb, "clang.arc.attachedcall");
    if k < 0 return NONE;
    b, e := call_bundle_range(cb, cast(u32) k);
    f := op(cb, b);
    if vkind(f) != .FUNCTION fatal("objc-arc: the clang.arc.attachedcall operand is not a function");
    return f;
}

// ---------------------------------------------------------------- ARCRuntimeEntryPoints.h

Arc_Entry :: enum u8 {
    AutoreleaseRV; Release; Retain; RetainBlock; Autorelease; StoreStrong; RetainRV; ClaimRV; UnsafeClaimRV;
    RetainAutorelease; RetainAutoreleaseRV; AutoreleasePoolPush; AutoreleasePoolPop;
}
Arc_Entry_Points :: struct { decls: [13] Value_Id; }
arc_ep_init :: (ep: *Arc_Entry_Points) { for * ep.decls it.* = NONE; }
arc_ep_get :: (ep: *Arc_Entry_Points, k: Arc_Entry) -> Value_Id {
    d := *ep.decls[cast(s64) k];
    if d.* != NONE && vkind(d.*) != .DEAD return d.*;
    id: Intrinsic_Id;
    if k == {
        case .AutoreleaseRV; id = IID_OBJC_AUTORELEASERETURNVALUE;
        case .Release; id = IID_OBJC_RELEASE;
        case .Retain; id = IID_OBJC_RETAIN;
        case .RetainBlock; id = IID_OBJC_RETAINBLOCK;
        case .Autorelease; id = IID_OBJC_AUTORELEASE;
        case .StoreStrong; id = IID_OBJC_STORESTRONG;
        case .RetainRV; id = IID_OBJC_RETAINAUTORELEASEDRETURNVALUE;
        case .ClaimRV; id = IID_OBJC_CLAIMAUTORELEASEDRETURNVALUE;
        case .UnsafeClaimRV; id = IID_OBJC_UNSAFECLAIMAUTORELEASEDRETURNVALUE;
        case .RetainAutorelease; id = IID_OBJC_RETAINAUTORELEASE;
        case .RetainAutoreleaseRV; id = IID_OBJC_RETAINAUTORELEASERETURNVALUE;
        case .AutoreleasePoolPush; id = IID_OBJC_AUTORELEASEPOOLPUSH;
        case .AutoreleasePoolPop; id = IID_OBJC_AUTORELEASEPOOLPOP;
    }
    d.* = get_or_insert_intrinsic_declaration(id);
    return d.*;
}

// ---------------------------------------------------------------- call creation helpers

Arc_Bundle :: struct { tag: string; inputs: [] Value_Id; }

// CallInst::Create(FTy, Callee, Args, OpBundles, "", InsertBefore) for a callee value (function or inline asm)
arc_new_call :: (fty: Type_Id, callee: Value_Id, args: [] Value_Id, bundles: [] Arc_Bundle) -> Value_Id {
    nin := 0;
    for bundles nin += it.inputs.count;
    i := new_inst(.CALL, func_ret(fty), cast(u32)(args.count + nin + 1));
    r := inst(i);
    r.ty2 = fty;
    k: u32 = 0;
    for args { set_op(i, k, it); k += 1; }
    if bundles.count {
        r = inst(i);
        r.idx = cast(u32) ir.u32_pool.count; r.nidx = cast(u32) bundles.count;
        b := k;
        for bundles {
            array_add(*ir.u32_pool, bundle_tag_id(it.tag));
            array_add(*ir.u32_pool, b);
            array_add(*ir.u32_pool, b + cast(u32) it.inputs.count);
            b += cast(u32) it.inputs.count;
        }
        for bd: bundles for bd.inputs { set_op(i, k, it); k += 1; }
    }
    set_op(i, k, callee);
    return i;
}
arc_new_call_fn :: (f: Value_Id, args: [] Value_Id, bundles: [] Arc_Bundle = .[]) -> Value_Id {
    return arc_new_call(glob(f).value_type, f, args, bundles);
}

// the operand bundles of `c` as definitions (inputs copied to temp)
arc_call_bundles :: (c: Value_Id, out: *[..] Arc_Bundle) {
    n := call_num_bundles(c);
    if n > 0 for k: 0..n-1 {
        b, e := call_bundle_range(c, k);
        ins := NewArray(cast(s64)(e - b), Value_Id,, allocator = temp);
        for x: cast(s64) b..cast(s64) e - 1 ins[x - cast(s64) b] = op(c, cast(u32) x);
        array_add(out, .{call_bundle_tag(c, k), ins});
    }
}

// CallBase::Create(CB, Bundles, InsertPt): a call or invoke with the same arguments, callee (and destinations),
// tail kind, calling convention, fast-math flags, attributes, debug location and name (unlinked; the caller inserts
// it and then calls arc_finish_clone to set the name)
arc_clone_call_with_bundles :: (c: Value_Id, bundles: [] Arc_Bundle) -> Value_Id {
    nargs := call_num_args(c);
    tail := call_non_data_operands(c);
    nin := 0;
    for bundles nin += it.inputs.count;
    n := nargs + cast(u32) nin + tail;
    nc := new_inst(inst_op(c), vtype(c), n);
    src := inst(c).*;
    r := inst(nc);
    r.* = src;
    r.parent = NONE; r.prev = NONE; r.next = NONE; r.records = 0; r.order = 0;
    k: u32 = 0;
    if nargs > 0 for x: 0..nargs-1 { set_op(nc, k, op(c, x)); k += 1; }
    r = inst(nc);
    r.idx = 0; r.nidx = 0;
    if bundles.count {
        r.idx = cast(u32) ir.u32_pool.count; r.nidx = cast(u32) bundles.count;
        b := k;
        for bundles {
            array_add(*ir.u32_pool, bundle_tag_id(it.tag));
            array_add(*ir.u32_pool, b);
            array_add(*ir.u32_pool, b + cast(u32) it.inputs.count);
            b += cast(u32) it.inputs.count;
        }
        for bd: bundles for bd.inputs { set_op(nc, k, it); k += 1; }
    }
    base := nops(c) - tail;
    for x: 0..tail-1 { set_op(nc, k, op(c, base + x)); k += 1; }
    if inst_op(c) == .INVOKE || inst_op(c) == .CALLBR {
        // successor operands keep their aux (none for invoke)
    }
    d := get_metadata(c, 0);
    if d != NONE set_metadata(nc, 0, d);
    return nc;
}

// call_set_tail(bool): setTailCall
arc_set_tail_call :: (c: Value_Id, tail := true) { call_set_tail_kind(c, cast(u32) ifx tail then TCK_TAIL else TCK_NONE); }
arc_is_tail_call :: (c: Value_Id) -> bool { k := call_tail_kind(c); return k == TCK_TAIL || k == TCK_MUSTTAIL; }

// EraseInstruction (ObjCARC.h)
arc_erase_instruction :: (ci: Value_Id) {
    old_arg := arc_arg0(ci);
    unused := !has_uses(ci);
    if !unused rauw_with_metadata(ci, old_arg);
    erase_inst_with_metadata(ci);
    if unused recursively_delete_trivially_dead_value(old_arg);
}

// getreturnRVOperand
arc_return_rv_operand :: (i: Value_Id, k: Arc_Kind) -> Value_Id {
    if k != .RetainRV return NONE;
    o := arc_strip(op(i, 0));
    if is_inst(o) && (inst_op(o) == .CALL || inst_op(o) == .INVOKE) return o;
    return NONE;
}

// getEquivalentPHIs
arc_equivalent_phis :: (pn: Value_Id, out: *[..] Value_Id) {
    bb := inst_block(pn);
    for p: block_insts(bb) {
        if inst_op(p) != .PHI break;
        if p == pn continue;
        e := phi_num_incoming(pn);
        i: u32 = 0;
        while i < e {
            b := phi_block(pn, i);
            a := arc_strip(phi_value(pn, i));
            c := arc_strip(phi_incoming_value_for_block(p, b));
            if a != c break;
            i += 1;
        }
        if i == e array_add(out, p);
    }
}

// getRVInstMarker
arc_rv_inst_marker :: () -> Md_Id {
    m := module_flag("clang.arc.retainAutoreleasedReturnValueMarker");
    if m != NONE && ir.mds[m].kind == .STRING return m;
    return NONE;
}

// the EH colors of a function: BlockColors / BlockEHColors (empty unless a scoped EH personality)
Arc_Colors :: struct { colors: Table(Value_Id, [..] Value_Id); any: bool; }
arc_colors_init :: (c: *Arc_Colors, f: Value_Id) {
    c.colors.allocator = temp;
    p := fn_personality(f);
    if p != NONE && is_scoped_eh_personality(classify_eh_personality(p)) {
        color_eh_funclets(f, *c.colors);
        c.any = c.colors.count > 0;
    }
}

// createCallInstWithColors
arc_create_call_with_colors :: (fty: Type_Id, callee: Value_Id, args: [] Value_Id, bb: Value_Id, before: Value_Id, head: bool, colors: *Arc_Colors) -> Value_Id {
    bundles: [..] Arc_Bundle; bundles.allocator = temp;
    if colors.any {
        cv := table_find_pointer(*colors.colors, bb);
        assert(cv != null && cv.count == 1, "non-unique color for block!");
        pad := block_first_non_phi(cv.*[0]);
        if pad != NONE && is_eh_pad(pad) {
            ins := NewArray(1, Value_Id,, allocator = temp); ins[0] = pad;
            array_add(*bundles, .{"funclet", ins});
        }
    }
    c := arc_new_call(fty, callee, args, bundles);
    insert_at_position(c, bb, before, head);
    return c;
}


// ---------------------------------------------------------------- BundledRetainClaimRVs (ObjCARC.cpp)

Arc_Bundled :: struct {
    keys: [..] Value_Id;               // the inserted retainRV/claimRV calls (DenseMap<CallInst *, CallBase *>)
    vals: [..] Value_Id;               // their annotated calls / invokes
    index: Table(Value_Id, s64);
    ep: *Arc_Entry_Points;
    contract_pass: bool;
    use_claim_rv: bool;
}
arc_bundled_init :: (b: *Arc_Bundled, ep: *Arc_Entry_Points, contract: bool, claim: bool) {
    b.keys.allocator = temp; b.vals.allocator = temp; b.index.allocator = temp;
    b.ep = ep; b.contract_pass = contract; b.use_claim_rv = claim;
}
arc_bundled_contains :: (b: *Arc_Bundled, i: Value_Id) -> bool {
    if !is_inst(i) || inst_op(i) != .CALL return false;
    x := table_find_pointer(*b.index, i);
    return x != null && x.* >= 0;
}

// insertRVCallWithColors
arc_bundled_insert_rv_call :: (b: *Arc_Bundled, bb: Value_Id, before: Value_Id, head: bool, annotated: Value_Id, colors: *Arc_Colors) -> Value_Id {
    f := arc_attached_function(annotated);
    assert(f != NONE, "operand isn't a Function");
    pty := vtype(fn_arg(f, 0));
    if pty != vtype(annotated) fatal("objc-arc: a bitcast of the attached call's result is not supported");
    c := arc_create_call_with_colors(glob(f).value_type, f, .[annotated], bb, before, head, colors);
    table_set(*b.index, c, b.keys.count);
    array_add(*b.keys, c);
    array_add(*b.vals, annotated);
    return c;
}

// insertAfterInvokes
arc_bundled_insert_after_invokes :: (b: *Arc_Bundled, f: Value_Id, dt: *Dom_Tree) -> (changed: bool, cfg_changed: bool) {
    changed, cfg := false, false;
    none: Arc_Colors;
    for bb: fn_blocks(f) {
        t := block_terminator(bb);
        if t == NONE || inst_op(t) != .INVOKE continue;
        if !arc_has_attached_call_bundle(t) continue;
        dest := get_successor(t, 0);
        if block_single_predecessor(dest) == NONE {
            o: Crit_Edge_Options; o.dt = dt;
            dest = split_critical_edge(t, 0, *o);
            cfg = true;
        }
        pt := block_first_insertion_pt(dest);
        arc_bundled_insert_rv_call(b, dest, pt, true, t, *none);
        changed = true;
    }
    return changed, cfg;
}

// eraseInst
arc_bundled_erase_inst :: (b: *Arc_Bundled, ci: Value_Id) {
    x := table_find_pointer(*b.index, ci);
    if x != null && x.* >= 0 {
        idx := x.*;
        annotated := b.vals[idx];
        u := ir.v_first_use[annotated];
        while u != NONE {
            usr := ir.u_user[u];
            if is_inst(usr) && inst_op(usr) == .CALL && call_iid(usr) == IID_OBJC_CLANG_ARC_NOOP_USE {
                erase_inst_with_metadata(usr);
                break;
            }
            u = ir.u_next[u];
        }
        k := call_bundle_index(annotated, "clang.arc.attachedcall");
        nc := annotated;
        if k >= 0 {
            all: [..] Arc_Bundle; all.allocator = temp;
            arc_call_bundles(annotated, *all);
            keep: [..] Arc_Bundle; keep.allocator = temp;
            for all if it.tag != "clang.arc.attachedcall" array_add(*keep, it);
            nc = arc_clone_call_with_bundles(annotated, keep);
            insert_at_position(nc, inst_block(annotated), annotated, false);
            if vname(annotated).count set_name(nc, vname(annotated));
        }
        copy_metadata(nc, annotated);
        if nc != annotated {
            rauw_with_metadata(annotated, nc);
            erase_inst_with_metadata(annotated);
        }
        b.vals[idx] = NONE;
        x.* = -1;
    }
    arc_erase_instruction(ci);
}

// ~BundledRetainClaimRVs (DenseMap order: each entry touches only its own calls)
arc_bundled_finish :: (b: *Arc_Bundled) {
    for c, idx: b.keys {
        cb := b.vals[idx];
        if cb == NONE continue;
        if b.contract_pass {
            if inst_op(cb) == .CALL call_set_tail_kind(cb, TCK_NOTAIL);
            if b.use_claim_rv {
                n := call_num_bundles(cb);
                if n > 0 for k: 0..n-1 {
                    if call_bundle_tag(cb, k) != "clang.arc.attachedcall" continue;
                    s, e := call_bundle_range(cb, k);
                    if op(cb, s) == arc_ep_get(b.ep, .RetainRV) {
                        set_op(cb, s, arc_ep_get(b.ep, .ClaimRV));
                        break;
                    }
                }
            }
        }
        arc_erase_instruction(c);
    }
    b.keys.count = 0; b.vals.count = 0;
    table_reset(*b.index);
}

// ---------------------------------------------------------------- ProvenanceAnalysis.cpp

Arc_Uo_Entry :: struct { v: Value_Id; computed: Vh; }
Arc_Pa :: struct {
    aar: *Aa_Results;
    cache: Table(u64, bool);
    uo_cache: Table(Value_Id, Arc_Uo_Entry);
}
arc_pa_init :: (pa: *Arc_Pa, aar: *Aa_Results) {
    pa.aar = aar;
    pa.cache.allocator = temp;
    pa.uo_cache.allocator = temp;
}

// GetUnderlyingObjCPtrCached (the WeakVH is a plain id: ids are never reused; the WeakTrackingVH a Vh slot)
arc_underlying_cached :: (pa: *Arc_Pa, v: Value_Id) -> Value_Id {
    e := table_find_pointer(*pa.uo_cache, v);
    if e != null && vkind(e.v) != .DEAD {
        c := vh_get(e.computed);
        if c != NONE return c;
    }
    computed := arc_underlying_objc_ptr(v);
    table_set(*pa.uo_cache, v, .{v, vh_new(computed)});
    return computed;
}

arc_pa_related_select :: (pa: *Arc_Pa, a: Value_Id, b: Value_Id) -> bool {
    if is_inst(b) && inst_op(b) == .SELECT && op(a, 0) == op(b, 0)
        return arc_pa_related(pa, op(a, 1), op(b, 1)) || arc_pa_related(pa, op(a, 2), op(b, 2));
    return arc_pa_related(pa, op(a, 1), b) || arc_pa_related(pa, op(a, 2), b);
}

arc_pa_related_phi :: (pa: *Arc_Pa, a: Value_Id, b: Value_Id) -> bool {
    if is_phi(b) && inst_block(b) == inst_block(a) {
        n := phi_num_incoming(a);
        if n > 0 for i: 0..n-1
            if arc_pa_related(pa, phi_value(a, i), phi_incoming_value_for_block(b, phi_block(a, i))) return true;
        return false;
    }
    seen: [..] Value_Id; seen.allocator = temp;
    n := phi_num_incoming(a);
    if n > 0 for i: 0..n-1 {
        v := phi_value(a, i);
        dup := false;
        for seen if it == v { dup = true; break; }
        if dup continue;
        array_add(*seen, v);
        if arc_pa_related(pa, v, b) return true;
    }
    return false;
}

// IsStoredObjCPointer
arc_is_stored_objc_pointer :: (p_in: Value_Id) -> bool {
    if is_constant_data(p_in) return true;   // !hasUseList()
    visited: Table(Value_Id, bool); visited.allocator = temp;
    wl: [..] Value_Id; wl.allocator = temp;
    array_add(*wl, p_in);
    table_set(*visited, p_in, true);
    while wl.count {
        p := pop(*wl);
        u := ir.v_first_use[p];
        while u != NONE {
            defer u = ir.u_next[u];
            ur := ir.u_user[u];
            if is_inst(ur) && inst_op(ur) == .STORE {
                if use_operand_no(u) == 0 return true;
                continue;
            }
            if is_inst(ur) && inst_op(ur) == .CALL continue;
            if is_inst(p) && inst_op(p) == .PTRTOINT return true;
            if !table_contains(*visited, ur) { table_set(*visited, ur, true); array_add(*wl, ur); }
        }
    }
    return false;
}

arc_pa_related_check :: (pa: *Arc_Pa, a: Value_Id, b: Value_Id) -> bool {
    r := aa_alias_once(pa.aar, mloc_before_or_after(a), mloc_before_or_after(b)).kind;
    if r == AR_NO return false;
    if r == AR_MUST || r == AR_PARTIAL return true;
    ai := arc_is_objc_identified_object(a);
    bi := arc_is_objc_identified_object(b);
    is_load :: (v: Value_Id) -> bool { return is_inst(v) && inst_op(v) == .LOAD; }
    if ai {
        if is_load(b) return arc_is_stored_objc_pointer(a);
        if bi {
            if is_load(a) return arc_is_stored_objc_pointer(b);
            return false;
        }
    } else if bi {
        if is_load(a) return arc_is_stored_objc_pointer(b);
    }
    if is_phi(a) return arc_pa_related_phi(pa, a, b);
    if is_phi(b) return arc_pa_related_phi(pa, b, a);
    if is_inst(a) && inst_op(a) == .SELECT return arc_pa_related_select(pa, a, b);
    if is_inst(b) && inst_op(b) == .SELECT return arc_pa_related_select(pa, b, a);
    return true;
}

// ProvenanceAnalysis::related
arc_pa_related :: (pa: *Arc_Pa, a_in: Value_Id, b_in: Value_Id) -> bool {
    a := arc_underlying_cached(pa, a_in);
    b := arc_underlying_cached(pa, b_in);
    if a == b return true;
    key := ((cast(u64) a) << 32) | cast(u64) b;
    p := table_find_pointer(*pa.cache, key);
    if p return p.*;
    table_set(*pa.cache, key, true);
    r := arc_pa_related_check(pa, a, b);
    table_set(*pa.cache, key, r);
    return r;
}

// ---------------------------------------------------------------- DependencyAnalysis.cpp

Arc_Dep :: enum u8 { NeedsPositiveRetainCount; AutoreleasePoolBoundary; CanChangeRetainCount; RetainAutoreleaseDep; RetainAutoreleaseRVDep; }

// CanAlterRefCount
arc_can_alter_ref_count :: (i: Value_Id, ptr: Value_Id, pa: *Arc_Pa, k: Arc_Kind) -> bool {
    if k == .Autorelease || k == .AutoreleaseRV || k == .IntrinsicUser || k == .User return false;
    me := aa_memory_effects_call(aa_query_new(pa.aar), i);
    if mem_only_reads(me) return false;
    if me_only_accesses_arg_pointees(me) {
        n := call_num_args(i);
        if n > 0 for x: 0..n-1 {
            o := call_arg(i, x);
            if arc_is_potential_retainable_aa(o, pa.aar) && arc_pa_related(pa, ptr, o) return true;
        }
        return false;
    }
    return true;
}
// CanDecrementRefCount(Inst, Ptr, PA, Class)
arc_can_decrement_ref_count :: (i: Value_Id, ptr: Value_Id, pa: *Arc_Pa, k: Arc_Kind) -> bool {
    o := inst_op(i);
    if o == .STORE && inst(i).ord1 != 0 return true;
    if o == .ATOMICRMW || o == .CMPXCHG return true;
    if !arc_kind_can_decrement_ref_count(k) return false;
    return arc_can_alter_ref_count(i, ptr, pa, k);
}
// CanUse
arc_can_use :: (i: Value_Id, ptr: Value_Id, pa: *Arc_Pa, k: Arc_Kind) -> bool {
    if k == .Call return false;
    o := inst_op(i);
    if o == .ICMP {
        if !arc_is_potential_retainable_aa(op(i, 1), pa.aar) return false;
    } else if is_call_base(i) {
        n := call_num_args(i);
        if n > 0 for x: 0..n-1 {
            a := call_arg(i, x);
            if arc_is_potential_retainable_aa(a, pa.aar) && arc_pa_related(pa, ptr, a) return true;
        }
        return false;
    } else if o == .STORE {
        p := arc_underlying_objc_ptr(op(i, 1));
        return arc_is_potential_retainable_aa(p, pa.aar) && arc_pa_related(pa, p, ptr);
    }
    n := nops(i);
    if n > 0 for x: 0..n-1 {
        a := op(i, x);
        if a == NONE continue;
        if arc_is_potential_retainable_aa(a, pa.aar) && arc_pa_related(pa, ptr, a) return true;
    }
    return false;
}

// Depends
arc_depends :: (flavor: Arc_Dep, i: Value_Id, arg: Value_Id, pa: *Arc_Pa) -> bool {
    if i == arg return true;
    if flavor == {
        case .NeedsPositiveRetainCount;
            k := arc_inst_kind(i);
            if k == .AutoreleasepoolPop || k == .AutoreleasepoolPush || k == .None return false;
            return arc_can_use(i, arg, pa, k);
        case .AutoreleasePoolBoundary;
            k := arc_inst_kind(i);
            return k == .AutoreleasepoolPop || k == .AutoreleasepoolPush;
        case .CanChangeRetainCount;
            k := arc_inst_kind(i);
            if k == .AutoreleasepoolPop return true;
            if k == .AutoreleasepoolPush || k == .None return false;
            return arc_can_alter_ref_count(i, arg, pa, k);
        case .RetainAutoreleaseDep;
            k := arc_basic_kind(i);
            if k == .AutoreleasepoolPop || k == .AutoreleasepoolPush return true;
            if k == .Retain || k == .RetainRV return arc_arg_rc_identity_root(i) == arg;
            return false;
        case .RetainAutoreleaseRVDep;
            k := arc_basic_kind(i);
            if k == .Retain || k == .RetainRV return arc_arg_rc_identity_root(i) == arg;
            return arc_can_interrupt_rv(k);
    }
    return false;
}

// findDependencies + findSingleDependency
arc_find_single_dependency :: (flavor: Arc_Dep, arg: Value_Id, start_bb: Value_Id, start_inst: Value_Id, pa: *Arc_Pa) -> Value_Id {
    Item :: struct { bb: Value_Id; pos: Value_Id; }   // pos: the instruction after the scan start (NONE = block end)
    visited: Table(Value_Id, bool); visited.allocator = temp;
    visited_list: [..] Value_Id; visited_list.allocator = temp;
    wl: [..] Item; wl.allocator = temp;
    depending: [..] Value_Id; depending.allocator = temp;
    preds: [..] Value_Id; preds.allocator = temp;
    array_add(*wl, .{start_bb, start_inst});
    while wl.count {
        it := pop(*wl);
        bb := it.bb;
        pos := it.pos;
        while true {
            prev := ifx pos == NONE then block(bb).last else inst(pos).prev;
            if prev == NONE {
                preds.count = 0;
                block_predecessors(bb, *preds);
                if preds.count == 0 return NONE;
                for p: preds if !table_contains(*visited, p) {
                    table_set(*visited, p, true); array_add(*visited_list, p);
                    array_add(*wl, .{p, NONE});
                }
                break;
            }
            pos = prev;
            if arc_depends(flavor, pos, arg, pa) {
                dup := false;
                for depending if it == pos { dup = true; break; }
                if !dup array_add(*depending, pos);
                break;
            }
        }
    }
    succs: [..] Value_Id; succs.allocator = temp;
    for b: visited_list {
        if b == start_bb continue;
        succs.count = 0;
        block_successors(b, *succs);
        for s: succs if s != start_bb && !table_contains(*visited, s) return NONE;
    }
    if depending.count != 1 return NONE;
    return depending[0];
}

// ---------------------------------------------------------------- PtrState.cpp

Arc_Seq :: enum u8 { None; Retain; CanRelease; Use; Stop; MovableRelease; }

// RRInfo (Calls / ReverseInsertPts: SmallPtrSet<Instruction *, 2> as insertion-ordered arrays)
Arc_Rr_Info :: struct {
    known_safe: bool;
    is_tail_call_release: bool;
    release_md: Md_Id = NONE;
    calls: [..] Value_Id;
    rips: [..] Value_Id;
    cfg_hazard: bool;
}
arc_set_insert :: (s: *[..] Value_Id, v: Value_Id) -> bool {
    for s.* if it == v return false;
    if s.allocator.proc == null s.allocator = temp;
    array_add(s, v);
    return true;
}
arc_set_contains :: (s: [..] Value_Id, v: Value_Id) -> bool { for s if it == v return true; return false; }
arc_set_copy :: (s: [..] Value_Id) -> [..] Value_Id {
    r: [..] Value_Id; r.allocator = temp;
    if s.count { array_reserve(*r, s.count); for s array_add(*r, it); }
    return r;
}
arc_rri_copy :: (r: Arc_Rr_Info) -> Arc_Rr_Info {
    c := r;
    c.calls = arc_set_copy(r.calls);
    c.rips = arc_set_copy(r.rips);
    return c;
}
arc_rri_clear :: (r: *Arc_Rr_Info) {
    r.known_safe = false; r.is_tail_call_release = false; r.release_md = NONE;
    r.calls.count = 0; r.rips.count = 0; r.cfg_hazard = false;
}
// RRInfo::Merge
arc_rri_merge :: (r: *Arc_Rr_Info, o: *Arc_Rr_Info) -> bool {
    if r.release_md != o.release_md r.release_md = NONE;
    r.known_safe &= o.known_safe;
    r.is_tail_call_release &= o.is_tail_call_release;
    r.cfg_hazard |= o.cfg_hazard;
    for o.calls arc_set_insert(*r.calls, it);
    partial := r.rips.count != o.rips.count;
    for o.rips partial |= arc_set_insert(*r.rips, it);
    return partial;
}

Arc_Ptr_State :: struct {
    known_positive: bool;
    partial: bool;
    seq: Arc_Seq;
    rri: Arc_Rr_Info;
}
arc_ps_copy :: (s: Arc_Ptr_State) -> Arc_Ptr_State { c := s; c.rri = arc_rri_copy(s.rri); return c; }
arc_ps_reset :: (s: *Arc_Ptr_State, seq: Arc_Seq) { s.seq = seq; s.partial = false; arc_rri_clear(*s.rri); }
arc_ps_clear_progress :: (s: *Arc_Ptr_State) { arc_ps_reset(s, .None); }

// MergeSeqs
arc_merge_seqs :: (a_in: Arc_Seq, b_in: Arc_Seq, top_down: bool) -> Arc_Seq {
    a, b := a_in, b_in;
    if a == b return a;
    if a == .None || b == .None return .None;
    if a > b { t := a; a = b; b = t; }
    if top_down {
        if (a == .Retain || a == .CanRelease) && (b == .CanRelease || b == .Use) return b;
    } else {
        if (a == .Use || a == .CanRelease) && (b == .Use || b == .Stop || b == .MovableRelease) return a;
        if a == .Stop && b == .MovableRelease return a;
    }
    return .None;
}
// PtrState::Merge
arc_ps_merge :: (s: *Arc_Ptr_State, o: *Arc_Ptr_State, top_down: bool) {
    s.seq = arc_merge_seqs(s.seq, o.seq, top_down);
    s.known_positive &= o.known_positive;
    if s.seq == .None {
        s.partial = false;
        arc_rri_clear(*s.rri);
    } else if s.partial || o.partial {
        arc_ps_clear_progress(s);
    } else {
        s.partial = arc_rri_merge(*s.rri, *o.rri);
    }
}

// BottomUpPtrState::InitBottomUp
arc_bu_init :: (s: *Arc_Ptr_State, i: Value_Id) -> bool {
    nesting := s.seq == .MovableRelease;
    md := get_metadata(i, arc_md_imprecise_release());
    new_seq: Arc_Seq = ifx md != NONE then .MovableRelease else .Stop;
    arc_ps_reset(s, new_seq);
    if new_seq == .Stop arc_set_insert(*s.rri.rips, i);
    s.rri.release_md = md;
    s.rri.known_safe = s.known_positive;
    s.rri.is_tail_call_release = arc_is_tail_call(i);
    arc_set_insert(*s.rri.calls, i);
    s.known_positive = true;
    return nesting;
}
// BottomUpPtrState::MatchWithRetain
arc_bu_match_with_retain :: (s: *Arc_Ptr_State) -> bool {
    s.known_positive = true;
    old := s.seq;
    if old == {
        case .Stop; #through; case .MovableRelease; #through; case .Use;
            if old != .Use || s.rri.release_md != NONE s.rri.rips.count = 0;
            return true;
        case .CanRelease; return true;
        case .None; return false;
    }
    assert(false, "bottom-up pointer in retain state!");
    return false;
}
// BottomUpPtrState::HandlePotentialAlterRefCount
arc_bu_handle_potential_alter_ref_count :: (s: *Arc_Ptr_State, i: Value_Id, ptr: Value_Id, pa: *Arc_Pa, k: Arc_Kind) -> bool {
    seq := s.seq;
    if !arc_can_decrement_ref_count(i, ptr, pa, k) return false;
    if seq == .Use { s.seq = .CanRelease; return true; }
    assert(seq != .Retain, "bottom-up pointer in retain state!");
    return false;
}
// skipDebugIntrinsics
arc_skip_debug_intrinsics :: (i_in: Value_Id) -> Value_Id {
    i := i_in;
    while i != NONE {
        id := call_iid(i);
        if id != IID_DBG_DECLARE && id != IID_DBG_VALUE && id != IID_DBG_LABEL && id != IID_DBG_ASSIGN break;
        i = inst(i).next;
    }
    return i;
}
// BottomUpPtrState::HandlePotentialUse
arc_bu_handle_potential_use :: (s: *Arc_Ptr_State, bb: Value_Id, i: Value_Id, ptr: Value_Id, pa: *Arc_Pa, k: Arc_Kind) {
    set_seq_and_insert_rip :: (s: *Arc_Ptr_State, bb: Value_Id, i: Value_Id, new_seq: Arc_Seq) {
        assert(s.rri.rips.count == 0);
        s.seq = new_seq;
        after: Value_Id;
        if inst_op(i) == .INVOKE {
            ip := block_first_insertion_pt(bb);
            after = ifx ip == NONE then block(bb).last else ip;
            if inst_op(after) == .CATCHSWITCH s.rri.cfg_hazard = true;
        } else after = inst(i).next;
        if after != NONE after = arc_skip_debug_intrinsics(after);
        if after == NONE fatal("objc-arc: a reverse insertion point at the end of a block");
        arc_set_insert(*s.rri.rips, after);
        if is_call_base(i) && arc_has_attached_call_bundle(i) s.rri.cfg_hazard = true;
    }
    if s.seq == {
        case .MovableRelease;
            if arc_can_use(i, ptr, pa, k) set_seq_and_insert_rip(s, bb, i, .Use);
            else {
                c := arc_return_rv_operand(i, k);
                if c != NONE && arc_can_use(c, ptr, pa, arc_basic_kind(c)) set_seq_and_insert_rip(s, bb, i, .Stop);
            }
        case .Stop;
            if arc_can_use(i, ptr, pa, k) s.seq = .Use;
        case .Retain; assert(false, "bottom-up pointer in retain state!");
    }
}

// TopDownPtrState::InitTopDown
arc_td_init :: (s: *Arc_Ptr_State, k: Arc_Kind, i: Value_Id) -> bool {
    nesting := false;
    if k != .RetainRV {
        if s.seq == .Retain nesting = true;
        arc_ps_reset(s, .Retain);
        s.rri.known_safe = s.known_positive;
        arc_set_insert(*s.rri.calls, i);
    }
    s.known_positive = true;
    return nesting;
}
// TopDownPtrState::MatchWithRelease
arc_td_match_with_release :: (s: *Arc_Ptr_State, release: Value_Id) -> bool {
    s.known_positive = false;
    old := s.seq;
    md := get_metadata(release, arc_md_imprecise_release());
    if old == {
        case .Retain; #through; case .CanRelease;
            if old == .Retain || md != NONE s.rri.rips.count = 0;
            #through;
        case .Use;
            s.rri.release_md = md;
            s.rri.is_tail_call_release = arc_is_tail_call(release);
            return true;
        case .None; return false;
    }
    assert(false, "top-down pointer in bottom up state!");
    return false;
}
// TopDownPtrState::HandlePotentialAlterRefCount
arc_td_handle_potential_alter_ref_count :: (s: *Arc_Ptr_State, i: Value_Id, ptr: Value_Id, pa: *Arc_Pa, k: Arc_Kind, bundled: *Arc_Bundled) -> bool {
    if !arc_can_decrement_ref_count(i, ptr, pa, k) && k != .IntrinsicUser return false;
    s.known_positive = false;
    if s.seq == .Retain {
        s.seq = .CanRelease;
        assert(s.rri.rips.count == 0);
        arc_set_insert(*s.rri.rips, i);
        if arc_bundled_contains(bundled, i) s.rri.cfg_hazard = true;
        return true;
    }
    return false;
}
// TopDownPtrState::HandlePotentialUse
arc_td_handle_potential_use :: (s: *Arc_Ptr_State, i: Value_Id, ptr: Value_Id, pa: *Arc_Pa, k: Arc_Kind) {
    if s.seq == .CanRelease {
        if !arc_can_use(i, ptr, pa, k) return;
        s.seq = .Use;
    }
}

// ---------------------------------------------------------------- objc-arc-aa (ObjCARCAliasAnalysis.cpp)

// ObjCARCAAResult::alias: AAResultBase::alias is MayAlias, so this is always MayAlias.
// ObjCARCAAResult::getModRefInfoMask: AAResultBase's is ModRef, so this is always ModRef.
// ObjCARCAAResult::getMemoryEffects(F)
objc_arc_aa_memory_effects_fn :: (f: Value_Id) -> u64 {
    if arc_cl.enable_arc_opts && arc_function_class(f) == .NoopCast return ME_NONE;
    return MEM_UNKNOWN;
}
// ObjCARCAAResult::getModRefInfo(Call, Loc)
objc_arc_aa_mod_ref_call_loc :: (call: Value_Id) -> u8 {
    if !arc_cl.enable_arc_opts return MR_MODREF;
    k := arc_basic_kind(call);
    if k == .Retain || k == .RetainRV || k == .Autorelease || k == .AutoreleaseRV || k == .NoopCast ||
       k == .AutoreleasepoolPush || k == .FusedRetainAutorelease || k == .FusedRetainAutoreleaseRV return MR_NO;
    return MR_MODREF;
}

// Value::stripPointerCasts (PSK_ZeroIndices, through `returned` arguments)
arc_strip :: inline (v: Value_Id) -> Value_Id { return strip_pointer_casts_kind(v, .ZERO_INDICES); }
