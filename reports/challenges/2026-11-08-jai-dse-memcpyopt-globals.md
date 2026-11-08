# Jai's global procedure namespace keeps producing silent duplicates between concurrent agents

- **Date / implementation / unit:** 2026-11-08 / jai / L1.dse, L1.memcpyopt
- **What happened:** porting DSE and MemCpyOpt next to the GVN agent. Jai only type-checks reachable code and every
  `#load`ed file shares one namespace, so helpers I added collided with existing ones in files I had not read
  (`common_alignment` in pass_sroa.jai, `Retained_Knowledge` in loads.jai with *different fields*). The struct case
  compiled into a confusing type error in an unrelated literal; the procedure case only showed up as "matches 2
  overloads". Coordinating names with the concurrent GVN agent by message worked well (it pushed phi_trans_addr.jai
  early, I reused it), but that was ad hoc.
- **Time or effort lost:** small (~15 minutes) this time; the bigger risk is a duplicate that type-checks and is
  silently picked by overload resolution.
- **What would have helped:** a generated index of top-level names per file in impl/jai (a `tools/names.py` that
  lists `name ::` definitions) to grep before adding a helper, and a convention that pass-local helpers carry the
  pass prefix (`dse_`, `mco_`), which I followed.
- **What you did instead:** prefixed everything pass-local, grepped `^name ::` before each shared helper, and
  messaged the GVN agent the list of shared names I was adding.
