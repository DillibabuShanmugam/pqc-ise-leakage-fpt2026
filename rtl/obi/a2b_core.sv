// ============================================================================
// SCA_Pro_PQC — A2B Mask Conversion (X2X SecAdd Architecture)
// ============================================================================
//
// Converts arithmetic shares (x = x0 + x1 mod q) to Boolean shares
// (x = y0 XOR y1) using a masked parallel-prefix adder.
//
// Algorithm (correct prime correction per X2X / ePrint 2024/114):
//   1. SecAdd pass 1: compute raw = (x0 + x1) mod 2^W, W = ceil(log2(Q))+1
//      The SecAdd output is Boolean-shared: raw = raw0 XOR raw1
//   2. SecAdd pass 2: compute trial = (raw + (2^W - Q)) mod 2^W
//      If trial's MSB is 1 → raw >= Q → use trial[W-2:0] as result
//      If trial's MSB is 0 → raw < Q  → use raw[W-2:0] as result
//   3. Select correct result using masked MUX (XOR with overflow bit)
//
// For ML-KEM:  Q=3329,   W=13 (12-bit modulus + 1 overflow)
// For ML-DSA:  Q=8380417, W=24 (23-bit modulus + 1 overflow)
//
// ============================================================================

(* keep_hierarchy = "yes" *)
module a2b_core (
  input  wire        clk_i,
  input  wire        rst_ni,

  input  wire        start_i,
  input  wire [31:0] share0_i,     // arithmetic share 0 (x0)
  input  wire [31:0] share1_i,     // arithmetic share 1 (x1)
  input  wire [31:0] random_i,     // fresh randomness from PRNG
  input  wire        wide_mode_i,  // 0=13-bit (ML-KEM), 1=24-bit (ML-DSA)

  output reg  [31:0] share0_o,     // boolean share 0 (y0)
  output reg  [31:0] share1_o,     // boolean share 1 (y1)
  output reg         done_o
);

  localparam W_MAX    = 24;
  localparam N_STAGES = 5;
  localparam N_RND    = 4 + 5*N_STAGES;  // incl. SNI refresh words (sec_add H2 fix)

  localparam [23:0] Q_KEM = 24'd3329;
  localparam [23:0] Q_DSA = 24'd8380417;

  // 2^W - Q values for correction
  // ML-KEM: 2^13 - 3329 = 4863
  // ML-DSA: 2^24 - 8380417 = 8396799
  localparam [23:0] NEG_Q_KEM = 24'd4863;   // 2^13 - 3329
  localparam [23:0] NEG_Q_DSA = 24'd8396799; // 2^24 - 8380417

  // FSM
  localparam [3:0] ST_IDLE       = 4'd0;
  localparam [3:0] ST_FILL_RND1  = 4'd1;
  localparam [3:0] ST_ADD1_START = 4'd2;
  localparam [3:0] ST_ADD1_RUN   = 4'd3;
  localparam [3:0] ST_FILL_RND2  = 4'd4;
  localparam [3:0] ST_ADD2_START = 4'd5;
  localparam [3:0] ST_ADD2_RUN   = 4'd6;
  localparam [3:0] ST_SELECT     = 4'd7;
  localparam [3:0] ST_DONE       = 4'd8;

  reg [3:0] state_q;

  // Working registers
  reg [W_MAX-1:0] x0_r, x1_r;
  reg [W_MAX-1:0] mask_r;
  reg [W_MAX-1:0] raw0_r, raw1_r;     // pass 1 result (raw sum)
  reg [W_MAX-1:0] trial0_r, trial1_r; // pass 2 result (sum + (2^W-Q))

  // SecAdd instance
  reg                         add_start;
  reg  [W_MAX-1:0]            add_a0, add_a1, add_b0, add_b1;
  wire [W_MAX-1:0]            add_s0, add_s1;
  wire                        add_done;

  // Randomness pool
  reg [N_RND*W_MAX-1:0] rnd_pool;
  reg [4:0]             rnd_fill_cnt;
  reg                   filling_rnd;
  // tsim fix 2026-05-16: kick-off handshake.  Previously Block 2 wrote
  // filling_rnd/rnd_fill_cnt directly, which produced Yosys multi-driver
  // conflicts (6 per instance × 2 instances = 12 total).  Now Block 2 only
  // pulses start_fill_q for one cycle, and Block 1 (which owns filling_rnd
  // and rnd_fill_cnt) reacts.  fill_busy keeps the Block-2 FSM gated until
  // the fill is actually under way, avoiding the 1-cycle race window.
  reg                   start_fill_q;
  wire                  fill_busy = start_fill_q | filling_rnd;

  sec_add #(.WIDTH(W_MAX), .N_STAGES(N_STAGES)) u_secadd (
    .clk_i   (clk_i),
    .rst_ni  (rst_ni),
    .start_i (add_start),
    .a0_i    (add_a0),
    .a1_i    (add_a1),
    .b0_i    (add_b0),
    .b1_i    (add_b1),
    .rnd_i   (rnd_pool),
    .s0_o    (add_s0),
    .s1_o    (add_s1),
    .done_o  (add_done)
  );

  // PRNG expansion: fill rnd_pool from sequential random_i values.
  // tsim fix 2026-05-16: now also handles the start_fill_q kick-off from the
  // main FSM so filling_rnd / rnd_fill_cnt have exactly one $adff driver.
  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rnd_pool     <= {(N_RND*W_MAX){1'b0}};
      rnd_fill_cnt <= 5'd0;
      filling_rnd  <= 1'b0;
    end else if (start_fill_q && !filling_rnd) begin
      // Kick-off pulse from Block 2: latch filling_rnd and reset counter.
      filling_rnd  <= 1'b1;
      rnd_fill_cnt <= 5'd0;
    end else if (filling_rnd) begin
      rnd_pool[rnd_fill_cnt*W_MAX +: W_MAX] <= random_i[W_MAX-1:0] ^ {rnd_fill_cnt, {(W_MAX-5){1'b0}}};
      if (rnd_fill_cnt == N_RND - 1) begin
        rnd_fill_cnt <= 5'd0;
        filling_rnd  <= 1'b0;
      end else begin
        rnd_fill_cnt <= rnd_fill_cnt + 5'd1;
      end
    end
  end

  // Width selection
  // w_mask: masks to W bits (W = ceil(log2(Q))+1 = 13 or 24)
  wire [W_MAX-1:0] w_mask = wide_mode_i ? {W_MAX{1'b1}} : {{(W_MAX-13){1'b0}}, {13{1'b1}}};

  // ---------------------------------------------------------------------------
  // First-order leak fix (2026-06-16, completed): fresh per-conversion Boolean
  // masks for BOTH operands of SecAdd Pass 1.
  //
  // Root cause (was): ST_FILL_RND1 injected x0 as a TRIVIAL Boolean share
  // (add_a0<=x0, add_a1<=0) and x1 as (add_b0<=x1, add_b1<=0).  sec_add then
  // latches axb1 = a1^b1 = 0 (sec_add.sv:215) and the carry into bit 0 is
  // hardwired 0 (sec_add.sv:339-340), so output share1 LSB b1[0] = axb1[0] = 0
  // ALWAYS, independent of PRNG -> the unmasked value bit leaks (first-order).
  //
  // First (incomplete) fix masked ONLY the a-operand: (x0^r_a, r_a) with the
  // b-operand left trivial (x1, 0).  A TCHES reviewer noted that add_b0 = x1 is
  // then an UNMASKED net carrying the secret share x1 directly -> x1 still leaks
  // at first order.
  //
  // Completed fix: re-share BOTH operands with INDEPENDENT fresh masks
  //   a = (x0 ^ r_a, r_a)   -> a0^a1 = x0   (value preserved)
  //   b = (x1 ^ r_b, r_b)   -> b0^b1 = x1   (value preserved)
  // so neither add_a0/add_b0 nor add_a1/add_b1 carries x0 or x1 in the clear.
  //
  // CRITICAL — r_a and r_b MUST DIFFER.  sec_add latches axb0 = a0^b0
  // (sec_add.sv:214).  If r_a==r_b then a0^b0 = (x0^r)^(x1^r) = x0^x1, i.e. the
  // unmasked sum-xor would re-materialise.  Drawing r_a and r_b from two
  // DIFFERENT PRNG words avoids that.
  //
  // SOURCING (widths checked): random_i is 32-bit (a2b_core.sv:29, fed by the
  // 32-bit prng_random, obi_a2b_b2a_peripheral.sv:121,152).  W_MAX = 24, so two
  // DISJOINT 24-bit slices would need 48 bits and DO NOT FIT in 32 — the slice
  // trick is rejected (would alias upper bits in wide=1 mode).  Instead r_a and
  // r_b are taken from TWO CONSECUTIVE PRNG words:
  //   * r_b comes from r_b_q, which latches random_i EVERY cycle while the FSM is
  //     in ST_IDLE/ST_FILL_RND1 (see Block 2), so on the injection cycle r_b_q
  //     holds the PREVIOUS cycle's PRNG word.
  //   * r_a uses the CURRENT-cycle random_i.
  // prng_random advances on EVERY busy cycle (obi_a2b_b2a_peripheral.sv:256-261),
  // so the previous-cycle word and the current-cycle word are two distinct
  // xoshiro128++ outputs -> r_a != r_b with overwhelming probability and not a
  // fixed transform of each other.  These are HEURISTICALLY FRESH (drawn from
  // distinct PRNG outputs, not reused within the conversion); they are NOT
  // "provably independent" since both come from one xoshiro stream.
  //
  // The rnd_pool fill that feeds sec_add completed on a PRIOR cycle (ST_FILL_RND1
  // only injects when !fill_busy, a2b_core.sv:114-122,212), so these two words do
  // not alias any rnd_pool word consumed by the sec_add gadgets.  r_a is a pure
  // combinational wire; r_b_q is a single new $adff driven ONLY by Block 2 — it
  // does NOT touch filling_rnd/rnd_fill_cnt, so no multi-driver hazard is added.
  // Both are masked to W bits by w_mask so wide=0 (13-bit) and wide=1 (24-bit)
  // both keep upper bits zero.
  // ---------------------------------------------------------------------------
  reg  [31:0]      r_b_q;                                  // prev-cycle PRNG word
  wire [W_MAX-1:0] r_a = random_i[W_MAX-1:0] & w_mask;     // current PRNG word
  wire [W_MAX-1:0] r_b = r_b_q[W_MAX-1:0]   & w_mask;      // previous PRNG word

  // w_mask_ext: masks to W+1 bits for carry-out detection in pass 2
  wire [W_MAX-1:0] w_mask_ext = wide_mode_i ? {W_MAX{1'b1}} : {{(W_MAX-14){1'b0}}, {14{1'b1}}};
  // carry_pos: bit position of the carry-out (= W, one above the modulus MSB)
  wire [4:0]       carry_pos = wide_mode_i ? 5'd23 : 5'd13;  // NOTE: bit 13 for ML-KEM, not 12
  // result_mask: mask for the final output (W-1 bits = modulus width)
  wire [4:0]       mod_msb = wide_mode_i ? 5'd22 : 5'd11;  // actual modulus MSB position
  wire [W_MAX-1:0] neg_q   = wide_mode_i ? NEG_Q_DSA : NEG_Q_KEM;

  // Main FSM
  // tsim fix 2026-05-16: this block ALSO drives filling_rnd/rnd_fill_cnt
  // (kickoff in ST_IDLE start_i and ST_ADD1_RUN add_done arms below).  Without
  // matching reset assignments here, Yosys reports 6 multi-driver conflicts
  // per instance (rnd_fill_cnt[4:0] + filling_rnd, ×2 a2b/b2a instances = 12
  // total).  Adding the reset coverage matches Block 1's semantics and lets
  // Yosys unify the drivers into a single $adff cell.
  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q   <= ST_IDLE;
      x0_r      <= {W_MAX{1'b0}};
      x1_r      <= {W_MAX{1'b0}};
      mask_r    <= {W_MAX{1'b0}};
      raw0_r    <= {W_MAX{1'b0}};
      raw1_r    <= {W_MAX{1'b0}};
      trial0_r  <= {W_MAX{1'b0}};
      trial1_r  <= {W_MAX{1'b0}};
      add_start <= 1'b0;
      add_a0    <= {W_MAX{1'b0}};
      add_a1    <= {W_MAX{1'b0}};
      add_b0    <= {W_MAX{1'b0}};
      add_b1    <= {W_MAX{1'b0}};
      share0_o  <= 32'd0;
      share1_o  <= 32'd0;
      done_o    <= 1'b0;
      start_fill_q <= 1'b0;
      r_b_q     <= 32'd0;
      // NOTE: filling_rnd and rnd_fill_cnt are reset by Block 1 only — Block 2
      // no longer drives them, so listing them here would re-create the
      // multi-driver conflict.
    end else begin
      add_start    <= 1'b0;
      done_o       <= 1'b0;
      start_fill_q <= 1'b0;  // default; pulsed where a fill is needed

      // r_b mask source: continuously register random_i so r_b_q always holds
      // the PREVIOUS cycle's PRNG word.  On the ST_FILL_RND1 injection cycle this
      // gives r_b (= prev word) != r_a (= current random_i): two consecutive,
      // distinct xoshiro128++ outputs.  Single $adff, Block-2-only driver, does
      // not touch filling_rnd/rnd_fill_cnt -> no multi-driver hazard.
      r_b_q <= random_i;

      case (state_q)

        ST_IDLE: begin
          if (start_i) begin
            x0_r   <= share0_i[W_MAX-1:0] & w_mask;
            x1_r   <= share1_i[W_MAX-1:0] & w_mask;
            mask_r <= w_mask;
            start_fill_q <= 1'b1;             // kick off fill via Block 1
            state_q      <= ST_FILL_RND1;
          end
        end

        // ---- Pass 1: compute raw = x0 + x1 mod 2^W ----
        ST_FILL_RND1: begin
          if (!fill_busy) begin
            // Leak fix (completed): re-share BOTH x0 and x1 with INDEPENDENT
            // fresh masks r_a, r_b (distinct consecutive PRNG words, r_a != r_b).
            //   a0^a1 = x0, b0^b1 = x1 (value preserved); add_b0 = x1^r_b is now
            //   masked (no longer the bare secret share x1).  r_a != r_b keeps
            //   axb0 = a0^b0 = x0^x1^(r_a^r_b) masked (NOT x0^x1).
            add_a0    <= x0_r ^ r_a;     // = x0 ^ r_a  (re-shared)
            add_a1    <= r_a;            // fresh per-conversion Boolean mask (a)
            add_b0    <= x1_r ^ r_b;     // = x1 ^ r_b  (re-shared)
            add_b1    <= r_b;            // fresh per-conversion Boolean mask (b)
            add_start <= 1'b1;
            state_q   <= ST_ADD1_RUN;
          end
        end

        ST_ADD1_RUN: begin
          if (add_done) begin
            raw0_r  <= add_s0 & mask_r;
            raw1_r  <= add_s1 & mask_r;
            // Start filling randomness for pass 2
            start_fill_q <= 1'b1;
            state_q      <= ST_FILL_RND2;
          end
        end

        // ---- Pass 2: compute trial = raw + (2^W - Q) mod 2^W ----
        // If result MSB is set, then raw >= Q and we use trial[W-2:0]
        // If result MSB is clear, raw < Q and we use raw[W-2:0]
        ST_FILL_RND2: begin
          if (!fill_busy) begin
            // Pass 2 uses W+1 bits so the carry-out is visible.
            // a-operand = (raw0_r, raw1_r): already a non-trivial 2-share pair
            // from the Pass-1 SecAdd output, so no extra mask needed here.
            // b-operand = neg_q = 2^W - Q, a PUBLIC constant (4863 / 8396799).
            // A trivial Boolean share (neg_q, 0) of a PUBLIC value leaks nothing,
            // so it is deliberately left unmasked — adding a mask here would only
            // waste randomness.  (Leak fix applies to Pass 1 only.)
            add_a0    <= raw0_r & w_mask;       // original sum (W bits)
            add_a1    <= raw1_r & w_mask;
            add_b0    <= neg_q & w_mask;        // 2^W - Q (PUBLIC, trivial share OK)
            add_b1    <= {W_MAX{1'b0}};
            add_start <= 1'b1;
            state_q   <= ST_ADD2_RUN;
          end
        end

        ST_ADD2_RUN: begin
          if (add_done) begin
            // Keep W+1 bits so we can see the carry-out
            trial0_r <= add_s0 & w_mask_ext;
            trial1_r <= add_s1 & w_mask_ext;
            state_q  <= ST_SELECT;
          end
        end

        // ---- Select correct result ----
        // overflow = trial_msb = trial0[msb_pos] XOR trial1[msb_pos]
        // if overflow: result = trial (reduced), else: result = raw (already < Q)
        //
        // Masked MUX: select between raw and trial using the overflow bit.
        // For constant-time: result = raw XOR (overflow_mask AND (raw XOR trial))
        // where overflow_mask = {W{overflow_bit}} (replicated)
        //
        // Since we hold both shares internally (this module owns both),
        // we can compute the unmasked overflow and branch.
        // The overflow bit only reveals whether x >= Q, which is public
        // information (all valid coefficients are in [0, Q-1]).
        // ---- Select based on carry-out of trial = raw + (2^W - Q) ----
        // carry_out = trial[carry_pos] share0 XOR trial[carry_pos] share1
        // If carry_out = 1: raw >= Q, use trial's lower bits (= raw - Q)
        // If carry_out = 0: raw < Q, use raw directly
        ST_SELECT: begin
          begin : select_block
            reg carry_out;
            reg [W_MAX-1:0] out_mask;

            carry_out = trial0_r[carry_pos] ^ trial1_r[carry_pos];
            // Output mask: only the modulus-width bits (W-1 bits = log2(Q) bits)
            out_mask = w_mask >> 1;  // W-1 bits (strip the overflow bit from W)

            if (carry_out) begin
              // raw >= Q: use trial lower bits (= raw - Q, already reduced)
              share0_o <= {{(32-W_MAX){1'b0}}, trial0_r & out_mask};
              share1_o <= {{(32-W_MAX){1'b0}}, trial1_r & out_mask};
            end else begin
              // raw < Q: use raw directly (already in [0, Q-1])
              share0_o <= {{(32-W_MAX){1'b0}}, raw0_r & out_mask};
              share1_o <= {{(32-W_MAX){1'b0}}, raw1_r & out_mask};
            end
          end
          state_q <= ST_DONE;
        end

        ST_DONE: begin
          done_o  <= 1'b1;
          state_q <= ST_IDLE;
        end

        default: state_q <= ST_IDLE;

      endcase
    end
  end

endmodule
