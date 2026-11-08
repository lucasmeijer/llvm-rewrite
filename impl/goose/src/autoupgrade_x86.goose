// x86 intrinsic auto-upgrades. Port of AutoUpgrade.cpp: shouldUpgradeX86Intrinsic (all of it) and the
// upgradeX86IntrinsicCall cases the corpus uses (scalar sse/sse2 arithmetic and sqrt, packed sqrt, pmuldq/pmuludq,
// vcvtph2ps, xop vpcom, bmi pdep/pext, xop vfrcz). Other upgraded names fail loudly.
// New instructions are built like IRBuilder<> with the default ConstantFolder: constant operands fold,
// everything gets the call's !dbg and (for FP math) its fast-math flags.
import std;
import ir;
import calls;
import intrinsics;
import constfold;
import dinfo;

// Port of AutoUpgrade.cpp shouldUpgradeX86Intrinsic (Name without "x86.").
fn x86_should_upgrade(name0: const u8[:]) -> bool {
    var nm = name0;

  if starts_with(nm, "avx.") { nm = nm[4..]; return (starts_with(nm, "blend.p") ||        
            nm == "cvt.ps2.pd.256" ||           
            nm == "cvtdq2.pd.256" ||            
            nm == "cvtdq2.ps.256" ||            
            starts_with(nm, "movnt.") ||         
            starts_with(nm, "sqrt.p") ||         
            starts_with(nm, "storeu.") ||        
            starts_with(nm, "vbroadcast.s") ||   
            starts_with(nm, "vbroadcastf128") || 
            starts_with(nm, "vextractf128.") ||  
            starts_with(nm, "vinsertf128.") ||   
            starts_with(nm, "vperm2f128.") ||    
            starts_with(nm, "vpermil.")); }        
  if starts_with(nm, "avx2.") { nm = nm[5..]; return (nm == "movntdqa" ||             
            starts_with(nm, "pabs.") ||      
            starts_with(nm, "padds.") ||     
            starts_with(nm, "paddus.") ||    
            starts_with(nm, "pblendd.") ||   
            nm == "pblendw" ||              
            starts_with(nm, "pbroadcast") || 
            starts_with(nm, "pcmpeq.") ||    
            starts_with(nm, "pcmpgt.") ||    
            starts_with(nm, "pmax") ||       
            starts_with(nm, "pmin") ||       
            starts_with(nm, "pmovsx") ||     
            starts_with(nm, "pmovzx") ||     
            nm == "pmul.dq" ||              
            nm == "pmulu.dq" ||             
            starts_with(nm, "psll.dq") ||    
            starts_with(nm, "psrl.dq") ||    
            starts_with(nm, "psubs.") ||     
            starts_with(nm, "psubus.") ||    
            starts_with(nm, "vbroadcast") || 
            nm == "vbroadcasti128" ||       
            nm == "vextracti128" ||         
            nm == "vinserti128" ||          
            nm == "vperm2i128"); }            
  if starts_with(nm, "avx512.") { nm = nm[7..];
    if starts_with(nm, "mask.") { nm = nm[5..]; return (starts_with(nm, "add.p") ||       
              starts_with(nm, "and.") ||        
              starts_with(nm, "andn.") ||       
              starts_with(nm, "broadcast.s") || 
              starts_with(nm, "broadcastf32x4.") || 
              starts_with(nm, "broadcastf32x8.") || 
              starts_with(nm, "broadcastf64x2.") || 
              starts_with(nm, "broadcastf64x4.") || 
              starts_with(nm, "broadcasti32x4.") || 
              starts_with(nm, "broadcasti32x8.") || 
              starts_with(nm, "broadcasti64x2.") || 
              starts_with(nm, "broadcasti64x4.") || 
              starts_with(nm, "cmp.b") ||           
              starts_with(nm, "cmp.d") ||           
              starts_with(nm, "cmp.q") ||           
              starts_with(nm, "cmp.w") ||           
              starts_with(nm, "compress.b") ||      
              starts_with(nm, "compress.d") ||      
              starts_with(nm, "compress.p") ||      
              starts_with(nm, "compress.q") ||      
              starts_with(nm, "compress.store.") || 
              starts_with(nm, "compress.w") ||      
              starts_with(nm, "conflict.") ||       
              starts_with(nm, "cvtdq2pd.") ||       
              starts_with(nm, "cvtdq2ps.") ||       
              nm == "cvtpd2dq.256" ||              
              nm == "cvtpd2ps.256" ||              
              nm == "cvtps2pd.128" ||              
              nm == "cvtps2pd.256" ||              
              starts_with(nm, "cvtqq2pd.") ||       
              nm == "cvtqq2ps.256" ||              
              nm == "cvtqq2ps.512" ||              
              nm == "cvttpd2dq.256" ||             
              nm == "cvttps2dq.128" ||             
              nm == "cvttps2dq.256" ||             
              starts_with(nm, "cvtudq2pd.") ||      
              starts_with(nm, "cvtudq2ps.") ||      
              starts_with(nm, "cvtuqq2pd.") ||      
              nm == "cvtuqq2ps.256" ||             
              nm == "cvtuqq2ps.512" ||             
              starts_with(nm, "dbpsadbw.") ||       
              starts_with(nm, "div.p") ||    
              starts_with(nm, "expand.b") || 
              starts_with(nm, "expand.d") || 
              starts_with(nm, "expand.load.") || 
              starts_with(nm, "expand.p") ||     
              starts_with(nm, "expand.q") ||     
              starts_with(nm, "expand.w") ||     
              starts_with(nm, "fpclass.p") ||    
              starts_with(nm, "insert") ||       
              starts_with(nm, "load.") ||        
              starts_with(nm, "loadu.") ||       
              starts_with(nm, "lzcnt.") ||       
              starts_with(nm, "max.p") ||       
              starts_with(nm, "min.p") ||       
              starts_with(nm, "movddup") ||     
              starts_with(nm, "move.s") ||      
              starts_with(nm, "movshdup") ||    
              starts_with(nm, "movsldup") ||    
              starts_with(nm, "mul.p") ||       
              starts_with(nm, "or.") ||         
              starts_with(nm, "pabs.") ||       
              starts_with(nm, "packssdw.") ||   
              starts_with(nm, "packsswb.") ||   
              starts_with(nm, "packusdw.") ||   
              starts_with(nm, "packuswb.") ||   
              starts_with(nm, "padd.") ||       
              starts_with(nm, "padds.") ||      
              starts_with(nm, "paddus.") ||     
              starts_with(nm, "palignr.") ||    
              starts_with(nm, "pand.") ||       
              starts_with(nm, "pandn.") ||      
              starts_with(nm, "pavg") ||        
              starts_with(nm, "pbroadcast") ||  
              starts_with(nm, "pcmpeq.") ||     
              starts_with(nm, "pcmpgt.") ||     
              starts_with(nm, "perm.df.") ||    
              starts_with(nm, "perm.di.") ||    
              starts_with(nm, "permvar.") ||    
              starts_with(nm, "pmaddubs.w.") || 
              starts_with(nm, "pmaddw.d.") ||   
              starts_with(nm, "pmax") ||        
              starts_with(nm, "pmin") ||        
              nm == "pmov.qd.256" ||           
              nm == "pmov.qd.512" ||           
              nm == "pmov.wb.256" ||           
              nm == "pmov.wb.512" ||           
              starts_with(nm, "pmovsx") ||      
              starts_with(nm, "pmovzx") ||      
              starts_with(nm, "pmul.dq.") ||    
              starts_with(nm, "pmul.hr.sw.") || 
              starts_with(nm, "pmulh.w.") ||    
              starts_with(nm, "pmulhu.w.") ||   
              starts_with(nm, "pmull.") ||      
              starts_with(nm, "pmultishift.qb.") || 
              starts_with(nm, "pmulu.dq.") ||       
              starts_with(nm, "por.") ||            
              starts_with(nm, "prol.") ||           
              starts_with(nm, "prolv.") ||          
              starts_with(nm, "pror.") ||           
              starts_with(nm, "prorv.") ||          
              starts_with(nm, "pshuf.b.") ||        
              starts_with(nm, "pshuf.d.") ||        
              starts_with(nm, "pshufh.w.") ||       
              starts_with(nm, "pshufl.w.") ||       
              starts_with(nm, "psll.d") ||          
              starts_with(nm, "psll.q") ||          
              starts_with(nm, "psll.w") ||          
              starts_with(nm, "pslli") ||           
              starts_with(nm, "psllv") ||           
              starts_with(nm, "psra.d") ||          
              starts_with(nm, "psra.q") ||          
              starts_with(nm, "psra.w") ||          
              starts_with(nm, "psrai") ||           
              starts_with(nm, "psrav") ||           
              starts_with(nm, "psrl.d") ||          
              starts_with(nm, "psrl.q") ||          
              starts_with(nm, "psrl.w") ||          
              starts_with(nm, "psrli") ||           
              starts_with(nm, "psrlv") ||           
              starts_with(nm, "psub.") ||           
              starts_with(nm, "psubs.") ||          
              starts_with(nm, "psubus.") ||         
              starts_with(nm, "pternlog.") ||       
              starts_with(nm, "punpckh") ||         
              starts_with(nm, "punpckl") ||         
              starts_with(nm, "pxor.") ||           
              starts_with(nm, "shuf.f") ||          
              starts_with(nm, "shuf.i") ||          
              starts_with(nm, "shuf.p") ||          
              starts_with(nm, "sqrt.p") ||          
              starts_with(nm, "store.b.") ||        
              starts_with(nm, "store.d.") ||        
              starts_with(nm, "store.p") ||         
              starts_with(nm, "store.q.") ||        
              starts_with(nm, "store.w.") ||        
              nm == "store.ss" ||                  
              starts_with(nm, "storeu.") ||         
              starts_with(nm, "sub.p") ||       
              starts_with(nm, "ucmp.") ||       
              starts_with(nm, "unpckh.") ||     
              starts_with(nm, "unpckl.") ||     
              starts_with(nm, "valign.") ||     
              nm == "vcvtph2ps.128" ||         
              nm == "vcvtph2ps.256" ||         
              starts_with(nm, "vextract") ||    
              starts_with(nm, "vfmadd.") ||     
              starts_with(nm, "vfmaddsub.") ||  
              starts_with(nm, "vfnmadd.") ||    
              starts_with(nm, "vfnmsub.") ||    
              starts_with(nm, "vpdpbusd.") ||   
              starts_with(nm, "vpdpbusds.") ||  
              starts_with(nm, "vpdpwssd.") ||   
              starts_with(nm, "vpdpwssds.") ||  
              starts_with(nm, "vpermi2var.") || 
              starts_with(nm, "vpermil.p") ||   
              starts_with(nm, "vpermilvar.") || 
              starts_with(nm, "vpermt2var.") || 
              starts_with(nm, "vpmadd52") ||    
              starts_with(nm, "vpshld.") ||     
              starts_with(nm, "vpshldv.") ||    
              starts_with(nm, "vpshrd.") ||     
              starts_with(nm, "vpshrdv.") ||    
              starts_with(nm, "vpshufbitqmb.") || 
              starts_with(nm, "xor.")); }           
    if starts_with(nm, "mask3.") { nm = nm[6..]; return (starts_with(nm, "vfmadd.") ||    
              starts_with(nm, "vfmaddsub.") || 
              starts_with(nm, "vfmsub.") ||    
              starts_with(nm, "vfmsubadd.") || 
              starts_with(nm, "vfnmsub.")); }    
    if starts_with(nm, "maskz.") { nm = nm[6..]; return (starts_with(nm, "pternlog.") ||   
              starts_with(nm, "vfmadd.") ||     
              starts_with(nm, "vfmaddsub.") ||  
              starts_with(nm, "vpdpbusd.") ||   
              starts_with(nm, "vpdpbusds.") ||  
              starts_with(nm, "vpdpwssd.") ||   
              starts_with(nm, "vpdpwssds.") ||  
              starts_with(nm, "vpermt2var.") || 
              starts_with(nm, "vpmadd52") ||    
              starts_with(nm, "vpshldv.") ||    
              starts_with(nm, "vpshrdv.")); }     
    return (nm == "movntdqa" ||               
            nm == "pmul.dq.512" ||            
            nm == "pmulu.dq.512" ||           
            starts_with(nm, "broadcastm") ||   
            starts_with(nm, "cmp.p") ||        
            starts_with(nm, "cvtb2mask.") ||   
            starts_with(nm, "cvtd2mask.") ||   
            starts_with(nm, "cvtmask2") ||     
            starts_with(nm, "cvtq2mask.") ||   
            nm == "cvtusi2sd" ||              
            starts_with(nm, "cvtw2mask.") ||   
            nm == "kand.w" ||                 
            nm == "kandn.w" ||                
            nm == "knot.w" ||                 
            nm == "kor.w" ||                  
            nm == "kortestc.w" ||             
            nm == "kortestz.w" ||             
            starts_with(nm, "kunpck") ||       
            nm == "kxnor.w" ||                
            nm == "kxor.w" ||                 
            starts_with(nm, "padds.") ||       
            starts_with(nm, "pbroadcast") ||   
            starts_with(nm, "prol") ||         
            starts_with(nm, "pror") ||         
            starts_with(nm, "psll.dq") ||      
            starts_with(nm, "psrl.dq") ||      
            starts_with(nm, "psubs.") ||       
            starts_with(nm, "ptestm") ||       
            starts_with(nm, "ptestnm") ||      
            starts_with(nm, "storent.") ||     
            starts_with(nm, "vbroadcast.s") || 
            starts_with(nm, "vpshld.") ||      
            starts_with(nm, "vpshrd."));       
  }
  if starts_with(nm, "fma.") { nm = nm[4..]; return (starts_with(nm, "vfmadd.") ||    
            starts_with(nm, "vfmsub.") ||    
            starts_with(nm, "vfmsubadd.") || 
            starts_with(nm, "vfnmadd.") ||   
            starts_with(nm, "vfnmsub.")); }    
  if starts_with(nm, "fma4.") { nm = nm[5..]; return starts_with(nm, "vfmadd.s"); } 
  if starts_with(nm, "sse.") { nm = nm[4..]; return (nm == "add.ss" ||            
            nm == "cvtsi2ss" ||          
            nm == "cvtsi642ss" ||        
            nm == "div.ss" ||            
            nm == "mul.ss" ||            
            starts_with(nm, "sqrt.p") ||  
            nm == "sqrt.ss" ||           
            starts_with(nm, "storeu.") || 
            nm == "sub.ss"); }             
  if starts_with(nm, "sse2.") { nm = nm[5..]; return (nm == "add.sd" ||            
            nm == "cvtdq2pd" ||          
            nm == "cvtdq2ps" ||          
            nm == "cvtps2pd" ||          
            nm == "cvtsi2sd" ||          
            nm == "cvtsi642sd" ||        
            nm == "cvtss2sd" ||          
            nm == "div.sd" ||            
            nm == "mul.sd" ||            
            starts_with(nm, "padds.") ||  
            starts_with(nm, "paddus.") || 
            starts_with(nm, "pcmpeq.") || 
            starts_with(nm, "pcmpgt.") || 
            nm == "pmaxs.w" ||           
            nm == "pmaxu.b" ||           
            nm == "pmins.w" ||           
            nm == "pminu.b" ||           
            nm == "pmulu.dq" ||          
            starts_with(nm, "pshuf") ||   
            starts_with(nm, "psll.dq") || 
            starts_with(nm, "psrl.dq") || 
            starts_with(nm, "psubs.") ||  
            starts_with(nm, "psubus.") || 
            starts_with(nm, "sqrt.p") ||  
            nm == "sqrt.sd" ||           
            nm == "storel.dq" ||         
            starts_with(nm, "storeu.") || 
            nm == "sub.sd"); }             
  if starts_with(nm, "sse41.") { nm = nm[6..]; return (starts_with(nm, "blendp") || 
            nm == "movntdqa" ||         
            nm == "pblendw" ||          
            nm == "pmaxsb" ||           
            nm == "pmaxsd" ||           
            nm == "pmaxud" ||           
            nm == "pmaxuw" ||           
            nm == "pminsb" ||           
            nm == "pminsd" ||           
            nm == "pminud" ||           
            nm == "pminuw" ||           
            starts_with(nm, "pmovsx") || 
            starts_with(nm, "pmovzx") || 
            nm == "pmuldq"); }            
  if starts_with(nm, "sse42.") { nm = nm[6..]; return nm == "crc32.64.8"; } 
  if starts_with(nm, "sse4a.") { nm = nm[6..]; return starts_with(nm, "movnt."); } 
  if starts_with(nm, "ssse3.") { nm = nm[6..]; return (nm == "pabs.b.128" || 
            nm == "pabs.d.128" || 
            nm == "pabs.w.128"); }  
  if starts_with(nm, "xop.") { nm = nm[4..]; return (nm == "vpcmov" ||          
            nm == "vpcmov.256" ||      
            starts_with(nm, "vpcom") || 
            starts_with(nm, "vprot")); }  
  if starts_with(nm, "bmi.") { nm = nm[4..]; return (starts_with(nm, "pdep.") || 
            starts_with(nm, "pext.")); }  
  return (nm == "addcarry.u32" ||        
          nm == "addcarry.u64" ||        
          nm == "addcarryx.u32" ||       
          nm == "addcarryx.u64" ||       
          nm == "subborrow.u32" ||       
          nm == "subborrow.u64" ||       
          starts_with(nm, "vcvtph2ps.")); 
}

// ---------------------------------------------------------------------------------------------
// IRBuilder subset (insert before ci)

fn xb_insert(ci: i32, v: i32, name: const u8[:]) -> i32 {
    let oi = inst_of(ci);
    let ii = inst_of(v);
    for k in insts[oi].nmd {
        if md_att[insts[oi].md + 2 * k] == 0 {
            let at = md_att.len as i32;
            md_att.push(0);
            md_att.push(md_att[insts[oi].md + 2 * k + 1]);
            insts[ii].md = at;
            insts[ii].nmd = 1;
        }
    }
    inst_insert_before(v, ci);
    if name.len > 0 { set_name(v, name); }
    return v;
}

fn xb_is_fp_math(t: i32) -> bool { ty_is_fp(ty_scalar(t)) }

fn xb_extractelement(ci: i32, vec: i32, idx: i32) -> i32 {
    if is_constant(vec) { return ce_extractelement(vec, idx); }
    let v = new_inst(OP_EXTRACTELEMENT, types[vals[vec].ty].a, 2);
    set_op(v, 0, vec);
    set_op(v, 1, idx);
    return xb_insert(ci, v, "");
}

fn xb_insertelement(ci: i32, vec: i32, elt: i32, idx: i32) -> i32 {
    if is_constant(vec) && is_constant(elt) { return ce_insertelement(vec, elt, idx); }
    let v = new_inst(OP_INSERTELEMENT, vals[vec].ty, 3);
    set_op(v, 0, vec);
    set_op(v, 1, elt);
    set_op(v, 2, idx);
    return xb_insert(ci, v, "");
}

fn xb_binop(ci: i32, opc: i64, a: i32, b: i32) -> i32 {
    if is_constant(a) && is_constant(b) {
        let f = if is_desirable_binop(opc) { ce_binop(opc, a, b, 0) } else { cf_binop(opc, a, b) };
        if f >= 0 { return f; }
    }
    let v = new_inst(opc, vals[a].ty, 2);
    set_op(v, 0, a);
    set_op(v, 1, b);
    if xb_is_fp_math(vals[a].ty) && xb_is_fp_math(vals[ci].ty) { insts[inst_of(v)].fmf = insts[inst_of(ci)].fmf; }
    return xb_insert(ci, v, "");
}

fn xb_icmp(ci: i32, pred: i64, a: i32, b: i32) -> i32 {
    if is_constant(a) && is_constant(b) {
        let f = cf_compare(pred, a, b);
        if f >= 0 { return f; }
    }
    let at = vals[a].ty;
    let rt = if ty_is_vector(at) { ty_vector(T_I1, types[at].cnt, types[at].kind == TK_SVEC) } else { T_I1 };
    let v = new_inst(OP_ICMP, rt, 2);
    set_op(v, 0, a);
    set_op(v, 1, b);
    insts[inst_of(v)].pred = pred as u8;
    return xb_insert(ci, v, "");
}

fn xb_cast(ci: i32, opc: i64, a: i32, ty: i32, name: const u8[:]) -> i32 {
    if vals[a].ty == ty { return a; }
    if is_constant(a) {
        let f = if is_desirable_cast_op(opc) { ce_cast(opc, a, ty) } else { cf_cast(opc, a, ty) };
        if f >= 0 { return f; }
    }
    let v = new_inst(opc, ty, 1);
    set_op(v, 0, a);
    if (opc == OP_FPEXT || opc == OP_FPTRUNC) && xb_is_fp_math(vals[ci].ty) { insts[inst_of(v)].fmf = insts[inst_of(ci)].fmf; }
    return xb_insert(ci, v, name);
}

fn xb_shuffle(ci: i32, a: i32, b: i32, mask: const i32[:]) -> i32 {
    if is_constant(a) && is_constant(b) { return ce_shufflevector(a, b, mask); }
    let at = vals[a].ty;
    let rt = ty_vector(types[at].a, mask.len, types[at].kind == TK_SVEC);
    let v = new_inst(OP_SHUFFLEVECTOR, rt, 2);
    set_op(v, 0, a);
    set_op(v, 1, b);
    let ii = inst_of(v);
    insts[ii].aux = ints.len as i32;
    insts[ii].naux = mask.len as i32;
    for m in mask { ints.push(m); }
    return xb_insert(ci, v, "");
}

// CreateIntrinsic (the default ConstantFolder does not fold intrinsics)
fn xb_intrinsic(ci: i32, iname: const u8[:], ov: const i32[:], argsv: const i32[:]) -> i32 {
    let id = intr_lookup(iname);
    if id == 0 { fatal(str("internal: unknown intrinsic ", iname)); }
    let d = au_get_declaration(id, ov);
    return au_create_call(ci, d, argsv);
}

fn xb_i32(k: i64) -> i32 { c_int(T_I32, k) }

// ---------------------------------------------------------------------------------------------
// upgradeX86IntrinsicCall (subset); name without "llvm.x86."

fn upgrade_x86_call(name: const u8[:], ci: i32) -> i32 {
    let a0 = op(ci, 0);
    let ty = vals[ci].ty;
    if name == "sse.sqrt.ss" || name == "sse2.sqrt.sd" {
        let e0 = xb_extractelement(ci, a0, c_int(T_I64, 0));
        let s = xb_intrinsic(ci, "llvm.sqrt", [vals[e0].ty], [e0]);
        return xb_insertelement(ci, a0, s, c_int(T_I64, 0));
    }
    if starts_with(name, "avx.sqrt.p") || starts_with(name, "sse2.sqrt.p") || starts_with(name, "sse.sqrt.p") {
        return xb_intrinsic(ci, "llvm.sqrt", [ty], [a0]);
    }
    if name == "sse.add.ss" || name == "sse2.add.sd" || name == "sse.sub.ss" || name == "sse2.sub.sd" ||
       name == "sse.mul.ss" || name == "sse2.mul.sd" || name == "sse.div.ss" || name == "sse2.div.sd" {
        let e0 = xb_extractelement(ci, a0, xb_i32(0));
        let e1 = xb_extractelement(ci, op(ci, 1), xb_i32(0));
        var o = OP_FDIV;
        if find(name, ".add.") >= 0 { o = OP_FADD; } else if find(name, ".sub.") >= 0 { o = OP_FSUB; } else if find(name, ".mul.") >= 0 { o = OP_FMUL; }
        let r = xb_binop(ci, o, e0, e1);
        return xb_insertelement(ci, a0, r, xb_i32(0));
    }
    let unsigned_mul = name == "sse2.pmulu.dq" || name == "avx2.pmulu.dq" || name == "avx512.pmulu.dq.512";
    let signed_mul = name == "sse41.pmuldq" || name == "avx2.pmul.dq" || name == "avx512.pmul.dq.512";
    if unsigned_mul || signed_mul {
        // upgradePMULDQ
        var l = xb_cast(ci, OP_BITCAST, a0, ty, "");
        var r = xb_cast(ci, OP_BITCAST, op(ci, 1), ty, "");
        if signed_mul {
            let sh = c_splat(ty, c_int(types[ty].a, 32));
            l = xb_binop(ci, OP_SHL, l, sh);
            l = xb_binop(ci, OP_ASHR, l, sh);
            r = xb_binop(ci, OP_SHL, r, sh);
            r = xb_binop(ci, OP_ASHR, r, sh);
        } else {
            let m = c_splat(ty, c_int(types[ty].a, 0xffffffff));
            l = xb_binop(ci, OP_AND, l, m);
            r = xb_binop(ci, OP_AND, r, m);
        }
        return xb_binop(ci, OP_MUL, l, r);
    }
    if starts_with(name, "vcvtph2ps.") {
        var rep = a0;
        let n = types[ty].cnt;
        if n != types[vals[rep].ty].cnt { rep = xb_shuffle(ci, rep, rep, [0, 1, 2, 3]); }
        rep = xb_cast(ci, OP_BITCAST, rep, ty_vector(ty_simple(TK_HALF), n, false), "");
        return xb_cast(ci, OP_FPEXT, rep, ty, "cvtph2ps");
    }
    if starts_with(name, "xop.vpcom") {
        var signed = false;
        if ends_with(name, "ub") || ends_with(name, "uw") || ends_with(name, "ud") || ends_with(name, "uq") { signed = false; }
        else if ends_with(name, "b") || ends_with(name, "w") || ends_with(name, "d") || ends_with(name, "q") { signed = true; }
        else { fatal("Intrinsic has unknown suffix"); }
        var imm: i64 = 0;
        if cb_nargs(ci) == 3 { imm = cint_lo(op(ci, 2)) as! i64; }
        else {
            let r = name[9..];
            if starts_with(r, "lt") { imm = 0; } else if starts_with(r, "le") { imm = 1; } else if starts_with(r, "gt") { imm = 2; }
            else if starts_with(r, "ge") { imm = 3; } else if starts_with(r, "eq") { imm = 4; } else if starts_with(r, "ne") { imm = 5; }
            else if starts_with(r, "false") { imm = 6; } else if starts_with(r, "true") { imm = 7; }
            else { fatal("Unknown condition"); }
        }
        // upgradeX86vpcom
        if imm == 6 { return c_null(ty); }
        if imm == 7 { return c_all_ones(ty); }
        var pred: i64 = 0;
        if imm == 0 { pred = if signed { 40 } else { 36 }; }
        else if imm == 1 { pred = if signed { 41 } else { 37 }; }
        else if imm == 2 { pred = if signed { 38 } else { 34 }; }
        else if imm == 3 { pred = if signed { 39 } else { 35 }; }
        else if imm == 4 { pred = 32; }
        else { pred = 33; }
        let c = xb_icmp(ci, pred, a0, op(ci, 1));
        return xb_cast(ci, OP_SEXT, c, ty, "");
    }
    if starts_with(name, "bmi.pdep.") || starts_with(name, "bmi.pext.") {
        let iname = if starts_with(name, "bmi.pdep.") { "llvm.pdep" } else { "llvm.pext" };
        return xb_intrinsic(ci, iname, [ty], [a0, op(ci, 1)]);
    }
    fatal(str("x86 intrinsic call upgrade is not supported yet (@llvm.x86.", name, ")"));
    return -1;
}
