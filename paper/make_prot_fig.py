#!/usr/bin/env python3
"""Fig: protected multiplier (SECMUL replacing MONT_K), six-block capture, 872 traces after clipping:
per-sample statistic of the Hamming weight of the unmasked secret, below 4.5 at every sample."""
import json
from pathlib import Path
import numpy as np
import matplotlib; matplotlib.use("Agg"); import matplotlib.pyplot as plt
ROOT = Path(__file__).resolve().parents[1]; P = ROOT / "protected"
plt.rcParams.update({"font.size": 7, "axes.labelsize": 7, "xtick.labelsize": 6, "ytick.labelsize": 6, "pdf.fonttype": 42,
                     "axes.spines.top": False, "axes.spines.right": False})
op = json.load(open(P / "operands_board.json"))
hw = lambda v: np.array([bin(int(x)).count("1") for x in v]).astype(float)
sec, a0 = hw(op["secret_coeff"]), hw(op["mul_a0"])
T = np.load(P / "block4_secmul_prot/traces.npy").astype(float); I = np.load(P / "block4_secmul_prot/operand_index.npy")
mx = np.abs(T).max(); keep = ~(np.abs(T) >= mx - 1e-9).any(1); T, I = T[keep], I[keep]
def corr(M, y):
    M = M - M.mean(0); y = y - y.mean(); return (M * y[:, None]).sum(0) / (np.sqrt((M**2).sum(0)) * np.sqrt((y**2).sum()) + 1e-30)
def tt(r, n): r = np.abs(r); return r * np.sqrt(n - 2) / np.sqrt(np.maximum(1 - r * r, 1e-12))
ts, ta = tt(corr(T, sec[I]), len(T)), tt(corr(T, a0[I]), len(T))
print(f"n={len(T)} secret peak {ts.max():.2f} at {ts.argmax()}, share a0 peak {ta.max():.2f} at {ta.argmax()}")
fig, ax = plt.subplots(figsize=(3.45, 1.55), layout="constrained")
ax.plot(ts, color="black", lw=.8)
ax.axhline(4.5, color="black", ls="--", lw=.9); ax.text(497, 4.9, "4.5", ha="right", va="bottom", fontsize=6)
ax.set_xlim(0, 500); ax.set_ylim(0, 6); ax.set_xlabel("sample"); ax.set_ylabel("|t|")
fig.savefig(ROOT / "paper/v14_tvla_prot.pdf"); print("written")
