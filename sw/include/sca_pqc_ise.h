/* ===========================================================================
 * SCA_Pro_PQC -- Inline Assembly Macros for 38 ISE Instructions
 * ===========================================================================
 *
 * Opcode:   Custom-3 = 0x7B (7'b1111011)
 * Encoding: .insn r opcode, funct3, funct7, rd, rs1, rs2
 *
 * Instruction word layout:
 *   [31:25] funct7  [24:20] rs2  [19:15] rs1  [14:12] funct3  [11:7] rd  [6:0] opcode
 *
 * Hardware decode extracts:
 *   funct3          = bits [14:12]   -- group select (8 groups)
 *   funct7_lo[3:0]  = bits [28:25]   -- operation within group
 *   funct7_4        = bit  [29]      -- Q selector (0=ML-KEM/3329, 1=ML-DSA/8380417)
 *
 * For .insn r, funct7 is the full 7-bit value at bits [31:25]:
 *   funct7 = (q_sel << 4) | funct7_lo
 *
 * ---------------------------------------------------------------------------
 * ISA Reference Table
 * ---------------------------------------------------------------------------
 *
 * Grp  funct3  Slot  funct7  Mnemonic         Operands      Description
 * ---  ------  ----  ------  ---------------  ------------  -------------------------
 *  0   0       0     0x00    SET_C            rd, rs1       acc_c <- rs1
 *  0   0       1     0x01    BCOP32_AB        rd, rs1, rs2  rs1 ^ (~rs2 & acc_c)
 *  0   0       2     0x02    SET_HI           rd, rs1       acc_hi <- rs1
 *  0   0       3     0x03    ROL32_L          rd, rs1, rs2  ROL64 low word
 *  0   0       4     0x04    ROL32_H          rd, rs1, rs2  ROL64 high word
 *  0   0       5     0x05    XOR3             rd, rs1, rs2  rs1 ^ rs2 ^ acc_c
 *
 *  1   1       0     0x00    BARRETT_K        rd, rs1       Barrett mod 3329
 *  1   1       1     0x01    MONT_K           rd, rs1, rs2  Montgomery mul Q=3329
 *  1   1       2     0x02    CADDQ            rd, rs1       Conditional add Q
 *  1   1       3     0x03    BARRETT_D        rd, rs1       Barrett mod 8380417
 *  1   1       4     0x04    MONT_D           rd, rs1, rs2  Montgomery mul Q=8380417
 *
 *  2   2       0     0x00    NTT_BFLY_CT      rd, rs1, rs2  Cooley-Tukey butterfly
 *  2   2       1     0x01    NTT_BFLY_GS      rd, rs1, rs2  Gentleman-Sande butterfly
 *
 *  3   3       0-7   0x00-07 CBD2_1..CBD2_8   rd, rs1       CBD eta=2 steps 1-8
 *  3   3       8-11  0x08-0B CBD3_1..CBD3_4   rd, rs1       CBD eta=3 steps 1-4
 *
 *  4   4       0-3   0x00-03 COMPRESS_1..4    rd, rs1       Compress steps 1-4
 *  4   4       4     0x04    REJ_UNIFORM      rd, rs1       Rejection uniform sampling
 *
 *  5   5       0     0x00    POWER2ROUND      rd, rs1, rs2  Power2Round (ML-DSA)
 *  5   5       1     0x01    DECOMPOSE        rd, rs1, rs2  Decompose (ML-DSA)
 *
 *  6   6       0     0x00    SECMUL_STEP_K    rd, rs1, rs2  Secure mul mod 3329 (legacy)
 *  6   6       0     0x10    SECMUL_STEP_D    rd, rs1, rs2  Secure mul mod 8380417 (legacy)
 *  6   6       1     0x01    MASK_REFRESH_B   rd, rs1       Boolean mask refresh
 *  6   6       1     0x11    MASK_REFRESH_A   rd, rs1       Arithmetic mask refresh
 *  6   6       2     0x02    MASKED_AND       rd, rs1, rs2  DOM-AND gate (legacy)
 *  6   6       3     0x03    MASKED_XOR       rd, rs1, rs2  Linear XOR
 *  6   6       4     0x04    SECMUL_LATCH_K   rd, rs1, rs2  (rs1*rs2 + r_new) mod 3329, latch r
 *  6   6       4     0x14    SECMUL_LATCH_D   rd, rs1, rs2  (rs1*rs2 + r_new) mod 8380417
 *  6   6       5     0x05    SECMUL_REUSE_K   rd, rs1, rs2  (rs1*rs2 - r_latched) mod 3329
 *  6   6       5     0x15    SECMUL_REUSE_D   rd, rs1, rs2  (rs1*rs2 - r_latched) mod 8380417
 *  6   6       6     0x06    AND_LATCH        rd, rs1, rs2  (rs1 & rs2) ^ r_new, latch r
 *  6   6       7     0x07    AND_REUSE        rd, rs1, rs2  (rs1 & rs2) ^ r_latched
 *
 *  7   7       0     0x00    SEED_PRNG        rd, rs1, rs2  Seed PRNG (rs2[1:0]=idx)
 *  7   7       1     0x01    GET_RANDOM       rd            Get random word
 *
 * ===========================================================================
 */

#ifndef SCA_PQC_ISE_H
#define SCA_PQC_ISE_H

#include <stdint.h>

/* Custom-3 opcode */
#define SCA_CUSTOM3_OPCODE  0x7B

/* =========================================================================
 * Group 0: Keccak Primitives (funct3 = 0)
 * ========================================================================= */

/* SET_C: acc_c <- rs1; rd = rs1 (echo) */
#define SCA_SET_C(rd, rs1) \
    asm volatile(".insn r 0x7b, 0, 0, %0, %1, x0" \
        : "=r"(rd) : "r"(rs1))

/* BCOP32_AB: rd = rs1 ^ (~rs2 & acc_c) */
#define SCA_BCOP32(rd, rs1, rs2) \
    asm volatile(".insn r 0x7b, 0, 1, %0, %1, %2" \
        : "=r"(rd) : "r"(rs1), "r"(rs2))

/* SET_HI: acc_hi <- rs1; rd = rs1 (echo) */
#define SCA_SET_HI(rd, rs1) \
    asm volatile(".insn r 0x7b, 0, 2, %0, %1, x0" \
        : "=r"(rd) : "r"(rs1))

/* ROL32_L: rd = low word of ROL64({acc_hi, rs1}, rs2[5:0]) */
#define SCA_ROL32_L(rd, rs1, rs2) \
    asm volatile(".insn r 0x7b, 0, 3, %0, %1, %2" \
        : "=r"(rd) : "r"(rs1), "r"(rs2))

/* ROL32_H: rd = high word of ROL64({acc_hi, rs1}, rs2[5:0]) */
#define SCA_ROL32_H(rd, rs1, rs2) \
    asm volatile(".insn r 0x7b, 0, 4, %0, %1, %2" \
        : "=r"(rd) : "r"(rs1), "r"(rs2))

/* XOR3: rd = rs1 ^ rs2 ^ acc_c */
#define SCA_XOR3(rd, rs1, rs2) \
    asm volatile(".insn r 0x7b, 0, 5, %0, %1, %2" \
        : "=r"(rd) : "r"(rs1), "r"(rs2))

/* =========================================================================
 * Group 1: Modular Arithmetic (funct3 = 1)
 * ========================================================================= */

/* BARRETT_K: rd = rs1 mod 3329 (Barrett reduction) */
#define SCA_BARRETT_K(rd, rs1) \
    asm volatile(".insn r 0x7b, 1, 0, %0, %1, x0" \
        : "=r"(rd) : "r"(rs1))

/* MONT_K: rd = Montgomery multiply rs1 * rs2, Q=3329 */
#define SCA_MONT_K(rd, rs1, rs2) \
    asm volatile(".insn r 0x7b, 1, 1, %0, %1, %2" \
        : "=r"(rd) : "r"(rs1), "r"(rs2))

/* CADDQ: rd = rs1 + Q if rs1 < 0, else rs1 */
#define SCA_CADDQ(rd, rs1) \
    asm volatile(".insn r 0x7b, 1, 2, %0, %1, x0" \
        : "=r"(rd) : "r"(rs1))

/* BARRETT_D: rd = rs1 mod 8380417 (Barrett reduction) */
#define SCA_BARRETT_D(rd, rs1) \
    asm volatile(".insn r 0x7b, 1, 3, %0, %1, x0" \
        : "=r"(rd) : "r"(rs1))

/* MONT_D_REDUCE64: Montgomery REDUCTION of a 64-bit value (NOT a multiply).
 *
 * Hardware ABI:  rs1 = low 32 bits,  rs2 = high 32 bits.
 * Computes the Montgomery reduction of {rs2, rs1} modulo Q=8380417 with
 * R = 2^32, NINV = -Q^{-1} mod 2^32 = 4236238847.  Output is in (-Q, Q).
 *
 * Callers that want a Montgomery MULTIPLY should use SCA_MONT_D_MUL below,
 * which does the int64 multiply in software then dispatches to this opcode.
 *
 * The legacy `SCA_MONT_D(rd, a, b)` macro that interpreted (a, b) as factors
 * was removed in TCHES Round-2 -- its silent semantics mismatch (RTL is
 * reduce-only of 64-bit input) caused KAT divergence in early ML-DSA paths.
 */
#define SCA_MONT_D_REDUCE64(rd, rs1_lo32, rs2_hi32) \
    asm volatile(".insn r 0x7b, 1, 4, %0, %1, %2" \
        : "=r"(rd) : "r"(rs1_lo32), "r"(rs2_hi32))

/* SCA_MONT_D_MUL: software multiply + ISE reduce.
 *   rd = (a * b) * R^{-1} mod 8380417, R = 2^32.
 * Equivalent to pq-crystals fqmul.  a, b are signed 32-bit. */
#define SCA_MONT_D_MUL(rd, a, b) do {                                         \
    int64_t _scapd_prod = (int64_t)(a) * (int64_t)(b);                        \
    int32_t _scapd_lo = (int32_t)_scapd_prod;                                 \
    int32_t _scapd_hi = (int32_t)(_scapd_prod >> 32);                         \
    SCA_MONT_D_REDUCE64((rd), _scapd_lo, _scapd_hi);                          \
} while (0)

/* =========================================================================
 * Group 2: NTT Butterfly (funct3 = 2)
 * ========================================================================= */

/* NTT_BFLY_CT: Cooley-Tukey butterfly */
#define SCA_NTT_BFLY_CT(rd, rs1, rs2) \
    asm volatile(".insn r 0x7b, 2, 0, %0, %1, %2" \
        : "=r"(rd) : "r"(rs1), "r"(rs2))

/* NTT_BFLY_GS: Gentleman-Sande butterfly */
#define SCA_NTT_BFLY_GS(rd, rs1, rs2) \
    asm volatile(".insn r 0x7b, 2, 1, %0, %1, %2" \
        : "=r"(rd) : "r"(rs1), "r"(rs2))

/* NTT_BFLY_CT_MUL: forward CT butterfly with twiddle Mont-mul folded in.
 * rs1 = a (low 16 bits, signed)
 * rs2 = packed { zeta[15:0], b[15:0] }   (high half = zeta, low half = b)
 * rd  = packed { (a-t)[15:0], (a+t)[15:0] }  with t = mont(b*zeta)
 */
#define SCA_NTT_BFLY_CT_MUL(rd, a, packed_zb) \
    asm volatile(".insn r 0x7b, 2, 2, %0, %1, %2" \
        : "=r"(rd) : "r"(a), "r"(packed_zb))

/* NTT_BFLY_GS_MUL: inverse GS butterfly with twiddle Mont-mul folded in.
 * Same operand layout as CT_MUL.
 * rd = packed { mont((a-b)*zeta)[15:0], (a+b)[15:0] }
 */
#define SCA_NTT_BFLY_GS_MUL(rd, a, packed_zb) \
    asm volatile(".insn r 0x7b, 2, 3, %0, %1, %2" \
        : "=r"(rd) : "r"(a), "r"(packed_zb))

/* =========================================================================
 * Group 3: CBD Sampling (funct3 = 3)
 * ========================================================================= */

/* CBD eta=2: 8 pipeline steps */
#define SCA_CBD2_1(rd, rs1) \
    asm volatile(".insn r 0x7b, 3, 0, %0, %1, x0" : "=r"(rd) : "r"(rs1))

#define SCA_CBD2_2(rd, rs1) \
    asm volatile(".insn r 0x7b, 3, 1, %0, %1, x0" : "=r"(rd) : "r"(rs1))

#define SCA_CBD2_3(rd, rs1) \
    asm volatile(".insn r 0x7b, 3, 2, %0, %1, x0" : "=r"(rd) : "r"(rs1))

#define SCA_CBD2_4(rd, rs1) \
    asm volatile(".insn r 0x7b, 3, 3, %0, %1, x0" : "=r"(rd) : "r"(rs1))

#define SCA_CBD2_5(rd, rs1) \
    asm volatile(".insn r 0x7b, 3, 4, %0, %1, x0" : "=r"(rd) : "r"(rs1))

#define SCA_CBD2_6(rd, rs1) \
    asm volatile(".insn r 0x7b, 3, 5, %0, %1, x0" : "=r"(rd) : "r"(rs1))

#define SCA_CBD2_7(rd, rs1) \
    asm volatile(".insn r 0x7b, 3, 6, %0, %1, x0" : "=r"(rd) : "r"(rs1))

#define SCA_CBD2_8(rd, rs1) \
    asm volatile(".insn r 0x7b, 3, 7, %0, %1, x0" : "=r"(rd) : "r"(rs1))

/* CBD eta=3: 4 pipeline steps */
#define SCA_CBD3_1(rd, rs1) \
    asm volatile(".insn r 0x7b, 3, 8, %0, %1, x0" : "=r"(rd) : "r"(rs1))

#define SCA_CBD3_2(rd, rs1) \
    asm volatile(".insn r 0x7b, 3, 9, %0, %1, x0" : "=r"(rd) : "r"(rs1))

#define SCA_CBD3_3(rd, rs1) \
    asm volatile(".insn r 0x7b, 3, 10, %0, %1, x0" : "=r"(rd) : "r"(rs1))

#define SCA_CBD3_4(rd, rs1) \
    asm volatile(".insn r 0x7b, 3, 11, %0, %1, x0" : "=r"(rd) : "r"(rs1))

/* =========================================================================
 * Group 4: Compress + Sampling (funct3 = 4)
 * ========================================================================= */

#define SCA_COMPRESS_1(rd, rs1) \
    asm volatile(".insn r 0x7b, 4, 0, %0, %1, x0" : "=r"(rd) : "r"(rs1))

#define SCA_COMPRESS_2(rd, rs1) \
    asm volatile(".insn r 0x7b, 4, 1, %0, %1, x0" : "=r"(rd) : "r"(rs1))

#define SCA_COMPRESS_3(rd, rs1) \
    asm volatile(".insn r 0x7b, 4, 2, %0, %1, x0" : "=r"(rd) : "r"(rs1))

#define SCA_COMPRESS_4(rd, rs1) \
    asm volatile(".insn r 0x7b, 4, 3, %0, %1, x0" : "=r"(rd) : "r"(rs1))

/* REJ_UNIFORM: Rejection uniform sampling */
#define SCA_REJ_UNIFORM(rd, rs1) \
    asm volatile(".insn r 0x7b, 4, 4, %0, %1, x0" : "=r"(rd) : "r"(rs1))

/* COMPRESS_5: d=11 (ML-KEM-1024 du). rd = round(rs1 * 2^11 / 3329) & 0x7FF */
#define SCA_COMPRESS_5(rd, rs1) \
    asm volatile(".insn r 0x7b, 4, 5, %0, %1, x0" : "=r"(rd) : "r"(rs1))

/* =========================================================================
 * Group 5: ML-DSA Operations (funct3 = 5)
 * ========================================================================= */

/* POWER2ROUND: Power2Round decomposition */
#define SCA_POWER2ROUND(rd, rs1, rs2) \
    asm volatile(".insn r 0x7b, 5, 0, %0, %1, %2" \
        : "=r"(rd) : "r"(rs1), "r"(rs2))

/* DECOMPOSE: HighBits/LowBits decomposition */
#define SCA_DECOMPOSE(rd, rs1, rs2) \
    asm volatile(".insn r 0x7b, 5, 1, %0, %1, %2" \
        : "=r"(rd) : "r"(rs1), "r"(rs2))

/* =========================================================================
 * Group 6: Masking Primitives (funct3 = 6)
 *
 * funct7[4] (bit 29) = Q selector: 0 = Q=3329 (ML-KEM), 1 = Q=8380417 (ML-DSA)
 * For MASK_REFRESH: 0 = boolean, 1 = arithmetic
 * ========================================================================= */

/* SECMUL_STEP: (rs1 * rs2 + PRNG) mod Q */
/* Q=3329 (ML-KEM): funct7 = (0 << 4) | 0 = 0 */
#define SCA_SECMUL_STEP_K(rd, rs1, rs2) \
    asm volatile(".insn r 0x7b, 6, 0, %0, %1, %2" \
        : "=r"(rd) : "r"(rs1), "r"(rs2))

/* Q=8380417 (ML-DSA): funct7 = (1 << 4) | 0 = 16 */
#define SCA_SECMUL_STEP_D(rd, rs1, rs2) \
    asm volatile(".insn r 0x7b, 6, 16, %0, %1, %2" \
        : "=r"(rd) : "r"(rs1), "r"(rs2))

/* MASK_REFRESH: Re-randomize share */
/* Boolean refresh: funct7 = (0 << 4) | 1 = 1 */
#define SCA_MASK_REFRESH_B(rd, rs1) \
    asm volatile(".insn r 0x7b, 6, 1, %0, %1, x0" \
        : "=r"(rd) : "r"(rs1))

/* Arithmetic refresh: funct7 = (1 << 4) | 1 = 17 */
#define SCA_MASK_REFRESH_A(rd, rs1) \
    asm volatile(".insn r 0x7b, 6, 17, %0, %1, x0" \
        : "=r"(rd) : "r"(rs1))

/* MASKED_AND: DOM-AND gate */
#define SCA_MASKED_AND(rd, rs1, rs2) \
    asm volatile(".insn r 0x7b, 6, 2, %0, %1, %2" \
        : "=r"(rd) : "r"(rs1), "r"(rs2))

/* MASKED_XOR: Linear XOR of masked shares */
#define SCA_MASKED_XOR(rd, rs1, rs2) \
    asm volatile(".insn r 0x7b, 6, 3, %0, %1, %2" \
        : "=r"(rd) : "r"(rs1), "r"(rs2))

/* =========================================================================
 * Paired DOM gadgets (Gross-Mangard "+r/-r" cancellation).
 *
 * Use as a back-to-back pair within a single masked-multiply or DOM-AND.
 * Bare-metal firmware MUST disable interrupts around the pair to guarantee
 * no other PRNG-consuming op clobbers r_latched between LATCH and REUSE.
 *
 *   SECMUL_LATCH_K(rd, rs1, rs2): rd = (rs1*rs2 + r_new) mod 3329; latch r_new
 *   SECMUL_REUSE_K(rd, rs1, rs2): rd = (rs1*rs2 - r_latched) mod 3329
 *   SECMUL_LATCH_D(rd, rs1, rs2): rd = (rs1*rs2 + r_new) mod 8380417
 *   SECMUL_REUSE_D(rd, rs1, rs2): rd = (rs1*rs2 - r_latched) mod 8380417
 *   AND_LATCH      (rd, rs1, rs2): rd = (rs1 & rs2) ^ r_new; latch r_new
 *   AND_REUSE      (rd, rs1, rs2): rd = (rs1 & rs2) ^ r_latched
 * ========================================================================= */

/* SECMUL_LATCH_K: funct7 = (0 << 4) | 4 = 4 */
#define SCA_SECMUL_LATCH_K(rd, rs1, rs2) \
    asm volatile(".insn r 0x7b, 6, 4, %0, %1, %2" \
        : "=r"(rd) : "r"(rs1), "r"(rs2))

/* SECMUL_LATCH_D: funct7 = (1 << 4) | 4 = 20 */
#define SCA_SECMUL_LATCH_D(rd, rs1, rs2) \
    asm volatile(".insn r 0x7b, 6, 20, %0, %1, %2" \
        : "=r"(rd) : "r"(rs1), "r"(rs2))

/* SECMUL_REUSE_K: funct7 = (0 << 4) | 5 = 5 */
#define SCA_SECMUL_REUSE_K(rd, rs1, rs2) \
    asm volatile(".insn r 0x7b, 6, 5, %0, %1, %2" \
        : "=r"(rd) : "r"(rs1), "r"(rs2))

/* SECMUL_REUSE_D: funct7 = (1 << 4) | 5 = 21 */
#define SCA_SECMUL_REUSE_D(rd, rs1, rs2) \
    asm volatile(".insn r 0x7b, 6, 21, %0, %1, %2" \
        : "=r"(rd) : "r"(rs1), "r"(rs2))

/* AND_LATCH: funct7 = 6 */
#define SCA_AND_LATCH(rd, rs1, rs2) \
    asm volatile(".insn r 0x7b, 6, 6, %0, %1, %2" \
        : "=r"(rd) : "r"(rs1), "r"(rs2))

/* AND_REUSE: funct7 = 7 */
#define SCA_AND_REUSE(rd, rs1, rs2) \
    asm volatile(".insn r 0x7b, 6, 7, %0, %1, %2" \
        : "=r"(rd) : "r"(rs1), "r"(rs2))

/* Stateful masked-chi unit: z = DOM(~X & Y) computed inside the coprocessor
 * (cross-terms never co-locate in CPU registers).  funct7 = 8/9/10. */
#define SCA_CHI_LOADX(x0, x1) \
    do { uint32_t _cd; asm volatile(".insn r 0x7b, 6, 8, %0, %1, %2" \
        : "=r"(_cd) : "r"(x0), "r"(x1)); (void)_cd; } while (0)
#define SCA_CHI_AND(z0, y0, y1) \
    asm volatile(".insn r 0x7b, 6, 9, %0, %1, %2" : "=r"(z0) : "r"(y0), "r"(y1))
#define SCA_CHI_RDZ1(z1) \
    asm volatile(".insn r 0x7b, 6, 10, %0, x0, x0" : "=r"(z1))
/* Registered (2-cycle, glitch-resistant) DOM chi: ANDR latches the 4 partial
 * products (register barrier); RDZ0R/RDZ1R read the recombination of the
 * stable flops -> AND-tree glitches cannot cross share domains. */
#define SCA_CHI_ANDR(y0, y1) \
    do { uint32_t _cd; asm volatile(".insn r 0x7b, 6, 11, %0, %1, %2" \
        : "=r"(_cd) : "r"(y0), "r"(y1)); (void)_cd; } while (0)
#define SCA_CHI_RDZ0R(z0) \
    asm volatile(".insn r 0x7b, 6, 12, %0, x0, x0" : "=r"(z0))
#define SCA_CHI_RDZ1R(z1) \
    asm volatile(".insn r 0x7b, 6, 13, %0, x0, x0" : "=r"(z1))

/* =========================================================================
 * Atomicity-region macros for paired DOM gadgets.
 *
 * The hardware r_latched register is now guarded by a r_latched_valid bit:
 * any *_REUSE op that fires while the bit is low takes a coprocessor trap.
 * Even with that hardware enforcement, software must avoid PRNG-consuming
 * ops between LATCH and REUSE within a single dom_mul gadget, since GET_RANDOM,
 * MASK_REFRESH, MASKED_AND or legacy SECMUL_STEP would invalidate the latch
 * and convert a correctness path into a trap path.
 *
 * SCA_DOM_REGION_BEGIN() disables M-mode interrupts (mstatus.MIE bit 3)
 * SCA_DOM_REGION_END()   re-enables M-mode interrupts.
 *
 * On host (-DSCA_HOST_SIM) these are no-ops because there is no ISR; the
 * sequential C call order already guarantees atomicity.
 * ========================================================================= */
#define SCA_DOM_REGION_BEGIN() \
    asm volatile("csrrci x0, mstatus, 8" ::: "memory")
#define SCA_DOM_REGION_END() \
    asm volatile("csrrsi x0, mstatus, 8" ::: "memory")

/* =========================================================================
 * Group 7: PRNG Control (funct3 = 7)
 * ========================================================================= */

/* SEED_PRNG: Seed PRNG word; rs1 = seed data, rs2[1:0] = word index */
#define SCA_SEED_PRNG(rd, rs1, rs2) \
    asm volatile(".insn r 0x7b, 7, 0, %0, %1, %2" \
        : "=r"(rd) : "r"(rs1), "r"(rs2))

/* GET_RANDOM: Get 32-bit random word from PRNG */
#define SCA_GET_RANDOM(rd) \
    asm volatile(".insn r 0x7b, 7, 1, %0, x0, x0" \
        : "=r"(rd))

/* =========================================================================
 * State-resident Keccak-f[1600] (xc7a100t retarget) — Group 0, funct7 6..12.
 * Two in-coprocessor share banks (50 x 32-bit words each).  PERM is multi-cycle;
 * the CV-X-IF FSM stalls the pipeline until the permutation completes, so these
 * intrinsics block until done — no software polling required.
 *
 *   Plain path : LDW (load word) ; PERM ; RDW (read word).  mask_en forced 0.
 *   Masked path: MKSEED (seed+mask_en) ; MKLDW(share) ; MKPERM ; MKRDW(share).
 *                The two Boolean shares of the state never co-locate on the bus.
 * ========================================================================= */

/* Plain: kstate0[rs2[5:0]] <- rs1 ; kstate1 <- 0 */
#define SCA_KECCAK_LDW(rd, word, idx) \
    asm volatile(".insn r 0x7b, 0, 6, %0, %1, %2" : "=r"(rd) : "r"(word), "r"(idx))
/* Plain: run keccak_f over the bank (mask_en = 0); rd = 0 ack (blocks ~700 cyc) */
#define SCA_KECCAK_PERM(rd) \
    asm volatile(".insn r 0x7b, 0, 7, %0, x0, x0" : "=r"(rd))
/* Plain: rd <- kstate0[rs1[5:0]] */
#define SCA_KECCAK_RDW(rd, idx) \
    asm volatile(".insn r 0x7b, 0, 8, %0, %1, x0" : "=r"(rd) : "r"(idx))

/* Masked: seed PRNG (rs1) and set mask_en (rs2[0]) */
#define SCA_MKECCAK_SEED(rd, seed, mask_en) \
    asm volatile(".insn r 0x7b, 0, 9, %0, %1, %2" : "=r"(rd) : "r"(seed), "r"(mask_en))
/* Masked: kstate0[idx] <- word  (funct7_4 = 0 selects share 0) */
#define SCA_MKECCAK_LDW0(rd, word, idx) \
    asm volatile(".insn r 0x7b, 0, 10, %0, %1, %2" : "=r"(rd) : "r"(word), "r"(idx))
/* Masked: kstate1[idx] <- word  (funct7_4 = 1 -> funct7 = 16|10 = 26) */
#define SCA_MKECCAK_LDW1(rd, word, idx) \
    asm volatile(".insn r 0x7b, 0, 26, %0, %1, %2" : "=r"(rd) : "r"(word), "r"(idx))
/* Masked: run DOM-masked keccak_f over both share banks (blocks ~700 cyc) */
#define SCA_MKECCAK_PERM(rd) \
    asm volatile(".insn r 0x7b, 0, 11, %0, x0, x0" : "=r"(rd))
/* Masked: rd <- kstate0[idx] (share 0) / kstate1[idx] (share 1, funct7=28) */
#define SCA_MKECCAK_RDW0(rd, idx) \
    asm volatile(".insn r 0x7b, 0, 12, %0, %1, x0" : "=r"(rd) : "r"(idx))
#define SCA_MKECCAK_RDW1(rd, idx) \
    asm volatile(".insn r 0x7b, 0, 28, %0, %1, x0" : "=r"(rd) : "r"(idx))

/* =========================================================================
 * A2B / B2A mask conversion (X2X) — Group 6, funct7_lo 14/15, funct7[5]=dir.
 *   funct7 = (dir<<5) | (wide<<4) | funct7_lo
 *   dir : 0 = A2B (arith->bool), 1 = B2A (bool->arith)
 *   wide: 0 = ML-KEM (q=3329, 13b), 1 = ML-DSA (q=8380417, 24b)
 * CONV is multi-cycle (blocks ~25 cyc) and returns output share 0 in rd; the
 * paired RD1 returns the latched output share 1.
 * ========================================================================= */
/* A2B: rs1=x0 (arith), rs2=x1 (arith) -> rd=y0 (bool) ; then RD1 -> y1 */
#define SCA_A2B_CONV_K(rd, x0, x1) \
    asm volatile(".insn r 0x7b, 6, 14, %0, %1, %2" : "=r"(rd) : "r"(x0), "r"(x1))
#define SCA_A2B_CONV_D(rd, x0, x1) \
    asm volatile(".insn r 0x7b, 6, 30, %0, %1, %2" : "=r"(rd) : "r"(x0), "r"(x1))
#define SCA_A2B_RD1(rd) \
    asm volatile(".insn r 0x7b, 6, 15, %0, x0, x0" : "=r"(rd))
/* B2A: rs1=y0 (bool), rs2=y1 (bool) -> rd=x0 (arith) ; then RD1 -> x1 */
#define SCA_B2A_CONV_K(rd, y0, y1) \
    asm volatile(".insn r 0x7b, 6, 46, %0, %1, %2" : "=r"(rd) : "r"(y0), "r"(y1))
#define SCA_B2A_CONV_D(rd, y0, y1) \
    asm volatile(".insn r 0x7b, 6, 62, %0, %1, %2" : "=r"(rd) : "r"(y0), "r"(y1))
#define SCA_B2A_RD1(rd) \
    asm volatile(".insn r 0x7b, 6, 47, %0, x0, x0" : "=r"(rd))

/* ---- conversion driver helpers (ML-KEM q=3329) ---- */
/* arithmetic shares (a0,a1) -> boolean shares (*y0,*y1), a0+a1 == *y0^*y1 mod q */
static inline void sca_a2b_kem(uint32_t a0, uint32_t a1, uint32_t *y0, uint32_t *y1)
{
    uint32_t r0, r1; SCA_A2B_CONV_K(r0, a0, a1); SCA_A2B_RD1(r1); *y0 = r0; *y1 = r1;
}
/* boolean shares (b0,b1) -> arithmetic shares (*x0,*x1), (*x0+*x1)%q == b0^b1 */
static inline void sca_b2a_kem(uint32_t b0, uint32_t b1, uint32_t *x0, uint32_t *x1)
{
    uint32_t r0, r1; SCA_B2A_CONV_K(r0, b0, b1); SCA_B2A_RD1(r1); *x0 = r0; *x1 = r1;
}

/* ---- Keccak permutation drivers ---- */
/* Plain Keccak-f[1600] on a 50-word state in place. */
static inline void sca_keccakf1600(uint32_t state[50])
{
    uint32_t ack;
    for (int i = 0; i < 50; i++) SCA_KECCAK_LDW(ack, state[i], (uint32_t)i);
    SCA_KECCAK_PERM(ack); (void)ack;
    for (int i = 0; i < 50; i++) SCA_KECCAK_RDW(state[i], (uint32_t)i);
}
/* DOM-masked Keccak-f[1600] on two Boolean-shared 50-word states in place.
 * The plaintext state never appears: only s0 and s1 (s = s0 ^ s1) are loaded,
 * permuted under fresh per-chi randomness, and read back as shares. */
static inline void sca_keccakf1600_masked(uint32_t s0[50], uint32_t s1[50], uint32_t seed)
{
    uint32_t ack;
    SCA_MKECCAK_SEED(ack, seed, 1u);
    for (int i = 0; i < 50; i++) SCA_MKECCAK_LDW0(ack, s0[i], (uint32_t)i);
    for (int i = 0; i < 50; i++) SCA_MKECCAK_LDW1(ack, s1[i], (uint32_t)i);
    SCA_MKECCAK_PERM(ack); (void)ack;
    for (int i = 0; i < 50; i++) SCA_MKECCAK_RDW0(s0[i], (uint32_t)i);
    for (int i = 0; i < 50; i++) SCA_MKECCAK_RDW1(s1[i], (uint32_t)i);
}
/* SHA3-256/512, SHAKE-128/256 and the ML-KEM/ML-DSA XOFs are the standard
 * FIPS-202 sponge (rate + pad10*1 + domain byte) wrapped around the two drivers
 * above: drive sca_keccakf1600() for public-input absorb/squeeze, and
 * sca_keccakf1600_masked() for blocks that carry secret-shared state.  The
 * sponge bookkeeping lives in fips202.c; only the permutation is in hardware. */

/* =========================================================================
 * Convenience: Keccak round helpers
 * ========================================================================= */

/* Execute chi step: rd = a ^ (~b & c) using SET_C + BCOP32 */
static inline uint32_t sca_chi_step(uint32_t a, uint32_t b, uint32_t c)
{
    uint32_t tmp, result;
    SCA_SET_C(tmp, c);
    SCA_BCOP32(result, a, b);
    return result;
}

/* Execute XOR3: rd = a ^ b ^ c using SET_C + XOR3 */
static inline uint32_t sca_xor3(uint32_t a, uint32_t b, uint32_t c)
{
    uint32_t tmp, result;
    SCA_SET_C(tmp, c);
    SCA_XOR3(result, a, b);
    return result;
}

/* Execute 64-bit rotate left using SET_HI + ROL32_L + ROL32_H */
static inline void sca_rol64(uint32_t hi_in, uint32_t lo_in, uint32_t rot,
                             uint32_t *hi_out, uint32_t *lo_out)
{
    uint32_t tmp;
    SCA_SET_HI(tmp, hi_in);
    SCA_ROL32_L(*lo_out, lo_in, rot);
    SCA_ROL32_H(*hi_out, lo_in, rot);
}

/* =========================================================================
 * Host simulation override (build with -DSCA_HOST_SIM)
 *
 * Replaces the RV32 inline-asm bodies above with pure-C functions that
 * reproduce the RTL semantics bit-for-bit, so masked code can KAT-test
 * on the development host without flashing CW305 each iteration.  The
 * NTT-butterfly / CBD / Compress / REJ / P2Round / Decompose / Keccak
 * macros are deliberately NOT host-overridden -- the host KAT path
 * uses the pq-crystals reference helpers for those, and only the
 * mask-related primitives must match RTL.
 * ========================================================================= */
#ifdef SCA_HOST_SIM
#include "sca_pqc_ise_host.h"

#undef  SCA_GET_RANDOM
#define SCA_GET_RANDOM(rd)            ((rd) = sca_host_get_random())

#undef  SCA_BARRETT_K
#define SCA_BARRETT_K(rd, rs1)        ((rd) = sca_host_barrett_k((int32_t)(rs1)))
#undef  SCA_MONT_K
#define SCA_MONT_K(rd, rs1, rs2)      ((rd) = sca_host_mont_k((int32_t)(rs1), (int32_t)(rs2)))
#undef  SCA_CADDQ
#define SCA_CADDQ(rd, rs1)            ((rd) = sca_host_caddq((int32_t)(rs1)))
#undef  SCA_BARRETT_D
#define SCA_BARRETT_D(rd, rs1)        ((rd) = sca_host_barrett_d((int32_t)(rs1)))
#undef  SCA_MONT_D_REDUCE64
#define SCA_MONT_D_REDUCE64(rd, rs1, rs2)  ((rd) = sca_host_mont_d((int32_t)(rs1), (int32_t)(rs2)))
/* SCA_MONT_D_MUL is a do-while macro defined above; it expands to two int32 ops
 * plus a SCA_MONT_D_REDUCE64.  Nothing to override here for host mode. */

#undef  SCA_SECMUL_STEP_K
#define SCA_SECMUL_STEP_K(rd, a, b)   ((rd) = sca_host_secmul_step_k((int32_t)(a), (int32_t)(b)))
#undef  SCA_SECMUL_STEP_D
#define SCA_SECMUL_STEP_D(rd, a, b)   ((rd) = sca_host_secmul_step_d((int32_t)(a), (int32_t)(b)))

#undef  SCA_SECMUL_LATCH_K
#define SCA_SECMUL_LATCH_K(rd, a, b)  ((rd) = sca_host_secmul_latch_k((int32_t)(a), (int32_t)(b)))
#undef  SCA_SECMUL_REUSE_K
#define SCA_SECMUL_REUSE_K(rd, a, b)  ((rd) = sca_host_secmul_reuse_k((int32_t)(a), (int32_t)(b)))
#undef  SCA_SECMUL_LATCH_D
#define SCA_SECMUL_LATCH_D(rd, a, b)  ((rd) = sca_host_secmul_latch_d((int32_t)(a), (int32_t)(b)))
#undef  SCA_SECMUL_REUSE_D
#define SCA_SECMUL_REUSE_D(rd, a, b)  ((rd) = sca_host_secmul_reuse_d((int32_t)(a), (int32_t)(b)))

#undef  SCA_AND_LATCH
#define SCA_AND_LATCH(rd, a, b)       ((rd) = sca_host_and_latch((uint32_t)(a), (uint32_t)(b)))
#undef  SCA_AND_REUSE
#define SCA_AND_REUSE(rd, a, b)       ((rd) = sca_host_and_reuse((uint32_t)(a), (uint32_t)(b)))
#undef  SCA_MASKED_AND
#define SCA_MASKED_AND(rd, a, b)      ((rd) = sca_host_masked_and((uint32_t)(a), (uint32_t)(b)))
#undef  SCA_MASKED_XOR
#define SCA_MASKED_XOR(rd, a, b)      ((rd) = ((uint32_t)(a) ^ (uint32_t)(b)))

/* Stateful masked-chi unit, host emulation. */
uint32_t sca_host_chi_loadx(uint32_t x0, uint32_t x1);
uint32_t sca_host_chi_and(uint32_t y0, uint32_t y1);
uint32_t sca_host_chi_rdz1(void);
#define SCA_CHI_LOADX(x0, x1)  ((void)sca_host_chi_loadx((uint32_t)(x0), (uint32_t)(x1)))
#define SCA_CHI_AND(z0, y0, y1) ((z0) = sca_host_chi_and((uint32_t)(y0), (uint32_t)(y1)))
#define SCA_CHI_RDZ1(z1)        ((z1) = sca_host_chi_rdz1())
uint32_t sca_host_chi_andr(uint32_t y0, uint32_t y1);
uint32_t sca_host_chi_rdz0r(void);
uint32_t sca_host_chi_rdz1r(void);
#define SCA_CHI_ANDR(y0, y1)   ((void)sca_host_chi_andr((uint32_t)(y0), (uint32_t)(y1)))
#define SCA_CHI_RDZ0R(z0)      ((z0) = sca_host_chi_rdz0r())
#define SCA_CHI_RDZ1R(z1)      ((z1) = sca_host_chi_rdz1r())

/* SEED_PRNG on host: rs1 = seed word, rs2 ignored */
#undef  SCA_SEED_PRNG
#define SCA_SEED_PRNG(rd, rs1, rs2)   do { sca_host_seed_prng((uint32_t)(rs1)); (rd) = (rs1); } while (0)

/* DOM-region atomicity macros are no-ops on host (no ISR can preempt). */
#undef  SCA_DOM_REGION_BEGIN
#define SCA_DOM_REGION_BEGIN() ((void)0)
#undef  SCA_DOM_REGION_END
#define SCA_DOM_REGION_END()   ((void)0)

/* -------- CBD eta=2 / eta=3 host helpers (functional reference only) ----
 * Pure-C versions of the 8 CBD2 and 4 CBD3 pipeline steps.  Each call
 * extracts one coefficient from the input 32-bit / 24-bit word in
 * the same lane order as the RTL ise_cbd module.
 * ----------------------------------------------------------------------- */
static inline int32_t _sca_host_cbd2_step(uint32_t w, int slot)
{
    /* Each coefficient consumes 4 bits: 2 bits "a" + 2 bits "b" at offset 4*slot. */
    int a = (int)((w >> (4 * slot     )) & 0x3u);
    int b = (int)((w >> (4 * slot + 2)) & 0x3u);
    int popa = (a & 1) + ((a >> 1) & 1);
    int popb = (b & 1) + ((b >> 1) & 1);
    return (int32_t)(popa - popb);
}

static inline int32_t _sca_host_cbd3_step(uint32_t w, int slot)
{
    int a = (int)((w >> (6 * slot     )) & 0x7u);
    int b = (int)((w >> (6 * slot + 3)) & 0x7u);
    int popa = (a & 1) + ((a >> 1) & 1) + ((a >> 2) & 1);
    int popb = (b & 1) + ((b >> 1) & 1) + ((b >> 2) & 1);
    return (int32_t)(popa - popb);
}

#undef SCA_CBD2_1
#undef SCA_CBD2_2
#undef SCA_CBD2_3
#undef SCA_CBD2_4
#undef SCA_CBD2_5
#undef SCA_CBD2_6
#undef SCA_CBD2_7
#undef SCA_CBD2_8
#define SCA_CBD2_1(rd, w) ((rd) = _sca_host_cbd2_step((uint32_t)(w), 0))
#define SCA_CBD2_2(rd, w) ((rd) = _sca_host_cbd2_step((uint32_t)(w), 1))
#define SCA_CBD2_3(rd, w) ((rd) = _sca_host_cbd2_step((uint32_t)(w), 2))
#define SCA_CBD2_4(rd, w) ((rd) = _sca_host_cbd2_step((uint32_t)(w), 3))
#define SCA_CBD2_5(rd, w) ((rd) = _sca_host_cbd2_step((uint32_t)(w), 4))
#define SCA_CBD2_6(rd, w) ((rd) = _sca_host_cbd2_step((uint32_t)(w), 5))
#define SCA_CBD2_7(rd, w) ((rd) = _sca_host_cbd2_step((uint32_t)(w), 6))
#define SCA_CBD2_8(rd, w) ((rd) = _sca_host_cbd2_step((uint32_t)(w), 7))

#undef SCA_CBD3_1
#undef SCA_CBD3_2
#undef SCA_CBD3_3
#undef SCA_CBD3_4
#define SCA_CBD3_1(rd, w) ((rd) = _sca_host_cbd3_step((uint32_t)(w), 0))
#define SCA_CBD3_2(rd, w) ((rd) = _sca_host_cbd3_step((uint32_t)(w), 1))
#define SCA_CBD3_3(rd, w) ((rd) = _sca_host_cbd3_step((uint32_t)(w), 2))
#define SCA_CBD3_4(rd, w) ((rd) = _sca_host_cbd3_step((uint32_t)(w), 3))

/* COMPRESS host helpers: just pass-through identity with a TODO marker.
 * The DOM tests never exercise compression, but masked_poly_compress_d in
 * mlkem_masked.c references SCA_COMPRESS_1 -- give it a minimal stub so the
 * file still links if compiled.  Real compression is bench/RTL only. */
#undef  SCA_COMPRESS_1
#define SCA_COMPRESS_1(rd, rs1)       ((rd) = (int32_t)((((int32_t)(rs1) & 0xFFFF) + 1665) / 3329 & 1))
#undef  SCA_COMPRESS_2
#define SCA_COMPRESS_2(rd, rs1)       ((rd) = (int32_t)(rs1))
#undef  SCA_COMPRESS_3
#define SCA_COMPRESS_3(rd, rs1)       ((rd) = (int32_t)(rs1))
#undef  SCA_COMPRESS_4
#define SCA_COMPRESS_4(rd, rs1)       ((rd) = (int32_t)(rs1))
#undef  SCA_COMPRESS_5
#define SCA_COMPRESS_5(rd, rs1)       ((rd) = (int32_t)(rs1))

#endif /* SCA_HOST_SIM */

#endif /* SCA_PQC_ISE_H */
