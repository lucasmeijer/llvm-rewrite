// stub
import std;
import ir;
import analyses;
fn inl_run_cgscc(c: i32, only_mandatory: bool) -> u32 { fatal("inline not implemented yet"); return PA_ALL; }
fn always_inliner_run(m: i32) -> u32 { fatal("always-inline not implemented yet"); return PA_ALL; }
fn module_inliner_run(m: i32) -> u32 { fatal("module-inline not implemented yet"); return PA_ALL; }
fn inliner_wrapper_run(m: i32, nomand: bool) -> u32 { fatal("inliner-wrapper not implemented yet"); return PA_ALL; }
