// ============================================================================
// SCA_Pro_PQC -- CW305 Top-Level Integration
// ============================================================================
//
// Structural wrapper integrating:
//   1. Greyhound SoC (external module, vendored separately)
//   2. SCA_PQC coprocessor via Greyhound fabric adapter
//   3. OBI A2B/B2A mask conversion peripheral (fabric 0x000-0x0FF)
//   4. OBI TRNG peripheral (fabric 0x100-0x1FF)
//
// CW305 target board connections:
//   - clk_i:        20 MHz input from CW305 PLL (directly or via MMCM)
//   - rst_ni:       Active-low reset (directly from CW305 pushbutton, active-low)
//   - uart_tx_o:    UART transmit to host
//   - uart_rx_i:    UART receive from host
//   - sca_trigger_o: SCA trigger output (directly to CW305 SMA connector)
//
// Memory map (fabric OBI bus, from CPU perspective):
//   0x5000_0000 .. 0x5000_00FF : A2B/B2A mask conversion
//   0x5000_0100 .. 0x5000_01FF : TRNG
//
// The Greyhound SoC presents a 24-bit fabric address bus. Bit [8] of the
// fabric address selects between A2B/B2A (0) and TRNG (1).
//
// ============================================================================

module greyhound_sca_pqc_cw305_top (
    // Clock and reset
    input  wire        clk_i,
    input  wire        rst_ni,

    // UART
    output wire        uart_tx_o,
    input  wire        uart_rx_i,

    // SCA trigger (directly to CW305 SMA)
    output wire        sca_trigger_o,

    // GPIO (directly to CW305 LEDs / headers)
    output wire [7:0]  gpio_o
);

    // ========================================================================
    // Internal wires: Greyhound fabric custom instruction interface (ISE)
    // ========================================================================
    wire        fabric_issue_valid;
    wire [31:0] fabric_issue_instr;
    wire [31:0] fabric_issue_op0;
    wire [31:0] fabric_issue_op1;
    wire [3:0]  fabric_issue_id;
    wire        fabric_issue_ready;
    wire        fabric_issue_accept;

    wire        fabric_result_valid;
    wire [3:0]  fabric_result_id;
    wire [4:0]  fabric_result_rd;
    wire [31:0] fabric_result_data;

    // ========================================================================
    // Internal wires: Greyhound fabric OBI bus (memory-mapped peripherals)
    // ========================================================================
    wire        fabric_req;
    wire        fabric_gnt;
    wire        fabric_rvalid;
    wire        fabric_we;
    wire [3:0]  fabric_be;
    wire [23:0] fabric_addr;
    wire [31:0] fabric_wdata;
    wire [31:0] fabric_rdata;

    // ========================================================================
    // Greyhound SoC instance (external module)
    // ========================================================================
    // The Greyhound SoC is vendored separately and provides:
    //   - RISC-V core with custom instruction extension interface
    //   - Internal SRAM, boot ROM, interrupt controller
    //   - UART, GPIO, timer peripherals
    //   - Fabric bus for external memory-mapped peripherals
    //   - Fabric custom instruction ports for ISE coprocessor
    //
    // Port list reference:
    //   .clk_i, .rst_ni
    //   .uart_tx_o, .uart_rx_i
    //   .gpio_o[7:0]
    //   .fabric_issue_valid_o, .fabric_issue_instr_o[31:0]
    //   .fabric_issue_op0_o[31:0], .fabric_issue_op1_o[31:0]
    //   .fabric_issue_id_o[3:0]
    //   .fabric_issue_ready_i, .fabric_issue_accept_i
    //   .fabric_result_valid_i, .fabric_result_id_i[3:0]
    //   .fabric_result_rd_i[4:0], .fabric_result_i[31:0]
    //   .fabric_req_o, .fabric_gnt_i, .fabric_rvalid_i
    //   .fabric_we_o, .fabric_be_o[3:0], .fabric_addr_o[23:0]
    //   .fabric_wdata_o[31:0], .fabric_rdata_i[31:0]
    //   .sca_trigger_o

    greyhound_soc i_greyhound_soc (
        .clk_i                  (clk_i),
        .rst_ni                 (rst_ni),

        // UART
        .uart_tx_o              (uart_tx_o),
        .uart_rx_i              (uart_rx_i),

        // GPIO
        .gpio_o                 (gpio_o),

        // SCA trigger
        .sca_trigger_o          (sca_trigger_o),

        // Fabric custom instruction interface (to ISE coprocessor)
        .fabric_issue_valid_o   (fabric_issue_valid),
        .fabric_issue_instr_o   (fabric_issue_instr),
        .fabric_issue_op0_o     (fabric_issue_op0),
        .fabric_issue_op1_o     (fabric_issue_op1),
        .fabric_issue_id_o      (fabric_issue_id),
        .fabric_issue_ready_i   (fabric_issue_ready),
        .fabric_issue_accept_i  (fabric_issue_accept),
        .fabric_result_valid_i  (fabric_result_valid),
        .fabric_result_id_i     (fabric_result_id),
        .fabric_result_rd_i     (fabric_result_rd),
        .fabric_result_i        (fabric_result_data),

        // Fabric OBI bus (to memory-mapped peripherals)
        .fabric_req_o           (fabric_req),
        .fabric_gnt_i           (fabric_gnt),
        .fabric_rvalid_i        (fabric_rvalid),
        .fabric_we_o            (fabric_we),
        .fabric_be_o            (fabric_be),
        .fabric_addr_o          (fabric_addr),
        .fabric_wdata_o         (fabric_wdata),
        .fabric_rdata_i         (fabric_rdata)
    );

    // ========================================================================
    // SCA_PQC ISE Coprocessor (via Greyhound fabric adapter)
    // ========================================================================

    sca_pqc_greyhound_adapter i_sca_pqc_adapter (
        .clk_i                  (clk_i),
        .rst_ni                 (rst_ni),

        // Greyhound fabric custom instruction interface
        .fabric_issue_ready_o   (fabric_issue_ready),
        .fabric_issue_accept_o  (fabric_issue_accept),
        .fabric_issue_valid_i   (fabric_issue_valid),
        .fabric_issue_instr_i   (fabric_issue_instr),
        .fabric_issue_op0_i     (fabric_issue_op0),
        .fabric_issue_op1_i     (fabric_issue_op1),
        .fabric_issue_id_i      (fabric_issue_id),

        .fabric_result_valid_o  (fabric_result_valid),
        .fabric_result_id_o     (fabric_result_id),
        .fabric_result_rd_o     (fabric_result_rd),
        .fabric_result_o        (fabric_result_data)
    );

    // ========================================================================
    // OBI Address Demux: fabric_addr[8] selects peripheral
    //   0 = A2B/B2A (0x000-0x0FF)
    //   1 = TRNG    (0x100-0x1FF)
    // ========================================================================

    wire periph_sel = fabric_addr[8]; // 0 = A2B/B2A, 1 = TRNG

    // --- A2B/B2A OBI signals ---
    wire        a2b_req;
    wire        a2b_gnt;
    wire        a2b_rvalid;
    wire [31:0] a2b_rdata;

    // --- TRNG OBI signals ---
    wire        trng_req;
    wire        trng_gnt;
    wire        trng_rvalid;
    wire [31:0] trng_rdata;

    // Demux request: route to selected peripheral
    assign a2b_req  = fabric_req & ~periph_sel;
    assign trng_req = fabric_req &  periph_sel;

    // Mux grant back to fabric
    assign fabric_gnt = periph_sel ? trng_gnt : a2b_gnt;

    // Track which peripheral was selected when request was granted, so we
    // return rvalid and rdata from the correct source one cycle later.
    reg periph_sel_q;

    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni)
            periph_sel_q <= 1'b0;
        else if (fabric_req && fabric_gnt)
            periph_sel_q <= periph_sel;
    end

    // Mux rvalid and rdata from the peripheral that was granted
    assign fabric_rvalid = periph_sel_q ? trng_rvalid : a2b_rvalid;
    assign fabric_rdata  = periph_sel_q ? trng_rdata  : a2b_rdata;

    // ========================================================================
    // OBI A2B/B2A Mask Conversion Peripheral (0x000-0x0FF)
    // ========================================================================

    obi_a2b_b2a_peripheral i_a2b_b2a (
        .clk_i      (clk_i),
        .rst_ni     (rst_ni),

        // OBI target interface
        .obi_req_i  (a2b_req),
        .obi_gnt_o  (a2b_gnt),
        .obi_rvalid_o(a2b_rvalid),
        .obi_we_i   (fabric_we),
        .obi_be_i   (fabric_be),
        .obi_addr_i ({24'd0, fabric_addr[7:0]}),  // pad to 32-bit
        .obi_wdata_i(fabric_wdata),
        .obi_rdata_o(a2b_rdata)
    );

    // ========================================================================
    // OBI TRNG Peripheral (0x100-0x1FF)
    // ========================================================================

    // trng_intr_o is directly exposed from the TRNG module. Currently unused
    // in the CW305 integration (no interrupt controller on the fabric bus).
    // Tie off here; route to an interrupt controller in future revisions.
    wire trng_intr;  // future: connect to interrupt controller

    obi_trng i_trng (
        .clk_i      (clk_i),
        .rst_ni     (rst_ni),

        // OBI target interface
        .obi_req_i  (trng_req),
        .obi_gnt_o  (trng_gnt),
        .obi_rvalid_o(trng_rvalid),
        .obi_we_i   (fabric_we),
        .obi_addr_i ({24'd0, fabric_addr[7:0]}),  // pad to 32-bit
        .obi_wdata_i(fabric_wdata),
        .obi_rdata_o(trng_rdata),

        // Interrupt (unused in CW305; for future interrupt support)
        .trng_intr_o(trng_intr)
    );

endmodule
