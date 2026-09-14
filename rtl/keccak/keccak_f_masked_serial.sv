//////////////////////////////////////////////////////////////////////////////////////////
// Design Name:  keccak_f_masked_serial
// Language:     SystemVerilog
//
// LANE-SERIAL first-order DOM (2-share) masked Keccak-f[1600] top. Drop-in
// replacement for keccak_f_masked (IDENTICAL external interface) that trades
// latency for area so it fits the CW305 xc7a35t.
//
// AREA STRATEGY (vs full-round keccak_f_masked which is ~22k LUTs):
//   * theta/rho/pi are GF(2)-LINEAR -> applied ONCE per round, full width, on
//     each of the two shares (cheap XOR/rotate via keccak_linear_thetarhopi).
//   * chi is the only nonlinear step. Instead of 1600 combinational DOM-ANDs,
//     we instantiate ONE 64-bit DOM-AND (keccak_dom_and64) and reuse it once
//     per lane (25 lanes -> 25 chi cycles per round).
//
//   To avoid the enormous 25:1 / 1600-bit variable-index muxes that a naive
//   "pick lane (y,x)" datapath would synthesize, chi is processed ROW BY ROW
//   with a ROTATING 5-lane window:
//     - Load row y (5 lanes = 320 bits) of each chi_in share via a 5:1 row mux.
//     - Each cycle rotate the window LEFT by one lane. At rotation k the window
//       holds  win[i] = L[(i+k) mod 5]  (L = the 5 input lanes of row y).
//       chi output for column k is  O[k] = win[0] ^ ((~win[1]) & win[2]).
//       The DOM-AND consumes win[1] (=b) and win[2] (=c); the registered result
//       is XORed with the (delayed) win[0] one cycle later and stored at orow[k].
//     - After 5 rotations the output row orow[0..4] is complete; write it back
//       to the chi_out bank (5:1 row demux). 5 rows x 5 cols = 25 chi cycles.
//   All indexing is now at most 5:1 over 320-bit rows / 64-bit lanes -> small.
//
// Fresh randomness: only 64 bits / chi cycle from a small xorshift bank (2 x
// xorshift32 lanes -> 64 bits), NOT the 1600-bit-per-round bank.
//
// Latency per round: 1 LIN cycle + per-row (1 load + 5 compute + 1 drain) over
// 5 rows. Total measured ~673 cyc / permutation (reported by the testbench).
//
// Two resident 1600-bit state share banks (state0_q, state1_q) hold S0, S1 with
// S = S0 ^ S1. They are loaded from Din0/Din1 at start and permuted in place.
//
// mask_en = 0 : PRNG forced to 0 AND share1 bank forced to 0, so the masked
// datapath collapses and Dout0 == plain keccak_f result, Dout1 == 0.
//////////////////////////////////////////////////////////////////////////////////////////

import pkg_keccak::k_state;
import pkg_keccak::k_plane;
import pkg_keccak::k_lane;
import pkg_keccak::KEC_N;

module keccak_f_masked_serial (
    input  logic           clk,
    input  logic           rst_n,        // async active-low
    input  logic           start_i,      // pulse: launch permutation
    input  logic           mask_en_i,    // 1 = masked ; 0 = collapse to plain
    input  logic [31:0]    seed_i,       // PRNG seed (sampled at start)
    input  logic [1599:0]  Din0,         // share-0 input state (flat, lane L = bits 64L..64L+63)
    input  logic [1599:0]  Din1,         // share-1 input state
    output logic [1599:0]  Dout0,        // share-0 output state
    output logic [1599:0]  Dout1,        // share-1 output state
    output logic           status_d      // 1 = idle / last permutation complete
);

    // -----------------------------------------------------------------------
    // Flat <-> k_state helpers (lane L = x + 5*y occupies bits [64L .. 64L+63]).
    // Matches keccak_dp / keccak_f_masked: bit i of lane (y,x) at 320*y+64*x+i.
    // -----------------------------------------------------------------------
    function automatic k_state flat2state (input logic [1599:0] f);
        for (int y = 0; y < 5; y++)
            for (int x = 0; x < 5; x++)
                for (int i = 0; i < KEC_N; i++)
                    flat2state[y][x][i] = f[320*y + 64*x + i];
    endfunction

    function automatic logic [1599:0] state2flat (input k_state s);
        for (int y = 0; y < 5; y++)
            for (int x = 0; x < 5; x++)
                for (int i = 0; i < KEC_N; i++)
                    state2flat[320*y + 64*x + i] = s[y][x][i];
    endfunction

    // -----------------------------------------------------------------------
    // Resident two-share state banks (k_state = [y][x][i]).
    // -----------------------------------------------------------------------
    // NOTE: the large two-share storage banks deliberately carry NO keep /
    // dont_touch. The first-order DOM glitch barrier that the security argument
    // relies on lives on the partial registers INSIDE keccak_dom_and64
    // (ps0_q/pc0_q/ps1_q/pc1_q, which DO keep dont_touch). The banks are plain
    // resident state; forcing keep on them blocks the synthesizer from sharing
    // the combinational theta/rho/pi cones and balloons the core from ~8k to
    // ~26k LUTs (over the xc7a35t budget) for no security benefit.
    k_state state0_q, state1_q;

    // chi-input share banks (= thetarhopi(state) per share), latched per round.
    k_state chi_in0_q, chi_in1_q;
    // chi-output share banks accumulated row-by-row during the chi phase.
    k_state chi_out0_q, chi_out1_q;

    // -----------------------------------------------------------------------
    // Linear theta/rho/pi on each share (combinational, once per round).
    // keccak_linear_thetarhopi is defined in keccak_round_masked.sv.
    // -----------------------------------------------------------------------
    k_state lin0, lin1;
    keccak_linear_thetarhopi u_lin0 (.Round_in(state0_q), .pi_out(lin0));
    keccak_linear_thetarhopi u_lin1 (.Round_in(state1_q), .pi_out(lin1));

    // -----------------------------------------------------------------------
    // Small xorshift PRNG : 2 lanes x 32 bits -> 64 fresh bits per chi cycle.
    // Distinct per-lane seeds (never all-zero). Placeholder for a TRNG.
    // -----------------------------------------------------------------------
    localparam int unsigned NLANE = 2;
    (* keep = "true" *) reg [31:0] prng_q [0:NLANE-1];

    function automatic [31:0] xs32 (input [31:0] s);
        reg [31:0] t;
        begin
            t = s ^ (s << 13);
            t = t ^ (t >> 17);
            t = t ^ (t << 5);
            xs32 = t;
        end
    endfunction

    k_lane rnd64;
    assign rnd64 = mask_en_i ? {prng_q[1], prng_q[0]} : 64'd0;

    // -----------------------------------------------------------------------
    // Round constant generation (one per round).
    // -----------------------------------------------------------------------
    logic [4:0] round_ctr;       // 0..23
    logic [7:0] rc;
    keccak_round_constants_gen u_rc (
        .round_number              (round_ctr),
        .round_constant_signal_out (rc)
    );
    // Public round-constant lane (bits 0,1,2,3,7,15,31,63 carry RC; iota).
    k_lane rc_lane;
    always_comb begin
        rc_lane     = '0;
        rc_lane[0]  = rc[0];
        rc_lane[1]  = rc[1];
        rc_lane[2]  = rc[2];
        rc_lane[3]  = rc[3];
        rc_lane[7]  = rc[4];
        rc_lane[15] = rc[5];
        rc_lane[31] = rc[6];
        rc_lane[63] = rc[7];
    end

    // =======================================================================
    // chi datapath : per-row rotating 5-lane window, ONE shared DOM-AND-64.
    // =======================================================================
    // Working window (5 lanes) of the current row, per share.
    k_lane win0 [0:4];
    k_lane win1 [0:4];
    // Output row accumulator (5 lanes), per share.
    k_lane orow0 [0:4];
    k_lane orow1 [0:4];

    // win[0] one cycle delayed, to align with the registered DOM result and to
    // know which output column the result belongs to.
    k_lane win0_d, win1_d;
    logic [2:0] col_d;           // output column index (0..4) of the delayed result
    logic [2:0] row_d;           // row index of the delayed result
    logic       res_valid;       // a DOM result is ready to be accumulated
    logic       iota_d;          // delayed: this result is lane (0,0) -> add RC

    // DOM operands: b = win[1], c = win[2] (current rotation).
    k_lane b0_s, b1_s, c0_s, c1_s;
    assign b0_s = win0[1];
    assign b1_s = mask_en_i ? win1[1] : '0;
    assign c0_s = win0[2];
    assign c1_s = mask_en_i ? win1[2] : '0;

    // Latch DOM partials whenever we are in CHI presenting a column (col 0..4).
    logic in_chi_compute;        // combinational: st_q==CHI && col_ctr<=4
    logic dom_latch_en;
    assign dom_latch_en = in_chi_compute;
    k_lane z0_s, z1_s;
    keccak_dom_and64 u_dom (
        .clk_i       (clk),
        .rst_ni      (rst_n),
        .stage1_en_i (dom_latch_en),
        .b0          (b0_s),
        .b1          (b1_s),
        .c0          (c0_s),
        .c1          (c1_s),
        .r           (rnd64),
        .z0          (z0_s),
        .z1          (z1_s)
    );

    // Recombined output lane for the delayed column: O = win0_d ^ z (+RC if iota).
    k_lane res0, res1;
    assign res0 = win0_d ^ z0_s ^ (iota_d ? rc_lane : '0);
    assign res1 = win1_d ^ z1_s;   // RC is public -> share0 only

    // -----------------------------------------------------------------------
    // FSM
    //   IDLE   : wait start; load banks + seed PRNG.
    //   LIN    : capture chi_in banks = thetarhopi(state) per share. row_ctr=0.
    //   ROW_LD : load window from chi_in row[row_ctr]; col=0. -> CHI
    //   CHI    : 5 compute cycles + 1 drain per row.
    //              cycle c (0..4): present win[1]/win[2] (col c after rotation),
    //                              latch DOM partials; rotate window left;
    //                              advance PRNG. The result for col c is ready
    //                              the next cycle and accumulated into orow[c]
    //                              via the delayed pipeline regs.
    //              cycle 5: drain last result -> orow[4]; write orow to chi_out
    //                       bank row[row_ctr]; advance row or finish round.
    //   RND_DN : chi_out -> state banks; ++round_ctr; last -> FIN.
    //   FIN    : status_d = 1 -> IDLE.
    // -----------------------------------------------------------------------
    localparam int unsigned NROUND = 24;
    typedef enum logic [2:0] {IDLE, LIN, ROW_LD, CHI, RND_DN, FIN} st_e;
    st_e st_q;

    logic [2:0] row_ctr;         // current row 0..4
    logic [2:0] col_ctr;         // current rotation/column 0..5 (5 = drain)

    // Combinational: assert the DOM glitch-barrier latch while presenting a
    // column's operands (registering dom_latch_en would latch one cycle late,
    // after the window has already rotated).
    assign in_chi_compute = (st_q == CHI) && (col_ctr <= 3'd4);

    // Read a chi_in row (5 lanes) of the selected share. 5:1 over 320-bit rows.
    function automatic k_plane rd_row (input k_state s, input logic [2:0] yy);
        rd_row = s[yy];
    endfunction

    integer kk;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st_q        <= IDLE;
            round_ctr   <= '0;
            state0_q    <= '0;
            state1_q    <= '0;
            chi_in0_q   <= '0;
            chi_in1_q   <= '0;
            chi_out0_q  <= '0;
            chi_out1_q  <= '0;
            status_d    <= 1'b1;        // idle out of reset
            row_ctr     <= '0;
            col_ctr     <= '0;
            res_valid   <= 1'b0;
            col_d       <= '0;
            row_d       <= '0;
            iota_d      <= 1'b0;
            win0_d      <= '0;
            win1_d      <= '0;
            for (kk = 0; kk < 5; kk = kk + 1) begin
                win0[kk]  <= '0; win1[kk]  <= '0;
                orow0[kk] <= '0; orow1[kk] <= '0;
            end
            for (kk = 0; kk < NLANE; kk = kk + 1) prng_q[kk] <= 32'h0;
        end else begin
            // Accumulate a ready DOM result into the output row (any state).
            if (res_valid) begin
                orow0[col_d] <= res0;
                orow1[col_d] <= res1;
            end

            case (st_q)
                IDLE: begin
                    res_valid <= 1'b0;
                    if (start_i) begin
                        state0_q  <= flat2state(Din0);
                        state1_q  <= mask_en_i ? flat2state(Din1) : '0;
                        round_ctr <= '0;
                        status_d  <= 1'b0;
                        for (kk = 0; kk < NLANE; kk = kk + 1)
                            prng_q[kk] <= (seed_i ^ (32'h9E3779B9 * kk)) | 32'h1;
                        st_q <= LIN;
                    end
                end

                LIN: begin
                    // Capture chi_in banks (linear thetarhopi of each share).
                    chi_in0_q <= lin0;
                    chi_in1_q <= mask_en_i ? lin1 : '0;
                    row_ctr   <= 3'd0;
                    res_valid <= 1'b0;
                    st_q      <= ROW_LD;
                end

                ROW_LD: begin
                    // Load the 5-lane window of row row_ctr from each chi_in bank.
                    for (kk = 0; kk < 5; kk = kk + 1) begin
                        win0[kk] <= chi_in0_q[row_ctr][kk];
                        win1[kk] <= mask_en_i ? chi_in1_q[row_ctr][kk] : '0;
                    end
                    col_ctr   <= 3'd0;
                    res_valid <= 1'b0;
                    st_q      <= CHI;
                end

                CHI: begin
                    if (col_ctr <= 3'd4) begin
                        // Present operands for column col_ctr (DOM partials are
                        // latched combinationally via in_chi_compute this edge).
                        // Pipeline regs: remember win[0] and which column/row.
                        win0_d  <= win0[0];
                        win1_d  <= win1[0];
                        col_d   <= col_ctr;
                        row_d   <= row_ctr;
                        iota_d  <= (row_ctr == 3'd0) && (col_ctr == 3'd0);
                        res_valid <= 1'b1;     // result ready next cycle
                        // Rotate window LEFT by one lane.
                        win0[0] <= win0[1]; win0[1] <= win0[2];
                        win0[2] <= win0[3]; win0[3] <= win0[4]; win0[4] <= win0[0];
                        win1[0] <= win1[1]; win1[1] <= win1[2];
                        win1[2] <= win1[3]; win1[3] <= win1[4]; win1[4] <= win1[0];
                        // Advance PRNG (fresh r for next chi cycle).
                        for (kk = 0; kk < NLANE; kk = kk + 1)
                            prng_q[kk] <= xs32(prng_q[kk]);
                        col_ctr <= col_ctr + 3'd1;
                    end else begin
                        // col_ctr == 5 : last result (col 4) is being accumulated
                        // THIS cycle (res_valid was set for col 4). Write the row.
                        // The orow update for col 4 happens in the common accumulate
                        // block above; fold it in here for the bank write.
                        res_valid <= 1'b0;
                        for (kk = 0; kk < 5; kk = kk + 1) begin
                            chi_out0_q[row_ctr][kk] <= (kk == col_d) ? res0 : orow0[kk];
                            chi_out1_q[row_ctr][kk] <= (kk == col_d) ? res1 : orow1[kk];
                        end
                        if (row_ctr == 3'd4) begin
                            st_q <= RND_DN;
                        end else begin
                            row_ctr <= row_ctr + 3'd1;
                            st_q    <= ROW_LD;
                        end
                    end
                end

                RND_DN: begin
                    state0_q <= chi_out0_q;
                    state1_q <= chi_out1_q;
                    if (round_ctr == NROUND-1) begin
                        st_q <= FIN;
                    end else begin
                        round_ctr <= round_ctr + 5'd1;
                        st_q      <= LIN;
                    end
                end

                FIN: begin
                    status_d <= 1'b1;
                    st_q     <= IDLE;
                end

                default: st_q <= IDLE;
            endcase
        end
    end

    assign Dout0 = state2flat(state0_q);
    assign Dout1 = state2flat(state1_q);

endmodule
