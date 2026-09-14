// ============================================================================
// SCA_Pro_PQC — SCA-Resilient PQC Accelerator for ML-KEM + ML-DSA
// ============================================================================
//
// File        : sca_pqc_pkg.sv
// Description : Main package file defining 38 ISE instructions for the
//               SCA_Pro_PQC coprocessor. Uses RISC-V Custom-3 opcode
//               (0x7B = 7'b1111011).
//
// Encoding:
//   opcode       = 7'b1111011  (Custom-3, bits [6:0])
//   funct3       = bits [14:12] — group selection (8 groups)
//   funct7[3:0]  = bits [28:25] — operation within group
//
// ============================================================================
// ISA Summary Table
// ============================================================================
//
// Grp  funct3  Slot  Opcode  Mnemonic         Description
// ---  ------  ----  ------  ---------------  --------------------------------
//  0   3'b000   0    6'd0    OP_SET_C         acc_c <- rs1
//  0   3'b000   1    6'd1    OP_BCOP32_AB     rs1 ^ (~rs2 & acc_c)
//  0   3'b000   2    6'd2    OP_SET_HI        acc_hi <- rs1
//  0   3'b000   3    6'd3    OP_ROL32_L       ROL64 low
//  0   3'b000   4    6'd4    OP_ROL32_H       ROL64 high
//  0   3'b000   5    6'd5    OP_XOR3          rs1 ^ rs2 ^ acc_c
//  0   3'b000   6    6'd51   OP_KECCAK_LDW    kstate[rs2[5:0]] <- rs1
//  0   3'b000   7    6'd52   OP_KECCAK_PERM   keccak_f over kstate (~26 cyc stall)
//  0   3'b000   8    6'd53   OP_KECCAK_RDW    rd <- kstate[rs1[5:0]]
//  0   3'b000   9    6'd54   OP_KECCAK_M_SEED mset: seed<-rs1, mask_en<-rs2[0]
//  0   3'b000  10    6'd55   OP_KECCAK_M_LDW  mstate_plain[rs2[5:0]] <- rs1
//  0   3'b000  11    6'd56   OP_KECCAK_M_PERM HW-split + masked keccak_f (~49 cyc)
//  0   3'b000  12    6'd57   OP_KECCAK_M_RDW  rd <- (Dout0^Dout1)[rs1[5:0]]
//
//  1   3'b001   0    6'd6    OP_BARRETT_K     mod 3329
//  1   3'b001   1    6'd7    OP_MONT_K        Montgomery Q=3329
//  1   3'b001   2    6'd8    OP_CADDQ         conditional add Q
//  1   3'b001   3    6'd9    OP_BARRETT_D     mod 8380417
//  1   3'b001   4    6'd10   OP_MONT_D        Montgomery Q=8380417
//
//  2   3'b010   0    6'd11   OP_NTT_BFLY_CT   Cooley-Tukey butterfly
//  2   3'b010   1    6'd12   OP_NTT_BFLY_GS   Gentleman-Sande butterfly
//
//  3   3'b011   0-7  6'd13-20 OP_CBD2_1..8    CBD sampling eta=2
//  3   3'b011   8-11 6'd21-24 OP_CBD3_1..4    CBD sampling eta=3
//
//  4   3'b100   0-3  6'd25-28 OP_COMPRESS_1..4 Compress
//  4   3'b100   4    6'd29   OP_REJ_UNIFORM   Rejection sampling
//
//  5   3'b101   0    6'd30   OP_POWER2ROUND   Power2Round
//  5   3'b101   1    6'd31   OP_DECOMPOSE     Decompose
//
//  6   3'b110   0    6'd32   OP_SECMUL_STEP   (rs1*rs2+PRNG) mod q
//  6   3'b110   1    6'd33   OP_MASK_REFRESH  re-randomize share
//  6   3'b110   2    6'd34   OP_MASKED_AND    AND_BLIND: (rs1&rs2)^PRNG
//  6   3'b110   3    6'd35   OP_MASKED_XOR    linear XOR
//
//  7   3'b111   0    6'd36   OP_SEED_PRNG     Seed PRNG
//  7   3'b111   1    6'd37   OP_GET_RANDOM    Get random word
//
//  —   —        —    6'd63   OP_INVALID       Invalid / reserved
//
// ============================================================================

`ifndef SCA_PQC_PKG_SV
`define SCA_PQC_PKG_SV

// ============================================================================
// Custom-3 Opcode
// ============================================================================
`define CUSTOM3_OPCODE  7'b1111011

// ============================================================================
// Group Select — funct3 (bits [14:12])
// ============================================================================
`define GRP_KECCAK     3'b000
`define GRP_MOD_ARITH  3'b001
`define GRP_BUTTERFLY  3'b010
`define GRP_CBD        3'b011
`define GRP_COMPRESS   3'b100
`define GRP_MLDSA      3'b101
`define GRP_MASK       3'b110
`define GRP_PRNG       3'b111

// ============================================================================
// Group 0: Keccak (funct3 = 3'b000) — 6 micro-ops + 3 state-resident ops
// ============================================================================
`define OP_SET_C        6'd0    // acc_c <- rs1
`define OP_BCOP32_AB    6'd1    // rs1 ^ (~rs2 & acc_c)
`define OP_SET_HI       6'd2    // acc_hi <- rs1
`define OP_ROL32_L      6'd3    // ROL64 low
`define OP_ROL32_H      6'd4    // ROL64 high
`define OP_XOR3         6'd5    // rs1 ^ rs2 ^ acc_c
// ---------------------------------------------------------------------------
// State-resident Keccak-f[1600] ops — REINSTATED for the xc7a100t retarget.
// These wrap the lane-serial DOM core (keccak_f_masked_serial) with an in-ISE
// shared state bank so the masked sponge (SHA3-256/512, SHAKE128/256, XOF used
// by ML-KEM/ML-DSA) runs tightly-coupled: shares never traverse the OBI bus.
// funct3 = GRP_KECCAK (3'b000), funct7[3:0] = 6..12.
//   Unmasked (plain) path:
`define OP_KECCAK_LDW    6'd51   // kstate0[rs2[5:0]] <- rs1 ; kstate1 <- 0
`define OP_KECCAK_PERM   6'd52   // keccak_f over kstate, mask_en=0 (multi-cycle)
`define OP_KECCAK_RDW    6'd53   // rd <- kstate0[rs1[5:0]]
//   Masked (2-share DOM) path:
`define OP_MKECCAK_SEED  6'd54   // seed <- rs1 ; mask_en <- rs2[0]
`define OP_MKECCAK_LDW   6'd55   // kstate{funct7[4]}[rs2[5:0]] <- rs1 (share sel)
`define OP_MKECCAK_PERM  6'd56   // masked keccak_f over both share banks (multi-cycle)
`define OP_MKECCAK_RDW   6'd57   // rd <- kstate{funct7[4]}[rs1[5:0]] (share sel)
// The bit-manipulation micro-ops above (SET_C/BCOP32/ROL/XOR3) are unaffected.
// ---------------------------------------------------------------------------

// ============================================================================
// Group 1: Modular Arithmetic (funct3 = 3'b001) — 5 ops
// ============================================================================
`define OP_BARRETT_K    6'd6    // mod 3329
`define OP_MONT_K       6'd7    // Montgomery Q=3329
`define OP_CADDQ        6'd8    // conditional add Q
`define OP_BARRETT_D    6'd9    // mod 8380417
`define OP_MONT_D       6'd10   // Montgomery Q=8380417

// ============================================================================
// Group 2: NTT Butterfly (funct3 = 3'b010) — 2 ops
// ============================================================================
`define OP_NTT_BFLY_CT     6'd11   // Cooley-Tukey, sum/diff only
`define OP_NTT_BFLY_GS     6'd12   // Gentleman-Sande, sum/diff only
`define OP_NTT_BFLY_CT_MUL 6'd39   // CT with Mont-mul twiddle
`define OP_NTT_BFLY_GS_MUL 6'd40   // GS with Mont-mul twiddle

// ============================================================================
// Group 3: CBD Sampling (funct3 = 3'b011) — 12 ops
// ============================================================================
`define OP_CBD2_1       6'd13   // CBD eta=2, step 1
`define OP_CBD2_2       6'd14   // CBD eta=2, step 2
`define OP_CBD2_3       6'd15   // CBD eta=2, step 3
`define OP_CBD2_4       6'd16   // CBD eta=2, step 4
`define OP_CBD2_5       6'd17   // CBD eta=2, step 5
`define OP_CBD2_6       6'd18   // CBD eta=2, step 6
`define OP_CBD2_7       6'd19   // CBD eta=2, step 7
`define OP_CBD2_8       6'd20   // CBD eta=2, step 8
`define OP_CBD3_1       6'd21   // CBD eta=3, step 1
`define OP_CBD3_2       6'd22   // CBD eta=3, step 2
`define OP_CBD3_3       6'd23   // CBD eta=3, step 3
`define OP_CBD3_4       6'd24   // CBD eta=3, step 4

// ============================================================================
// Group 4: Compress + Sampling (funct3 = 3'b100) — 5 ops
// ============================================================================
`define OP_COMPRESS_1   6'd25   // Compress step 1
`define OP_COMPRESS_2   6'd26   // Compress step 2
`define OP_COMPRESS_3   6'd27   // Compress step 3
`define OP_COMPRESS_4   6'd28   // Compress step 4 (d=10)
`define OP_REJ_UNIFORM  6'd29   // Rejection uniform sampling
`define OP_COMPRESS_5   6'd38   // Compress step 5 (d=11, ML-KEM-1024 du)

// ============================================================================
// Group 5: ML-DSA Operations (funct3 = 3'b101) — 2 ops
// ============================================================================
`define OP_POWER2ROUND  6'd30   // Power2Round
`define OP_DECOMPOSE    6'd31   // Decompose

// ============================================================================
// Group 6: Masking Primitives (funct3 = 3'b110) — 8 ops
// ============================================================================
// Slots 0-3: legacy single-blind primitives (kept for back-compat / micro-bench)
`define OP_SECMUL_STEP  6'd32   // (rs1*rs2+PRNG) mod q; funct7[4] selects Q
`define OP_MASK_REFRESH 6'd33   // re-randomize share
`define OP_MASKED_AND   6'd34   // AND_BLIND: (rs1&rs2)^PRNG, single building block
`define OP_MASKED_XOR   6'd35   // linear XOR
// Slots 4-7: paired DOM gadgets (Gross-Mangard "+r/-r" cancellation pattern).
// LATCH op draws fresh PRNG word, captures it in r_latched, returns blinded result.
// REUSE op consumes r_latched (no PRNG advance) so the +r and -r terms cancel
// exactly when shares are recombined. Use as { _LATCH ; _REUSE } pairs.
`define OP_SECMUL_LATCH 6'd41   // (rs1*rs2 + r_new) mod q; latch r_new
`define OP_SECMUL_REUSE 6'd42   // (rs1*rs2 - r_latched) mod q
`define OP_AND_LATCH    6'd43   // (rs1 & rs2) ^ r_new; latch r_new
`define OP_AND_REUSE    6'd44   // (rs1 & rs2) ^ r_latched
// Stateful masked-chi unit (Keccak chi = (~X)&Y): the full DOM-AND of (~X&Y) is
// computed inside the coprocessor so the cross-terms never co-locate in CPU
// registers.  Sequence: CHI_LOADX(X0,X1) ; CHI_AND(Y0,Y1)->z0 ; CHI_RDZ1->z1.
`define OP_CHI_LOADX    6'd45   // latch X shares: rs1=X0, rs2=X1
`define OP_CHI_AND      6'd46   // 1-cyc (glitchy): result=z0 comb, latch z1
`define OP_CHI_RDZ1     6'd47   // result = latched z1 share
// Registered (2-cycle, glitch-resistant) DOM chi: ANDR latches the 4 partial
// products (register barrier); RDZ0R/RDZ1R read z=partial XOR (on stable flops).
`define OP_CHI_ANDR     6'd48   // stage1: latch (~x0&Y0),(~x0&Y1)^r,(x1&Y1),(x1&Y0)^r
`define OP_CHI_RDZ0R    6'd49   // stage2: result = p_s0 ^ p_c0  (= z0 share)
`define OP_CHI_RDZ1R    6'd50   // stage2: result = p_s1 ^ p_c1  (= z1 share)
// --------------------------------------------------------------------------
// A2B / B2A mask conversion (X2X, ePrint 2024/114) as tightly-coupled custom
// instructions. Promoted from the loosely-coupled obi_a2b_b2a_peripheral so
// the two shares of a coefficient never co-locate on the CPU data bus.
// funct3 = GRP_MASK (3'b110). Encoding within the group:
//   funct7[4] (bit 29) = wide_mode  (0 = ML-KEM q=3329 / 13b, 1 = ML-DSA / 24b)
//   funct7[5] (bit 30) = direction page (0 = A2B, 1 = B2A)
//   funct7[3:0]        = 14 -> CONV (start, multi-cycle, rd = output share0)
//                        15 -> RD1  (single-cycle, rd = latched output share1)
// CONV is multi-cycle (~25 cyc); the ISE FSM stalls issue until done, then a
// following RD1 returns the second share. Round-trip A2B(B2A(x)) == x mod q.
`define OP_A2B_CONV     6'd58   // arith->bool start; rs1=x0, rs2=x1; rd=y0
`define OP_A2B_RD1      6'd59   // rd = latched y1
`define OP_B2A_CONV     6'd60   // bool->arith start; rs1=y0, rs2=y1; rd=x0
`define OP_B2A_RD1      6'd61   // rd = latched x1

// ============================================================================
// Group 7: PRNG Control (funct3 = 3'b111) — 2 ops
// ============================================================================
`define OP_SEED_PRNG    6'd36   // Seed PRNG
`define OP_GET_RANDOM   6'd37   // Get random word

// ============================================================================
// Invalid / Reserved
// ============================================================================
`define OP_INVALID      6'd63

// ============================================================================
// FIPS-203 / FIPS-204 prime constants -- one source of truth.
// Used by ise_mod_reduce.sv, ise_mask_ops.sv, and any future ML-DSA module
// that needs the prime or the Montgomery negation constant.
// ============================================================================
`define MLKEM_Q             16'd3329
`define MLKEM_QINV_NEG_R16  16'd62209          // -Q^{-1} mod 2^16 (Q=3329)
`define MLDSA_Q             24'd8380417
`define MLDSA_QINV_NEG_R32  32'd4236238847     // -Q^{-1} mod 2^32 (Q=8380417)

`endif // SCA_PQC_PKG_SV
