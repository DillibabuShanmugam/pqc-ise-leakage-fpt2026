#!/usr/bin/env python3
"""Per-instruction toggle windows from a full-SoC simulation, one block per run.

The power proxy is the per-cycle count of signal transitions over the whole
simulated design, which is the same proxy the six-block campaign used. A window
is located by watching the CV-X-IF issue handshake: when the adapter accepts an
instruction whose opcode is Custom-3 and whose (funct3, funct7) match the block
under test, the mailbox tells us which operand row it belongs to.

Optionally the count can be restricted to one part of the hierarchy, which
answers a question the whole-design count cannot: does the secret-dependent
switching live in the coprocessor, or in the processor coupling that carries the
operand to it? On a tightly-coupled ISA extension those are different security
stories.

  usage: extract10.py <vcd> <block 1..10> [ncycles=12] [scope]
         scope is "all" (default), "copro", or "core"
  writes SIM_block<k>[_<scope>].npy  (rows x ncycles) and the matching _idx.npy
"""
import sys, numpy as np

VCD = sys.argv[1]
BLK = int(sys.argv[2])
NCYC = int(sys.argv[3]) if len(sys.argv) > 3 else 12
SCOPE = sys.argv[4] if len(sys.argv) > 4 else "all"
SUFFIX = "" if SCOPE == "all" else f"_{SCOPE}"

# substrings that place a signal inside the coprocessor or inside the core
COPRO_PATH = "i_sca_pqc"
CORE_PATH = "cv32e40x"

# (funct3, funct7) of the instruction each block issues
TARGET = {1: (1, 1), 2: (1, 0), 3: (6, 6), 4: (1, 2), 5: (2, 3),
          6: (4, 0), 7: (3, 0), 8: (1, 3), 9: (1, 4), 10: (5, 1)}
NAME = {1: "MONT_K", 2: "BARRETT_K", 3: "AND_LATCH", 4: "CADDQ",
        5: "NTT_BFLY_GS_MUL", 6: "COMPRESS_1", 7: "CBD2_1", 8: "BARRETT_D",
        9: "MONT_D_REDUCE64", 10: "DECOMPOSE"}

IF = {"iv": "x_issue_valid_i", "iacc": "x_issue_resp_accept_o",
      "instr": "x_issue_req_instr_i"}

def pc(x):
    return bin(x).count("1")

# ---- header: map VCD symbols to the handshake signals and the mailbox --------
sym2, MB, cur, scope = {}, {}, {}, []
with open(VCD) as fh:
    for ln in fh:
        s = ln.strip()
        if s.startswith("$scope"):
            scope.append(s.split()[2])
        elif s.startswith("$upscope"):
            if scope:
                scope.pop()
        elif s.startswith("$var"):
            p = s.split()
            sym, nm = p[3], p[4]
            path = ".".join(scope)
            if SCOPE == "all":
                cur[sym] = 0
            elif SCOPE == "copro" and COPRO_PATH in path:
                cur[sym] = 0
            elif SCOPE == "core" and CORE_PATH in path and COPRO_PATH not in path:
                cur[sym] = 0
            else:
                cur.setdefault(sym, None)     # tracked for handshakes, not counted
            if "i_sca_pqc" in path and "adapter" in path:
                for k, v in IF.items():
                    if nm == v:
                        sym2[sym] = k
            if nm.startswith("mailbox_reg[") and sym not in MB and len(scope) <= 2:
                MB[sym] = nm
        elif s.startswith("$enddefinitions"):
            break

# ---- body: per-cycle toggle count plus the value of the watched signals ------
tog, vals, order, ci = {}, {}, [], {}
acc, t, body = 0, None, False
with open(VCD) as fh:
    for ln in fh:
        s = ln.rstrip("\n")
        if not body:
            if s.startswith("$enddefinitions"):
                body = True
            continue
        if not s:
            continue
        if s[0] == "#":
            if t is not None:
                tog[t] = acc
                vals[t] = dict(ci)
                order.append(t)
            acc = 0
            t = int(s[1:])
            continue
        if t is None:
            continue
        if s[0] in "01":
            sym = s[1:]
            if sym in cur:
                v = int(s[0])
                if cur[sym] is not None:
                    acc += cur[sym] ^ v
                    cur[sym] = v
                if sym in sym2:
                    ci[sym2[sym]] = v
                if sym in MB:
                    ci[MB[sym]] = v
        elif s[0] in "bB":
            p = s.split()
            if len(p) > 1 and p[1] in cur:
                try:
                    v = int(p[0][1:].replace("x", "0").replace("z", "0"), 2)
                except ValueError:
                    v = 0
                if cur[p[1]] is not None:
                    acc += pc(cur[p[1]] ^ v)
                    cur[p[1]] = v
                if p[1] in sym2:
                    ci[sym2[p[1]]] = v
                if p[1] in MB:
                    ci[MB[p[1]]] = v
if t is not None:
    tog[t] = acc
    vals[t] = dict(ci)
    order.append(t)

idx = {tt: i for i, tt in enumerate(order)}
want = TARGET[BLK]

hits = []
for tt in order:
    v = vals[tt]
    if v.get("iv") and v.get("iacc"):
        w = v.get("instr", 0)
        if (w & 0x7f) == 0x7b and ((w >> 12) & 7, (w >> 25) & 0x7f) == want:
            if v.get("mailbox_reg[0]", 0) == BLK:
                hits.append((tt, v.get("mailbox_reg[2]", 0)))

# the handshake is held across two VCD timestamps per cycle; keep the first
uniq = [h for i, h in enumerate(hits) if i == 0 or idx[h[0]] - idx[hits[i - 1][0]] > 1]

out = {}
for tt, oi in uniq:
    i0 = idx[tt] - 2
    if i0 < 0 or i0 + 2 * NCYC >= len(order):
        continue
    seg = np.array([tog[order[j]] for j in range(i0, i0 + 2 * NCYC)],
                   np.float32).reshape(NCYC, 2).sum(1)
    out[oi] = seg

ks = sorted(out)
if not ks:
    raise SystemExit(f"block {BLK}: no {NAME[BLK]} issue found in {VCD}")
A = np.stack([out[k] for k in ks])
np.save(f"SIM_block{BLK}{SUFFIX}.npy", A)
np.save(f"SIM_block{BLK}{SUFFIX}_idx.npy", np.array(ks))
print(f"  block {BLK} {NAME[BLK]} [{SCOPE}]: {A.shape}, operand rows {ks[0]}..{ks[-1]} "
      f"({len(ks)} unique), mean toggles/cycle {A.mean():.1f}")
