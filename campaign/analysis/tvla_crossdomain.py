#!/usr/bin/env python3
"""Agreement between the pre-silicon and the post-silicon TVLA, nothing else.
Per instruction:
  verdict   crosses 4.5 in simulation / on the board (pass given)
  |r|       activity correlation: Pearson r between simulated toggle count at cycle c
            and measured amplitude at sample j over the RANDOM-class traces paired by
            operand; peak |r| of the 12 x 500 grid, with the largest |r| over 100
            re-pairings of the same traces as the null
  d sim / d board   Cohen's d between the classes at each domain's own peak column
No t value is compared across the domains.
usage: tvla_crossdomain.py [--campaign tvla10|tvla3] [--pass 1|2]
"""
import os, sys, json
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from campaign import get, load_sim, load_board, ROOT
from names import INSTR
from campaign import welch_t

C = get(); p = int(sys.argv[sys.argv.index("--pass") + 1]) - 1 if "--pass" in sys.argv else 0
rng = np.random.default_rng(11)

def cohen(a, b):
    sp = np.sqrt((a.var(ddof=1) + b.var(ddof=1)) / 2); return float((a.mean() - b.mean()) / sp) if sp > 0 else float("inf")

rows = []
print(f"campaign {C['name']}, board pass {p+1}")
print(f"{'#':>2} {'instruction':<16} {'sim':>4} {'brd':>4} {'|r|':>6} {'null':>6} {'cyc':>3} {'smp':>4} {'d sim':>6} {'d brd':>6}")
for k in range(1, 11):
    S, si = load_sim(C, k); T, ti = load_board(C, k, p)
    if T is None: continue
    cls = C["cls"][k]
    fs = cls[si] == 1; fb = cls[ti] == 1
    ts = welch_t(S[fs], S[~fs]); tb = welch_t(T[fb], T[~fb])
    js, jb = int(np.argmax(np.abs(ts))), int(np.argmax(np.abs(tb)))
    ds, db = cohen(S[fs, js], S[~fs, js]), cohen(T[fb, jb], T[~fb, jb])
    rnd = np.where(cls == 0)[0]
    common = np.intersect1d(np.intersect1d(si, ti), rnd)
    A = S[np.searchsorted(np.sort(si), common)] if np.all(np.diff(si) > 0) else S[[int(np.where(si == c)[0][0]) for c in common]]
    B = T[[int(np.where(ti == c)[0][0]) for c in common]]
    A = (A - A.mean(0)) / (A.std(0) + 1e-12); B = (B - B.mean(0)) / (B.std(0) + 1e-12)
    G = A.T @ B / len(common); c, j = np.unravel_index(np.argmax(np.abs(G)), G.shape)
    null = max(np.abs(A[rng.permutation(len(common))].T @ B / len(common)).max() for _ in range(100))
    rows.append({"block": k, "instr": INSTR[k], "sim_cross": bool(abs(ts[js]) > 4.5), "board_cross": bool(abs(tb[jb]) > 4.5),
                 "r": float(G[c, j]), "null_max": float(null), "cycle": int(c), "sample": int(j), "n_paired": int(len(common)),
                 "d_sim": ds, "d_board": db, "sim_peak_t": float(abs(ts[js])), "board_peak_t": float(abs(tb[jb]))})
    print(f"{k:>2} {INSTR[k]:<16} {'yes' if rows[-1]['sim_cross'] else 'no':>4} {'yes' if rows[-1]['board_cross'] else 'no':>4} "
          f"{abs(G[c,j]):>6.3f} {null:>6.3f} {c:>3} {j:>4} {ds:>6.2f} {db:>6.2f}")
agree = sum(r["sim_cross"] == r["board_cross"] for r in rows)
print(f"verdict agreement {agree}/{len(rows)}; mean |r| {np.mean([abs(r['r']) for r in rows]):.3f}; all |r| above null: {all(abs(r['r']) > r['null_max'] for r in rows)}; r sign: {'all negative' if all(r['r'] < 0 for r in rows) else 'mixed'}")
json.dump(rows, open(f"{ROOT}/analysis/tvla_crossdomain_{C['name']}_pass{p+1}.json", "w"), indent=1)
