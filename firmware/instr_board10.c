// =============================================================================
// CW305 board firmware: ten secret-carrying custom instructions, unprotected.
//
// Each block issues exactly one custom instruction under its own trigger pulse,
// with the secret present in the clear. The set spans both algorithms and four
// distinct datapaths inside the coprocessor, so the campaign measures the ISA
// rather than one arithmetic unit.
//
//   block  1  MONT_K            ML-KEM basemul  s_hat . u_hat        (mod-reduce)
//   block  2  BARRETT_K         ML-KEM reduce of a secret coefficient (mod-reduce)
//   block  3  AND_LATCH         ML-KEM tomsg Boolean AND on a secret   (masking)
//   block  4  CADDQ             ML-KEM conditional add Q, sign of secret (mod-reduce)
//   block  5  NTT_BFLY_GS_MUL   ML-KEM inverse butterfly on s.u        (butterfly)
//   block  6  COMPRESS_1        ML-KEM poly_tomsg, message-bit decode  (compress)
//   block  7  CBD2_1            ML-KEM FO re-encryption noise sampling (cbd)
//   block  8  BARRETT_D         ML-DSA reduce32 of c.s1                (mod-reduce)
//   block  9  MONT_D_REDUCE64   ML-DSA Montgomery reduce of c.s1       (mod-reduce)
//   block 10  DECOMPOSE         ML-DSA w0/w1 split, secret through y   (mldsa-ops)
//
// Blocks 1 to 3 repeat the six-block campaign instruction for instruction and
// operand for operand, so this firmware re-measures them rather than replacing
// them. Any drift between the two campaigns on those blocks is a property of the
// build, not of the instruction.
//
// The design has no host-to-SoC write path: the USB front end can only be read.
// The firmware therefore sequences itself and publishes what it is about to do
// in the mailbox, which the host reads back to label each captured trace.
//
//   MBOX(0) = block identifier, 1 to 10
//   MBOX(1) = trigger, bit 0 drives TIO4
//   MBOX(2) = operand index within the block
//   MBOX(3) = 0xB0A5D000 once running, low byte counts completed blocks
//
// A gap is inserted before and after every trigger pulse so the host has time
// to re-arm between captures.
//
// Every block reads its operands as plain word-table loads inside the trigger
// window, which is exactly what the six-block firmware did. Block 5 needs
// rs2 = { zeta, b }, so the pack is precomputed in the table rather than in the
// loop, keeping all ten windows the same shape.
// =============================================================================
#include <stdint.h>
#include "sca_pqc_ise.h"

#define MBOX(n)  (*(volatile uint32_t *)(uintptr_t)(0x50000200u + 4u * (n)))
#define TRIG_HI  do { MBOX(1) = 1u; } while (0)
#define TRIG_LO  do { MBOX(1) = 0u; } while (0)

#ifndef GAP
#define GAP 40000u          /* idle loop iterations between traces */
#endif

/* ONLY_BLOCK=k compiles a single block, which is how the pre-silicon runs are
   built: one Verilator simulation per instruction keeps each waveform small
   enough to parse, and the instruction's pipeline context inside its own loop
   is identical either way. NSIM shortens the loop for simulation. */
#if defined(ONLY_BLOCK)
#define BLOCK_ENABLED(k) (ONLY_BLOCK == (k))
#else
#define BLOCK_ENABLED(k) 1
#endif

/* Scrub campaign (fw_tvla3): every measured run is preceded by the same
   instruction on one constant operand, so every run has the same predecessor
   state and the fixed class does not differ from the random class by the
   absence of an operand transition. The scrub run is not triggered and the
   extractor keeps the last issue per operand index, i.e. the measured one. */
#define SCRUB_K      1717u                 /* in [0, 3329) */
#define SCRUB_12     0xA5Au                /* 12-bit mask word */
#define SCRUB_PACKED ((1234u << 16) | (b5_packed[i] & 0xFFFFu))  /* zeta = 1234, secret b unchanged (low half of the packed word) */
#define SCRUB_32     0x9E3779B9u
#define SCRUB_30     0x2A5A5A5Au           /* in [-2^30, 2^30) */
#define SCRUB_LO     0x00ABCDEFu
#define SCRUB_HI     0x00000000u
#define SCRUB_D      4190208u              /* in [0, 8380417) */
#include "operands10.h"     /* defines NTRACE and the operand tables */

#ifdef NSIM
/* NSIM shortens the loop for simulation. It must never lengthen it past the end
   of the operand tables: reading beyond them walks into the next table and the
   instruction then runs on data that no ground truth describes, silently. A
   2000-trace simulation against 1000-entry tables produced exactly that and the
   results were thrown away. */
#if NSIM > NTRACE
#error "NSIM must not exceed the operand table length; regenerate the tables"
#endif
#undef NTRACE
#define NTRACE NSIM
#endif

static volatile uint32_t sink;

static void gap(void)
{
    for (volatile uint32_t i = 0; i < GAP; i++) { }
}

void main(void)
{
    uint32_t d, u;
    const uint32_t zero_mode = 0u;   /* gamma2 selector: 0 = ML-DSA-44 */

    MBOX(3) = 0xA11FE000u;      /* alive marker, written before anything else */
    MBOX(0) = 0u; MBOX(2) = 0u; TRIG_LO;

    /* Seed the mask generator once. No block here consumes it, but seeding is
       kept identical to the six-block firmware so the two builds differ only in
       the instructions issued. */
    SCA_SEED_PRNG(d, 0xC0FFEE01u, 0u); SCA_SEED_PRNG(d, 0xDEADBEEFu, 1u);
    SCA_SEED_PRNG(d, 0x12345678u, 2u); SCA_SEED_PRNG(d, 0xA5A5A5A5u, 3u);
    (void)d;

    MBOX(3) = 0xB0A5D000u;      /* seeding completed */

    for (;;) {
#if BLOCK_ENABLED(1)
        /* ---- block 1: ML-KEM Montgomery multiply ---------------------- */
        MBOX(0) = 1u;
        for (uint32_t i = 0; i < NTRACE; i++) {
            MBOX(2) = i; gap();
            SCA_MONT_K(u, b1_secret[i], SCRUB_K); sink = u;
            TRIG_HI; SCA_MONT_K(u, b1_secret[i], b1_public[i]); TRIG_LO;
            sink = u; gap();
        }
        MBOX(3) = 0xB0A5D001u;
#endif

#if BLOCK_ENABLED(2)
        /* ---- block 2: ML-KEM Barrett reduce ---------------------------- */
        MBOX(0) = 2u;
        for (uint32_t i = 0; i < NTRACE; i++) {
            MBOX(2) = i; gap();
            SCA_BARRETT_K(u, SCRUB_K); sink = u;
            TRIG_HI; SCA_BARRETT_K(u, b2_secret[i]); TRIG_LO;
            sink = u; gap();
        }
        MBOX(3) = 0xB0A5D002u;
#endif

#if BLOCK_ENABLED(3)
        /* ---- block 3: ML-KEM Boolean AND on a secret word -------------- */
        MBOX(0) = 3u;
        for (uint32_t i = 0; i < NTRACE; i++) {
            MBOX(2) = i; gap();
            SCA_AND_LATCH(u, b3_secret[i], SCRUB_12); sink = u;
            TRIG_HI; SCA_AND_LATCH(u, b3_secret[i], b3_public[i]); TRIG_LO;
            sink = u; gap();
        }
        MBOX(3) = 0xB0A5D003u;
#endif

#if BLOCK_ENABLED(4)
        /* ---- block 4: ML-KEM conditional add Q ------------------------- */
        /* The table holds the signed coefficient in two's complement; the
           instruction adds Q exactly when the sign bit is set. */
        MBOX(0) = 4u;
        for (uint32_t i = 0; i < NTRACE; i++) {
            MBOX(2) = i; gap();
            SCA_CADDQ(u, SCRUB_K); sink = u;
            TRIG_HI; SCA_CADDQ(u, b4_secret[i]); TRIG_LO;
            sink = u; gap();
        }
        MBOX(3) = 0xB0A5D004u;
#endif

#if BLOCK_ENABLED(5)
        /* ---- block 5: ML-KEM inverse NTT butterfly with twiddle -------- */
        /* rs2 carries { zeta[15:0], b[15:0] }, packed by the generator. */
        MBOX(0) = 5u;
        for (uint32_t i = 0; i < NTRACE; i++) {
            MBOX(2) = i; gap();
            SCA_NTT_BFLY_GS_MUL(u, b5_a[i], SCRUB_PACKED); sink = u;
            TRIG_HI; SCA_NTT_BFLY_GS_MUL(u, b5_a[i], b5_packed[i]); TRIG_LO;
            sink = u; gap();
        }
        MBOX(3) = 0xB0A5D005u;
#endif

#if BLOCK_ENABLED(6)
        /* ---- block 6: ML-KEM message-bit decode ------------------------ */
        MBOX(0) = 6u;
        for (uint32_t i = 0; i < NTRACE; i++) {
            MBOX(2) = i; gap();
            SCA_COMPRESS_1(u, SCRUB_K); sink = u;
            TRIG_HI; SCA_COMPRESS_1(u, b6_secret[i]); TRIG_LO;
            sink = u; gap();
        }
        MBOX(3) = 0xB0A5D006u;
#endif

#if BLOCK_ENABLED(7)
        /* ---- block 7: ML-KEM CBD noise sampling ------------------------ */
        MBOX(0) = 7u;
        for (uint32_t i = 0; i < NTRACE; i++) {
            MBOX(2) = i; gap();
            SCA_CBD2_1(u, SCRUB_32); sink = u;
            TRIG_HI; SCA_CBD2_1(u, b7_word[i]); TRIG_LO;
            sink = u; gap();
        }
        MBOX(3) = 0xB0A5D007u;
#endif

#if BLOCK_ENABLED(8)
        /* ---- block 8: ML-DSA Barrett reduce ---------------------------- */
        MBOX(0) = 8u;
        for (uint32_t i = 0; i < NTRACE; i++) {
            MBOX(2) = i; gap();
            SCA_BARRETT_D(u, SCRUB_30); sink = u;
            TRIG_HI; SCA_BARRETT_D(u, b8_secret[i]); TRIG_LO;
            sink = u; gap();
        }
        MBOX(3) = 0xB0A5D008u;
#endif

#if BLOCK_ENABLED(9)
        /* ---- block 9: ML-DSA Montgomery reduce of a 64-bit product ----- */
        MBOX(0) = 9u;
        for (uint32_t i = 0; i < NTRACE; i++) {
            MBOX(2) = i; gap();
            SCA_MONT_D_REDUCE64(u, SCRUB_LO, SCRUB_HI); sink = u;
            TRIG_HI; SCA_MONT_D_REDUCE64(u, b9_lo[i], b9_hi[i]); TRIG_LO;
            sink = u; gap();
        }
        MBOX(3) = 0xB0A5D009u;
#endif

#if BLOCK_ENABLED(10)
        /* ---- block 10: ML-DSA Decompose -------------------------------- */
        /* rs2 = 0 selects the ML-DSA-44 gamma2. */
        MBOX(0) = 10u;
        for (uint32_t i = 0; i < NTRACE; i++) {
            MBOX(2) = i; gap();
            SCA_DECOMPOSE(u, SCRUB_D, zero_mode); sink = u;
            TRIG_HI; SCA_DECOMPOSE(u, b10_w[i], zero_mode); TRIG_LO;
            sink = u; gap();
        }
        MBOX(3) = 0xB0A5D00Au;
#endif
    }
}
