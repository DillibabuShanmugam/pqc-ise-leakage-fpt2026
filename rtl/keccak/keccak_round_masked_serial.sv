//////////////////////////////////////////////////////////////////////////////////////////
// Design Name:  keccak_round_masked_serial helpers
// Language:     SystemVerilog
//
// LANE-SERIAL first-order DOM (2-share) masked Keccak-f[1600] datapath helpers.
//
// Motivation: the full-round masked core (keccak_round_masked.sv) instantiates
// the chi DOM-AND 1600 times COMBINATIONALLY (25 lanes x 64 bits), costing
// ~22k LUTs — far over the CW305 xc7a35t budget. This serial variant computes
// the cheap GF(2)-LINEAR steps (theta/rho/pi) once per round, full width, on
// each share; then it folds the nonlinear chi step onto ONE reusable 64-bit
// first-order DOM-AND unit, processing ONE output lane (y,x) per cycle. 25
// lanes -> 25 chi cycles per round. Fresh randomness is only 64 bits/cycle.
//
// Files in this unit:
//   * keccak_dom_and64  : ONE registered (glitch-barrier) 64-bit first-order
//                         DOM-AND of z = (~b) & c. Same gadget as
//                         keccak_round_masked.sv, widened to a 64-bit lane.
//   * (keccak_linear_thetarhopi / keccak_linear_iota live in
//      keccak_round_masked.sv and are reused here.)
//
// The DOM-AND of z = (~b) & c, shares b=(b0,b1), c=(c0,c1), fresh r (per bit):
//     X0 = ~b0 , X1 = b1            ( ~b shares ;  ~b = ~(b0^b1) = (~b0)^b1 )
//     Y0 =  c0 , Y1 = c1
//     ps0 =  X0 & Y0                       // domain-0 same
//     pc0 = (X0 & Y1) ^ r                  // cross 0<-1, remasked
//     ps1 =  X1 & Y1                       // domain-1 same
//     pc1 = (X1 & Y0) ^ r                  // cross 1<-0, remasked
//     -- REGISTER ps0,pc0,ps1,pc1 (barrier) --
//     z0 = ps0_q ^ pc0_q ;  z1 = ps1_q ^ pc1_q     // z0^z1 = (~b)&c
// Non-completeness: each stage-1 term uses at most one share of b and one of c.
//
// mask_en = 0 collapses to plain: r forced 0 and (by the caller) share-1 input
// forced 0, so z1 = 0 and z0 = (~b0)&c0 = the plain chi term.
//////////////////////////////////////////////////////////////////////////////////////////

import pkg_keccak::KEC_N;

//------------------------------------------------------------------------------
// keccak_dom_and64 : 64-bit registered first-order DOM-AND of z = (~b) & c.
// stage1_en_i latches the four partials; outputs z0/z1 are combinational from
// the latched partials (one cycle after stage1_en_i was asserted with the
// operands b0/b1/c0/c1 and randomness r present).
//------------------------------------------------------------------------------
module keccak_dom_and64 (
    input  logic                  clk_i,
    input  logic                  rst_ni,        // async active-low
    input  logic                  stage1_en_i,   // latch partials this edge
    input  logic [KEC_N-1:0]      b0,            // share0 of operand b
    input  logic [KEC_N-1:0]      b1,            // share1 of operand b
    input  logic [KEC_N-1:0]      c0,            // share0 of operand c
    input  logic [KEC_N-1:0]      c1,            // share1 of operand c
    input  logic [KEC_N-1:0]      r,             // fresh randomness (zeroed if !mask)
    output logic [KEC_N-1:0]      z0,            // share0 of z = (~b)&c
    output logic [KEC_N-1:0]      z1             // share1 of z
);
    // (~b) shares : X0 = ~b0, X1 = b1.  c shares : Y0 = c0, Y1 = c1.
    logic [KEC_N-1:0] X0, X1, Y0, Y1;
    assign X0 = ~b0;
    assign X1 =  b1;
    assign Y0 =  c0;
    assign Y1 =  c1;

    // Combinational partials.
    logic [KEC_N-1:0] ps0_c, pc0_c, ps1_c, pc1_c;
    assign ps0_c =  X0 & Y0;
    assign pc0_c = (X0 & Y1) ^ r;
    assign ps1_c =  X1 & Y1;
    assign pc1_c = (X1 & Y0) ^ r;

    // Glitch barrier: register the four partials.
    (* keep = "true" *) (* dont_touch = "true" *) logic [KEC_N-1:0] ps0_q, pc0_q, ps1_q, pc1_q;
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            ps0_q <= '0; pc0_q <= '0; ps1_q <= '0; pc1_q <= '0;
        end else if (stage1_en_i) begin
            ps0_q <= ps0_c; pc0_q <= pc0_c; ps1_q <= ps1_c; pc1_q <= pc1_c;
        end
    end

    assign z0 = ps0_q ^ pc0_q;
    assign z1 = ps1_q ^ pc1_q;
endmodule
