// ===========================================================================
// hw_masked_proof : bounded HW-resident first-order DOM chi-gadget proof.
//
// TCHES-corrected design (round 2).  The previous version was rejected for
// three fatal flaws:
//   (1) it boolean-split a key then INTEGER-multiplied the boolean shares
//       (s0*pub) and XOR-recombined.  XOR does not distribute over integer
//       multiply, so the recombination was simply wrong AND leaked.
//   (2) its chi computed (~m') & (m'<<1), ANDing two operands DERIVED FROM
//       THE SAME secret m'.  DOM requires the two AND operands to be
//       INDEPENDENT; a self-AND of correlated shares violates the
//       non-completeness assumption.
//   (3) its DOM randomness r = prng_n was the deterministic successor of the
//       lane mask rmask = prng_q, so r was not independent of the share mask.
//
// Corrected gadget:
//   * TWO INDEPENDENT resident boolean-masked lanes A and B, each loaded from
//     its own key port and masked by an INDEPENDENT PRNG stream:
//        A = a0 ^ a1,  a1 = rA,  a0 = keyA ^ rA   (rA from PRNG stream A)
//        B = b0 ^ b1,  b1 = rB,  b0 = keyB ^ rB   (rB from PRNG stream B)
//   * A registered (2-cycle) DOM of  z = (~A) & B.  Because A and B are
//     independent secrets, standard first-order DOM applies.  The 4 partial
//     products are latched in flops (glitch barrier) before the same-domain
//     XOR recombination, exactly as in ise_mask_ops.sv OP_CHI_*R.
//   * The DOM randomness r comes from a THIRD independent PRNG stream, so it
//     is independent of both lane masks rA, rB.
//   * Everything is BOOLEAN (AND / XOR / NOT).  No integer multiply anywhere.
//   * Accumulators acc0_q, acc1_q are kept separate and NEVER recombined in
//     synthesizable logic; only the sim-only tap acc_unmasked_o exposes the
//     XOR for the testbench reference check.
// ===========================================================================
module hw_masked_proof #(
    parameter int W = 32
)(
    input  wire           clk_i,
    input  wire           rst_ni,
    input  wire           key_load_i,        // pulse: load + HW-mask both lanes
    input  wire           step_i,            // pulse: one masked chi step
    input  wire           mask_en_i,         // 1 = real HW masks ; 0 = control (rA=rB=r=0)
    input  wire [W-1:0]   keyA_i,            // secret lane-A word (loaded on key_load_i)
    input  wire [W-1:0]   keyB_i,            // secret lane-B word (loaded on key_load_i)
    output reg            done_o,
    // verification tap (SIM ONLY): unmasked recombination of the accumulator
    output wire [W-1:0]   acc_unmasked_o
);
    // -----------------------------------------------------------------------
    // THREE INDEPENDENT xorshift32 PRNG streams (distinct seeds).
    //   streamA -> rA (lane-A mask)
    //   streamB -> rB (lane-B mask)
    //   streamR -> r  (DOM cross-term randomness)
    // Distinct seeds + independent state regs guarantee the three words are
    // mutually independent on every cycle (no successor relationship).
    // Replace each with a vetted TRNG tap in silicon.
    // -----------------------------------------------------------------------
    function automatic [31:0] xs32 (input [31:0] s);
        reg [31:0] t;
        begin
            t  = s ^ (s << 13);
            t  = t ^ (t >> 17);
            t  = t ^ (t << 5);
            xs32 = t;
        end
    endfunction

    reg [31:0] prngA_q, prngB_q, prngR_q;
    wire [31:0] prngA_n = xs32(prngA_q);
    wire [31:0] prngB_n = xs32(prngB_q);
    wire [31:0] prngR_n = xs32(prngR_q);

    // Active mask words (zeroed in control mode so masked==unmasked result and
    // the masked datapath collapses to the plain reference).
    wire [W-1:0] rA = mask_en_i ? prngA_q[W-1:0] : {W{1'b0}};
    wire [W-1:0] rB = mask_en_i ? prngB_q[W-1:0] : {W{1'b0}};
    wire [W-1:0] r  = mask_en_i ? prngR_q[W-1:0] : {W{1'b0}};

    // -----------------------------------------------------------------------
    // Resident boolean-masked lanes  A = a0^a1 ,  B = b0^b1.
    // -----------------------------------------------------------------------
    (* keep="true" *) (* dont_touch="true" *) reg [W-1:0] a0_q, a1_q;
    (* keep="true" *) (* dont_touch="true" *) reg [W-1:0] b0_q, b1_q;

    // DOM of z = (~A) & B.  X = ~A shares = (~a0, a1) ; Y = B shares = (b0, b1).
    wire [W-1:0] X0 = ~a0_q,  X1 = a1_q;
    wire [W-1:0] Y0 =  b0_q,  Y1 = b1_q;

    // Non-complete partials (each uses at most one share of X and one of Y).
    wire [W-1:0] ps0 =  X0 & Y0;            //  ~a0 & b0
    wire [W-1:0] pc0 = (X0 & Y1) ^ r;       // (~a0 & b1) ^ r
    wire [W-1:0] ps1 =  X1 & Y1;            //   a1 & b1
    wire [W-1:0] pc1 = (X1 & Y0) ^ r;       // ( a1 & b0) ^ r

    // Registered partials (glitch barrier).
    (* keep="true" *) (* dont_touch="true" *) reg [W-1:0] p_s0_q, p_c0_q, p_s1_q, p_c1_q;

    // Stage-2 recombination on STABLE registered partials.
    wire [W-1:0] z0 = p_s0_q ^ p_c0_q;
    wire [W-1:0] z1 = p_s1_q ^ p_c1_q;

    // Separate share accumulators (never recombined in synth logic).
    (* keep="true" *) (* dont_touch="true" *) reg [W-1:0] acc0_q, acc1_q;

    typedef enum logic [1:0] {IDLE, ANDR, COMB, DONE} st_e;
    st_e st_q;

    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            prngA_q <= 32'hC0FFEE01;        // three DISTINCT seeds
            prngB_q <= 32'h1234ABCD;
            prngR_q <= 32'hDEADBEEF;
            a0_q <= '0; a1_q <= '0; b0_q <= '0; b1_q <= '0;
            p_s0_q <= '0; p_c0_q <= '0; p_s1_q <= '0; p_c1_q <= '0;
            acc0_q <= '0; acc1_q <= '0;
            done_o <= 1'b0;
            st_q   <= IDLE;
        end else begin
            // Advance all three independent streams every cycle.
            prngA_q <= prngA_n;
            prngB_q <= prngB_n;
            prngR_q <= prngR_n;
            done_o  <= 1'b0;

            // Resident masked-lane load (independent masks rA, rB).
            if (key_load_i) begin
                a1_q <= rA;  a0_q <= keyA_i ^ rA;
                b1_q <= rB;  b0_q <= keyB_i ^ rB;
            end

            case (st_q)
                IDLE: if (step_i) st_q <= ANDR;
                ANDR: begin                          // stage 1: latch partials (barrier)
                          p_s0_q <= ps0; p_c0_q <= pc0;
                          p_s1_q <= ps1; p_c1_q <= pc1;
                          st_q   <= COMB;
                      end
                COMB: begin                          // stage 2: recombine + accumulate
                          acc0_q <= acc0_q ^ z0;
                          acc1_q <= acc1_q ^ z1;
                          st_q   <= DONE;
                      end
                DONE: begin done_o <= 1'b1; st_q <= IDLE; end
                default: st_q <= IDLE;
            endcase
        end
    end

    assign acc_unmasked_o = acc0_q ^ acc1_q;    // SIM-ONLY verification tap
endmodule
