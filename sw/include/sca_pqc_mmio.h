/* ===========================================================================
 * SCA_Pro_PQC -- MMIO Register Definitions and Helper Functions
 * ===========================================================================
 *
 * Memory map (on Greyhound fabric OBI bus):
 *
 *   Base + 0x000 .. 0x0FF : A2B / B2A mask conversion peripheral
 *   Base + 0x100 .. 0x1FF : TRNG peripheral
 *
 * The fabric OBI bus base address is 0x5000_0000.
 *
 * ===========================================================================
 */

#ifndef SCA_PQC_MMIO_H
#define SCA_PQC_MMIO_H

#include <stdint.h>
#include "prof.h"

/* A2B/B2A are now tightly-coupled CV-X-IF custom instructions (the loosely
 * coupled OBI peripheral was removed). The hardware a2b_convert/b2a_convert
 * bodies below lower to .insn r 0x7b ops; masking randomness is drawn from the
 * in-coprocessor ISE PRNG (seeded once via SCA_SEED_PRNG). */
#ifndef SCA_HOST_SIM
#include "sca_pqc_ise.h"
#endif

/* =========================================================================
 * Base addresses
 * ========================================================================= */
/* croc port: A2B/B2A peripheral is mapped at croc_pkg::UserBaseAddr
 * (XbarUser start = 0x2000_0000) in user_domain.sv. The peripheral decodes
 * only the low 8 address bits, so the register offsets below land correctly. */
#define A2B_B2A_BASE        0x20000000UL
#define TRNG_BASE           0x20000100UL  /* TRNG not instantiated on croc */

/* HW-resident DOM chi-gadget proof peripheral (UserBaseAddr + 0x2000).
 * Decodes only the low 8 address bits. See rtl/sca_pqc/hwmask. */
#define HWMASK_BASE         0x20002000UL

#define HWMASK_CTRL         (HWMASK_BASE + 0x00)  /* W: [0]=key_load,[1]=run,[2]=mask_en */
#define HWMASK_STATUS       (HWMASK_BASE + 0x04)  /* R: [1]=done/idle */
#define HWMASK_KEYA         (HWMASK_BASE + 0x08)  /* W: lane-A secret word */
#define HWMASK_KEYB         (HWMASK_BASE + 0x0C)  /* W: lane-B secret word */

/* HWMASK CTRL bits */
#define HWMASK_CTRL_LOAD    (1U << 0)
#define HWMASK_CTRL_RUN     (1U << 1)
#define HWMASK_CTRL_MASKEN  (1U << 2)

/* HWMASK STATUS bits */
#define HWMASK_STATUS_DONE  (1U << 1)

/* =========================================================================
 * A2B / B2A Mask Conversion Peripheral Registers
 * =========================================================================
 *
 * Offset  Name         R/W  Description
 * ------  -----------  ---  ------------------------------------------------
 * 0x00    CTRL         W    [0]   start conversion
 *                           [1]   direction: 0=A2B, 1=B2A
 *                           [2]   wide_mode: 0=12-bit (ML-KEM), 1=23-bit (ML-DSA)
 * 0x04    STATUS       R    [0]   busy
 *                           [1]   done (write 1 to CTRL[0] clears done)
 * 0x08    SHARE0_IN    W    Input share 0
 * 0x0C    SHARE1_IN    W    Input share 1
 * 0x10    SHARE0_OUT   R    Output share 0
 * 0x14    SHARE1_OUT   R    Output share 1
 * 0x18    RANDOM_IN    W    Fresh randomness for conversion
 */

#define A2B_REG_CTRL        (A2B_B2A_BASE + 0x00)
#define A2B_REG_STATUS      (A2B_B2A_BASE + 0x04)
#define A2B_REG_SHARE0_IN   (A2B_B2A_BASE + 0x08)
#define A2B_REG_SHARE1_IN   (A2B_B2A_BASE + 0x0C)
#define A2B_REG_SHARE0_OUT  (A2B_B2A_BASE + 0x10)
#define A2B_REG_SHARE1_OUT  (A2B_B2A_BASE + 0x14)
#define A2B_REG_RANDOM_IN   (A2B_B2A_BASE + 0x18)

/* CTRL register bit positions */
#define A2B_CTRL_START      (1U << 0)
#define A2B_CTRL_DIR_B2A    (1U << 1)   /* 0=A2B, 1=B2A */
#define A2B_CTRL_WIDE       (1U << 2)   /* 0=12-bit, 1=23-bit */

/* STATUS register bit positions */
#define A2B_STATUS_BUSY     (1U << 0)
#define A2B_STATUS_DONE     (1U << 1)

/* =========================================================================
 * TRNG Peripheral Registers
 * =========================================================================
 *
 * Offset  Name         R/W  Description
 * ------  -----------  ---  ------------------------------------------------
 * 0x00    CTRL         W    [0]   enable ring oscillators
 *                           [1]   seed internal PRNG from TRNG entropy
 *                           [7:4] post-processing mode (0=raw, 1=vonNeumann)
 * 0x04    STATUS       R    [0]   entropy valid (at least 1 word available)
 *                           [1]   PRNG seeded
 *                           [7:4] health test status (0=pass)
 * 0x08    DATA         R    32-bit true random word (auto-advances FIFO)
 * 0x0C    HEALTH       R    Health test counters (repetition + adaptive)
 * 0x10    SEED_DATA    W    Manual seed word for PRNG (for deterministic test)
 * 0x14    SEED_IDX     W    Seed word index [1:0] (4 words total)
 */

#define TRNG_REG_CTRL       (TRNG_BASE + 0x00)
#define TRNG_REG_STATUS     (TRNG_BASE + 0x04)
#define TRNG_REG_DATA       (TRNG_BASE + 0x08)
#define TRNG_REG_HEALTH     (TRNG_BASE + 0x0C)
#define TRNG_REG_SEED_DATA  (TRNG_BASE + 0x10)
#define TRNG_REG_SEED_IDX   (TRNG_BASE + 0x14)

/* TRNG CTRL bits */
#define TRNG_CTRL_ENABLE    (1U << 0)
#define TRNG_CTRL_SEED_PRNG (1U << 1)
#define TRNG_CTRL_PP_RAW    (0U << 4)
#define TRNG_CTRL_PP_VN     (1U << 4)

/* TRNG STATUS bits */
#define TRNG_STATUS_VALID   (1U << 0)
#define TRNG_STATUS_SEEDED  (1U << 1)
#define TRNG_STATUS_HEALTH_MASK (0xFU << 4)

/* =========================================================================
 * Low-level MMIO access
 * ========================================================================= */

#ifdef SCA_HOST_SIM
/* Host build: MMIO target addresses are not dereferenced as physical pointers.
 * Stubs are sufficient because the host A2B/B2A path uses sca_host_a2b /
 * sca_host_b2a (declared below) which mirror the OBI peripheral semantics
 * via pure C, instead of issuing MMIO writes/reads. */
static inline void mmio_write(uint32_t addr, uint32_t val) { (void)addr; (void)val; }
static inline uint32_t mmio_read(uint32_t addr) { (void)addr; return 0u; }
#else
#define MMIO_REG(addr) (*(volatile uint32_t *)(uintptr_t)(addr))

static inline void mmio_write(uint32_t addr, uint32_t val)
{
    MMIO_REG(addr) = val;
}

static inline uint32_t mmio_read(uint32_t addr)
{
    return MMIO_REG(addr);
}
#endif

/* =========================================================================
 * A2B / B2A Helper Functions
 * ========================================================================= */

/**
 * Perform Arithmetic-to-Boolean mask conversion.
 *
 * Converts arithmetic shares (x0 + x1 mod 2^k) to boolean shares (y0 XOR y1).
 *
 * @param share0_in   Arithmetic share 0
 * @param share1_in   Arithmetic share 1
 * @param random      Fresh randomness
 * @param wide_mode   0 = 12-bit (ML-KEM, q=3329), 1 = 23-bit (ML-DSA, q=8380417)
 * @param share0_out  Pointer to receive boolean share 0
 * @param share1_out  Pointer to receive boolean share 1
 */
#ifdef SCA_HOST_SIM
/* Host emulation of the OBI peripheral A2B core, BIT-EXACT to the silicon in
 * rtl/sca_pqc/obi/a2b_core.sv.  This must match the RTL select logic exactly
 * (NOT a textbook mod-Q reduction) so that host KATs reproduce the silicon's
 * behaviour for ALL inputs -- including KEM-sized inputs fed through the
 * wide_mode=1 (ML-DSA) datapath.
 *
 * RTL semantics (a2b_core.sv):
 *   W      = wide_mode ? 24 : 13            (modulus width + 1 overflow bit)
 *   w_mask = (1<<W)-1                        (L127)
 *   neg_q  = wide_mode ? 8396799 : 4863      (= 2^W - Q)         (L47-48,L134)
 *   raw    = (x0 + x1) & w_mask              (pass 1, L196-197)
 *   trial  = (raw + neg_q) & w_mask_ext      (pass 2; w_mask_ext keeps the
 *                                             carry bit, L222-223)
 *   carry_pos = wide_mode ? 23 : 13          (L131)
 *   carry_out = trial[carry_pos]             (L249)
 *   out_mask  = w_mask >> 1                  (W-1 bits, L251)
 *   result    = carry_out ? (trial & out_mask) : (raw & out_mask)   (L253-261)
 *
 * KEY CONSEQUENCE (the bug class this faithful model now catches):
 *   For a KEM coefficient sum w in [0, 2q) (w < 6658) pushed through
 *   wide_mode=1: raw = w, trial = w + 8396799 (no 24-bit wrap since
 *   w+8396799 < 2^24).  trial[23] = 1 for every such w (w+8396799 >= 2^23),
 *   so carry_out=1 and result = trial & 0x7FFFFF = (w + 8396799) - 2^23
 *   = w + 8191.  i.e. wide_mode=1 returns w+8191, NOT w.  Any caller that
 *   assumes the boolean value equals the raw sum w is therefore wrong on
 *   silicon (every coefficient off by +8191).
 *
 *   For wide_mode=0 (the correct ML-KEM datapath) the value returned is the
 *   true (x0+x1) mod q in [0, q), masked to 12 bits (out_mask=0xFFF).
 *
 * Output is a fresh boolean split with `random` as one share. */
static inline void a2b_convert(uint32_t share0_in, uint32_t share1_in,
                               uint32_t random, int wide_mode,
                               uint32_t *share0_out, uint32_t *share1_out)
{ PROF(P_A2B);
    uint32_t w_mask     = wide_mode ? 0x00FFFFFFu : 0x00001FFFu;  /* W=24/13 bits          */
    uint32_t w_mask_ext = wide_mode ? 0x00FFFFFFu : 0x00003FFFu;  /* W+1 bits (L129)        */
    uint32_t out_mask   = w_mask >> 1;                            /* W-1 bits (L251)        */
    uint32_t neg_q      = wide_mode ? 8396799u    : 4863u;        /* 2^W - Q  (L134)        */
    uint32_t carry_pos  = wide_mode ? 23u         : 13u;          /* carry bit pos (L131)   */

    uint32_t raw   = (share0_in + share1_in) & w_mask;            /* pass 1 (L196-197)      */
    uint32_t trial = (raw + neg_q) & w_mask_ext;                 /* pass 2 (L222-223)      */
    uint32_t carry_out = (trial >> carry_pos) & 1u;              /* (L249)                 */
    uint32_t recon = carry_out ? (trial & out_mask)              /* raw >= Q: reduced       */
                               : (raw   & out_mask);             /* raw <  Q: as-is         */

    uint32_t y1 = random & out_mask;
    *share1_out = y1;
    *share0_out = (recon ^ y1) & out_mask;
}
#else
static inline void a2b_convert(uint32_t share0_in, uint32_t share1_in,
                               uint32_t random, int wide_mode,
                               uint32_t *share0_out, uint32_t *share1_out)
{
    /* Tightly-coupled CV-X-IF: A2B_CONV blocks until done (multi-cycle FSM),
     * returns boolean share0 in rd; A2B_RD1 returns the latched share1. The
     * core draws its own fresh randomness from the seeded ISE PRNG, so the
     * caller-supplied `random` is unused on the hardware path. */
    uint32_t y0, y1;
    (void)random;
    if (wide_mode) { SCA_A2B_CONV_D(y0, share0_in, share1_in); }
    else           { SCA_A2B_CONV_K(y0, share0_in, share1_in); }
    SCA_A2B_RD1(y1);
    *share0_out = y0;
    *share1_out = y1;
}
#endif

/**
 * Perform Boolean-to-Arithmetic mask conversion.
 *
 * Converts boolean shares (x0 XOR x1) to arithmetic shares (y0 + y1 mod 2^k).
 *
 * @param share0_in   Boolean share 0
 * @param share1_in   Boolean share 1
 * @param random      Fresh randomness
 * @param wide_mode   0 = 12-bit (ML-KEM), 1 = 23-bit (ML-DSA)
 * @param share0_out  Pointer to receive arithmetic share 0
 * @param share1_out  Pointer to receive arithmetic share 1
 */
#ifdef SCA_HOST_SIM
static inline void b2a_convert(uint32_t share0_in, uint32_t share1_in,
                               uint32_t random, int wide_mode,
                               uint32_t *share0_out, uint32_t *share1_out)
{ PROF(P_B2A);
    uint32_t out_mask = wide_mode ? 0x007FFFFFu : 0x00000FFFu;
    uint32_t Q_val    = wide_mode ? 8380417u    : 3329u;
    uint32_t recon    = (share0_in ^ share1_in) & out_mask;
    uint32_t y1       = random % Q_val;             /* uniform mod-Q random */
    *share1_out = y1;
    *share0_out = (recon + Q_val - y1) % Q_val;
}
#else
static inline void b2a_convert(uint32_t share0_in, uint32_t share1_in,
                               uint32_t random, int wide_mode,
                               uint32_t *share0_out, uint32_t *share1_out)
{
    /* Tightly-coupled CV-X-IF: B2A_CONV blocks until done, returns arithmetic
     * share0 in rd; B2A_RD1 returns the latched share1. Randomness from the
     * seeded ISE PRNG; caller `random` unused on the hardware path. */
    uint32_t x0, x1;
    (void)random;
    if (wide_mode) { SCA_B2A_CONV_D(x0, share0_in, share1_in); }
    else           { SCA_B2A_CONV_K(x0, share0_in, share1_in); }
    SCA_B2A_RD1(x1);
    *share0_out = x0;
    *share1_out = x1;
}
#endif

/* =========================================================================
 * TRNG Helper Functions
 * ========================================================================= */

/**
 * Enable the TRNG with specified post-processing mode.
 *
 * @param pp_mode  Post-processing: TRNG_CTRL_PP_RAW or TRNG_CTRL_PP_VN
 */
static inline void trng_enable(uint32_t pp_mode)
{
    mmio_write(TRNG_REG_CTRL, TRNG_CTRL_ENABLE | pp_mode);
}

/**
 * Read a 32-bit true random word. Blocks until entropy is available.
 *
 * @return  32-bit random word
 */
static inline uint32_t trng_read(void)
{
    while (!(mmio_read(TRNG_REG_STATUS) & TRNG_STATUS_VALID))
        ;
    return mmio_read(TRNG_REG_DATA);
}

/**
 * Seed the internal ISE PRNG from TRNG entropy.
 * Writes 4 seed words via the TRNG peripheral, then triggers the seed
 * operation so the coprocessor PRNG is ready for masked operations.
 */
static inline void trng_seed_prng(void)
{
    /* Wait for TRNG to have entropy */
    for (int i = 0; i < 4; i++) {
        uint32_t rng = trng_read();
        mmio_write(TRNG_REG_SEED_DATA, rng);
        mmio_write(TRNG_REG_SEED_IDX, (uint32_t)i);
    }

    /* Trigger PRNG seed latch */
    mmio_write(TRNG_REG_CTRL, TRNG_CTRL_ENABLE | TRNG_CTRL_SEED_PRNG);

    /* Wait for PRNG seeded status */
    while (!(mmio_read(TRNG_REG_STATUS) & TRNG_STATUS_SEEDED))
        ;
}

/**
 * Read the TRNG health status.
 *
 * @return  0 if health tests pass, non-zero on failure
 */
static inline uint32_t trng_health_status(void)
{
    return (mmio_read(TRNG_REG_STATUS) & TRNG_STATUS_HEALTH_MASK) >> 4;
}

#endif /* SCA_PQC_MMIO_H */
