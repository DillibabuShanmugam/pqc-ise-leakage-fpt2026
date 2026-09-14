// Full-system profiling harness: CV32E40X + CV-X-IF + sca_pqc coprocessor on the
// CW305 top level. Clocks are driven from C++ so no SystemVerilog delays and no
// coroutine support are needed. The firmware is loaded by the design's own
// $readmemh from build/firmware_bram_init.hex, exactly as on the board.
#include "Vsca_pqc_cw305_top.h"
#include "verilated.h"
#include "verilated_fst_c.h"
#include <cstdio>
#include <cstdlib>
int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Verilated::traceEverOn(true);
    long long ncyc   = (argc > 1) ? atoll(argv[1]) : 200000;
    const char* fst  = (argc > 2) ? argv[2] : "e40x_profile.fst";
    long long tstart = (argc > 3) ? atoll(argv[3]) : 0;      // start tracing here
    auto* dut = new Vsca_pqc_cw305_top;
    auto* tfp = new VerilatedFstC;
    dut->trace(tfp, 99);
    tfp->open(fst);
    dut->rst_n = 0; dut->j16_sel = 0; dut->k16_sel = 1;
    dut->k15_sel = 1;                    // fetch enable, as DIP K15 on the board
    dut->l14_sel = 0; dut->uart_rx_i = 1;
    dut->jtag_tck_i = 0; dut->jtag_tms_i = 0; dut->jtag_tdi_i = 0; dut->jtag_trst_ni = 1;
    dut->usb_addr = 0; dut->usb_rdn = 1; dut->usb_wrn = 1; dut->usb_cen = 1; dut->usb_alen = 0;
    dut->tio_clkin = 0; dut->usb_clk = 0; dut->pll_clk1 = 0;
    vluint64_t t = 0;
    auto half = [&](void) {
        dut->pll_clk1 = !dut->pll_clk1;
        dut->tio_clkin = dut->pll_clk1;
        dut->usb_clk = !dut->usb_clk;
        dut->eval();
        if ((long long)t >= tstart) tfp->dump(t);
        t++;
    };
    for (int i = 0; i < 40; i++) { half(); half(); }
    dut->rst_n = 1;
    for (long long c = 0; c < ncyc; c++) { half(); half(); }
    tfp->close();
    printf("[TB] ran %lld cycles, trace from %lld\n", ncyc, tstart);
    delete dut;
    return 0;
}
