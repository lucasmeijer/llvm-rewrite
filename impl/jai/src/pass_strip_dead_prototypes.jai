// StripDeadPrototypes: delete unused function and global variable declarations.
// Ported from llvm/lib/Transforms/IPO/StripDeadPrototypes.cpp.

strip_dead_prototypes_run :: () -> Preserved {
    made_change := false;
    i := 0;
    while i < ir.m_functions.count {
        f := ir.m_functions[i];
        if is_declaration(f) && !has_uses(f) {
            gv_erase_from_parent(f);
            made_change = true;
            continue;
        }
        i += 1;
    }
    i = 0;
    while i < ir.m_globals.count {
        gv := ir.m_globals[i];
        if is_declaration(gv) && !has_uses(gv) { gv_erase_from_parent(gv); continue; }
        i += 1;
    }
    if made_change { printer_note_ir_changed(); return PRESERVE_NONE; }
    return PRESERVE_ALL;
}
