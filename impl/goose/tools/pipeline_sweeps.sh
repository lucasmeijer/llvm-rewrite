#!/usr/bin/env bash
# Multi-pass pipeline sweeps: realistic O2-like fragments over the corpus and tests/perf/compile, vs LLVM.
# Single-pass sweeps miss bugs that need IR shaped by an earlier pass (or stale state between passes).
# Report only (like `harness/run sweep`); prints one summary line per (pipeline, file set, debugify).
#
#   impl/goose/tools/pipeline_sweeps.sh                 # all pipelines, corpus + perf, with and without debugify
#   impl/goose/tools/pipeline_sweeps.sh -k 3            # only pipeline #3
#   SWEEP_ARGS='--per-function' impl/goose/tools/pipeline_sweeps.sh -k 1
#   NO_DEBUGIFY=1 / NO_PERF=1 / NO_CORPUS=1 / NO_SPLIT=1 to skip parts
#
# Artifacts: .harness-out/sweep/goose/<args>/ as for every sweep (a copy per label: <dir>.<label>). Passes Goose
# doesn't have yet (mldst-motion, the vectorizers, globalopt, ...) are left out. Results: impl/goose/NOTES.md
# ("Multi-pass pipeline sweeps").
set -uo pipefail
cd "$(dirname "$0")/../../.."

P=(
  'sroa,early-cse<memssa>,instcombine,simplifycfg'
  'sroa,early-cse<memssa>,instcombine,simplifycfg,gvn,sccp,instcombine,jump-threading,correlated-propagation,dse,adce,simplifycfg'
  'sroa,instcombine,loop-mssa(loop-rotate,licm)'
  'sroa,instcombine,simplifycfg,loop-mssa(loop-instsimplify,loop-simplifycfg,licm,loop-rotate,licm)'
  'sroa,instcombine,simplifycfg,loop-mssa(loop-instsimplify,loop-simplifycfg,licm,loop-rotate,licm,simple-loop-unswitch<nontrivial>),simplifycfg,instcombine'
  'sroa,instcombine,simplifycfg,loop(loop-idiom,indvars,loop-deletion)'
  'sroa,instcombine,simplifycfg,loop-mssa(loop-rotate,licm),loop(loop-idiom,indvars,loop-deletion,loop-unroll-full)'
  'sroa,early-cse<memssa>,simplifycfg,instcombine,aggressive-instcombine,jump-threading,correlated-propagation,simplifycfg,instcombine,reassociate,loop-mssa(loop-instsimplify,loop-simplifycfg,licm,loop-rotate,licm),simplifycfg,instcombine,loop(loop-idiom,indvars,loop-deletion),sroa,gvn,sccp,bdce,instcombine,jump-threading,correlated-propagation,adce,memcpyopt,dse,loop-mssa(licm),simplifycfg,instcombine'
  'sroa,instcombine,simplifycfg,loop-mssa(loop-rotate,licm),loop(indvars),loop-distribute,loop-load-elim,instcombine,simplifycfg'
  'sroa,instcombine,simplifycfg,constraint-elimination,instcombine,dse,adce'
  'cgscc(function-attrs),function(sroa,instcombine,simplifycfg),cgscc(function-attrs),function(gvn,instcombine)'
  'sroa,instcombine,simplifycfg,loop-mssa(loop-rotate,licm),loop(indvars,loop-deletion),loop-unroll<O2>,sroa,instcombine,loop-mssa(licm<allowspeculation>),simplifycfg,instcombine'
  'module(ipsccp<no-func-spec>),cgscc(inline,function-attrs,function(sroa,early-cse<memssa>,simplifycfg,instcombine)),function(gvn,instcombine,simplifycfg)'
  'sroa,early-cse<memssa>,simplifycfg<bonus-inst-threshold=1;no-forward-switch-cond;switch-range-to-icmp;no-switch-to-lookup;keep-loops;no-hoist-common-insts;no-sink-common-insts;speculate-blocks;simplify-cond-branch>,instcombine,simplifycfg<bonus-inst-threshold=1;forward-switch-cond;switch-range-to-icmp;switch-to-lookup;no-keep-loops;hoist-common-insts;sink-common-insts;speculate-blocks;simplify-cond-branch>,instcombine'
)

only=""
if [ "${1:-}" = "-k" ]; then only="$2"; fi
extra=${SWEEP_ARGS:-}
./impl/goose/build.sh >/dev/null || exit 1

summary() { # $1 label, rest: sweep args. The sweep's artifact dir is replaced by the next run of the same
  # arguments (corpus and perf share one), so the silent mismatches are listed right away from its output.
  local label="$1"; shift
  local out
  out=$(./harness/run sweep --impl goose --no-build $extra "$@" 2>&1)
  local ident diff bad failed
  ident=$(grep -m1 ' identical' <<<"$out" | awk '{print $1}')
  diff=$(grep -m1 ' differs' <<<"$out" | awk '{print $1}')
  bad=$(grep -m1 ' bad-ir' <<<"$out" | awk '{print $1}')
  failed=$(grep -m1 ' failed ' <<<"$out" | awk '{print $1}')
  printf '%-12s identical %5s  differs %3s  bad-ir %3s  failed %4s\n' "$label" "$ident" "$diff" "$bad" "$failed"
  local dir
  dir=$(grep -m1 '^artifacts: ' <<<"$out" | awk '{print $2}')
  if [ -n "$dir" ] && [ -f "$dir/results.tsv" ]; then
    grep -E '^(differs|bad-ir)' "$dir/results.tsv" | cut -f1-3 | sed 's/^/    /'
    # keep a copy per label: the next run with the same arguments replaces the directory
    rm -rf "${dir%/}.${label// /-}"; cp -r "$dir" "${dir%/}.${label// /-}"
  fi
}

for i in "${!P[@]}"; do
  n=$((i + 1))
  [ -n "$only" ] && [ "$only" != "$n" ] && continue
  echo "#$n ${P[$i]}"
  # split: every top-level pass in its own function adaptor (function(a),function(b),...), so analyses cached by
  # one pass for a function survive while the next adaptor visits the other functions (LLVM keeps one result per
  # function in its FunctionAnalysisManager; JumpThreading's LVI reaching CVP is the case that found this)
  if [ -z "${NO_SPLIT:-}" ] && [ -z "${NO_CORPUS:-}" ]; then
    sp=$(python3 -c '
import sys
s=sys.argv[1]; d=0; cur=""; out=[]
for ch in s:
    if ch=="(": d+=1
    if ch==")": d-=1
    if ch=="," and d==0: out.append(cur); cur=""; continue
    cur+=ch
out.append(cur)
print(",".join(x if x.startswith(("cgscc(","function(","module(")) else "function(%s)" % x for x in out))' "${P[$i]}")
    summary "split corpus" --passes "$sp"
  fi
  for dbg in "" "debugify,"; do
    [ -n "$dbg" ] && [ -n "${NO_DEBUGIFY:-}" ] && continue
    tag=${dbg:+dbg }
    p=${P[$i]}
    # debugify is a module pass: a function pipeline after it needs function(...)
    if [ -n "$dbg" ]; then case "$p" in cgscc\(*|function\(*|module\(*) p="debugify,$p" ;; *) p="debugify,function($p)" ;; esac; fi
    [ -z "${NO_CORPUS:-}" ] && summary "${tag}corpus" --passes "$p"
    # LLVM's opt stops at InstCombine's fixpoint verification on 3 of the 4 programs. Whole programs mostly stop
    # loudly somewhere (one unported corner per program is enough), so they are also compared per function.
    pp=$(sed -E 's/(^|[,(])instcombine/\1instcombine<no-verify-fixpoint>/g' <<<"$p")
    [ -z "${NO_PERF:-}" ] && summary "${tag}perf" --passes "$pp" 'tests/perf/compile/*'
    [ -z "${NO_PERF:-}" ] && summary "${tag}perf-fn" --per-function --passes "$pp" 'tests/perf/compile/*'
  done
done
