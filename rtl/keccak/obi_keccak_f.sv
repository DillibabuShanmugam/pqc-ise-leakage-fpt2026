// ============================================================================
// obi_keccak_f : flat-OBI MMIO wrapper around the CIRCE Keccak-f[1600] core.
//
// Exposes the CIRCE keccak_f permutation (loosely-coupled coprocessor) to
// firmware as a memory-mapped peripheral on the user-domain OBI bus
// (UserBaseAddr + 0x3000 .. 0x4000).
//
// The 1600-bit Keccak state is presented as 50 little-endian 32-bit words.
// keccak_f expects the rate already XORed into the state by firmware (it does
// the absorb-XOR internally against a zeroed state on start, so Din is the
// full 1600-bit state to permute).  Lane L (0..24, = x + 5*y) occupies
// Din[64*L+63 : 64*L]; word index k (0..49) drives Din[32*k+31 : 32*k], i.e.
//   word 2*L   = low  32 bits of state lane L
//   word 2*L+1 = high 32 bits of state lane L
// matching a little-endian uint64_t s[25] in firmware.
//
// Register Map (low 12 bits of OBI address; word granular):
//   0x000 .. 0x0C4   STATE  [R/W]  50 x 32b state words (k = addr>>2, 0..49)
//                            write : loads STATE_IN word k
//                            read  : STATE_OUT word k (latched Dout after done)
//   0x100            CTRL   [W]    bit0 = start (pulse: launch permutation)
//   0x104            STATUS [R]    bit0 = done  (1 = last permutation complete,
//                                               core idle)
//
// While busy (between a start write and done), STATE writes are ignored and
// STATE_IN is held stable so Din does not change under the running core.
//
// OBI protocol (matches obi_hw_masked_proof / obi_a2b_b2a_peripheral):
//   gnt = req (granted in the address phase, single cycle),
//   rvalid registered one cycle later, rdata combinational from latched addr.
// ============================================================================

module obi_keccak_f (
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

  // -------------------------------------------------------------------------
  // Address decode — low 12 bits select the register (4KB window)
  // -------------------------------------------------------------------------
  localparam int unsigned NWORDS = 50; // 50 x 32b = 1600b

  wire [11:0] reg_addr  = obi_addr_i[11:0];
  wire [11:0] req_word  = obi_addr_i[11:2];     // word index region (addr>>2)
  wire        is_state  = (reg_addr < 12'h0C8); // 0x000..0x0C7 -> words 0..49
  wire [5:0]  word_idx  = reg_addr[7:2];        // 0..49 (state word select)

  localparam [11:0] ADDR_CTRL   = 12'h100;
  localparam [11:0] ADDR_STATUS = 12'h104;

  // -------------------------------------------------------------------------
  // OBI grant: always grant immediately (single-cycle address phase)
  // -------------------------------------------------------------------------
  assign obi_gnt_o = obi_req_i;

  // -------------------------------------------------------------------------
  // Latched request for response phase
  // -------------------------------------------------------------------------
  reg         req_pending_q;
  reg [11:0]  req_addr_q;
  reg         req_we_q;
  reg [5:0]   req_word_q;
  reg         req_is_state_q;

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      req_pending_q  <= 1'b0;
      req_addr_q     <= 12'd0;
      req_we_q       <= 1'b0;
      req_word_q     <= 6'd0;
      req_is_state_q <= 1'b0;
    end else begin
      req_pending_q <= obi_req_i & obi_gnt_o;
      if (obi_req_i & obi_gnt_o) begin
        req_addr_q     <= reg_addr;
        req_we_q       <= obi_we_i;
        req_word_q     <= word_idx;
        req_is_state_q <= is_state;
      end
    end
  end

  // -------------------------------------------------------------------------
  // State-in words (drive Din) and latched state-out words (read after done)
  // -------------------------------------------------------------------------
  reg [31:0] state_in_q  [0:NWORDS-1];
  reg [31:0] state_out_q [0:NWORDS-1];

  // Flatten state_in_q -> Din[1599:0]
  wire [1599:0] din_flat;
  genvar gi;
  generate
    for (gi = 0; gi < NWORDS; gi++) begin : g_din
      assign din_flat[32*gi +: 32] = state_in_q[gi];
    end
  endgenerate

  // -------------------------------------------------------------------------
  // CIRCE keccak_f core + control
  // -------------------------------------------------------------------------
  wire [1599:0] dout_flat;
  wire          status_d;     // 1-cycle done pulse from the CU
  wire          keccak_intr;  // unused (polled by firmware)

  reg           start_level;  // held start request to the CU
  reg           busy_q;       // 1 between start and done
  reg           done_q;       // STATUS.done (1 = idle / last run complete)

  keccak_f u_keccak (
    .clk         (clk_i),
    .rst_n       (rst_ni),       // async active-low — matches OBI domain reset
    .start_i     (start_level),
    .Din         (din_flat),
    .Dout        (dout_flat),
    .status_d    (status_d),
    .keccak_intr (keccak_intr)
  );

  // -------------------------------------------------------------------------
  // Control / data FSM
  //   - CTRL.start write (when idle) latches busy, raises start_level
  //   - keccak_f.status_d pulse marks completion: latch Dout, drop busy,
  //     set done, drop start_level.
  // -------------------------------------------------------------------------
  integer k;
  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      start_level <= 1'b0;
      busy_q      <= 1'b0;
      done_q      <= 1'b1;          // idle out of reset
      for (k = 0; k < NWORDS; k = k + 1) begin
        state_in_q[k]  <= 32'd0;
        state_out_q[k] <= 32'd0;
      end
    end else begin
      // --- Register writes (address phase, immediate) ---
      if (obi_req_i && obi_we_i) begin
        if (is_state && !busy_q) begin
          // load STATE_IN word (only while idle so Din is stable when running)
          state_in_q[word_idx] <= obi_wdata_i;
        end else if (reg_addr == ADDR_CTRL) begin
          if (obi_wdata_i[0] && !busy_q) begin
            start_level <= 1'b1;    // launch
            busy_q      <= 1'b1;
            done_q      <= 1'b0;
          end
        end
      end

      // --- Completion: status_d pulses high for one cycle when done ---
      if (busy_q && status_d) begin
        for (k = 0; k < NWORDS; k = k + 1)
          state_out_q[k] <= dout_flat[32*k +: 32];
        start_level <= 1'b0;
        busy_q      <= 1'b0;
        done_q      <= 1'b1;
      end
    end
  end

  // -------------------------------------------------------------------------
  // Read logic (response phase). rvalid registered; rdata combinational from
  // latched req_* so it is valid on the cycle rvalid is asserted.
  // -------------------------------------------------------------------------
  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) obi_rvalid_o <= 1'b0;
    else         obi_rvalid_o <= req_pending_q;
  end

  always @(*) begin
    obi_rdata_o = 32'd0;
    if (!req_we_q) begin
      if (req_is_state_q)
        obi_rdata_o = state_out_q[req_word_q];
      else if (req_addr_q == ADDR_STATUS)
        obi_rdata_o = {31'd0, done_q};   // bit0 = done
    end
  end

endmodule
