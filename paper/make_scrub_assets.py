#!/usr/bin/env python3
"""Paper assets from the scrub campaign (fixed-versus-random, every run after one constant operand):
   v13_results/table_tvla3.tex, v13_figs/v14_crossdomain_scrub.pdf, v13_results/scrub_numbers.tex"""
import json, sys
from pathlib import Path
import numpy as np
import matplotlib; matplotlib.use("Agg"); import matplotlib.pyplot as plt
ROOT = Path(__file__).resolve().parents[1]; AN = ROOT / "campaign/results"
sys.path.insert(0, str(ROOT / "campaign/analysis"))
from campaign import get, load_sim, load_board
from names import INSTR
plt.rcParams.update({"font.size": 7, "axes.labelsize": 7, "xtick.labelsize": 6, "ytick.labelsize": 6, "pdf.fonttype": 42,
                     "axes.spines.top": False, "axes.spines.right": False})
SHORT = {"NTT_BFLY_GS_MUL": "GS\\_MUL", "MONT_D_REDUCE64": "MONT\\_D\\_R64"}
ALGO = {1: "ML-KEM", 2: "ML-KEM", 3: "ML-KEM", 4: "ML-KEM", 5: "ML-KEM", 6: "ML-KEM", 7: "ML-KEM", 8: "ML-DSA", 9: "ML-DSA", 10: "ML-DSA"}
sim = json.load(open(AN / "tvla_simple_tvla3_sim.json")); p1 = json.load(open(AN / "tvla_simple_tvla3_board_pass1.json"))
p2 = json.load(open(AN / "tvla_simple_tvla3_board_pass2.json")); x1 = {r["block"]: r for r in json.load(open(AN / "tvla_crossdomain_tvla3_pass1.json"))}
single = [2, 4, 6, 7, 8, 10]; double = [1, 3, 5, 9]
nm = lambda k: SHORT.get(INSTR[k], INSTR[k].replace("_", "\\_"))
L = [r"\begin{tabular}{@{}r@{\hspace{3pt}}l r r r r r r@{}}", r"\toprule",
     r"\# & Instruction & $|t|$ sim & $d$ sim & $|t|$ CW305 & $|t|$ pass 2 & $d$ CW305 & $|r|$ \\", r"\midrule",
     r"\multicolumn{8}{@{}l}{Secret operand fixed against random} \\"]
for k in single + ["mid"] + double:
    if k == "mid": L.append(r"\multicolumn{8}{@{}l}{Secret constant, public operand fixed against random} \\"); continue
    s, a, b, c = sim[str(k)], p1[str(k)], p2[str(k)], x1[k]
    L.append(f"{k} & \\texttt{{{nm(k)}}} & {s['peak_abs_t']:.1f} & {abs(c['d_sim']):.2f} & {a['peak_abs_t']:.1f} & {b['peak_abs_t']:.1f} & {abs(c['d_board']):.2f} & {abs(c['r']):.3f} \\\\")
L += [r"\bottomrule", r"\end{tabular}"]
(ROOT / "paper/table_tvla3.tex").write_text("\n".join(L) + "\n")

# acquisition-order correlation, max over columns, each domain
C = get.__globals__["CAMPAIGNS"]["tvla3"]; sys.argv += ["--campaign", "tvla3"]; C = get()
osim, obrd = [], []
for k in range(1, 11):
    S, si = load_sim(C, k); T, ti = load_board(C, k, 0)
    osim.append(max(abs(np.corrcoef(si, S[:, c])[0, 1]) for c in range(S.shape[1])))
    obrd.append(max(abs(np.corrcoef(np.arange(len(T)), T[:, j])[0, 1]) for j in range(T.shape[1])))
rs = [abs(x1[k]["r"]) for k in range(1, 11)]
(ROOT / "paper/scrub_numbers.tex").write_text(
    f"\\renewcommand{{\\MeanCrossR}}{{{np.mean(rs):.3f}}}\n\\newcommand{{\\MinCrossR}}{{{min(rs):.2f}}}\n"
    f"\\newcommand{{\\OrderSim}}{{{max(osim):.3f}}}\n\\newcommand{{\\OrderBoard}}{{{max(obrd):.3f}}}\n"
    f"\\newcommand{{\\ThrR}}{{{4.5/np.sqrt(498+4.5**2):.3f}}}\n")
print("mean |r|", round(np.mean(rs), 3), "min", min(rs), "order corr sim", round(max(osim), 3), "board", round(max(obrd), 3), "r at 4.5, N=500:", round(4.5/np.sqrt(498+4.5**2), 3))

fig, ax = plt.subplots(figsize=(3.45, 2.55), layout="constrained"); y = np.arange(10)
for i, k in enumerate(range(1, 11)):
    ax.barh(y[i], rs[i], 0.62, facecolor="white" if ALGO[k] == "ML-KEM" else "black", edgecolor="black", linewidth=.7)
ax.axvline(4.5 / np.sqrt(498 + 4.5**2), color="black", ls="--", lw=0.9)
ax.set_yticks(y); ax.set_yticklabels([f"{k} {nm(k).replace(chr(92), '')}" for k in range(1, 11)], fontsize=6.4)
ax.set_xlabel("peak |r|, simulated cycle against measured sample"); ax.set_xlim(0, 1.05); ax.set_ylim(-0.5, 9.5); ax.invert_yaxis()
fig.legend(handles=[plt.Rectangle((0, 0), 1, 1, facecolor="white", edgecolor="black", label="ML-KEM-1024"),
                    plt.Rectangle((0, 0), 1, 1, facecolor="black", edgecolor="black", label="ML-DSA-44"),
                    plt.Line2D([], [], color="black", ls="--", label="|t| = 4.5 at N = 500 (|r| = 0.198)")],
           loc="lower center", bbox_to_anchor=(0.5, -0.02), ncol=3, frameon=False, fontsize=6.2, handletextpad=.4, columnspacing=.8)
fig.get_layout_engine().set(rect=(0, 0.06, 1, 0.94))
fig.savefig(ROOT / "paper/v14_crossdomain_scrub.pdf"); plt.close(fig); print("assets written")
