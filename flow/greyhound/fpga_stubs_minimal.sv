// Minimal FPGA stubs — IHP-specific cells + UART clock gate bypass
// Xilinx primitives (BUFG, BUFGMUX_CTRL, etc.) are provided by synth_xilinx

// IHP SG13G2 clock gate → passthrough on FPGA
module sg13g2_lgcp_1 (input CLK, input GATE, output GCLK);
    assign GCLK = CLK;
endmodule

// EF_UART clock gate bypass for FPGA testing
// The ef_util_gating_cell in ef_util_lib.v uses CLKG_GENERIC (assign clk_o = clk & clk_en)
// which creates a gated clock that Yosys routes through LUT fabric instead of BUFGCE.
// This causes baud rate issues. Bypass it entirely for initial testing.
// TODO: Replace with BUFGCE-based proper clock gating for production.
module ef_util_gating_cell (
`ifdef USE_POWER_PINS
    input wire vpwr,
    input wire vgnd,
`endif
    input wire clk,
    input wire clk_en,
    output wire clk_o
);
    assign clk_o = clk;  // Bypass: UART always clocked (for testing)
endmodule
