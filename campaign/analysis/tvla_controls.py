#!/usr/bin/env python3
"""Controls for the fixed-versus-random TVLA, per instruction and domain.
  peak      |t| fixed vs random, and its column
  FF-vs-FR  at that column: fixed rows after a fixed row vs fixed rows after a random row (repetition part)
  FaR-vs-R  peak |t| of fixed rows with a random predecessor vs all random rows (value part with matched history)
  R-vs-R    peak |t| of the random class split at random in two halves (must stay below 4.5)
  null      largest peak |t| over 100 shuffles of the class labels (must stay below the observed peak)
usage: tvla_controls.py [--campaign tvla10|tvla3] [--pass 1|2]
"""
import os, sys
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from campaign import get, load_sim, load_board
from names import INSTR
from campaign import welch_t

C = get(); p = int(sys.argv[sys.argv.index("--pass") + 1]) - 1 if "--pass" in sys.argv else 0
rng = np.random.default_rng(5)
print(f"campaign {C['name']} (board pass {p+1})")
print(f"{'instr':<16} {'dom':<5} {'peak':>6} {'col':>4} | {'FF-vs-FR':>8} {'FaR-vs-R':>8} {'R-vs-R':>7} {'null':>6}")
for k in range(1, 11):
    cls = C["cls"][k]; pred = np.r_[0, cls[:-1]]
    for dom in ["sim", "board"]:
        T, I = load_sim(C, k) if dom == "sim" else load_board(C, k, p)
        if T is None: continue
        c = cls[I]; pc = pred[I]; F = c == 1; R = ~F
        t = welch_t(T[F], T[R]); j = int(np.argmax(np.abs(t)))
        ff = F & (pc == 1); fr = F & (pc == 0)
        t_ffr = abs(welch_t(T[ff], T[fr])[j]) if ff.sum() > 2 and fr.sum() > 2 else float("nan")
        t_frR = np.abs(welch_t(T[fr], T[R])).max()
        ri = np.where(R)[0]; h = rng.permutation(len(ri)); a, b = ri[h[:len(ri) // 2]], ri[h[len(ri) // 2:]]
        t_rr = np.abs(welch_t(T[a], T[b])).max()
        null = max(np.abs(welch_t(T[m], T[~m])).max() for m in (rng.permutation(F) for _ in range(100)))
        print(f"{INSTR[k]:<16} {dom:<5} {abs(t[j]):>6.1f} {j:>4} | {t_ffr:>8.1f} {t_frR:>8.1f} {t_rr:>7.1f} {null:>6.1f}")
