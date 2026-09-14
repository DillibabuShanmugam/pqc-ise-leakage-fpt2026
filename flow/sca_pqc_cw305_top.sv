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

module sca_pqc_cw305_top #(
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
    wire [15:0] bank_word_addr;  // 16 bits for 256KB (65536 words) — combined firmware
    wire [3:0]  bank_be;
    wire [31:0] bank_wdata;
    wire        bank_req;
    wire        bank_we;

    // 256 KB SRAM for code + data. Sized to hold the COMBINED multi-primitive
    // firmware (ML-KEM + masked ML-KEM + ML-DSA + masked ML-DSA + AES) selected
    // at run time via the host mailbox. CPU boots from BootAddr, mapped here.
    (* ram_style = "block" *)
    reg [31:0] sram_mem [0:16383]; // 64 KB = 16384 x 32-bit
    // Halved from 65536: at 64K depth yosys maps the array onto CASCADE-linked
    // RAMB36 pairs, and nextpnr places the two halves non-adjacently, which the
    // cascade path cannot route. 32K depth maps one block per column, no cascade.
    // The profiling firmware is 13,264 words, so this is 2.5x headroom.

    // Initialize SRAM with firmware (Makefile writes this path)
    initial begin
        $readmemh("build/firmware_bram_init.hex", sram_mem);
    end

    reg [31:0] sram_rdata_q;
    always @(posedge soc_clk) begin
        if (bank_req) begin
            if (bank_we) begin
                if (bank_be[0]) sram_mem[bank_word_addr[13:0]][7:0]   <= bank_wdata[7:0];
                if (bank_be[1]) sram_mem[bank_word_addr[13:0]][15:8]  <= bank_wdata[15:8];
                if (bank_be[2]) sram_mem[bank_word_addr[13:0]][23:16] <= bank_wdata[23:16];
                if (bank_be[3]) sram_mem[bank_word_addr[13:0]][31:24] <= bank_wdata[31:24];
            end
            sram_rdata_q <= sram_mem[bank_word_addr[13:0]];
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

    sca_pqc_greyhound_adapter i_sca_pqc_adapter (
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

    // Fabric bus signals → OBI peripherals
    wire        fabric_req, fabric_we;
    wire [3:0]  fabric_be;
    wire [23:0] fabric_addr;
    wire [31:0] fabric_wdata;
    wire        fabric_gnt, fabric_rvalid;
    wire [31:0] fabric_rdata;

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

        // Fabric bus → OBI peripherals (A2B/B2A + TRNG)
        .fabric_gnt_i           (fabric_gnt),
        .fabric_req_o           (fabric_req),
        .fabric_rvalid_i        (fabric_rvalid),
        .fabric_we_o            (fabric_we),
        .fabric_be_o            (fabric_be),
        .fabric_addr_o          (fabric_addr),
        .fabric_wdata_o         (fabric_wdata),
        .fabric_rdata_i         (fabric_rdata),

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
    // OBI Fabric Bus Peripherals (loosely coupled)
    // Address demux: fabric_addr[8] selects peripheral
    //   0x000-0x0FF → A2B/B2A mask conversion
    //   0x100-0x1FF → TRNG
    // =========================================================================
    wire periph_sel = fabric_addr[8];
    wire a2b_req  = fabric_req & ~periph_sel;
    wire trng_req = fabric_req &  periph_sel;

    wire a2b_gnt, a2b_rvalid;
    wire [31:0] a2b_rdata;

    obi_a2b_b2a_peripheral i_a2b_b2a (
        .clk_i       (soc_clk),
        .rst_ni      (synced_rst_n),
        .obi_req_i   (a2b_req),
        .obi_gnt_o   (a2b_gnt),
        .obi_addr_i  ({24'd0, fabric_addr[7:0]}),
        .obi_we_i    (fabric_we),
        .obi_be_i    (fabric_be),
        .obi_wdata_i (fabric_wdata),
        .obi_rvalid_o(a2b_rvalid),
        .obi_rdata_o (a2b_rdata)
    );

    // TRNG removed for v1 bitstream (causes combinational loops from ROs).
    // PRNG seeded from host via UART/USB in v1.
    // TRNG will be added in v2 with proper RO placement constraints.

    // =========================================================================
    // Diagnostics: SoC-clock heartbeat and board switch state
    //
    // The heartbeat counts on soc_clk and is cleared only by the raw reset pin,
    // so a non-zero, advancing value proves the SoC clock is live independently
    // of whether the processor has been released. The status byte exposes the
    // user switches and both reset levels, which are otherwise invisible to the
    // host. Both are read across the USB clock domain without synchronisers, so
    // a single read may tear; only movement between reads is meaningful.
    // =========================================================================
    reg [31:0] soc_hb_diag;
    always @(posedge soc_clk or negedge rst_n) begin
        if (!rst_n) soc_hb_diag <= 32'h0;
        else        soc_hb_diag <= soc_hb_diag + 32'h1;
    end

    wire [7:0] board_status = {1'b0, greyhound_core_sleep, rst_n, synced_rst_n,
                               l14_sel, k15_sel, k16_sel, j16_sel};

    // =========================================================================
    // CPU→USB Mailbox (firmware writes, host reads via fpga_read)
    // Fabric bus address 0x50000200-0x50000210 → mailbox registers
    // USB reads at reg 0x0B (mailbox[0]), 0x0C (mailbox[1]), etc.
    // =========================================================================
    wire mailbox_sel = fabric_addr[9];  // bit 9 = 0x200 offset
    wire mailbox_req = fabric_req & mailbox_sel;
    wire mailbox_gnt = mailbox_req;  // always grant

    reg        mailbox_rvalid;
    reg [31:0] mailbox_rdata;
    reg [31:0] mailbox_reg [0:3];  // 4 mailbox registers

    always @(posedge soc_clk or negedge synced_rst_n) begin
        if (!synced_rst_n) begin
            mailbox_rvalid <= 1'b0;
            mailbox_reg[0] <= 32'h0;
            mailbox_reg[1] <= 32'h0;
            mailbox_reg[2] <= 32'h0;
            mailbox_reg[3] <= 32'h0;
        end else begin
            mailbox_rvalid <= mailbox_req;
            if (mailbox_req && fabric_we) begin
                mailbox_reg[fabric_addr[3:2]] <= fabric_wdata;
            end
            mailbox_rdata <= mailbox_reg[fabric_addr[3:2]];
        end
    end

    // Route A2B/B2A requests (bit 9 = 0) vs mailbox (bit 9 = 1)
    wire a2b_req_gated = fabric_req & ~mailbox_sel & ~fabric_addr[8];

    // OBI response mux: A2B/B2A or mailbox
    reg periph_sel_q;
    always @(posedge soc_clk or negedge synced_rst_n) begin
        if (!synced_rst_n) periph_sel_q <= 1'b0;
        else if (fabric_req) periph_sel_q <= mailbox_sel;
    end

    assign fabric_gnt    = mailbox_sel ? mailbox_gnt : a2b_gnt;
    assign fabric_rvalid = periph_sel_q ? mailbox_rvalid : a2b_rvalid;
    assign fabric_rdata  = periph_sel_q ? mailbox_rdata : a2b_rdata;

    // =========================================================================
    // Trigger output: TIO4 driven by MBOX[1] bit 0.  Firmware writes
    // MBOX(1) = 1 immediately before verify(ct,ct') and MBOX(1) = 0
    // immediately after, giving CW-Lite a clean per-decap rising edge.
    // Previous wiring (~greyhound_core_sleep) was a coarse "CPU awake"
    // indicator -- it never fell during free-running decaps so the scope
    // never saw an edge.
    // =========================================================================
    assign trig_out = mailbox_reg[1][0];

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
            14'h06: // Magic "SP01" = 0x47483031
                case (reg_bytecnt[1:0])
                    2'd0: read_data = 8'h31;
                    2'd1: read_data = 8'h30;
                    2'd2: read_data = 8'h50;
                    2'd3: read_data = 8'h53;
                endcase
            14'h07: // Identify "CW05" = 0x43573035
                case (reg_bytecnt[1:0])
                    2'd0: read_data = 8'h35;
                    2'd1: read_data = 8'h30;
                    2'd2: read_data = 8'h57;
                    2'd3: read_data = 8'h43;
                endcase
            14'h0A: // Debug: CPU core_sleep status
                case (reg_bytecnt[1:0])
                    2'd0: read_data = {7'b0, greyhound_core_sleep};
                    2'd1: read_data = 8'hDE;  // sentinel
                    2'd2: read_data = 8'hAD;
                    2'd3: read_data = 8'h42;
                endcase
            14'h0B: // Mailbox[0] — firmware writes to 0x50000200
                case (reg_bytecnt[1:0])
                    2'd0: read_data = mailbox_reg[0][7:0];
                    2'd1: read_data = mailbox_reg[0][15:8];
                    2'd2: read_data = mailbox_reg[0][23:16];
                    2'd3: read_data = mailbox_reg[0][31:24];
                endcase
            14'h0C: // Mailbox[1] — firmware writes to 0x50000204
                case (reg_bytecnt[1:0])
                    2'd0: read_data = mailbox_reg[1][7:0];
                    2'd1: read_data = mailbox_reg[1][15:8];
                    2'd2: read_data = mailbox_reg[1][23:16];
                    2'd3: read_data = mailbox_reg[1][31:24];
                endcase
            14'h0D: // Mailbox[2] — firmware writes to 0x50000208
                case (reg_bytecnt[1:0])
                    2'd0: read_data = mailbox_reg[2][7:0];
                    2'd1: read_data = mailbox_reg[2][15:8];
                    2'd2: read_data = mailbox_reg[2][23:16];
                    2'd3: read_data = mailbox_reg[2][31:24];
                endcase
            14'h0E: // Mailbox[3] — firmware writes to 0x5000020C
                case (reg_bytecnt[1:0])
                    2'd0: read_data = mailbox_reg[3][7:0];
                    2'd1: read_data = mailbox_reg[3][15:8];
                    2'd2: read_data = mailbox_reg[3][23:16];
                    2'd3: read_data = mailbox_reg[3][31:24];
                endcase
            14'h0F: // SoC-clock heartbeat (advances only if soc_clk runs)
                case (reg_bytecnt[1:0])
                    2'd0: read_data = soc_hb_diag[7:0];
                    2'd1: read_data = soc_hb_diag[15:8];
                    2'd2: read_data = soc_hb_diag[23:16];
                    2'd3: read_data = soc_hb_diag[31:24];
                endcase
            14'h10: // board status: switches and resets
                case (reg_bytecnt[1:0])
                    2'd0: read_data = board_status;
                    2'd1: read_data = 8'hB0;
                    2'd2: read_data = 8'hA5;
                    2'd3: read_data = 8'hD1;
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
