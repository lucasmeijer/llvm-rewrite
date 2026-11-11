// Coroutine passes of the -O2 pipeline: the early exits of llvm/lib/Transforms/Coroutines/CoroEarly.cpp
// (declaresCoroEarlyIntrinsics), CoroCleanup.cpp (declaresCoroCleanupIntrinsics), CoroElide.cpp
// (declaresIntrinsics(M, coro_id)), CoroSplit.cpp (no presplit coroutine and no llvm.coro.prepare.* in the SCC) and
// CoroAnnotationElide.cpp (no "<callee>.noalloc" function), with coro::declaresIntrinsics from Coroutines.cpp. A
// module that needs the actual lowering fails loudly: the coroutine transforms are not ported.

coro_declares_any :: (names: [] string) -> bool {
    for names if module_get_function(it) != NONE return true;   // Intrinsic::getDeclarationIfExists
    return false;
}

coro_early_run :: () -> Preserved {
    // coro_suspend omitted as it is overloaded
    if !coro_declares_any(.["llvm.coro.id", "llvm.coro.id.retcon", "llvm.coro.id.retcon.once", "llvm.coro.id.async",
                            "llvm.coro.destroy", "llvm.coro.done", "llvm.coro.end", "llvm.coro.end.async",
                            "llvm.coro.free", "llvm.coro.promise", "llvm.coro.resume"]) return PRESERVE_ALL;
    fatal("coro-early: lowering coroutine intrinsics is not implemented yet");
    return PRESERVE_NONE;
}

coro_cleanup_run :: () -> Preserved {
    if !coro_declares_any(.["llvm.coro.alloc", "llvm.coro.begin", "llvm.coro.subfn.addr", "llvm.coro.free",
                            "llvm.coro.dead", "llvm.coro.id", "llvm.coro.id.retcon", "llvm.coro.id.async",
                            "llvm.coro.id.retcon.once", "llvm.coro.noop", "llvm.coro.async.size.replace",
                            "llvm.coro.async.resume", "llvm.coro.begin.custom.abi"]) return PRESERVE_ALL;
    fatal("coro-cleanup: lowering coroutine intrinsics is not implemented yet");
    return PRESERVE_NONE;
}

coro_elide_run :: (f: Value_Id) -> Preserved {
    if !coro_declares_any(.["llvm.coro.id"]) return PRESERVE_ALL;
    fatal("coro-elide: coroutine heap elision is not implemented yet");
    return PRESERVE_NONE;
}

coro_split_run_scc :: (c: s32) -> Preserved {
    prepare := module_get_function("llvm.coro.prepare.retcon") != NONE || module_get_function("llvm.coro.prepare.async") != NONE;
    if prepare fatal("coro-split: llvm.coro.prepare.retcon/async is not implemented yet");
    for n: lcg.sccs[c].nodes if fn_has_fn_attr(lcg_fn(n), .PresplitCoroutine) fatal("coro-split: splitting coroutines is not implemented yet");
    return PRESERVE_ALL;
}

coro_annotation_elide_run_scc :: (c: s32) -> Preserved {
    for n: lcg.sccs[c].nodes {
        if module_get_function(tconcat(vname(lcg_fn(n)), ".noalloc")) != NONE
            fatal("coro-annotation-elide: eliding coroutine allocations is not implemented yet");
    }
    return PRESERVE_ALL;
}

// coro::declaresAnyIntrinsic (Coroutines.cpp, NonOverloadedCoroIntrinsics): CoroConditionalWrapper's condition
coro_declares_any_intrinsic :: () -> bool {
    return coro_declares_any(.["llvm.coro.alloc", "llvm.coro.async.context.alloc", "llvm.coro.async.context.dealloc",
        "llvm.coro.async.resume", "llvm.coro.async.size.replace", "llvm.coro.await.suspend.bool",
        "llvm.coro.await.suspend.handle", "llvm.coro.await.suspend.void", "llvm.coro.begin", "llvm.coro.begin.custom.abi",
        "llvm.coro.destroy", "llvm.coro.done", "llvm.coro.end", "llvm.coro.end.async", "llvm.coro.frame", "llvm.coro.free",
        "llvm.coro.id", "llvm.coro.id.async", "llvm.coro.id.retcon", "llvm.coro.id.retcon.once", "llvm.coro.noop",
        "llvm.coro.prepare.async", "llvm.coro.prepare.retcon", "llvm.coro.promise", "llvm.coro.resume", "llvm.coro.save",
        "llvm.coro.subfn.addr", "llvm.coro.suspend", "llvm.coro.is_in_ramp"]);
}
