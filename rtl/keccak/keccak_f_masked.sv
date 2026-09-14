//////////////////////////////////////////////////////////////////////////////////////////
// Design Name:  keccak_f_masked
// Language:     SystemVerilog
//
// First-order DOM (2-share) masked Keccak-f[1600] top, forked from CIRCE keccak_f /
// keccak_dp (Dolmeta & Piscopo, PoliTo). Two resident 1600-bit state banks
// (share0, share1); 24 rounds at 2 cycles/round via keccak_round_masked.
//
// The two state banks are loaded from Din0/Din1 at start and permuted IN PLACE
// (no rate-absorb here; absorb is the caller's linear job, done in shares). The
// shares never leave the unit between rounds.
//
// chi randomness: a synthesizable xorshift32 PRNG bank expanded to 1600 bits
// (50 x 32-bit xorshift32 lanes, distinct per-lane seeds derived from SEED).
// One fresh 1600-bit word is produced and consumed per round. This is a
// PLACEHOLDER for a vetted TRNG / wide stream cipher (Trivium) in silicon.
//
// Latency: ~2 cyc/round x 24 = ~48 round cycles (+ a few FSM cycles).
// Randomness budget: 1600 fresh bits / round = 38,400 bits / permutation.
//
// mask_en = 0 : PRNG output forced to 0 AND share1 bank forced to 0, so the
// masked datapath collapses and Dout0 == plain keccak_f result, Dout1 == 0.
//////////////////////////////////////////////////////////////////////////////////////////

import pkg_keccak::k_state;
import pkg_keccak::KEC_N;

module keccak_f_masked (
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
    // Flat <-> k_state helpers (lane L = x + 5*y occupies bits [64L .. 64L+63])
    // matches keccak_dp: Dout[320*y + 64*x + i] = state[y][x][i].
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
    // Resident two-share state banks.
    // -----------------------------------------------------------------------
    (* keep = "true" *) (* dont_touch = "true" *) k_state state0_q, state1_q;

    // -----------------------------------------------------------------------
    // xorshift32 PRNG bank : 50 lanes x 32 bits = 1600 fresh bits / advance.
    // Distinct seeds: lane k seeded with (seed_i ^ golden*k) | 1 (avoid all-zero
    // state which is a fixed point of xorshift). Placeholder for a TRNG.
    // -----------------------------------------------------------------------
    localparam int unsigned NLANE = 50;
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

    // Flatten PRNG bank into 1600-bit fresh word, then into k_state, zeroed if !mask_en.
    logic [1599:0] rnd_flat;
    genvar gp;
    generate
        for (gp = 0; gp < NLANE; gp++) begin : g_rndflat
            assign rnd_flat[32*gp +: 32] = prng_q[gp];
        end
    endgenerate
    k_state rnd_state;
    assign rnd_state = flat2state(rnd_flat);

    // -----------------------------------------------------------------------
    // Masked round (2-cycle). Round_in shares come from the resident banks.
    // In unmasked mode, share1 is forced to 0 so the gadget collapses to plain.
    // -----------------------------------------------------------------------
    k_state round_in0, round_in1, round_out0, round_out1;
    assign round_in0 = state0_q;
    assign round_in1 = mask_en_i ? state1_q : '0;

    logic [7:0] rc;
    logic [4:0] round_ctr;       // 0..23 (feeds round-constant gen)
    logic       stage1_en;       // high during STG1 (drives masked round barrier)

    keccak_round_constants_gen u_rc (
        .round_number              (round_ctr),
        .round_constant_signal_out (rc)
    );

    keccak_round_masked u_round (
        .clk_i                 (clk),
        .rst_ni                (rst_n),
        .stage1_en_i           (stage1_en),
        .Round_in0             (round_in0),
        .Round_in1             (round_in1),
        .rnd_i                 (rnd_state),
        .Round_constant_signal (rc),
        .mask_en_i             (mask_en_i),
        .Round_out0            (round_out0),
        .Round_out1            (round_out1)
    );

    // -----------------------------------------------------------------------
    // FSM : 24 rounds, 2 cycles each.
    //   IDLE  : wait start; on start load banks + seed PRNG.
    //   STG1  : assert stage1_en (latch DOM partials), advance PRNG. -> STG2
    //   STG2  : capture round_out into banks; ++round_ctr;
    //           if last round -> FIN else -> STG1.
    //   FIN   : status_d = 1, back to IDLE.
    // -----------------------------------------------------------------------
    localparam int unsigned NROUND = 24;
    typedef enum logic [1:0] {IDLE, STG1, STG2, FIN} st_e;
    st_e        st_q;

    // Combinational stage-1 enable: high during STG1 so the masked round latches
    // its DOM partials on the STG1->STG2 edge (computed from the current round
    // input state). STG2 then captures the stable round output one edge later.
    assign stage1_en = (st_q == STG1);

    integer kk;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st_q      <= IDLE;
            round_ctr <= '0;
            state0_q  <= '0;
            state1_q  <= '0;
            status_d  <= 1'b1;       // idle out of reset
            for (kk = 0; kk < NLANE; kk = kk + 1) prng_q[kk] <= 32'h0;
        end else begin
            case (st_q)
                IDLE: begin
                    if (start_i) begin
                        state0_q  <= flat2state(Din0);
                        state1_q  <= mask_en_i ? flat2state(Din1) : '0;
                        round_ctr <= '0;
                        status_d  <= 1'b0;
                        // seed the PRNG bank (distinct per-lane, never all-zero)
                        for (kk = 0; kk < NLANE; kk = kk + 1)
                            prng_q[kk] <= (seed_i ^ (32'h9E3779B9 * kk)) | 32'h1;
                        st_q      <= STG1;
                    end
                end

                STG1: begin
                    // stage1_en (comb) is high now -> masked round latches its
                    // DOM partials on this edge. Advance PRNG so the NEXT round
                    // consumes a fresh 1600-bit word.
                    for (kk = 0; kk < NLANE; kk = kk + 1)
                        prng_q[kk] <= xs32(prng_q[kk]);
                    st_q <= STG2;
                end

                STG2: begin
                    state0_q <= round_out0;
                    state1_q <= round_out1;
                    if (round_ctr == NROUND-1) begin
                        st_q     <= FIN;
                    end else begin
                        round_ctr <= round_ctr + 1'b1;
                        st_q      <= STG1;
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
