"""Campaign selection shared by the TVLA scripts.
usage in scripts: from campaign import get; C = get()   (reads --campaign NAME from argv, default tvla10)
"""
import json, os, sys
import numpy as np
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CAMPAIGNS = {
    "tvla3": dict(fw="../firmware", sim_prefix="SIMS", traces=["board/traces_tvla3", "board/traces_tvla3_pass2"], tag="_scrub"),
}
def get():
    name = "tvla3"
    if "--campaign" in sys.argv:
        name = sys.argv[sys.argv.index("--campaign") + 1]
    c = dict(CAMPAIGNS[name]); c["name"] = name
    g = json.load(open(f"{ROOT}/{c['fw']}/operands_tvla10.json"))
    cb = g.get("class_by_block")
    c["cls"] = {k: np.asarray(cb[str(k)] if cb else g["class"]) for k in range(1, 11)}
    c["design"] = g["design"]; c["per_block_order"] = g.get("per_block_order", False)
    return c
def load_sim(c, k):
    S = np.load(f"{ROOT}/sim/{c['sim_prefix']}_block{k}.npy").astype(float)
    I = np.load(f"{ROOT}/sim/{c['sim_prefix']}_block{k}_idx.npy")
    return S, I
def load_board(c, k, p=0, name=None):
    from names import NAME
    d = f"{ROOT}/{c['traces'][p]}/block{k}_{NAME[k]}"
    if not os.path.isdir(d):
        return None, None
    T = np.load(f"{d}/traces.npy").astype(float); I = np.load(f"{d}/operand_index.npy")
    keep = ~(np.abs(T) >= 0.5 - 1.0 / 1024).any(1)      # rail-clipped traces out
    return T[keep], I[keep]

def welch_t(a, b):
    """Welch's t per column between two trace sets; 0 where both are constant."""
    den = np.sqrt(a.var(0, ddof=1) / len(a) + b.var(0, ddof=1) / len(b))
    with np.errstate(divide="ignore", invalid="ignore"):
        t = (a.mean(0) - b.mean(0)) / den
    return np.where(den > 0, t, 0.0)
