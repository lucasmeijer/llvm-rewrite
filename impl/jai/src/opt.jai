// opt: textual IR in, textual IR out (llvm/tools/opt). Passes are added unit by unit.

#load "ir.jai";
#load "gen_attrs.jai";
#load "gen_cc.jai";
#load "gen_intrinsics.jai";
#load "apfloat.jai";
#load "datalayout.jai";
#load "lexer.jai";
#load "parser.jai";
#load "printer.jai";
#load "intrinsics.jai";
#load "gen_iit.jai";
#load "autoupgrade.jai";
#load "constfold.jai";
#load "debuginfo.jai";
#load "gen_dwarf.jai";

#load "apint.jai";
#load "knownbits.jai";
#load "ir_edit.jai";
#load "inst_props.jai";
#load "print_util.jai";
#load "domtree.jai";
#load "analysis_base.jai";
#load "intrinsic_ids.jai";
#load "cmp_pred.jai";
#load "constant_range.jai";
#load "pattern.jai";
#load "value_tracking.jai";
#load "value_tracking2.jai";
#load "fpclass.jai";
#load "const_folding.jai";
#load "apfloat_ops.jai";
#load "const_folding_calls.jai";
#load "inst_simplify.jai";
#load "demanded_bits.jai";
#load "passes.jai";
#load "pass_dce.jai";
#load "pass_adce.jai";
#load "pass_bdce.jai";
#load "dbg_records.jai";
#load "pass_mem2reg.jai";
#load "pass_instsimplify.jai";
#load "ir_builder.jai";
#load "value_utils.jai";
#load "ssa_updater.jai";
#load "pass_sroa.jai";
#load "capture_tracking.jai";
#load "aa.jai";
#load "basic_aa.jai";
#load "tbaa.jai";
#load "scoped_noalias_aa.jai";
#load "memoryssa.jai";
#load "globals_aa.jai";
#load "loop_info.jai";
#load "cycle_info.jai";
#load "bb_utils.jai";
#load "mssa_updater.jai";

main :: () { opt_main(); }

#import "Basic";
#import "File";
#import "String";
