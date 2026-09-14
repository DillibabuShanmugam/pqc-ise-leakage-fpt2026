//////////////////////////////////////////////////////////////////////////////////////////
// Design Name:  keccak_round_masked
// Language:     SystemVerilog
//
// First-order DOM (2-share) masked Keccak-f[1600] round, forked from the CIRCE
// unmasked keccak_round (Dolmeta & Piscopo, PoliTo; Peeters & Van Assche).
//
// ------------------------------------------------------------------------------
// CIRCE round order (unmasked, see keccak_round.sv): theta -> rho -> pi -> chi -> iota.
// theta, rho, pi, iota are GF(2)-LINEAR; chi is the only nonlinear (degree-2) step.
//
//   chi : chi_out[y][x][i] = chi_in[y][x][i] ^ ( ~chi_in[y][x+1][i] & chi_in[y][x+2][i] )
//
// MASKING STRATEGY (matches doc/masked_keccak_hw_scope.md and hw_masked_proof.sv):
//   * Carry the state as TWO Boolean shares  S = S0 ^ S1.
//   * Apply theta/rho/pi/iota to EACH share independently (linear -> per-bank
//     replication is exact). iota XORs the public round constant into share-0 ONLY.
//   * For chi, the AND operands are  b = chi_in[y][x+1]  and  c = chi_in[y][x+2].
//     These are DISTINCT state lanes (different x), hence INDEPENDENT secrets ->
//     standard first-order DOM-AND of  z = (~b) & c  applies directly using the
//     two shares of b and of c, plus one fresh random bit per (y,x,i) lane-bit.
//   * The 4 DOM partial products are LATCHED IN A REGISTER (glitch barrier) before
//     the same-domain XOR recombination, exactly as in hw_masked_proof. This makes
//     the masked round 2-cycle:
//       stage 1 : compute theta/rho/pi on both shares -> chi_in shares -> DOM
//                 partials, REGISTER the partials (glitch barrier).
//       stage 2 : recombine partials into chi_out shares, then apply iota.
//
// DOM-AND of z = (~b) & c, shares b=(b0,b1), c=(c0,c1), fresh r:
//     X0 = ~b0 , X1 = b1            ( ~b shares ;  ~b = ~(b0^b1) = (~b0)^b1 )
//     Y0 =  c0 , Y1 = c1
//     ps0 =  X0 & Y0                       // domain-0 same
//     pc0 = (X0 & Y1) ^ r                  // cross 0<-1, remasked
//     ps1 =  X1 & Y1                       // domain-1 same
//     pc1 = (X1 & Y0) ^ r                  // cross 1<-0, remasked
//     -- REGISTER ps0,pc0,ps1,pc1 (barrier) --
//     z0 = ps0_q ^ pc0_q ;  z1 = ps1_q ^ pc1_q     // z0^z1 = (~b)&c
//   chi_out share0 = chi_in0 ^ z0 ;  chi_out share1 = chi_in1 ^ z1
//
// Non-completeness: each stage-1 term uses at most one share of b and one of c.
//
// mask_en = 0 collapses to the plain round:
//   - randomness is forced to 0 (r=0),
//   - share-1 input path is forced to 0 by the caller (keccak_f_masked feeds
//     Round_in1 = 0 in unmasked mode), so chi_in1 = 0 -> b1=c1=0 ->
//     ps1=pc1=0 -> z1 = 0 (share1 stays 0), and z0 = (~b0)&c0 == plain chi term.
//   Output share0 then equals the plain CIRCE round bit-for-bit.
//
// Randomness budget: 1600 fresh bits / round (25 lanes x 64 bits).
// Latency: 2 cycles / round.
//////////////////////////////////////////////////////////////////////////////////////////

import pkg_keccak::k_plane;
import pkg_keccak::k_state;
import pkg_keccak::KEC_N;
import pkg_keccak::ABS;

module keccak_round_masked (
    input  logic            clk_i,
    input  logic            rst_ni,            // async active-low
    input  logic            stage1_en_i,       // pulse: latch DOM partials (start round)
    input  k_state          Round_in0,         // share 0 of round input
    input  k_state          Round_in1,         // share 1 of round input
    input  k_state          rnd_i,             // 1600 fresh random bits (one per lane-bit)
    input  logic [7:0]      Round_constant_signal,
    input  logic            mask_en_i,         // 1 = masked ; 0 = collapse to plain
    output k_state          Round_out0,        // share 0 of round output
    output k_state          Round_out1         // share 1 of round output
);

    // =======================================================================
    // Linear steps theta -> rho -> pi, replicated per share (combinational).
    // chi_in0 / chi_in1 are the per-share chi inputs (= pi_out of each bank).
    // =======================================================================
    k_state chi_in0, chi_in1;

    keccak_linear_thetarhopi u_lin0 (.Round_in(Round_in0), .pi_out(chi_in0));
    keccak_linear_thetarhopi u_lin1 (.Round_in(Round_in1), .pi_out(chi_in1));

    // Effective fresh randomness (zeroed in unmasked mode).
    k_state r_eff;
    genvar gy, gx, gi;
    generate
        for (gy = 0; gy <= 4; gy++)
            for (gx = 0; gx <= 4; gx++)
                for (gi = 0; gi <= KEC_N-1; gi++)
                    assign r_eff[gy][gx][gi] = mask_en_i ? rnd_i[gy][gx][gi] : 1'b0;
    endgenerate

    // =======================================================================
    // chi DOM-AND : for each (y,x,i):  z = (~b) & c
    //   b = chi_in[y][(x+1)%5] , c = chi_in[y][(x+2)%5]
    // shares: b0=chi_in0[y][x+1], b1=chi_in1[y][x+1], c0=chi_in0[y][x+2], ...
    // X = ~b shares = (~b0, b1) ; Y = c shares = (c0, c1).
    // =======================================================================
    k_state ps0_c, pc0_c, ps1_c, pc1_c;   // combinational partials

    generate
        for (gy = 0; gy <= 4; gy++)
            for (gx = 0; gx <= 4; gx++)
                for (gi = 0; gi <= KEC_N-1; gi++) begin : g_dom
                    localparam int XB = (gx + 1) % 5;   // index of b
                    localparam int XC = (gx + 2) % 5;   // index of c
                    wire b0 = chi_in0[gy][XB][gi];
                    wire b1 = chi_in1[gy][XB][gi];
                    wire c0 = chi_in0[gy][XC][gi];
                    wire c1 = chi_in1[gy][XC][gi];
                    wire X0 = ~b0;   // (~b) share 0
                    wire X1 =  b1;   // (~b) share 1
                    wire Y0 =  c0;   //  c   share 0
                    wire Y1 =  c1;   //  c   share 1
                    assign ps0_c[gy][gx][gi] =  X0 & Y0;
                    assign pc0_c[gy][gx][gi] = (X0 & Y1) ^ r_eff[gy][gx][gi];
                    assign ps1_c[gy][gx][gi] =  X1 & Y1;
                    assign pc1_c[gy][gx][gi] = (X1 & Y0) ^ r_eff[gy][gx][gi];
                end
    endgenerate

    // -----------------------------------------------------------------------
    // Glitch barrier: register the 4 partials AND the linear chi_in shares
    // (so stage-2 recombination sees a stable, glitch-isolated snapshot).
    // -----------------------------------------------------------------------
    (* keep = "true" *) (* dont_touch = "true" *) k_state ps0_q, pc0_q, ps1_q, pc1_q;
    k_state chi_in0_q, chi_in1_q;
    logic [7:0] rc_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            ps0_q <= '0; pc0_q <= '0; ps1_q <= '0; pc1_q <= '0;
            chi_in0_q <= '0; chi_in1_q <= '0;
            rc_q <= '0;
        end else if (stage1_en_i) begin
            ps0_q <= ps0_c; pc0_q <= pc0_c; ps1_q <= ps1_c; pc1_q <= pc1_c;
            chi_in0_q <= chi_in0; chi_in1_q <= chi_in1;
            rc_q <= Round_constant_signal;
        end
    end

    // =======================================================================
    // Stage 2 : recombine -> chi_out shares, then iota (constant into share0).
    // =======================================================================
    k_state z0, z1, chi_out0, chi_out1;
    generate
        for (gy = 0; gy <= 4; gy++)
            for (gx = 0; gx <= 4; gx++)
                for (gi = 0; gi <= KEC_N-1; gi++) begin : g_recomb
                    assign z0[gy][gx][gi] = ps0_q[gy][gx][gi] ^ pc0_q[gy][gx][gi];
                    assign z1[gy][gx][gi] = ps1_q[gy][gx][gi] ^ pc1_q[gy][gx][gi];
                    assign chi_out0[gy][gx][gi] = chi_in0_q[gy][gx][gi] ^ z0[gy][gx][gi];
                    assign chi_out1[gy][gx][gi] = chi_in1_q[gy][gx][gi] ^ z1[gy][gx][gi];
                end
    endgenerate

    // iota : XOR the public round constant into lane (0,0) of share0 ONLY.
    keccak_linear_iota u_iota0 (.iota_in(chi_out0), .Round_constant_signal(rc_q), .iota_out(Round_out0));
    // share1 gets iota with a ZERO constant (pure pass-through) so the share
    // split is preserved (constant is public, belongs in one share only).
    keccak_linear_iota u_iota1 (.iota_in(chi_out1), .Round_constant_signal(8'h00), .iota_out(Round_out1));

endmodule


//////////////////////////////////////////////////////////////////////////////////////////
// keccak_linear_thetarhopi : combinational theta -> rho -> pi (one share).
// Verbatim copy of the CIRCE keccak_round linear assigns (NOT touched there).
//////////////////////////////////////////////////////////////////////////////////////////
module keccak_linear_thetarhopi (
    input  k_state Round_in,
    output k_state pi_out
);
    k_state theta_in, theta_out, rho_in, rho_out, pi_in;
    k_plane sum_sheet;

    assign theta_in = Round_in;
    assign rho_in   = theta_out;
    assign pi_in    = rho_out;

    genvar y, x, i;

    // Theta
    generate
        for (x = 0; x <= 4; x++)
            for (i = 0; i <= KEC_N-1; i++)
                assign sum_sheet[x][i] = theta_in[0][x][i] ^ theta_in[1][x][i] ^ theta_in[2][x][i] ^ theta_in[3][x][i] ^ theta_in[4][x][i];
    endgenerate

    generate
        for (y = 0; y <= 4; y++)
            for (x = 1; x <= 3; x++) begin
                assign theta_out[y][x][0] = theta_in[y][x][0] ^ sum_sheet[x-1][0] ^ sum_sheet[x+1][KEC_N-1];
                for (i = 1; i <= KEC_N-1; i++)
                    assign theta_out[y][x][i] = theta_in[y][x][i] ^ sum_sheet[x-1][i] ^ sum_sheet[x+1][i-1];
            end
    endgenerate

    generate
        for (y = 0; y <= 4; y++) begin
            assign theta_out[y][0][0] = theta_in[y][0][0] ^ sum_sheet[4][0] ^ sum_sheet[1][KEC_N-1];
            for (i = 1; i <= KEC_N-1; i++)
                assign theta_out[y][0][i] = theta_in[y][0][i] ^ sum_sheet[4][i] ^ sum_sheet[1][i-1];
        end
    endgenerate

    generate
        for (y = 0; y <= 4; y++) begin
            assign theta_out[y][4][0] = theta_in[y][4][0] ^ sum_sheet[3][0] ^ sum_sheet[0][KEC_N-1];
            for (i = 1; i <= KEC_N-1; i++)
                assign theta_out[y][4][i] = theta_in[y][4][i] ^ sum_sheet[3][i] ^ sum_sheet[0][i-1];
        end
    endgenerate

    // Rho
    always_comb begin
        for (int ri = 0; ri < KEC_N; ri++) begin
            rho_out[0][0][ri] = rho_in[0][0][ri];
            rho_out[0][1][ri] = rho_in[0][1][ABS((ri-1)  % KEC_N)];
            rho_out[0][2][ri] = rho_in[0][2][ABS((ri-62) % KEC_N)];
            rho_out[0][3][ri] = rho_in[0][3][ABS((ri-28) % KEC_N)];
            rho_out[0][4][ri] = rho_in[0][4][ABS((ri-27) % KEC_N)];

            rho_out[1][0][ri] = rho_in[1][0][ABS((ri-36) % KEC_N)];
            rho_out[1][1][ri] = rho_in[1][1][ABS((ri-44) % KEC_N)];
            rho_out[1][2][ri] = rho_in[1][2][ABS((ri-6)  % KEC_N)];
            rho_out[1][3][ri] = rho_in[1][3][ABS((ri-55) % KEC_N)];
            rho_out[1][4][ri] = rho_in[1][4][ABS((ri-20) % KEC_N)];

            rho_out[2][0][ri] = rho_in[2][0][ABS((ri-3)  % KEC_N)];
            rho_out[2][1][ri] = rho_in[2][1][ABS((ri-10) % KEC_N)];
            rho_out[2][2][ri] = rho_in[2][2][ABS((ri-43) % KEC_N)];
            rho_out[2][3][ri] = rho_in[2][3][ABS((ri-25) % KEC_N)];
            rho_out[2][4][ri] = rho_in[2][4][ABS((ri-39) % KEC_N)];

            rho_out[3][0][ri] = rho_in[3][0][ABS((ri-41) % KEC_N)];
            rho_out[3][1][ri] = rho_in[3][1][ABS((ri-45) % KEC_N)];
            rho_out[3][2][ri] = rho_in[3][2][ABS((ri-15) % KEC_N)];
            rho_out[3][3][ri] = rho_in[3][3][ABS((ri-21) % KEC_N)];
            rho_out[3][4][ri] = rho_in[3][4][ABS((ri-8)  % KEC_N)];

            rho_out[4][0][ri] = rho_in[4][0][ABS((ri-18) % KEC_N)];
            rho_out[4][1][ri] = rho_in[4][1][ABS((ri-2)  % KEC_N)];
            rho_out[4][2][ri] = rho_in[4][2][ABS((ri-61) % KEC_N)];
            rho_out[4][3][ri] = rho_in[4][3][ABS((ri-56) % KEC_N)];
            rho_out[4][4][ri] = rho_in[4][4][ABS((ri-14) % KEC_N)];
        end
    end

    // Pi
    generate
        for (y = 0; y <= 4; y++)
            for (x = 0; x <= 4; x++)
                for (i = 0; i <= KEC_N-1; i++)
                    assign pi_out[(2*x+3*y) % 5][0*x+1*y][i] = pi_in[y][x][i];
    endgenerate

endmodule


//////////////////////////////////////////////////////////////////////////////////////////
// keccak_linear_iota : combinational iota. Verbatim copy of CIRCE keccak_round iota.
//////////////////////////////////////////////////////////////////////////////////////////
module keccak_linear_iota (
    input  k_state     iota_in,
    input  logic [7:0] Round_constant_signal,
    output k_state     iota_out
);
    genvar y, x, i;
    generate
        for (y = 1; y <= 4; y++)
            for (x = 0; x <= 4; x++)
                for (i = 0; i <= KEC_N-1; i++)
                    assign iota_out[y][x][i] = iota_in[y][x][i];
    endgenerate
    generate
        for (x = 1; x <= 4; x++)
            for (i = 0; i <= KEC_N-1; i++)
                assign iota_out[0][x][i] = iota_in[0][x][i];
    endgenerate

    always_comb begin
        iota_out[0][0] = iota_in[0][0];
        iota_out[0][0][0]  = iota_in[0][0][0]  ^ Round_constant_signal[0];
        iota_out[0][0][1]  = iota_in[0][0][1]  ^ Round_constant_signal[1];
        iota_out[0][0][2]  = iota_in[0][0][2]  ^ Round_constant_signal[2];
        iota_out[0][0][3]  = iota_in[0][0][3]  ^ Round_constant_signal[3];
        iota_out[0][0][7]  = iota_in[0][0][7]  ^ Round_constant_signal[4];
        iota_out[0][0][15] = iota_in[0][0][15] ^ Round_constant_signal[5];
        iota_out[0][0][31] = iota_in[0][0][31] ^ Round_constant_signal[6];
        iota_out[0][0][63] = iota_in[0][0][63] ^ Round_constant_signal[7];
    end
endmodule
