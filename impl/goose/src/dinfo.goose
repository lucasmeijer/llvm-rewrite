// Debug-info metadata (llvm/IR/DebugInfoMetadata.h) and debug records (llvm/IR/DebugProgramInstruction.h).
// Debug-record bookkeeping ported from llvm/lib/IR/DebugProgramInstruction.cpp (DbgMarker: removeMarker,
// absorbDebugValues, cloneDebugInfoFrom; DbgRecord clone/erase), llvm/lib/IR/Metadata.cpp (ReplaceableMetadataImpl
// tracking, ValueAsMetadata::handleRAUW/handleDeletion, getAllDbgVariableRecordUsers/getAllArgListUsers),
// llvm/lib/IR/DebugInfoMetadata.cpp (DIArgList::handleChangedOperand/track) and llvm/lib/IR/DebugInfo.cpp
// (findDbgUsers, findDbgValues). Block insertion/splicing of records (llvm/lib/IR/BasicBlock.cpp spliceDebugInfo,
// flushTerminatorDbgRecords; llvm/lib/IR/Instruction.cpp insertBefore/moveBeforeImpl/adoptDbgRecords) is in
// ir.goose / irutil.goose on top of the marker helpers at the end of this file.
//
// A specialized node !DIxxx(...) is an Md of kind MK_DI: extra = DIK_* kind, ops = one slot per field of the
// kind's schema below (LLParser's field order). Slots hold md ids; integer-like fields hold MK_INTLIT ids;
// -1 = unset/null. Integer fields equal to their default are stored as -1, so uniquing (md_get on kind +
// slots) matches LLVM's MDNodeKeyImpl equality. Field types:
//   m metadata   s MDString (empty = null)   S MDString kept even when empty (DIFile source)
//   u unsigned   i signed   b bool   t DWARF tag   f DIFlags   p DISPFlags   A integer (DIEnumerator value)
//   a DW_ATE   L DW_LANG   N DW_LNAME   C DW_CC   V DW_VIRTUALITY   M DW_MACINFO   K DW_APPLE_ENUM_KIND
//   D dialect   E emissionKind   T nameTableKind   X checksumkind   F fixed-point kind
//   U unsigned-or-metadata, I signed-or-metadata (an integer becomes ConstantAsMetadata(i64))
//   G signed-or-metadata for DIGenericSubrange (an integer becomes !DIExpression(DW_OP_consts, N))
// A '=N' suffix gives a non-zero default; '!' means "no default": the slot records whether it was written.
import std;
import ir;
import gen_dwarf;

let DIK_NAMES: const u8[:][] = ["DILocation", "DIAssignID", "GenericDINode", "DISubrangeType", "DISubrange",
    "DIGenericSubrange", "DIEnumerator", "DIBasicType", "DIFixedPointType", "DIStringType", "DIDerivedType",
    "DICompositeType", "DISubroutineType", "DIFile", "DICompileUnit", "DISubprogram", "DILexicalBlock",
    "DILexicalBlockFile", "DICommonBlock", "DINamespace", "DIMacro", "DIMacroFile", "DIModule",
    "DITemplateTypeParameter", "DITemplateValueParameter", "DIGlobalVariable", "DILocalVariable", "DILabel",
    "DIGlobalVariableExpression", "DIObjCProperty", "DIImportedEntity"];

let DIK_FIELDS: const u8[:][] = [
    "line:u,column:u,scope:m,inlinedAt:m,isImplicitCode:b,atomGroup:u,atomRank:u",
    "",
    "tag:t,header:s",
    "name:s,file:m,line:u,scope:m,baseType:m,size:U,align:u,flags:f,lowerBound:I,upperBound:I,stride:I,bias:I",
    "count:I,lowerBound:I,upperBound:I,stride:I",
    "count:G,lowerBound:G,upperBound:G,stride:G",
    "name:s,value:A,isUnsigned:b",
    "tag:t=36,name:s,file:m,line:u,scope:m,size:U,align:u,dataSize:u,encoding:a,num_extra_inhabitants:u,flags:f",
    "tag:t=36,name:s,file:m,line:u,scope:m,size:U,align:u,encoding:a,flags:f,kind:F!,factor:i,numerator:A!,denominator:A!",
    "tag:t=18,name:s,stringLength:m,stringLengthExpression:m,stringLocationExpression:m,size:U,align:u,encoding:a",
    "tag:t,name:s,file:m,line:u,scope:m,baseType:m,size:U,align:u,offset:U,flags:f,extraData:m,dwarfAddressSpace:u!,annotations:m,ptrAuthKey:u,ptrAuthIsAddressDiscriminated:b,ptrAuthExtraDiscriminator:u,ptrAuthIsaPointer:b,ptrAuthAuthenticatesNullValues:b",
    "tag:t,name:s,file:m,line:u,scope:m,baseType:m,size:U,align:u,offset:U,flags:f,elements:m,runtimeLang:L,enumKind:K!,vtableHolder:m,templateParams:m,identifier:s,discriminator:m,dataLocation:m,associated:m,allocated:m,rank:I,annotations:m,num_extra_inhabitants:u,specification:m,bitStride:m",
    "flags:f,cc:C,types:m",
    "filename:s,directory:s,checksumkind:X!,checksum:s,source:S",
    "file:m,language:L!,sourceLanguageName:N!,sourceLanguageVersion:u,producer:s,isOptimized:b,flags:s,runtimeVersion:u,splitDebugFilename:s,emissionKind:E,enums:m,retainedTypes:m,globals:m,imports:m,macros:m,dwoId:u,splitDebugInlining:b=1,debugInfoForProfiling:b,nameTableKind:T,rangesBaseAddress:b,sysroot:s,sdk:s,dialect:D",
    "scope:m,name:s,linkageName:s,file:m,line:u,type:m,isLocal:b,isDefinition:b=1,scopeLine:u,containingType:m,virtuality:V,virtualIndex:u,thisAdjustment:i,flags:f,spFlags:p!,isOptimized:b,unit:m,templateParams:m,declaration:m,retainedNodes:m,thrownTypes:m,annotations:m,targetFuncName:s,keyInstructions:b",
    "scope:m,file:m,line:u,column:u",
    "scope:m,file:m,discriminator:u",
    "scope:m,declaration:m,name:s,file:m,line:u",
    "scope:m,name:s,exportSymbols:b",
    "type:M,line:u,name:s,value:s",
    "type:M=3,line:u,file:m,nodes:m",
    "scope:m,name:s,configMacros:s,includePath:s,apinotes:s,file:m,line:u,isDecl:b",
    "name:s,type:m,defaulted:b",
    "tag:t=48,name:s,type:m,defaulted:b,value:m",
    "name:s,scope:m,linkageName:s,file:m,line:u,type:m,isLocal:b,isDefinition:b=1,templateParams:m,declaration:m,align:u,annotations:m",
    "scope:m,name:s,arg:u,file:m,line:u,type:m,flags:f,align:u,annotations:m",
    "scope:m,name:s,file:m,line:u,column:u,isArtificial:b,coroSuspendIdx:u!",
    "var:m,expr:m",
    "name:s,file:m,line:u,setter:s,getter:s,attributes:u,type:m",
    "tag:t,scope:m,entity:m,file:m,line:u,name:s,elements:m"];

let DIK_LOCATION = 0;
let DIK_ASSIGNID = 1;
let DIK_GENERIC = 2;
let DIK_SUBRANGETYPE = 3;
let DIK_SUBRANGE = 4;
let DIK_GENERICSUBRANGE = 5;
let DIK_ENUMERATOR = 6;
let DIK_BASICTYPE = 7;
let DIK_FIXEDPOINTTYPE = 8;
let DIK_STRINGTYPE = 9;
let DIK_DERIVEDTYPE = 10;
let DIK_COMPOSITETYPE = 11;
let DIK_SUBROUTINETYPE = 12;
let DIK_FILE = 13;
let DIK_COMPILEUNIT = 14;
let DIK_SUBPROGRAM = 15;
let DIK_LEXICALBLOCK = 16;
let DIK_LEXICALBLOCKFILE = 17;
let DIK_COMMONBLOCK = 18;
let DIK_NAMESPACE = 19;
let DIK_MACRO = 20;
let DIK_MACROFILE = 21;
let DIK_MODULE = 22;
let DIK_TEMPLATETYPEPARAM = 23;
let DIK_TEMPLATEVALUEPARAM = 24;
let DIK_GLOBALVARIABLE = 25;
let DIK_LOCALVARIABLE = 26;
let DIK_LABEL = 27;
let DIK_GLOBALVAREXPR = 28;
let DIK_OBJCPROPERTY = 29;
let DIK_IMPORTEDENTITY = 30;

// MDNode operand order of each kind (DebugInfoMetadata.cpp getImpl "Ops"), which SlotTracker and
// TypeFinder walk: the fields that can hold metadata, by name.
let DIK_OPORDER: const u8[:][] = [
    "scope,inlinedAt",
    "",
    "",
    "file,scope,name,size,baseType,lowerBound,upperBound,stride,bias",
    "count,lowerBound,upperBound,stride",
    "count,lowerBound,upperBound,stride",
    "name",
    "file,scope,name,size",
    "file,scope,name,size",
    "name,size,stringLength,stringLengthExpression,stringLocationExpression",
    "file,scope,name,size,offset,baseType,extraData,annotations",
    "file,scope,name,size,offset,baseType,elements,vtableHolder,templateParams,identifier,discriminator,dataLocation,associated,allocated,rank,annotations,specification,bitStride",
    "types",
    "filename,directory,checksum,source",
    "file,producer,flags,splitDebugFilename,enums,retainedTypes,globals,imports,macros,sysroot,sdk",
    "file,scope,name,linkageName,type,unit,declaration,retainedNodes,containingType,templateParams,thrownTypes,annotations,targetFuncName",
    "file,scope",
    "file,scope",
    "scope,declaration,name,file",
    "scope,name",
    "name,value",
    "file,nodes",
    "file,scope,name,configMacros,includePath,apinotes",
    "name,type",
    "name,type,value",
    "scope,name,file,type,linkageName,declaration,templateParams,annotations",
    "scope,name,file,type,annotations",
    "scope,name,file",
    "var,expr",
    "name,file,getter,setter,type",
    "scope,entity,name,file,elements"];

// Fills out with the slot values of m in MDNode operand order.
fn di_operands(m: i32, out: i32[>..<]&) {
    let kind = di_kind(m);
    let spec = DIK_OPORDER[kind];
    if spec.len == 0 { return; }
    each_split(spec, ',') { out.push(md_op(m, di_field_index(kind, it))); };
}

// Decoded schemas: per kind, a run [fstart, fstart + fcount) of fields.
struct DiField { name: i32, ty: u8, has_default: u8, def: i64 }
var di_fields: DiField[>..];
var dik_start: i32[>..];
var dik_count: i32[>..];

fn di_init() {
    if dik_start.len > 0 { return; }
    for spec in DIK_FIELDS {
        dik_start.push(di_fields.len as i32);
        var n = 0;
        if spec.len > 0 {
            each_split(spec, ',') {
                let f = it;
                var c = 0;
                while f[c] != ':' { c++; }
                let nm = intern(f[..c]);
                let ty = f[c + 1];
                var hd: u8 = 1;
                var def: i64 = 0;
                if f.len > c + 2 {
                    if f[c + 2] == '!' { hd = 0; }
                    else {
                        var v: i64 = 0;
                        for k in (c + 3)..f.len { v = v * 10 + (f[k] - '0') as i64; }
                        def = v;
                    }
                }
                di_fields.push(DiField { name: nm, ty: ty, has_default: hd, def: def });
                n++;
            };
        }
        dik_count.push(n as i32);
    }
}

fn dik_lookup(name: const u8[:]) -> i64 {
    for n, i in DIK_NAMES { if n == name { return i; } }
    return -1;
}

fn di_field_index(kind: i64, name: const u8[:]) -> i64 {
    di_init();
    let st = dik_start[kind] as i64;
    for k in dik_count[kind] {
        if sbytes(di_fields[st + k].name) == name { return k; }
    }
    return -1;
}

// ---------------------------------------------------------------------------------------------
// Integer literals inside DI nodes

fn md_int(v: i64) -> i32 {
    let u = v as! u64;
    let lo = (u & 0xFFFFFFFF) as! i32;
    let hi = (u >> 32) as! i32;
    return md_get(MK_INTLIT, lo, [hi], false);
}
fn md_int_val(m: i32) -> i64 {
    let lo = (mds[m].extra as! u32) as u64;
    let hi = (md_op(m, 0) as! u32) as u64;
    return (lo | (hi << 32)) as! i64;
}

// Field access by name.
fn di_kind(m: i32) -> i64 { mds[m].extra as i64 }
fn di_slot(m: i32, name: const u8[:]) -> i32 {
    let k = di_field_index(di_kind(m), name);
    if k < 0 { fatal(str("internal: no DI field ", name)); }
    return md_op(m, k);
}
fn di_has(m: i32, name: const u8[:]) -> bool { di_slot(m, name) >= 0 }
fn di_int(m: i32, name: const u8[:]) -> i64 {
    let kind = di_kind(m);
    let k = di_field_index(kind, name);
    let s = md_op(m, k);
    if s >= 0 { return md_int_val(s); }
    return di_fields[dik_start[kind] as i64 + k].def;
}
fn di_str(m: i32, name: const u8[:]) -> const u8[:] {
    let s = di_slot(m, name);
    if s < 0 { return ""; }
    return sbytes(mds[s].extra);
}

// ---------------------------------------------------------------------------------------------
// DWARF name tables

fn dw_name(names: const u8[:][:], vals: const i64[:], v: i64) -> const u8[:] {
    for x, i in vals { if x == v { return names[i]; } }
    return "";
}
fn dw_value(names: const u8[:][:], vals: const i64[:], s: const u8[:]) -> i64 {
    for n, i in names { if n == s { return vals[i]; } }
    return -1;
}

// DIExpression::ExprOperand::getSize
fn diexpr_op_size(op: i64) -> i64 {
    if op >= 0x70 && op <= 0x8f { return 2; }   // DW_OP_breg0..31
    if op == 0x1001 || op == 0x1000 || op == 0x1006 || op == 0x1007 || op == 0x92 { return 3; }
    if op == 0x10 || op == 0x11 || op == 0x94 || op == 0x23 || op == 0x1002 || op == 0x1003 || op == 0x1005 || op == 0x90 { return 2; }
    return 1;
}

// ---------------------------------------------------------------------------------------------
// Debug records (DbgVariableRecord / DbgLabelRecord), attached before an instruction.

let DR_VALUE = 0;
let DR_DECLARE = 1;
let DR_ASSIGN = 2;
let DR_LABEL = 3;
let DR_DECLARE_VALUE = 4;

// loc/addr: metadata (ValueAsMetadata, DIArgList or MDNode), var (or label), expr, aid, aexpr, dl: md ids.
// owner: the instruction whose marker holds the record (-1 = none), kept by inst_add_dbg / dbg_records_to_next.
struct DbgRec { kind: u8, dead: u8, loc: i32, dvar: i32, expr: i32, aid: i32, addr: i32, aexpr: i32, dl: i32, next: i32, owner: i32 }
var dbgrecs: DbgRec[>..];
var inst_dbg: i32[>..];        // inst sub -> first record (-1)

fn inst_first_dbg(iv: i32) -> i32 {
    let i = inst_of(iv);
    if i < inst_dbg.len { return inst_dbg[i]; }
    return -1;
}

// BasicBlock::insertDbgRecordBefore: appended to the instruction's marker.
fn inst_add_dbg(iv: i32, r: i32) {
    let i = inst_of(iv);
    while inst_dbg.len <= i { inst_dbg.push(-1); }
    dbgrecs[r].next = -1;
    dbgrecs[r].owner = iv;
    if inst_dbg[i] < 0 { inst_dbg[i] = r; return; }
    var p = inst_dbg[i];
    while dbgrecs[p].next >= 0 { p = dbgrecs[p].next; }
    dbgrecs[p].next = r;
}

fn new_dbgrec(kind: i64) -> i32 {
    let r = dbgrecs.len as i32;
    dbgrecs.push(DbgRec { kind: kind as u8, dead: 0, loc: -1, dvar: -1, expr: -1, aid: -1, addr: -1, aexpr: -1, dl: -1, next: -1, owner: -1 });
    return r;
}

// BasicBlock trailing records (DbgMarker at end()): the records of an erased last instruction, by block sub; they
// are adopted by the next instruction appended to the block (Instruction::insertBefore, flushTerminatorDbgRecords).
var block_trail: i32[>..];
fn dbg_adopt_trailing(bv: i32, iv: i32) {
    let b = block_of(bv);
    let head = block_trail[b];
    block_trail[b] = -1;
    let i = inst_of(iv);
    while inst_dbg.len <= i { inst_dbg.push(-1); }
    // the new instruction has no records of its own (a detached instruction has no marker)
    var r = head;
    var last = -1;
    while r >= 0 { dbgrecs[r].owner = iv; last = r; r = dbgrecs[r].next; }
    if inst_dbg[i] >= 0 { dbgrecs[last].next = inst_dbg[i]; }
    inst_dbg[i] = head;
}

// DbgMarker::removeMarker: when an instruction is erased, its records move to the head of the next
// instruction's records (or become the block's trailing records). Call before inst_erase.
fn dbg_records_to_next(iv: i32) {
    let i = inst_of(iv);
    if i >= inst_dbg.len || inst_dbg[i] < 0 { return; }
    let nx = insts[i].next;
    if nx < 0 {
        var r = inst_dbg[i];
        var last = -1;
        let bv = insts[i].parent;
        while r >= 0 { dbgrecs[r].owner = -2 - bv; last = r; r = dbgrecs[r].next; }
        if bv >= 0 {
            let b = block_of(bv);
            while block_trail.len <= b { block_trail.push(-1); }
            // a trailing marker that already exists absorbs them at its end
            if block_trail[b] >= 0 {
                var t = block_trail[b];
                while dbgrecs[t].next >= 0 { t = dbgrecs[t].next; }
                dbgrecs[t].next = inst_dbg[i];
            } else { block_trail[b] = inst_dbg[i]; }
        }
        inst_dbg[i] = -1;
        return;
    }
    let ni = inst_of(nx);
    while inst_dbg.len <= ni { inst_dbg.push(-1); }
    var last = inst_dbg[i];
    dbgrecs[last].owner = nx;
    while dbgrecs[last].next >= 0 { last = dbgrecs[last].next; dbgrecs[last].owner = nx; }
    dbgrecs[last].next = inst_dbg[ni];
    inst_dbg[ni] = inst_dbg[i];
    inst_dbg[i] = -1;
}

// DbgRecord::eraseFromParent: unlink the record from its instruction's marker.
fn dbg_erase_record(r: i32) {
    let o = dbgrecs[r].owner;
    if o <= -2 {
        // a trailing record of block -2 - o
        let b = block_of(-2 - o);
        if block_trail[b] == r { block_trail[b] = dbgrecs[r].next; }
        else {
            var p = block_trail[b];
            while p >= 0 && dbgrecs[p].next != r { p = dbgrecs[p].next; }
            if p < 0 { fatal("internal: trailing debug record is not in its block's marker"); }
            dbgrecs[p].next = dbgrecs[r].next;
        }
        dbgrecs[r].next = -1;
        dbgrecs[r].owner = -1;
        return;
    }
    if o < 0 { return; }
    let i = inst_of(o);
    if inst_dbg[i] == r { inst_dbg[i] = dbgrecs[r].next; }
    else {
        var p = inst_dbg[i];
        while p >= 0 && dbgrecs[p].next != r { p = dbgrecs[p].next; }
        if p < 0 { fatal("internal: debug record is not in its owner's marker"); }
        dbgrecs[p].next = dbgrecs[r].next;
    }
    dbgrecs[r].next = -1;
    dbgrecs[r].owner = -1;
}

// ---------------------------------------------------------------------------------------------
// Metadata tracking of debug-record locations (llvm/lib/IR/Metadata.cpp ReplaceableMetadataImpl, ValueAsMetadata::
// handleRAUW/handleDeletion, DIArgList::handleChangedOperand/track, DebugValueUser in DebugProgramInstruction.cpp,
// findDbgUsers in DebugInfo.cpp).
//
// Every ValueAsMetadata (MK_VALUE md) and live DIArgList (MK_DIARGLIST md) is a ReplaceableMetadataImpl: a set of
// tracking references, each with the owner (a debug record's location/address slot, or a DIArgList's argument) and
// the RMI's NextIndex at the time it was added. The order of users that LLVM's algorithms see (findDbgUsers,
// replaceAllUsesWith) is by that index, so we keep it. A value is "used by metadata" when val_vam[v] >= 0.
// Records are tracked from the end of parsing (dbg_track_module, in program order, as LLParser creates them).
// Function-local metadata as call operands (MetadataAsValue) is not tracked.

let TRK_REC = 0;      // owner = record id, slot = 0 location / 1 address
let TRK_AL = 1;       // owner = DIArgList md id, slot = argument index
struct Trk { md: i32, owner: i32, okind: u8, live: u8, slot: i32, idx: i64, next: i32, prev: i32 }
var trks: Trk[>..];
var trk_free: i32 = -1;
var md_trk_head: i32[>..];     // md id -> first tracking reference (-1)
var md_trk_nidx: i64[>..];     // md id -> NextIndex
var md_al_live: u8[>..];       // DIArgList md id -> in LLVMContext's DIArgLists store (args tracked)
var md_al_trk: i32[>..];       // DIArgList md id -> start of its args' tracking ids in al_trk_pool
var md_al_fwd: i32[>..];       // DIArgList md id -> the md id the same LLVM object has after an in-place change
var al_trk_pool: i32[>..];
var rec_trk: i32[>..];         // record * 2 + slot -> tracking id (-1)
var val_vam: i32[>..];         // value id -> its ValueAsMetadata in the store (-1: not used by metadata)
var dbg_tracking_on = false;

fn md_trk_grow(m: i32) {
    while md_trk_head.len <= m { md_trk_head.push(-1); md_trk_nidx.push(0); md_al_live.push(0); md_al_trk.push(-1); md_al_fwd.push(-1); }
}
fn val_vam_of(v: i32) -> i32 { if v >= 0 && v < val_vam.len { val_vam[v] } else { -1 } }
fn val_used_by_md(v: i32) -> bool { val_vam_of(v) >= 0 }
fn set_val_vam(v: i32, m: i32) { while val_vam.len <= v { val_vam.push(-1); } val_vam[v] = m; }

// ReplaceableMetadataImpl::getOrCreate: VAMs and DIArgLists track; MDNodes (resolved) don't.
fn md_is_trackable(m: i32) -> bool { m >= 0 && (mds[m].kind == MK_VALUE || mds[m].kind == MK_DIARGLIST) }

// ReplaceableMetadataImpl::addRef
fn trk_add(m: i32, owner: i32, okind: i64, slot: i64) -> i32 {
    md_trk_grow(m);
    if mds[m].kind == MK_DIARGLIST && md_al_live[m] == 0 { al_track(m); }
    return trk_add_raw(m, owner, okind, slot);
}
fn trk_add_raw(m: i32, owner: i32, okind: i64, slot: i64) -> i32 {
    md_trk_grow(m);
    var t = trk_free;
    let e = Trk { md: m, owner: owner, okind: okind as u8, live: 1, slot: slot as i32, idx: md_trk_nidx[m], next: md_trk_head[m], prev: -1 };
    if t >= 0 { trk_free = trks[t].next; trks[t] = e; } else { t = trks.len as i32; trks.push(e); }
    md_trk_nidx[m] = md_trk_nidx[m] + 1;
    if md_trk_head[m] >= 0 { trks[md_trk_head[m]].prev = t; }
    md_trk_head[m] = t;
    if mds[m].kind == MK_VALUE { let v = mds[m].extra; if val_vam_of(v) != m { set_val_vam(v, m); } }
    return t;
}
// ReplaceableMetadataImpl::dropRef
fn trk_drop(t: i32) {
    if t < 0 || trks[t].live == 0 { return; }
    let m = trks[t].md;
    let p = trks[t].prev;
    let n = trks[t].next;
    if p >= 0 { trks[p].next = n; } else { md_trk_head[m] = n; }
    if n >= 0 { trks[n].prev = p; }
    trks[t].live = 0;
    trks[t].next = trk_free;
    trk_free = t;
}

// DIArgList::get(...) for a list not in the store yet / DIArgList::track(): its arguments track their VAMs.
fn al_track(m: i32) {
    md_trk_grow(m);
    md_al_live[m] = 1;
    md_al_fwd[m] = -1;
    let at = al_trk_pool.len as i32;
    md_al_trk[m] = at;
    let n = mds[m].nops as i64;
    for k in n { al_trk_pool.push(-1); }
    for k in n {
        let a = md_op(m, k);
        if md_is_trackable(a) { let t = trk_add_raw(a, m, TRK_AL, k); al_trk_pool[at + k] = t; }
    }
}
// DIArgList::untrack()
fn al_untrack(m: i32) {
    if m >= md_al_live.len || md_al_live[m] == 0 { return; }
    let at = md_al_trk[m];
    for k in mds[m].nops as i64 { let t = al_trk_pool[at + k]; trk_drop(t); al_trk_pool[at + k] = -1; }
}

// DebugValueUser::trackDebugValue / untrackDebugValue for record slot 0 (location) or 1 (address).
fn rec_untrack(r: i32, slot: i64) {
    let k = (r as i64) * 2 + slot;
    if k < rec_trk.len { trk_drop(rec_trk[k]); rec_trk[k] = -1; }
}
fn rec_track(r: i32, slot: i64) {
    let k = (r as i64) * 2 + slot;
    while rec_trk.len <= k { rec_trk.push(-1); }
    if rec_trk[k] >= 0 { trk_drop(rec_trk[k]); rec_trk[k] = -1; }
    let m = if slot == 0 { dbgrecs[r].loc } else { dbgrecs[r].addr };
    if md_is_trackable(m) { rec_trk[k] = trk_add(m, r, TRK_REC, slot); }
}
// DebugValueUser::resetDebugValue(Idx, New) (DbgVariableRecord::setRawLocation / setRawAddress).
fn dbg_set_slot(r: i32, slot: i64, m: i32) {
    if dbg_tracking_on { rec_untrack(r, slot); }
    if slot == 0 { dbgrecs[r].loc = m; } else { dbgrecs[r].addr = m; }
    if dbg_tracking_on { rec_track(r, slot); }
}
fn dbg_set_loc(r: i32, m: i32) { dbg_set_slot(r, 0, m); }
fn dbg_set_addr(r: i32, m: i32) { dbg_set_slot(r, 1, m); }
// A record created with its fields set directly: DbgVariableRecord's constructor tracks location then address.
fn dbg_track_new(r: i32) {
    if !dbg_tracking_on { return; }
    rec_track(r, 0);
    rec_track(r, 1);
}

// The tracking references of md m (a snapshot), ascending by index (ReplaceableMetadataImpl::replaceAllUsesWith).
fn trk_snapshot(m: i32, out: i32[>..<]&) {
    if m < 0 || m >= md_trk_head.len { return; }
    var t = md_trk_head[m];
    while t >= 0 { out.push(t); t = trks[t].next; }
    // insertion sort by idx ascending (lists are short)
    var i: i64 = 1;
    while i < out.len {
        let x = out[i];
        var j = i - 1;
        while j >= 0 && trks[out[j]].idx > trks[x].idx { out[j + 1] = out[j]; j--; }
        out[j + 1] = x;
        i++;
    }
}

// Is (owner, kind, slot) still tracking m? (the "UseMap.count(Ref)" check in replaceAllUsesWith)
fn trk_still(m: i32, owner: i32, okind: i64, slot: i64) -> bool {
    if okind == TRK_REC {
        let k = (owner as i64) * 2 + slot;
        if k >= rec_trk.len || rec_trk[k] < 0 { return false; }
        return trks[rec_trk[k]].md == m;
    }
    var o = owner;
    while o < md_al_fwd.len && md_al_fwd[o] >= 0 { o = md_al_fwd[o]; }
    if o >= md_al_live.len || md_al_live[o] == 0 { return false; }
    let t = al_trk_pool[md_al_trk[o] + slot];
    return t >= 0 && trks[t].md == m;
}

// The type of the value a VAM wraps (for the poison replacement).
fn vam_poison(m: i32) -> i32 { md_value(c_poison(vals[mds[m].extra].ty)) }

// ReplaceableMetadataImpl::replaceAllUsesWith(nw) for m (a VAM or a DIArgList); nw = -1 is nullptr.
fn rmi_replace_all_uses_with(m: i32, nw: i32) {
    var snap: i32[>..<] = [];
    trk_snapshot(m, snap);
    var owners: i32[>..<] = [];
    var kinds: i32[>..<] = [];
    var slots: i32[>..<] = [];
    for t in snap { owners.push(trks[t].owner); kinds.push(trks[t].okind as i32); slots.push(trks[t].slot); }
    for k in snap.len {
        let owner = owners[k];
        let ok = kinds[k] as i64;
        let slot = slots[k] as i64;
        if !trk_still(m, owner, ok, slot) { continue; }
        var cur_owner = owner;
        while ok == TRK_AL && cur_owner < md_al_fwd.len && md_al_fwd[cur_owner] >= 0 { cur_owner = md_al_fwd[cur_owner]; }
        if ok == TRK_REC {
            // DebugValueUser::handleChangedValue: a VAM replaced by nullptr becomes poison
            var x = nw;
            if x < 0 && mds[m].kind == MK_VALUE { x = vam_poison(m); }
            dbg_set_slot(owner, slot, x);
        } else {
            al_handle_changed_operand(cur_owner, slot, nw);
        }
    }
}
// The same for a DIArgList, whose users are records only.
fn rmi_replace_record_users(m: i32, nw: i32) {
    var snap: i32[>..<] = [];
    trk_snapshot(m, snap);
    var owners: i32[>..<] = [];
    var slots: i32[>..<] = [];
    for t in snap { owners.push(trks[t].owner); slots.push(trks[t].slot); }
    for k in snap.len {
        if !trk_still(m, owners[k], TRK_REC, slots[k] as i64) { continue; }
        dbg_set_slot(owners[k], slots[k] as i64, nw);
    }
}

// DIArgList::handleChangedOperand(Ref = argument k, New)
fn al_handle_changed_operand(al: i32, k: i64, nw: i32) {
    al_untrack(al);
    md_al_live[al] = 0;
    var ops: i32[>..<] = [];
    for j in mds[al].nops as i64 {
        let o = md_op(al, j);
        if j == k { ops.push(if nw >= 0 { nw } else { vam_poison(o) }); } else { ops.push(o); }
    }
    let nal = md_get(MK_DIARGLIST, -1, ops, false);
    md_trk_grow(nal);
    if nal != al && md_al_live[nal] != 0 {
        // an equal list exists: RAUW onto it (users re-track there, in index order)
        rmi_replace_record_users(al, nal);
        return;
    }
    // the list changed in place: its users keep their indices
    if nal != al {
        md_al_fwd[al] = nal;
        md_al_fwd[nal] = -1;
        var t = md_trk_head[al];
        md_trk_head[al] = -1;
        var last: i32 = -1;
        var x = t;
        while x >= 0 { trks[x].md = nal; last = x; x = trks[x].next; }
        if last >= 0 {
            trks[last].next = md_trk_head[nal];
            if md_trk_head[nal] >= 0 { trks[md_trk_head[nal]].prev = last; }
            md_trk_head[nal] = t;
        }
        if md_trk_nidx[nal] < md_trk_nidx[al] { md_trk_nidx[nal] = md_trk_nidx[al]; }
        // records whose location was al now hold nal
        x = md_trk_head[nal];
        while x >= 0 {
            if trks[x].okind as i64 == TRK_REC {
                let r = trks[x].owner;
                if trks[x].slot == 0 { dbgrecs[r].loc = nal; } else { dbgrecs[r].addr = nal; }
            }
            x = trks[x].next;
        }
    }
    al_track(nal);
}

fn dinfo_value_func(v: i32) -> i32 {
    let k = vals[v].kind;
    if k == VK_ARG { return args_parent[vals[v].sub]; }
    if k == VK_INST { let bv = insts[inst_of(v)].parent; if bv >= 0 { return blocks[block_of(bv)].parent; } }
    return -1;
}
fn dinfo_func_subprogram(fv: i32) -> i32 {
    if fv < 0 { return -1; }
    let g = globs[glob_of(fv)];
    for k in g.nmd { if md_att[g.md + 2 * k] == 0 { return md_att[g.md + 2 * k + 1]; } }
    return -1;
}

// ValueAsMetadata::handleRAUW(From, To): called by rauw (Value::replaceAllUsesWith) when From is used by metadata.
fn vam_handle_rauw(from: i32, to: i32) {
    let m = val_vam_of(from);
    if m < 0 || from == to { return; }
    val_vam[from] = -1;
    if !is_constant(from) {
        if is_constant(to) { rmi_replace_all_uses_with(m, md_value(to)); return; }
        let sf = dinfo_func_subprogram(dinfo_value_func(from));
        let st = dinfo_func_subprogram(dinfo_value_func(to));
        if sf >= 0 && st >= 0 && sf != st { rmi_replace_all_uses_with(m, -1); return; }
    } else if !is_constant(to) {
        rmi_replace_all_uses_with(m, -1);
        return;
    }
    let e = val_vam_of(to);
    if e >= 0 { rmi_replace_all_uses_with(m, e); return; }
    // update the VAM in place: its users keep their indices, now under md_value(to)
    let nm = md_value(to);
    md_trk_grow(m);
    md_trk_grow(nm);
    var t = md_trk_head[m];
    md_trk_head[m] = -1;
    var users: i32[>..<] = [];
    var x = t;
    var last: i32 = -1;
    while x >= 0 { trks[x].md = nm; users.push(x); last = x; x = trks[x].next; }
    if last >= 0 {
        trks[last].next = md_trk_head[nm];
        if md_trk_head[nm] >= 0 { trks[md_trk_head[nm]].prev = last; }
        md_trk_head[nm] = t;
    }
    if md_trk_nidx[nm] < md_trk_nidx[m] { md_trk_nidx[nm] = md_trk_nidx[m]; }
    set_val_vam(to, nm);
    // the owners now refer to nm: records directly, DIArgLists through a changed argument list
    var als: i32[>..<] = [];
    for u in users {
        if trks[u].okind as i64 == TRK_REC {
            let r = trks[u].owner;
            if trks[u].slot == 0 { dbgrecs[r].loc = nm; } else { dbgrecs[r].addr = nm; }
        } else { als.push(u); }
    }
    for u in als { al_retarget_in_place(trks[u].owner, trks[u].slot as i64, nm); }
}

// A DIArgList whose argument k's VAM was updated in place to wrap another value: LLVM's DIArgList object is
// unchanged (same identity, same users), only the uniquing key changed. Here that is a different md id.
fn al_retarget_in_place(al: i32, k: i64, nm: i32) {
    if md_al_live[al] == 0 { return; }
    var ops: i32[>..<] = [];
    for j in mds[al].nops as i64 { ops.push(if j == k { nm } else { md_op(al, j) }); }
    let nal = md_get(MK_DIARGLIST, -1, ops, false);
    if nal == al { return; }
    md_trk_grow(nal);
    // move the argument tracking ids and the users over
    md_al_live[nal] = 1;
    md_al_trk[nal] = md_al_trk[al];
    md_al_live[al] = 0;
    md_al_fwd[al] = nal;
    md_al_fwd[nal] = -1;
    let at = md_al_trk[nal];
    for j in mds[nal].nops as i64 { let tj = al_trk_pool[at + j]; if tj >= 0 { trks[tj].owner = nal; } }
    var t = md_trk_head[al];
    md_trk_head[al] = -1;
    var last: i32 = -1;
    var x = t;
    while x >= 0 {
        trks[x].md = nal;
        if trks[x].okind as i64 == TRK_REC {
            let r = trks[x].owner;
            if trks[x].slot == 0 { dbgrecs[r].loc = nal; } else { dbgrecs[r].addr = nal; }
        }
        last = x;
        x = trks[x].next;
    }
    if last >= 0 {
        trks[last].next = md_trk_head[nal];
        if md_trk_head[nal] >= 0 { trks[md_trk_head[nal]].prev = last; }
        md_trk_head[nal] = t;
    }
    if md_trk_nidx[nal] < md_trk_nidx[al] { md_trk_nidx[nal] = md_trk_nidx[al]; }
}

// ValueAsMetadata::handleDeletion(V): its users get nullptr (records: poison; DIArgList arguments: poison).
fn vam_handle_deletion(v: i32) {
    let m = val_vam_of(v);
    if m < 0 { return; }
    val_vam[v] = -1;
    rmi_replace_all_uses_with(m, -1);
}

// The records tracking md m, by descending index (getAllDbgVariableRecordUsers), appended to out unless present.
fn rmi_record_users(m: i32, out: i32[>..<]&) {
    var snap: i32[>..<] = [];
    trk_snapshot(m, snap);
    var k = snap.len - 1;
    while k >= 0 {
        let t = snap[k];
        k--;
        if trks[t].okind as i64 != TRK_REC { continue; }
        let r = trks[t].owner;
        var seen = false;
        for x in out { if x == r { seen = true; break; } }
        if !seen { out.push(r); }
    }
}
// findDbgUsers(V): the records using V directly, then those using a DIArgList containing V (lists in ascending
// index order).
fn find_dbg_users(v: i32, out: i32[>..<]&) {
    let m = val_vam_of(v);
    if m < 0 { return; }
    rmi_record_users(m, out);
    var snap: i32[>..<] = [];
    trk_snapshot(m, snap);
    for t in snap {
        if trks[t].okind as i64 != TRK_AL { continue; }
        rmi_record_users(trks[t].owner, out);
    }
}
// findDbgValues(V): only dbg_value (and dbg_assign) records.
fn find_dbg_values(v: i32, out: i32[>..<]&) {
    var all: i32[>..<] = [];
    find_dbg_users(v, all);
    for r in all { let k = dbgrecs[r].kind as i64; if k == DR_VALUE || k == DR_ASSIGN { out.push(r); } }
}

// Start tracking the records of module mod, in program order (end of parsing).
fn dbg_track_module(module: i32) {
    dbg_tracking_on = true;
    if dbgrecs.len == 0 { return; }
    var f = modules[module].first_func;
    while f >= 0 {
        var b = globs[glob_of(f)].first_block;
        while b >= 0 {
            var i = blocks[block_of(b)].first;
            while i >= 0 {
                var r = inst_first_dbg(i);
                while r >= 0 { dbg_track_new(r); r = dbgrecs[r].next; }
                i = insts[inst_of(i)].next;
            }
            b = blocks[block_of(b)].next;
        }
        f = globs[glob_of(f)].next;
    }
}

// DbgRecord::eraseFromParent / deleteRecord: unlink and stop tracking.
fn dbg_delete_record(r: i32) {
    dbg_erase_record(r);
    if dbg_tracking_on { rec_untrack(r, 0); rec_untrack(r, 1); }
    dbgrecs[r].dead = 1;
}

// ---------------------------------------------------------------------------------------------
// DbgMarkers (llvm/lib/IR/DebugProgramInstruction.cpp DbgMarker, BasicBlock::getMarker/createMarker/
// getTrailingDbgRecords). A marker is identified by (block, position): position = an instruction, or -1 for
// end() (the block's trailing records). Records hold their owner: the instruction, or -2 - block for trailing.

fn marker_first(bv: i32, pos: i32) -> i32 {
    if pos >= 0 { return inst_first_dbg(pos); }
    let b = block_of(bv);
    return if b < block_trail.len { block_trail[b] } else { -1 };
}
fn marker_set_first(bv: i32, pos: i32, r: i32) {
    if pos >= 0 {
        let i = inst_of(pos);
        while inst_dbg.len <= i { inst_dbg.push(-1); }
        inst_dbg[i] = r;
    } else {
        let b = block_of(bv);
        while block_trail.len <= b { block_trail.push(-1); }
        block_trail[b] = r;
    }
}
// Detach the records of a marker (DbgMarker::removeFromParent + taking its list).
fn marker_take(bv: i32, pos: i32) -> i32 {
    let r = marker_first(bv, pos);
    if r >= 0 { marker_set_first(bv, pos, -1); }
    return r;
}
// DbgMarker::absorbDebugValues(Src = a detached list, InsertAtHead)
fn marker_absorb(bv: i32, pos: i32, list: i32, at_head: bool) {
    if list < 0 { return; }
    let owner = if pos >= 0 { pos } else { -2 - bv };
    var last: i32 = list;
    dbgrecs[last].owner = owner;
    while dbgrecs[last].next >= 0 { last = dbgrecs[last].next; dbgrecs[last].owner = owner; }
    let cur = marker_first(bv, pos);
    if cur < 0 { marker_set_first(bv, pos, list); return; }
    if at_head {
        dbgrecs[last].next = cur;
        marker_set_first(bv, pos, list);
    } else {
        var t = cur;
        while dbgrecs[t].next >= 0 { t = dbgrecs[t].next; }
        dbgrecs[t].next = list;
    }
}
fn block_has_trailing(bv: i32) -> bool { let b = block_of(bv); b < block_trail.len && block_trail[b] >= 0 }

// DbgRecord::clone(): same fields, not in any marker, tracked.
fn dbg_clone_record(r: i32) -> i32 {
    let x = dbgrecs[r];
    let nr = new_dbgrec(x.kind as i64);
    dbgrecs[nr].loc = x.loc;
    dbgrecs[nr].dvar = x.dvar;
    dbgrecs[nr].expr = x.expr;
    dbgrecs[nr].aid = x.aid;
    dbgrecs[nr].addr = x.addr;
    dbgrecs[nr].aexpr = x.aexpr;
    dbgrecs[nr].dl = x.dl;
    dbg_track_new(nr);
    return nr;
}

// Instruction::cloneDebugInfoFrom(From, FromHere, InsertAtHead) (DbgMarker::cloneDebugInfoFrom): clones of
// From's records (from record `from_here` on; -1 = all) go to the head or the end of `to`'s records. The new
// records are appended to `out`, in order.
fn inst_clone_debug_info_from(to: i32, from: i32, from_here: i32, at_head: bool, out: i32[>..<]&) {
    var r = if from_here >= 0 { from_here } else { inst_first_dbg(from) };
    if r < 0 { return; }
    let mark = out.len;
    while r >= 0 { out.push(dbg_clone_record(r)); r = dbgrecs[r].next; }
    // chain the clones and attach them
    var k = mark;
    while k + 1 < out.len { dbgrecs[out[k]].next = out[k + 1]; k++; }
    dbgrecs[out[out.len - 1]].next = -1;
    marker_absorb(insts[inst_of(to)].parent, to, out[mark], at_head);
}

// The location operands of a record (DbgVariableRecord::location_ops).
fn dbg_location_ops(r: i32, out: i32[>..<]&) {
    let l = dbgrecs[r].loc;
    if l < 0 { return; }
    if mds[l].kind == MK_VALUE { out.push(mds[l].extra); return; }
    if mds[l].kind == MK_DIARGLIST {
        for k in mds[l].nops as i64 { let o = md_op(l, k); if o >= 0 && mds[o].kind == MK_VALUE { out.push(mds[o].extra); } }
    }
}
// DbgVariableRecord::replaceVariableLocationOp(OpIdx, NewValue)
fn dbg_replace_location_op_idx(r: i32, idx: i64, nv: i32) {
    let l = dbgrecs[r].loc;
    if mds[l].kind != MK_DIARGLIST { dbg_set_loc(r, md_value(nv)); return; }
    var ops: i32[>..<] = [];
    for k in mds[l].nops as i64 { ops.push(if k == idx { md_value(nv) } else { md_op(l, k) }); }
    dbg_set_loc(r, md_get(MK_DIARGLIST, -1, ops, false));
}
