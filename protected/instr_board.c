// =============================================================================
// CW305 board firmware: the six custom instructions under test, each executed
// independently under its own trigger pulse.
//
//   block 1  MONT_K(secret, public)                     unprotected multiply
//   block 2  BARRETT_K(secret)                          unprotected reduce
//   block 3  AND_LATCH(secret, public)                  unprotected AND
//   block 4  SECMUL_LATCH(a0,b) + SECMUL_REUSE(a1,b)    protected multiply
//   block 5  BARRETT_K(s0) then BARRETT_K(s1)           protected reduce
//   block 6  AND_LATCH(a0,b1) + AND_REUSE(a1,b0)        protected AND
//
// The design has no host-to-SoC write path: the USB front end can only be read.
// The firmware therefore sequences itself and publishes what it is about to do
// in the mailbox, which the host reads back to label each captured trace.
//
//   MBOX(0) = block identifier, 1 to 6
//   MBOX(1) = trigger, bit 0 drives TIO4
//   MBOX(2) = operand index within the block
//   MBOX(3) = 0xB0A5D000 once running, low byte counts completed blocks
//
// A gap is inserted before and after every trigger pulse so the host has time
// to re-arm between captures.
// =============================================================================
#include <stdint.h>
#include "sca_pqc_ise.h"

#define MBOX(n)  (*(volatile uint32_t *)(uintptr_t)(0x50000200u + 4u * (n)))
#define TRIG_HI  do { MBOX(1) = 1u; } while (0)
#define TRIG_LO  do { MBOX(1) = 0u; } while (0)

#ifndef NTRACE
#define NTRACE 1000
#endif
#ifndef GAP
#define GAP 40000u          /* idle loop iterations between traces */
#endif

#include "operands_board.h"

static volatile uint32_t sink;

static void gap(void)
{
    for (volatile uint32_t i = 0; i < GAP; i++) { }
}

void main(void)
{
    uint32_t d, u, v;

    MBOX(3) = 0xA11FE000u;      /* alive marker, written before anything else */
    MBOX(0) = 0u; MBOX(2) = 0u; TRIG_LO;

    /* Seed the mask generator once. The protected blocks consume it; the
       unprotected ones do not, but seeding is kept identical so the two
       differ only in the instructions issued. */
    SCA_SEED_PRNG(d, 0xC0FFEE01u, 0u); SCA_SEED_PRNG(d, 0xDEADBEEFu, 1u);
    SCA_SEED_PRNG(d, 0x12345678u, 2u); SCA_SEED_PRNG(d, 0xA5A5A5A5u, 3u);
    (void)d;

    MBOX(3) = 0xB0A5D000u;      /* seeding completed */

    for (;;) {
        /* ---- block 1: unprotected multiply --------------------------- */
        MBOX(0) = 1u;
        for (uint32_t i = 0; i < NTRACE; i++) {
            MBOX(2) = i; gap();
            TRIG_HI; SCA_MONT_K(u, u_mont_s[i], u_mont_b[i]); TRIG_LO;
            sink = u; gap();
        }
        MBOX(3) = 0xB0A5D001u;

        /* ---- block 2: unprotected reduce ------------------------------ */
        MBOX(0) = 2u;
        for (uint32_t i = 0; i < NTRACE; i++) {
            MBOX(2) = i; gap();
            TRIG_HI; SCA_BARRETT_K(u, u_barr_x[i]); TRIG_LO;
            sink = u; gap();
        }
        MBOX(3) = 0xB0A5D002u;

        /* ---- block 3: unprotected AND -------------------------------- */
        MBOX(0) = 3u;
        for (uint32_t i = 0; i < NTRACE; i++) {
            MBOX(2) = i; gap();
            TRIG_HI; SCA_AND_LATCH(u, u_and_s[i], u_and_b[i]); TRIG_LO;
            sink = u; gap();
        }
        MBOX(3) = 0xB0A5D003u;

        /* ---- block 4: protected multiply ------------------------------ */
        MBOX(0) = 4u;
        for (uint32_t i = 0; i < NTRACE; i++) {
            MBOX(2) = i; gap();
            TRIG_HI;
            SCA_SECMUL_LATCH_K(u, p_mul_a0[i], p_mul_b[i]);
            SCA_SECMUL_REUSE_K(v, p_mul_a1[i], p_mul_b[i]);
            TRIG_LO;
            sink = u + v; gap();
        }
        MBOX(3) = 0xB0A5D004u;

        /* ---- block 5: protected reduce, one call per share ------------ */
        MBOX(0) = 5u;
        for (uint32_t i = 0; i < NTRACE; i++) {
            MBOX(2) = i; gap();
            TRIG_HI;
            SCA_BARRETT_K(u, p_red_s0[i]);
            SCA_BARRETT_K(v, p_red_s1[i]);
            TRIG_LO;
            sink = u + v; gap();
        }
        MBOX(3) = 0xB0A5D005u;

        /* ---- block 6: protected AND ----------------------------------- */
        MBOX(0) = 6u;
        for (uint32_t i = 0; i < NTRACE; i++) {
            MBOX(2) = i; gap();
            TRIG_HI;
            SCA_AND_LATCH(u, p_and_a0[i], p_and_b1[i]);
            SCA_AND_REUSE(v, p_and_a1[i], p_and_b0[i]);
            TRIG_LO;
            sink = u ^ v; gap();
        }
        MBOX(3) = 0xB0A5D006u;
    }
}
