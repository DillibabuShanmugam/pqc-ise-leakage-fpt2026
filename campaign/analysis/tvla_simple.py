#!/usr/bin/env python3
"""Plain fixed-versus-random TVLA, one domain at a time.
Per instruction: Welch's t between the fixed and the random rows at every cycle
(pre-silicon) or sample (CW305); peak |t|, its position, and the number of
columns above 4.5. Nothing is compared across the domains here.
usage: tvla_simple.py sim|board [--pass 1|2] [--campaign tvla10|tvla3]
"""
import json, os, sys
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from campaign import get, load_sim, load_board, ROOT, welch_t
from names import INSTR


C = get(); dom = sys.argv[1]
p = int(sys.argv[sys.argv.index("--pass") + 1]) - 1 if "--pass" in sys.argv else 0
unit = "cycle" if dom == "sim" else "sample"
out = {}
print(f"campaign {C['name']}, {dom}" + (f" pass {p+1}" if dom == "board" else ""))
print(f"{'#':>2} {'instruction':<17} {'n_fix':>5} {'n_rnd':>5} {'peak|t|':>8} {unit:>6} {'cols>4.5':>8}")
for k in range(1, 11):
    T, I = load_sim(C, k) if dom == "sim" else load_board(C, k, p)
    if T is None:
        print(f"{k:>2} {INSTR[k]:<17} (no traces)"); continue
    fx = C["cls"][k][I] == 1
    t = welch_t(T[fx], T[~fx]); j = int(np.argmax(np.abs(t)))
    out[k] = {"instr": INSTR[k], "n_fixed": int(fx.sum()), "n_random": int((~fx).sum()),
              "peak_abs_t": float(abs(t[j])), "peak_pos": j, "n_above": int((np.abs(t) > 4.5).sum()), "t": t.tolist()}
    print(f"{k:>2} {INSTR[k]:<17} {fx.sum():>5} {(~fx).sum():>5} {abs(t[j]):>8.1f} {j:>6} {(np.abs(t)>4.5).sum():>8}")
sfx = "" if dom == "sim" else f"_pass{p+1}"
json.dump(out, open(f"{ROOT}/analysis/tvla_simple_{C['name']}_{dom}{sfx}.json", "w"))
