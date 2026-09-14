// ============================================================================
// obi_keccak_masked : flat-OBI MMIO wrapper around the first-order DOM masked
// Keccak-f[1600] core (keccak_f_masked). Clones obi_keccak_f's register map and
// OBI handshake, adding masking control.
//
// SHARES ARE BORN IN HARDWARE (preferred model, mirrors hw_masked_proof):
// the host writes the PLAIN 1600-bit state as 50 little-endian 32-bit words; on
// start the unit splits it into two Boolean shares using an on-chip input-mask
// PRNG (seeded by SEED) -> Din1 = mask, Din0 = plain ^ mask. The plain state and
// the unmasked output never coexist on the bus while masking is active in a way
// the host must recombine; the host only ever sees plain in / plain out.
//
// Register Map (low 12 bits of OBI address; word granular):
//   0x000 .. 0x0C4   STATE  [R/W]  50 x 32b PLAIN state words (k = addr>>2)
//                            write : load STATE_IN word k (plain)
//                            read  : UNMASKED result word k = (Dout0^Dout1)[k]
//                                    (recombined in HW; SIM/functional check)
//   0x100            CTRL   [W]    bit0 = start, bit1 = mask_en
//   0x104            STATUS [R]    bit0 = done
//   0x108            SEED   [W]    PRNG seed (sample at start)
//   0x200 .. 0x2C4   STATE0 [R]    share-0 output words (Dout0)  [observability]
//   0x300 .. 0x3C4   STATE1 [R]    share-1 output words (Dout1)  [observability]
//
// While busy, STATE writes are ignored so Din stays stable under the running core.
//
// OBI protocol: gnt = req (single-cycle addr phase); rvalid registered one cycle
// later; rdata combinational from latched addr (matches obi_keccak_f).
//
// Integration note (NOT done here): to make this reachable from firmware, add an
// instance in rtl/croc/user_domain.sv exactly like the obi_keccak_f / A2B
// adapters (carve a UserBaseAddr+offset slot in user_pkg.sv and route the OBI
// demux). No user_domain.sv / user_pkg.sv edits are made in this change set.
// ============================================================================

module obi_keccak_masked (
  input  wire        clk_i,
  input  wire        rst_ni,

  // OBI slave interface (flat)
  input  wire        obi_req_i,
  output wire        obi_gnt_o,
  input  wire [31:0] obi_addr_i,
  input  wire        obi_we_i,
  input  wire [3:0]  obi_be_i,
  input  wire [31:0] obi_wdata_i,
  output reg         obi_rvalid_o,
  output reg  [31:0] obi_rdata_o
);

  localparam int unsigned NWORDS = 50; // 50 x 32b = 1600b

  wire [11:0] reg_addr  = obi_addr_i[11:0];
  wire        is_state  = (reg_addr < 12'h0C8);             // 0x000..0x0C7 -> plain in / unmasked out
  wire        is_state0 = (reg_addr >= 12'h200) && (reg_addr < 12'h2C8); // share0 out
  wire        is_state1 = (reg_addr >= 12'h300) && (reg_addr < 12'h3C8); // share1 out
  wire [5:0]  word_idx  = reg_addr[7:2];                    // 0..49

  localparam [11:0] ADDR_CTRL   = 12'h100;
  localparam [11:0] ADDR_STATUS = 12'h104;
  localparam [11:0] ADDR_SEED   = 12'h108;

  assign obi_gnt_o = obi_req_i;

  // -------------------------------------------------------------------------
  // Latched request for response phase
  // -------------------------------------------------------------------------
  reg         req_pending_q;
  reg [11:0]  req_addr_q;
  reg         req_we_q;
  reg [5:0]   req_word_q;
  reg         req_is_state_q, req_is_state0_q, req_is_state1_q;

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      req_pending_q   <= 1'b0;
      req_addr_q      <= 12'd0;
      req_we_q        <= 1'b0;
      req_word_q      <= 6'd0;
      req_is_state_q  <= 1'b0;
      req_is_state0_q <= 1'b0;
      req_is_state1_q <= 1'b0;
    end else begin
      req_pending_q <= obi_req_i & obi_gnt_o;
      if (obi_req_i & obi_gnt_o) begin
        req_addr_q      <= reg_addr;
        req_we_q        <= obi_we_i;
        req_word_q      <= word_idx;
        req_is_state_q  <= is_state;
        req_is_state0_q <= is_state0;
        req_is_state1_q <= is_state1;
      end
    end
  end

  // -------------------------------------------------------------------------
  // Plain state-in words. On start, split into shares with the input-mask PRNG.
  // -------------------------------------------------------------------------
  reg [31:0] state_in_q [0:NWORDS-1];

  // Input-mask PRNG (independent of the core's chi PRNG): 50 xorshift32 lanes,
  // distinct seeds from SEED. Used ONLY to generate the initial share split.
  reg [31:0] seed_q;
  reg [31:0] imask_q [0:NWORDS-1];
  function automatic [31:0] xs32 (input [31:0] s);
    reg [31:0] t;
    begin
      t = s ^ (s << 13);
      t = t ^ (t >> 17);
      t = t ^ (t << 5);
      xs32 = t;
    end
  endfunction

  // Flatten plain-in and mask into the two share banks for the core.
  wire [1599:0] din0_flat;   // share0 = plain ^ mask
  wire [1599:0] din1_flat;   // share1 = mask
  genvar gi;
  generate
    for (gi = 0; gi < NWORDS; gi++) begin : g_din
      assign din1_flat[32*gi +: 32] = imask_q[gi];
      assign din0_flat[32*gi +: 32] = state_in_q[gi] ^ imask_q[gi];
    end
  endgenerate

  // -------------------------------------------------------------------------
  // Masked core
  // -------------------------------------------------------------------------
  wire [1599:0] dout0_flat, dout1_flat;
  wire          core_status_d;     // 1 = idle / done

  reg           start_pulse;
  reg           mask_en_q;
  reg           busy_q;
  reg           done_q;
  reg           seen_busy_q;     // core_status_d observed low since start (avoids start-race)

  // LANE-SERIAL masked core (area-optimized; same interface as keccak_f_masked).
  // The full-round keccak_f_masked is ~22k LUTs and does not fit the xc7a35t;
  // keccak_f_masked_serial folds chi onto one reused 64-bit DOM-AND (~8k LUTs)
  // at ~889 cyc/perm. Drop-in: identical ports.
  keccak_f_masked_serial u_core (
    .clk       (clk_i),
    .rst_n     (rst_ni),
    .start_i   (start_pulse),
    .mask_en_i (mask_en_q),
    .seed_i    (seed_q),
    .Din0      (din0_flat),
    .Din1      (din1_flat),
    .Dout0     (dout0_flat),
    .Dout1     (dout1_flat),
    .status_d  (core_status_d)
  );

  // Latched outputs (read after done).
  reg [31:0] state0_out_q [0:NWORDS-1];
  reg [31:0] state1_out_q [0:NWORDS-1];

  // -------------------------------------------------------------------------
  // Control / data FSM
  // -------------------------------------------------------------------------
  integer k;
  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      start_pulse <= 1'b0;
      mask_en_q   <= 1'b0;
      busy_q      <= 1'b0;
      done_q      <= 1'b1;            // idle out of reset
      seen_busy_q <= 1'b0;
      seed_q      <= 32'h1;
      for (k = 0; k < NWORDS; k = k + 1) begin
        state_in_q[k]   <= 32'd0;
        imask_q[k]      <= 32'd0;
        state0_out_q[k] <= 32'd0;
        state1_out_q[k] <= 32'd0;
      end
    end else begin
      start_pulse <= 1'b0;            // default: 1-cycle pulse

      // --- Register writes (address phase, immediate) ---
      if (obi_req_i && obi_we_i) begin
        if (is_state && !busy_q) begin
          state_in_q[word_idx] <= obi_wdata_i;
        end else if (reg_addr == ADDR_SEED) begin
          seed_q <= obi_wdata_i;
        end else if (reg_addr == ADDR_CTRL) begin
          if (obi_wdata_i[0] && !busy_q) begin
            // Generate the input share mask from the seed (distinct per lane).
            // mask_en=0 -> zero mask so share0 == plain and share1 == 0.
            for (k = 0; k < NWORDS; k = k + 1)
              imask_q[k] <= obi_wdata_i[1]
                          ? xs32((seed_q ^ (32'h85EBCA6B * k)) | 32'h1)
                          : 32'd0;
            mask_en_q   <= obi_wdata_i[1];
            start_pulse <= 1'b1;
            busy_q      <= 1'b1;
            done_q      <= 1'b0;
            seen_busy_q <= 1'b0;
          end
        end
      end

      // Track that the core has actually started (status_d went low) so the
      // initial idle status_d=1 does not look like a premature completion.
      if (busy_q && !core_status_d)
        seen_busy_q <= 1'b1;

      // --- Completion: core_status_d rises again after the run ---
      if (busy_q && seen_busy_q && core_status_d) begin
        for (k = 0; k < NWORDS; k = k + 1) begin
          state0_out_q[k] <= dout0_flat[32*k +: 32];
          state1_out_q[k] <= dout1_flat[32*k +: 32];
        end
        busy_q <= 1'b0;
        done_q <= 1'b1;
      end
    end
  end

  // -------------------------------------------------------------------------
  // Read logic (response phase).
  // -------------------------------------------------------------------------
  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) obi_rvalid_o <= 1'b0;
    else         obi_rvalid_o <= req_pending_q;
  end

  always @(*) begin
    obi_rdata_o = 32'd0;
    if (!req_we_q) begin
      if (req_is_state_q)
        obi_rdata_o = state0_out_q[req_word_q] ^ state1_out_q[req_word_q]; // UNMASKED
      else if (req_is_state0_q)
        obi_rdata_o = state0_out_q[req_word_q];
      else if (req_is_state1_q)
        obi_rdata_o = state1_out_q[req_word_q];
      else if (req_addr_q == ADDR_STATUS)
        obi_rdata_o = {31'd0, done_q};
    end
  end

endmodule
