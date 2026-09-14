/* =========================================================================
 * crt0.S -- Minimal startup for Greyhound SoC (CV32E40X, RV32IMAC)
 *
 * Memory: 256KB SRAM at 0x10000000 .. 0x1003FFFF
 * Boot:   CPU fetches from 0x10000080 (BootAddr in soc_pkg)
 * Stack:  top of SRAM at 0x1000FFF0 (grows downward)
 *
 * This file sets up the stack pointer, zeroes .bss, and calls main().
 * ========================================================================= */

    /* ---- Trap vector at mtvec (0x10000000) ---- */
    .section .vectors, "ax"
    .globl _vectors
_vectors:
    j       _start      /* All traps jump to _start (simple reset handler) */

    /* ---- Entry point at BootAddr (0x10000080) ---- */
    .section .init, "ax"
    .globl _start
    .type  _start, @function

_start:
    /* ---- Disable interrupts ---- */
    csrci   mstatus, 0x8       /* MIE = 0 */

    /* ---- Set stack pointer to top of 256KB SRAM ---- */
    /* SRAM 0x10000080 .. 0x1003FFFF (LENGTH 0x3FF80). Stack grows down from
     * just under the top of the enlarged 256 KB region so the combined image's
     * larger .bss (all primitives' statics coexist) cannot collide with it. */
    lui     sp, %hi(0x1000FFF0)
    addi    sp, sp, %lo(0x1000FFF0)
    /* Align to 16 bytes (RISC-V ABI) */
    andi    sp, sp, -16

    /* ---- Set global pointer (if used) ---- */
    .option push
    .option norelax
    la      gp, __global_pointer$
    .option pop

    /* ---- Zero .bss section ---- */
    la      t0, __bss_start
    la      t1, __bss_end
1:
    bge     t0, t1, 2f
    sw      zero, 0(t0)
    addi    t0, t0, 4
    j       1b
2:

    /* ---- Call main() ---- */
    jal     ra, main

    /* ---- If main returns, spin forever ---- */
3:
    wfi
    j       3b

    .size _start, . - _start
