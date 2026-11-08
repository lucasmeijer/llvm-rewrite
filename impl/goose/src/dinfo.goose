// Debug-info metadata (llvm/IR/DebugInfoMetadata.h) and debug records (llvm/IR/DebugProgramInstruction.h).
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
struct DbgRec { kind: u8, loc: i32, dvar: i32, expr: i32, aid: i32, addr: i32, aexpr: i32, dl: i32, next: i32 }
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
    if inst_dbg[i] < 0 { inst_dbg[i] = r; return; }
    var p = inst_dbg[i];
    while dbgrecs[p].next >= 0 { p = dbgrecs[p].next; }
    dbgrecs[p].next = r;
}

fn new_dbgrec(kind: i64) -> i32 {
    let r = dbgrecs.len as i32;
    dbgrecs.push(DbgRec { kind: kind as u8, loc: -1, dvar: -1, expr: -1, aid: -1, addr: -1, aexpr: -1, dl: -1, next: -1 });
    return r;
}

// DbgMarker::removeMarker: when an instruction is erased, its records move to the head of the next
// instruction's records. Call before inst_erase.
fn dbg_records_to_next(iv: i32) {
    let i = inst_of(iv);
    if i >= inst_dbg.len || inst_dbg[i] < 0 { return; }
    let nx = insts[i].next;
    if nx < 0 { inst_dbg[i] = -1; return; }
    let ni = inst_of(nx);
    while inst_dbg.len <= ni { inst_dbg.push(-1); }
    var last = inst_dbg[i];
    while dbgrecs[last].next >= 0 { last = dbgrecs[last].next; }
    dbgrecs[last].next = inst_dbg[ni];
    inst_dbg[ni] = inst_dbg[i];
    inst_dbg[i] = -1;
}
