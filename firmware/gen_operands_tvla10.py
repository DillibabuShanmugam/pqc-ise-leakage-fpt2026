#!/usr/bin/env python3
"""Fixed-versus-random operands for a TVLA of the ten instructions.

Each block gets N rows: N/2 carry one fixed operand set, N/2 carry fresh random
operands, in a parity-balanced random interleave (one fixed and one random row
per consecutive pair, order drawn at random). Strict alternation is NOT used:
it aliases the class to the loop-index parity, and the counter increment alone
then separates the classes (|t| about 32 at fixed cycles in every block). The firmware
is unchanged; only the tables differ from gen_operands10.py, so the same
instr_board10.c compiles against fw_tvla/operands10.h.

Classical TVLA arrangement. For the four two-operand instructions (MONT_K,
AND_LATCH, NTT_BFLY_GS_MUL, MONT_D_REDUCE64) the SECRET operand is held at one
constant value in every row of both classes, and the public (control) operand
is the test variable: fresh random in the random class, one constant value in
the fixed class. The six single-operand instructions have no control operand,
so their single operand is the test variable, random in one class and fixed in
the other. Random draws use the ranges of gen_operands10.py; fixed values come
from one draw of a separate seed.

Writes fw_tvla/operands10.h and fw_tvla/operands_tvla10.json; the JSON holds the
class of every row (1 = fixed, 0 = random) and the operands.
"""
import numpy as np, json, sys, os

QK, QD = 3329, 8380417
N = int(sys.argv[1]) if len(sys.argv) > 1 else 1000
OUT = sys.argv[2] if len(sys.argv) > 2 else "fw_tvla"
PER_BLOCK = "--per-block-order" in sys.argv
assert N % 2 == 0
H = N // 2
os.makedirs(OUT, exist_ok=True)

rr = np.random.default_rng(20260913)          # random class
rf = np.random.default_rng(777)               # the one fixed draw
# 1 = fixed row. Parity-balanced random interleave: every pair of consecutive
# rows holds one fixed and one random row in a random order, so the class is
# independent of the loop index parity (the counter increment toggles a
# different number of bits on odd and even indices) and of every higher index
# bit, while both classes stay evenly spread over the capture.
ro  = np.random.default_rng(31415)
def draw_order():
    c = np.zeros(N, dtype=int)
    if PER_BLOCK:   # exactly H/2 pairs start with the fixed row: 250 fixed rows on even and 250 on odd indices
        first_fixed = ro.permutation(np.r_[np.ones(H // 2, int), np.zeros(H - H // 2, int)])
    else:
        first_fixed = ro.integers(0, 2, H)
    c[0::2] = first_fixed
    c[1::2] = 1 - first_fixed
    return c
# one order shared by all blocks, or an independent order per block (--per-block-order)
CLS = {k: (draw_order() if (PER_BLOCK or k == 1) else None) for k in range(1, 11)}
if not PER_BLOCK:
    for k in range(2, 11): CLS[k] = CLS[1]
cls = CLS[1]   # used by mix() through CUR

CUR = [1]
def mix(rand_vals, fixed_val):
    """test operand of block CUR[0]: fixed_val where that block's class == 1, rand_vals elsewhere."""
    v = np.array(rand_vals).copy()
    v[CLS[CUR[0]] == 1] = fixed_val
    return v
def blk(k):
    CUR[0] = k

def const(val):
    """secret operand of a two-operand instruction: one value in every row."""
    return np.full(N, val)

# ---- random draws (same ranges as gen_operands10.py) and one fixed draw ----
s   = const(rf.integers(0, QK))                              # secret, constant
blk(1); b   = mix(rr.integers(0, QK, N),             rf.integers(0, QK))   # public: random vs fixed
blk(2); x   = mix(rr.integers(0, QK, N),             rf.integers(0, QK))
blk(3); w   = const(rf.integers(0, 1 << 12))                         # secret, constant
pw  = mix(rr.integers(0, 1 << 12, N),        rf.integers(0, 1 << 12))   # public: random vs fixed
blk(4); c4  = mix(rr.integers(-(QK-1), QK, N),       rf.integers(-(QK-1), QK)).astype(np.int64)
blk(5); a5  = const(rf.integers(-(QK-1), QK)).astype(np.int64)      # secret, constant
b5  = const(rf.integers(-(QK-1), QK)).astype(np.int64)      # secret, constant
z5  = mix(rr.integers(-(QK-1), QK, N),       rf.integers(-(QK-1), QK)).astype(np.int64)   # public twiddle: random vs fixed
blk(6); c6  = mix(rr.integers(0, QK, N),             rf.integers(0, QK)).astype(np.int64)
blk(7); w7  = mix(rr.integers(0, 1 << 32, N, dtype=np.uint64), rf.integers(0, 1 << 32, dtype=np.uint64)).astype(np.uint64)
blk(8); v8  = mix(rr.integers(-(1 << 30), 1 << 30, N), rf.integers(-(1 << 30), 1 << 30)).astype(np.int64)
blk(9); f9a = mix(rr.integers(-(QD-1)//2, (QD-1)//2, N), rf.integers(-(QD-1)//2, (QD-1)//2)).astype(np.int64)   # public factor: random vs fixed
f9b = const(rf.choice([-2, -1, 1, 2])).astype(np.int64)     # secret s1, constant and non-zero
p9  = f9a * f9b
assert f9b[0] != 0 and p9[CLS[9] == 1][0] != 0
lo9 = (p9 & 0xFFFFFFFF).astype(np.uint32)
hi9 = ((p9 >> 32) & 0xFFFFFFFF).astype(np.uint32)
blk(10); w10 = mix(rr.integers(0, QD, N),             rf.integers(0, QD)).astype(np.uint64)

def u32(v):
    return (np.asarray(v).astype(np.int64) & 0xFFFFFFFF).astype(np.uint32)

tables32 = [
    ("b1_secret", u32(s)),      ("b1_public", u32(b)),
    ("b2_secret", u32(x)),
    ("b3_secret", u32(w)),      ("b3_public", u32(pw)),
    ("b4_secret", u32(c4)),
    ("b5_a",      u32(a5 & 0xFFFF)),
    ("b5_packed", u32(((z5 & 0xFFFF) << 16) | (b5 & 0xFFFF))),
    ("b6_secret", u32(c6)),
    ("b7_word",   u32(w7)),
    ("b8_secret", u32(v8)),
    ("b9_lo",     u32(lo9)), ("b9_hi", u32(hi9)),
    ("b10_w",     u32(w10)),
]
with open(f"{OUT}/operands10.h", "w") as f:
    f.write("/* generated by gen_operands_tvla10.py, do not edit */\n")
    f.write(f"#define NTRACE {N}\n")
    for nm, v in tables32:
        f.write(f"static const uint32_t {nm}[] = {{" + ",".join(str(int(t)) + "u" for t in v) + "};\n")

gt = {"n": N, "n_fixed": int(cls.sum()), "n_random": int((cls == 0).sum()), "design": "secret constant; public operand random vs fixed (two-operand), operand random vs fixed (single-operand)",
      "class": cls.tolist(),        # 1 = fixed, 0 = random: the order of block 1 (all blocks when not per-block)
      "class_by_block": {str(k): CLS[k].tolist() for k in range(1, 11)},
      "per_block_order": PER_BLOCK,
      "seed_random": 20260913, "seed_fixed": 777, "order": "parity-balanced random interleave, one fixed and one random row per consecutive pair", "seed_order": 31415,
      "b1": {"instr": "MONT_K", "secret": s.tolist(), "public": b.tolist()},
      "b2": {"instr": "BARRETT_K", "secret": x.tolist()},
      "b3": {"instr": "AND_LATCH", "secret": w.tolist(), "public": pw.tolist()},
      "b4": {"instr": "CADDQ", "secret": c4.tolist()},
      "b5": {"instr": "NTT_BFLY_GS_MUL", "a": a5.tolist(), "b": b5.tolist(), "zeta": z5.tolist()},
      "b6": {"instr": "COMPRESS_1", "secret": c6.tolist()},
      "b7": {"instr": "CBD2_1", "secret": w7.tolist()},
      "b8": {"instr": "BARRETT_D", "secret": v8.tolist()},
      "b9": {"instr": "MONT_D_REDUCE64", "factor": f9a.tolist(), "s1": f9b.tolist(),
             "lo": lo9.tolist(), "hi": hi9.tolist()},
      "b10": {"instr": "DECOMPOSE", "secret": w10.tolist()}}
json.dump(gt, open(f"{OUT}/operands_tvla10.json", "w"))
print(f"TVLA operands: N={N}, fixed={cls.sum()}, random={(cls==0).sum()}, "
      f"{sum(len(v)*4 for _, v in tables32)} B of tables")
