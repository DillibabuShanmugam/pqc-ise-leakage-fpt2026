// FPGA stubs for IHP SG13G2 and Xilinx primitives
// Used by open-source synthesis flow for CW305 prototyping

// IHP SG13G2 latch-based clock gate (replaced with passthrough on FPGA)
module sg13g2_lgcp_1 (
    input  CLK,
    input  GATE,
    output GCLK
);
    // On FPGA, clock gating is disabled (passthrough)
    assign GCLK = CLK;
endmodule

// Xilinx BUFG
module BUFG (
    input  I,
    output O
);
    assign O = I;
endmodule

// Xilinx BUFGMUX_CTRL
module BUFGMUX_CTRL (
    input  I0, I1, S,
    output O
);
    assign O = S ? I1 : I0;
endmodule

// Override BUFGMUX -> simple mux (nextpnr-xilinx has a bug with BUFGMUX)
module BUFGMUX (
    input  I0, I1, S,
    output O
);
    assign O = S ? I1 : I0;
endmodule

// Clock cell stubs (replace tc_clk_xilinx.sv to avoid BUFGMUX primitive)
module tc_clk_and2 (input clk0_i, input clk1_i, output clk_o);
    assign clk_o = clk0_i & clk1_i;
endmodule
module tc_clk_buffer (input clk_i, output clk_o);
    assign clk_o = clk_i;
endmodule
module tc_clk_gating (input clk_i, input en_i, input test_en_i, output clk_o);
    assign clk_o = clk_i; // No gating on FPGA
endmodule
module tc_clk_inverter (input clk_i, output clk_o);
    assign clk_o = ~clk_i;
endmodule
module tc_clk_mux2 (input clk0_i, input clk1_i, input clk_sel_i, output clk_o);
    BUFGCTRL i_bufgctrl (
        .O(clk_o), .I0(clk0_i), .I1(clk1_i),
        .S0(~clk_sel_i), .S1(clk_sel_i),
        .CE0(1'b1), .CE1(1'b1), .IGNORE0(1'b0), .IGNORE1(1'b0)
    );
endmodule
module tc_clk_xor2 (input clk0_i, input clk1_i, output clk_o);
    assign clk_o = clk0_i ^ clk1_i;
endmodule
module tc_clk_or2 (input clk0_i, input clk1_i, output clk_o);
    assign clk_o = clk0_i | clk1_i;
endmodule

// =====================================================================
// tsim stubs 2026-05-16
// EF_PSRAM_CTRL_AHBL and EF_UART_AHBL are Verilog blackboxes from the
// OpenROAD/EF IP catalogue; their RTL is not vendored into this repo.
// Without these stubs Yosys silently drops the instance and ~60 wires
// (psram_HRDATA[31:0], psram_dout/douten, uart0_HRDATA[31:0], uart0_irq,
// HREADYOUT) become "used but no driver" warnings.  ML-KEM smoke does
// not exercise either peripheral, so a minimal AHB-not-ready / no-irq
// behavioural stub keeps the netlist clean without changing functional
// behaviour for the boot path.
// =====================================================================

module EF_PSRAM_CTRL_AHBL (
    input  logic        HCLK,
    input  logic        HRESETn,
    input  logic        HSEL,
    input  logic [31:0] HADDR,
    input  logic [31:0] HWDATA,
    input  logic [ 1:0] HTRANS,
    input  logic [ 2:0] HSIZE,
    input  logic        HWRITE,
    input  logic        HREADY,
    output logic        HREADYOUT,
    output logic [31:0] HRDATA,
    output logic        sck,
    output logic        ce_n,
    input  logic [ 3:0] din,
    output logic [ 3:0] dout,
    output logic [ 3:0] douten
);
    // AHB slave that always declares "ready" but returns 0xDEADBEEF (a
    // distinctive sentinel so that any accidental ML-KEM read from PSRAM
    // is obvious in the trace).  Drives all output side bands inactive.
    assign HREADYOUT = 1'b1;
    assign HRDATA    = 32'hDEADBEEF;
    assign sck       = 1'b0;
    assign ce_n      = 1'b1;
    assign dout      = 4'h0;
    assign douten    = 4'h0;
endmodule

module EF_UART_AHBL (
    input  logic        HCLK,
    input  logic        HRESETn,
    input  logic        HSEL,
    input  logic [31:0] HADDR,
    input  logic [31:0] HWDATA,
    input  logic [ 1:0] HTRANS,
    input  logic        HWRITE,
    input  logic        HREADY,
    output logic        HREADYOUT,
    output logic [31:0] HRDATA,
    output logic        IRQ,
    input  logic        rx,
    output logic        tx
);
    // AHB slave that always declares "ready", returns 0x00000000 for
    // reads (matches "UART RX FIFO empty + TX done" reset reading) and
    // never raises IRQ.  Drives tx idle-high.
    assign HREADYOUT = 1'b1;
    assign HRDATA    = 32'h00000000;
    assign IRQ       = 1'b0;
    assign tx        = 1'b1;
endmodule
