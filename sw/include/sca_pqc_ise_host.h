/* ===========================================================================
 * SCA_Pro_PQC -- Host-mode (x86/ARM dev) emulation of the ISE primitives
 * ===========================================================================
 *
 * Compile with -DSCA_HOST_SIM to redirect every SCA_* inline-asm macro to a
 * pure-C function that reproduces the RTL semantics bit-for-bit.  This lets
 * the masked code base run NIST KAT vectors on the host, without flashing
 * the CW305 every iteration.
 *
 * Coverage: all primitives needed for masked ML-KEM-1024 / ML-DSA-44
 *   - GET_RANDOM                       (xorshift32 PRNG, deterministic seed)
 *   - BARRETT_K / BARRETT_D / CADDQ    (modular reduction)
 *   - MONT_K   / MONT_D                (Montgomery multiply, R = 2^16 / 2^32)
 *   - SECMUL_LATCH/REUSE_K/D           (paired DOM cross-term gadget)
 *   - AND_LATCH / AND_REUSE            (paired DOM-AND for Keccak chi)
 *   - MASK_REFRESH_A / MASK_REFRESH_B  (single-share re-randomization)
 *   - MASKED_XOR                       (linear XOR)
 *   - SECMUL_STEP_K/D, MASKED_AND      (legacy single-blind, kept for parity)
 *
 * NTT butterfly, CBD, Compress, REJ, Power2Round, Decompose are NOT emulated
 * here -- those are exercised end-to-end against the pq-crystals reference
 * (which already has a verified C implementation), so the host KAT path uses
 * the reference helpers directly.  See sw/host/sca_pqc_kat_host.c.
 * ===========================================================================
 */

#ifndef SCA_PQC_ISE_HOST_H
#define SCA_PQC_ISE_HOST_H

#include <stdint.h>

/* -------- Deterministic PRNG state (host-only) -------------------------- */
extern uint32_t _sca_host_prng_state;
extern uint32_t _sca_host_r_latched;
extern int      _sca_host_q_sel;          /* 0=KEM, 1=DSA, set by macros */
extern int      _sca_host_r_latched_valid;
extern unsigned _sca_host_atomicity_traps;

/* Reseed the host PRNG.  Calling with seed=0 picks a fixed default that is
 * deterministic across runs (so KAT diffs are reproducible). */
void sca_host_seed_prng(uint32_t seed);

/* xorshift32 step; advances state and returns the previous word. */
uint32_t sca_host_get_random(void);

/* Q=3329 helpers (signed 16-bit semantics, matching ise_mod_reduce.sv) */
int32_t sca_host_barrett_k(int32_t a);
int32_t sca_host_mont_k(int32_t a, int32_t b);
int32_t sca_host_caddq(int32_t a);

/* Q=8380417 helpers (signed 32-bit semantics, matching ise_mod_reduce.sv) */
int32_t sca_host_barrett_d(int32_t a);
int32_t sca_host_mont_d(int32_t a, int32_t b);

/* Paired DOM cross-term gadgets.  Same internal r_latched state. */
int32_t sca_host_secmul_latch_k(int32_t a, int32_t b);  /* a*b + r_new mod 3329 */
int32_t sca_host_secmul_reuse_k(int32_t a, int32_t b);  /* a*b - r_latched mod 3329 */
int32_t sca_host_secmul_latch_d(int32_t a, int32_t b);  /* a*b + r_new mod Q_D */
int32_t sca_host_secmul_reuse_d(int32_t a, int32_t b);  /* a*b - r_latched mod Q_D */
uint32_t sca_host_and_latch(uint32_t a, uint32_t b);    /* (a&b) ^ r_new */
uint32_t sca_host_and_reuse(uint32_t a, uint32_t b);    /* (a&b) ^ r_latched */

/* Legacy single-blind */
int32_t  sca_host_secmul_step_k(int32_t a, int32_t b);  /* a*b + r mod 3329 */
int32_t  sca_host_secmul_step_d(int32_t a, int32_t b);  /* a*b + r mod Q_D */
uint32_t sca_host_masked_and(uint32_t a, uint32_t b);   /* (a&b) ^ r */

/* Mask refresh */
int32_t  sca_host_mask_refresh_a(int32_t a);            /* (a + r[11:0]) mod 3329 */
uint32_t sca_host_mask_refresh_b(uint32_t a);           /* a ^ r */

#endif /* SCA_PQC_ISE_HOST_H */
