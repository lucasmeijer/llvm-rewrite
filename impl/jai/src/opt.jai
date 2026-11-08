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
#load "known_bits.jai";
#load "demanded_bits.jai";
#load "passes.jai";
#load "pass_dce.jai";
#load "pass_adce.jai";
#load "pass_bdce.jai";
#load "dbg_records.jai";
#load "pass_mem2reg.jai";

main :: () { opt_main(); }

#import "Basic";
#import "File";
#import "String";
