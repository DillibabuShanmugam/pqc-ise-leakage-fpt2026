"""Instruction names of the ten blocks and a scalar Welch helper."""
import numpy as np
INSTR = {1: 'MONT_K', 2: 'BARRETT_K', 3: 'AND_LATCH', 4: 'CADDQ', 5: 'NTT_BFLY_GS_MUL',
         6: 'COMPRESS_1', 7: 'CBD2_1', 8: 'BARRETT_D', 9: 'MONT_D_REDUCE64', 10: 'DECOMPOSE'}
NAME = {1: 'mont_k', 2: 'barrett_k', 3: 'and_latch', 4: 'caddq', 5: 'ntt_bfly_gs_mul',
        6: 'compress_1', 7: 'cbd2_1', 8: 'barrett_d', 9: 'mont_d', 10: 'decompose'}
def welch(a, b):
    na, nb = len(a), len(b)
    if na < 3 or nb < 3:
        return 0.0
    va, vb = a.var(ddof=1), b.var(ddof=1)
    den = np.sqrt(va / na + vb / nb)
    return 0.0 if den < 1e-30 else float((a.mean() - b.mean()) / den)
