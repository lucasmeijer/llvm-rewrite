// SimplifyCFG.cpp, fourth part: switches, icmp chains, conditional branch pairs, stores, invokes, EH, unreachable.

try_to_simplify_uncond_branch_with_icmp_in_it :: (s: *Scfg, icmp: Value_Id, b: *Irb) -> bool { scfg_np("tryToSimplifyUncondBranchWithICmpInIt"); return false; }
try_to_simplify_uncond_branch_with_icmp_select_in_it :: (s: *Scfg, icmp: Value_Id, sel: Value_Id, b: *Irb) -> bool { scfg_np("tryToSimplifyUncondBranchWithICmpSelectInIt"); return false; }
simplify_branch_on_icmp_chain :: (s: *Scfg, bi: Value_Id, b: *Irb) -> bool { return false; }
simplify_cond_branch_to_cond_branch :: (s: *Scfg, pbi: Value_Id, bi: Value_Id) -> bool { return false; }
merge_conditional_stores :: (s: *Scfg, pbi: Value_Id, qbi: Value_Id) -> bool { return false; }
merge_compatible_invokes :: (s: *Scfg, bb: Value_Id) -> bool { return false; }
simplify_duplicate_predecessors :: (s: *Scfg, bb: Value_Id) -> bool { return false; }
simplify_resume :: (s: *Scfg, ri: Value_Id, b: *Irb) -> bool { scfg_np("simplifyResume"); return false; }
simplify_cleanup_return :: (s: *Scfg, ri: Value_Id) -> bool { scfg_np("simplifyCleanupReturn"); return false; }
simplify_switch :: (s: *Scfg, si: Value_Id, b: *Irb) -> bool { scfg_np("simplifySwitch"); return false; }
simplify_unreachable :: (s: *Scfg, ui: Value_Id) -> bool { scfg_np("simplifyUnreachable"); return false; }
simplify_indirect_br :: (s: *Scfg, ibi: Value_Id) -> bool { scfg_np("simplifyIndirectBr"); return false; }
