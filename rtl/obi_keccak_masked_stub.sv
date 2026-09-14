// ============================================================================
// obi_keccak_masked_stub : drop-in EMPTY replacement for obi_keccak_masked,
// used by the SOFTWARE-MASKED build variant (synth_croc_sca_pqc_swmask.tcl).
//
// Why: the real DOM-masked serial Keccak peripheral is ~9.3k LUTs and pushes
// the full protected SoC over the xc7a35t (CW305) LUT budget (~25k vs 20.8k).
// In the software-masked decapsulation firmware (sw/mlkem1024_masked,
// main_masked.c) the masked G and masked rkprf are computed in SOFTWARE on the
// DOM datapath, so the UserKeccakM @ UserBaseAddr+0x4000 peripheral is never
// accessed. Keeping its address slot wired to this stub preserves the SoC
// structure / address map (user_pkg.sv unchanged) while reclaiming the LUTs.
//
// IDENTICAL port list to obi_keccak_masked. OBI slave that always grants,
// returns 0, and pulses rvalid one cycle after a request (registered-rvalid,
// matches the real peripheral's handshake). Synthesizes to ~1 flop.
// ============================================================================

module obi_keccak_masked (
  input  wire        clk_i,
  input  wire        rst_ni,
  input  wire        obi_req_i,
  output wire        obi_gnt_o,
  input  wire [31:0] obi_addr_i,
  input  wire        obi_we_i,
  input  wire [3:0]  obi_be_i,
  input  wire [31:0] obi_wdata_i,
  output reg         obi_rvalid_o,
  output reg  [31:0] obi_rdata_o
);
  // Unused inputs (silence lint); the stub holds no state.
  wire _unused = &{1'b0, obi_addr_i, obi_we_i, obi_be_i, obi_wdata_i};

  assign obi_gnt_o = obi_req_i;            // single-cycle address phase

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) obi_rvalid_o <= 1'b0;
    else         obi_rvalid_o <= obi_req_i;   // rvalid one cycle after grant
  end

  always @(*) obi_rdata_o = 32'd0;
endmodule
