"""Fixed-versus-random TVLA figures, one per domain, from the fw_tvla campaign.
Pre-silicon: Welch's |t| per simulated cycle (500 fixed vs 500 random).
Post-silicon (when traces exist): Welch's |t| per CW305 sample, one figure per pass.
"""
import json, os, sys
from pathlib import Path
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

ROOT = Path(__file__).resolve().parents[1]
C = ROOT / "campaign"
sys.path.insert(0, str(C / "analysis"))
from names import welch, NAME
from names import INSTR
from campaign import get
CAMP = get()                      # --campaign tvla10 (default) or tvla3; figure names carry CAMP["tag"]
plt.rcParams.update({"font.size": 7, "axes.titlesize": 5.5, "axes.labelsize": 7, "xtick.labelsize": 6,
                     "ytick.labelsize": 6, "pdf.fonttype": 42, "axes.spines.top": False, "axes.spines.right": False})
SHORT = {"NTT_BFLY_GS_MUL": "GS_MUL", "MONT_D_REDUCE64": "MONT_D_R64", "DECOMPOSE": "DECOMP", "COMPRESS_1": "COMPR_1"}

def tprofile(T, lab):
    return np.array([abs(welch(T[lab, j], T[~lab, j])) for j in range(T.shape[1])])

# ---- pre-silicon ---------------------------------------------------------------
fig, axes = plt.subplots(2, 5, figsize=(3.45, 2.4), sharex=True, layout="constrained")
for k, ax in zip(range(1, 11), axes.ravel()):
    S = np.load(C / f"sim/{CAMP['sim_prefix']}_block{k}.npy"); si = np.load(C / f"sim/{CAMP['sim_prefix']}_block{k}_idx.npy")
    lab = CAMP["cls"][k][si] == 1
    t = tprofile(S, lab)
    ax.plot(range(12), t, "-o", color="black", lw=.8, ms=2.2)
    ax.axhline(4.5, color="black", ls="--", lw=.9)
    ax.set_title(f"{k} {SHORT.get(INSTR[k], INSTR[k])}", pad=2)
    ax.set_xticks([0, 4, 8]); ax.set_ylim(0, max(50, t.max() * 1.1)); ax.set_yticks([0, 20, 40])
for ax in axes[1]: ax.set_xlabel("cycle")
for ax in axes[:, 0]: ax.set_ylabel("|t|")
axes[0, 2].text(11, 6.5, "4.5", ha="right", va="bottom", fontsize=5)
fig.savefig(ROOT / f"paper/v14_tvla_pre{CAMP['tag']}.pdf"); plt.close(fig)
print("pre-silicon figure written")

# ---- post-silicon, one figure per pass (never pooled) -------------------------------
RAIL = 0.5 - 1.0 / 1024
for d, suffix in [(C / CAMP["traces"][0], CAMP["tag"]), (C / CAMP["traces"][1], CAMP["tag"] + "_pass2")]:
    if not (d / f"block1_{NAME[1]}").is_dir():
        continue
    fig, axes = plt.subplots(2, 5, figsize=(3.45, 1.95), sharex=True, layout="constrained")
    for k, ax in zip(range(1, 11), axes.ravel()):
        p = d / f"block{k}_{NAME[k]}"
        T = np.load(p / "traces.npy"); I = np.load(p / "operand_index.npy")
        kp = ~(np.abs(T) >= RAIL).any(1); T, I = T[kp], I[kp]; lab = CAMP["cls"][k][I] == 1
        t = tprofile(T, lab)
        W = 128
        ax.plot(range(W), t[:W], "-", color="black", lw=.7)
        ax.axhline(4.5, color="black", ls="--", lw=.9)
        ax.set_title(f"{k} {SHORT.get(INSTR[k], INSTR[k])}", pad=2)
        ax.set_xticks([0, 64, 128]); ax.set_xticklabels(["0", "64", "128"], fontsize=5); ax.set_ylim(0, max(50, t[:W].max() * 1.1)); ax.set_yticks([0, 20, 40])
    for ax in axes[1]: ax.set_xlabel("sample")
    for ax in axes[:, 0]: ax.set_ylabel("|t|")
    fig.savefig(ROOT / f"paper/v14_tvla_post{suffix}.pdf"); plt.close(fig)
    print(f"post-silicon figure written for {d.name}")
