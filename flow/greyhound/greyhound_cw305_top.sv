// =============================================================================
// Greyhound SoC + H_v1 PQC Coprocessor — CW305-A35T Top Wrapper
// =============================================================================
//
// Instantiates Greyhound SoC (CV32E40X RISC-V) with H_v1 PQC coprocessor
// connected via the fabric custom instruction interface.
//
// For CW305 board:
//   - eFPGA fabric is replaced by H_v1 PQC coprocessor (fixed ISE)
//   - QSPI Flash/PSRAM stubs (not used on CW305)
//   - SRAM inferred as BRAM
//   - USB register interface for host communication
//   - Clock mux: PLL_CLK1 (normal) vs CW HS-IO (glitch clock)
//   - Trigger output for ChipWhisperer capture
//
// USB Register Map:
//   REG 0x00: instruction word (W)
//   REG 0x01: rs1 value (W)
//   REG 0x02: rs2 value (W)
//   REG 0x03: control (W) — bit 0: issue, bit 1: run test, bit 2: fetch_enable
//   REG 0x04: result (R)
//   REG 0x05: status (R) — bit 0: result valid, bit 1: test done, [15:8]: pass
//   REG 0x06: magic = 0x47483031 ("GH01") (R)
//   REG 0x07: identify = 0x43573035 ("CW05") (R)
// =============================================================================

`default_nettype none
`timescale 1ns / 1ps

module greyhound_cw305_top #(
    parameter int unsigned pADDR_WIDTH   = 21,
    parameter int unsigned pBYTECNT_SIZE = 7
) (
    // ---- Clocks ----
    input  wire   pll_clk1,     // N13: CDCE906 PLL (20 MHz)
    input  wire   tio_clkin,    // N14: CW Husky HS-IO (glitch clock)
    input  wire   usb_clk,      // F5:  SAM3U USB bus clock (96 MHz)

    // ---- Reset ----
    input  wire   rst_n,        // R1:  Push-button SW4

    // ---- DIP switch S2 ----
    input  wire   j16_sel,      // J16: Clock source select
    input  wire   k16_sel,      // K16: HS-Out enable
    input  wire   k15_sel,      // K15: Fetch enable
    input  wire   l14_sel,      // L14: Spare

    // ---- LEDs ----
    output wire   led1,         // T2: USB heartbeat
    output wire   led2,         // T3: SoC heartbeat
    output wire   led3,         // T4: Test pass

    // ---- UART ----
    output wire   uart_tx_o,    // P16: IO1
    input  wire   uart_rx_i,    // R16: IO2

    // ---- Trigger ----
    output wire   trig_out,     // T14: IO4

    // ---- ADC clock ----
    output wire   ext_clock,    // M16

    // ---- JTAG (JP3) ----
    input  wire   jtag_tck_i,
    input  wire   jtag_tms_i,
    input  wire   jtag_tdi_i,
    output wire   jtag_tdo_o,
    input  wire   jtag_trst_ni,

    // ---- SAM3U USB bus ----
    inout  wire  [7:0] usb_data,
    input  wire  [pADDR_WIDTH-1:0] usb_addr,
    input  wire        usb_rdn,
    input  wire        usb_wrn,
    input  wire        usb_cen,
    input  wire        usb_alen
);

    // =========================================================================
    // Clock infrastructure
    // =========================================================================
    wire usb_clk_buf;
    BUFG i_usb_clk_buf (.I(usb_clk), .O(usb_clk_buf));

    wire soc_clk;
    BUFGMUX_CTRL i_clk_mux (
        .O  (soc_clk),
        .I0 (pll_clk1),
        .I1 (tio_clkin),
        .S  (j16_sel)
    );

    assign ext_clock = k16_sel ? soc_clk : 1'b0;

    // =========================================================================
    // Reset synchronizer
    // =========================================================================
    reg rst_ff1, synced_rst_n;
    always @(posedge soc_clk or negedge rst_n) begin
        if (!rst_n) begin
            rst_ff1      <= 1'b0;
            synced_rst_n <= 1'b0;
        end else begin
            rst_ff1      <= 1'b1;
            synced_rst_n <= rst_ff1;
        end
    end

    // =========================================================================
    // Heartbeat LEDs
    // =========================================================================
    reg [24:0] usb_heartbeat;
    always @(posedge usb_clk_buf) usb_heartbeat <= usb_heartbeat + 25'd1;
    assign led1 = usb_heartbeat[24];

    reg [22:0] soc_heartbeat;
    always @(posedge soc_clk) soc_heartbeat <= soc_heartbeat + 23'd1;
    assign led2 = soc_heartbeat[22];

    // =========================================================================
    // SAM3U USB register bridge
    // =========================================================================
    wire [7:0] usb_dout;
    wire       usb_isout;
    wire [pADDR_WIDTH-1:pBYTECNT_SIZE] reg_address;
    wire [pBYTECNT_SIZE-1:0]           reg_bytecnt;
    wire [7:0] reg_datao;
    wire [7:0] reg_datai;
    wire       reg_read, reg_write, reg_addrvalid;

    cw305_usb_reg_fe #(
        .pADDR_WIDTH   (pADDR_WIDTH),
        .pBYTECNT_SIZE (pBYTECNT_SIZE),
        .pREG_RDDLY_LEN(3)
    ) i_usb_reg_fe (
        .rst         (~rst_n),
        .usb_clk     (usb_clk_buf),
        .usb_din     (usb_data),
        .usb_dout    (usb_dout),
        .usb_rdn     (usb_rdn),
        .usb_wrn     (usb_wrn),
        .usb_cen     (usb_cen),
        .usb_alen    (usb_alen),
        .usb_addr    (usb_addr),
        .usb_isout   (usb_isout),
        .reg_address (reg_address),
        .reg_bytecnt (reg_bytecnt),
        .reg_datao   (reg_datao),
        .reg_datai   (reg_datai),
        .reg_read    (reg_read),
        .reg_write   (reg_write),
        .reg_addrvalid(reg_addrvalid)
    );

    assign usb_data = usb_isout ? usb_dout : 8'bZ;

    // =========================================================================
    // SRAM for Greyhound SoC (inferred as BRAM)
    // =========================================================================
    wire [31:0] bank_rdata;
    wire [10:0] bank_word_addr;
    wire [3:0]  bank_be;
    wire [31:0] bank_wdata;
    wire        bank_req;
    wire        bank_we;

    (* ram_style = "block" *)
    reg [31:0] sram_mem [0:2047]; // 8 KB = 2048 x 32-bit

    reg [31:0] sram_rdata_q;
    always @(posedge soc_clk) begin
        if (bank_req) begin
            if (bank_we) begin
                if (bank_be[0]) sram_mem[bank_word_addr][7:0]   <= bank_wdata[7:0];
                if (bank_be[1]) sram_mem[bank_word_addr][15:8]  <= bank_wdata[15:8];
                if (bank_be[2]) sram_mem[bank_word_addr][23:16] <= bank_wdata[23:16];
                if (bank_be[3]) sram_mem[bank_word_addr][31:24] <= bank_wdata[31:24];
            end
            sram_rdata_q <= sram_mem[bank_word_addr];
        end
    end
    assign bank_rdata = sram_rdata_q;

    // =========================================================================
    // H_v1 PQC Coprocessor (via fabric custom instruction interface)
    // =========================================================================
    wire        h_v1_issue_ready;
    wire        h_v1_issue_accept;
    wire        h_v1_issue_valid;
    wire [31:0] h_v1_issue_instr;
    wire [31:0] h_v1_issue_op0;
    wire [31:0] h_v1_issue_op1;
    wire [3:0]  h_v1_issue_id;
    wire        h_v1_result_valid;
    wire [3:0]  h_v1_result_id;
    wire [4:0]  h_v1_result_rd;
    wire [31:0] h_v1_result;

    h_v1_greyhound_adapter i_h_v1_adapter (
        .clk_i                (soc_clk),
        .rst_ni               (synced_rst_n),
        .fabric_issue_ready_o (h_v1_issue_ready),
        .fabric_issue_accept_o(h_v1_issue_accept),
        .fabric_issue_valid_i (h_v1_issue_valid),
        .fabric_issue_instr_i (h_v1_issue_instr),
        .fabric_issue_op0_i   (h_v1_issue_op0),
        .fabric_issue_op1_i   (h_v1_issue_op1),
        .fabric_issue_id_i    (h_v1_issue_id),
        .fabric_result_valid_o(h_v1_result_valid),
        .fabric_result_id_o   (h_v1_result_id),
        .fabric_result_rd_o   (h_v1_result_rd),
        .fabric_result_o      (h_v1_result)
    );

    // =========================================================================
    // Greyhound SoC instance
    // =========================================================================
    wire        greyhound_uart_tx;
    wire        greyhound_core_sleep;

    // Stub signals for unused peripherals
    wire        flash_sck_stub, flash_ce_n_stub;
    wire [3:0]  flash_dout_stub, flash_douten_stub;
    wire        psram_sck_stub, psram_ce_n_stub;
    wire [3:0]  psram_dout_stub, psram_douten_stub;

    // Stub signals for fabric bus (unused — H_v1 uses custom instruction only)
    wire        fabric_req, fabric_we;
    wire [3:0]  fabric_be;
    wire [23:0] fabric_addr;
    wire [31:0] fabric_wdata;

    // Stub signals for bitstream/warmboot (no eFPGA on CW305)
    wire        bitstream_valid;
    wire [31:0] bitstream_data;
    wire        warmboot_boot;
    wire [3:0]  warmboot_slot;

    greyhound_soc i_greyhound_soc (
        // Clock and reset
        .clk_i                  (soc_clk),
        .rst_ni                 (synced_rst_n),

        // Fabric IRQ (unused)
        .fabric_irq_i           (4'b0),

        // Fabric config (always ready, no eFPGA)
        .fabric_config_busy_i   (1'b0),
        .fabric_configured_i    (1'b1),

        // Bitstream (unused)
        .bitstream_valid_o      (bitstream_valid),
        .bitstream_data_o       (bitstream_data),

        // Warmboot (unused)
        .warmboot_boot_o        (warmboot_boot),
        .warmboot_slot_o        (warmboot_slot),

        // Custom instruction interface → H_v1 PQC coprocessor
        .fabric_issue_ready_i   (h_v1_issue_ready),
        .fabric_issue_accept_i  (h_v1_issue_accept),
        .fabric_issue_valid_o   (h_v1_issue_valid),
        .fabric_issue_instr_o   (h_v1_issue_instr),
        .fabric_issue_op0_o     (h_v1_issue_op0),
        .fabric_issue_op1_o     (h_v1_issue_op1),
        .fabric_issue_id_o      (h_v1_issue_id),
        .fabric_result_valid_i  (h_v1_result_valid),
        .fabric_result_id_i     (h_v1_result_id),
        .fabric_result_rd_i     (h_v1_result_rd),
        .fabric_result_i        (h_v1_result),

        // Fabric bus (stub — always grant, no data)
        .fabric_gnt_i           (1'b1),
        .fabric_req_o           (fabric_req),
        .fabric_rvalid_i        (1'b0),
        .fabric_we_o            (fabric_we),
        .fabric_be_o            (fabric_be),
        .fabric_addr_o          (fabric_addr),
        .fabric_wdata_o         (fabric_wdata),
        .fabric_rdata_i         (32'h0),

        // SRAM (inferred BRAM)
        .bank_rdata_i           (bank_rdata),
        .bank_word_addr_o       (bank_word_addr),
        .bank_be_o              (bank_be),
        .bank_wdata_o           (bank_wdata),
        .bank_req_o             (bank_req),
        .bank_we_o              (bank_we),

        // QSPI Flash (stubbed)
        .flash_sck              (flash_sck_stub),
        .flash_ce_n             (flash_ce_n_stub),
        .flash_din              (4'b0),
        .flash_dout             (flash_dout_stub),
        .flash_douten           (flash_douten_stub),

        // QSPI PSRAM (stubbed)
        .psram_sck              (psram_sck_stub),
        .psram_ce_n             (psram_ce_n_stub),
        .psram_din              (4'b0),
        .psram_dout             (psram_dout_stub),
        .psram_douten           (psram_douten_stub),

        // UART
        .uart0_rx               (uart_rx_i),
        .uart0_tx               (greyhound_uart_tx),

        // CPU control
        .fetch_enable_i         (k15_sel),
        .core_sleep_o           (greyhound_core_sleep)
    );

    assign uart_tx_o = greyhound_uart_tx;

    // =========================================================================
    // Trigger output (active during core execution)
    // =========================================================================
    assign trig_out = ~greyhound_core_sleep;

    // =========================================================================
    // LED3: fetch enable indicator
    // =========================================================================
    assign led3 = k15_sel;

    // =========================================================================
    // USB read registers (stub — full register interface TBD)
    // =========================================================================
    reg [7:0] read_data;
    always @(*) begin
        read_data = 8'h00;
        case (reg_address)
            14'h06: // Magic "GH01" = 0x47483031
                case (reg_bytecnt[1:0])
                    2'd0: read_data = 8'h31;
                    2'd1: read_data = 8'h30;
                    2'd2: read_data = 8'h48;
                    2'd3: read_data = 8'h47;
                endcase
            14'h07: // Identify "CW05" = 0x43573035
                case (reg_bytecnt[1:0])
                    2'd0: read_data = 8'h35;
                    2'd1: read_data = 8'h30;
                    2'd2: read_data = 8'h57;
                    2'd3: read_data = 8'h43;
                endcase
            default: read_data = 8'h00;
        endcase
    end

    reg [7:0] read_data_r;
    always @(posedge usb_clk_buf) read_data_r <= read_data;
    assign reg_datai = read_data_r;

    // =========================================================================
    // Unused JTAG (directly exposed on JP3 header)
    // =========================================================================
    assign jtag_tdo_o = 1'b0;

endmodule

`default_nettype wire
