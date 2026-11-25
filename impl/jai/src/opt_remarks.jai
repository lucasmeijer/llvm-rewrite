// Optimization remarks on stderr for `-pass-remarks=<regex>` (llvm/lib/IR/DiagnosticInfo.cpp,
// DiagnosticInfoOptimizationBase / DiagnosticInfoWithLocationBase::getLocationStr, and the RemarkPassed filter of
// llvm/lib/IR/LLVMRemarkStreamer.cpp / opt's PassRemarksOpt). Only the `loop-vectorize` remarks are ported: any other
// pattern fails loudly, since passes that would report something print nothing here. -pass-remarks-missed and
// -pass-remarks-analysis stay unsupported options.

remarks_cl: struct {
    passed: string;   // -pass-remarks
};

remarks_parse_cl_opt :: (name: string, value: string, has_value: bool) -> bool {
    if name != "pass-remarks" return false;
    if !has_value fatal("for the --pass-remarks option: requires a value!");
    if value != "loop-vectorize" fatal("unsupported option '--pass-remarks=%' (only loop-vectorize remarks are ported)", value);
    remarks_cl.passed = copy_string(value);
    return true;
}

// OptimizationRemarkEmitter::enabled(): DiagnosticHandler::isAnyRemarkEnabled() for any pass
remarks_enabled :: () -> bool { return remarks_cl.passed.count != 0; }
// DiagnosticHandler::isAnyRemarkEnabled(PassName) = OptimizationRemarkEmitter::allowExtraAnalysis
remarks_any_enabled :: (pass_name: string) -> bool { return remarks_cl.passed.count != 0 && remarks_cl.passed == pass_name; }
// isPassedOptRemarkEnabled
remarks_passed_enabled :: (pass_name: string) -> bool { return remarks_any_enabled(pass_name); }

// ORE->emit(OptimizationRemark(PassName, ..., Loc, ...) << msg): "remark: <file>:<line>:<col>: <msg>"
remark_emit_passed :: (pass_name: string, loc: Md_Id, msg: string) {
    if !remarks_passed_enabled(pass_name) return;
    where := "<unknown>:0:0";
    if loc != NONE {
        s := diloc_scope(loc);
        file := ifx s != NONE then discope_file(s) else NONE;
        if file != NONE where = tprint("%:%:%", md_str_of(di_op(file, 0)), diloc_line(loc), diloc_col(loc));
    }
    print_stderr("remark: %: %\n", where, msg);
}
