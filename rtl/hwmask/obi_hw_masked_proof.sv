// ============================================================================
// obi_hw_masked_proof : flat-OBI MMIO wrapper around hw_masked_proof.
//
// Exposes the HW-resident first-order DOM chi-gadget proof to firmware as a
// memory-mapped peripheral on the user domain OBI bus (UserBaseAddr+0x2000).
//
// The wrapped hw_masked_proof holds two boolean-masked lanes A,B (each loaded
// UNMASKED via keyA_i/keyB_i and masked INTERNALLY by independent HW PRNG).
// CTRL.key_load loads+masks the lanes; CTRL.run issues NREP=400 chi step_i
// pulses (one chi step per step_i pulse: ANDR->COMB->DONE), accumulating
// internally; STATUS.done reports idle/finished.
//
// Register Map (low 8 bits of OBI address):
//   0x00  CTRL      [W]  [0]=key_load (pulse), [1]=run (pulse), [2]=mask_en
//   0x04  STATUS    [R]  [1]=done/idle (1 = idle and last run complete)
//   0x08  KEYA_IN   [W]  lane-A secret word (used on next key_load)
//   0x0C  KEYB_IN   [W]  lane-B secret word (used on next key_load)
//
// OBI protocol (matches obi_a2b_b2a_peripheral): gnt = req (same cycle),
// rvalid registered one cycle later, rdata combinational from latched addr.
// ============================================================================

module obi_hw_masked_proof #(
  parameter int W    = 32,
  parameter int NREP = 400
)(
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
  // Address decode — low 8 bits select the register
  // -------------------------------------------------------------------------
  wire [7:0] reg_addr = obi_addr_i[7:0];

  localparam [7:0] ADDR_CTRL    = 8'h00;
  localparam [7:0] ADDR_STATUS  = 8'h04;
  localparam [7:0] ADDR_KEYA_IN = 8'h08;
  localparam [7:0] ADDR_KEYB_IN = 8'h0C;

  // -------------------------------------------------------------------------
  // OBI grant: always grant immediately (single-cycle address phase)
  // -------------------------------------------------------------------------
  assign obi_gnt_o = obi_req_i;

  // -------------------------------------------------------------------------
  // Latched request for response phase
  // -------------------------------------------------------------------------
  reg        req_pending_q;
  reg [7:0]  req_addr_q;
  reg        req_we_q;

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      req_pending_q <= 1'b0;
      req_addr_q    <= 8'd0;
      req_we_q      <= 1'b0;
    end else begin
      req_pending_q <= obi_req_i & obi_gnt_o;
      if (obi_req_i & obi_gnt_o) begin
        req_addr_q  <= obi_addr_i[7:0];
        req_we_q    <= obi_we_i;
      end
    end
  end

  // -------------------------------------------------------------------------
  // Config / data registers
  // -------------------------------------------------------------------------
  reg [W-1:0] keyA_r;
  reg [W-1:0] keyB_r;
  reg         mask_en_r;

  // -------------------------------------------------------------------------
  // hw_masked_proof instance + drive signals
  // -------------------------------------------------------------------------
  reg          key_load_pulse;   // 1-cycle pulse to wrapped instance
  reg          step_pulse;       // 1-cycle step pulse to wrapped instance
  wire         hwm_done;
  wire [W-1:0] hwm_acc_unmasked; // SIM-ONLY tap (unused here)

  hw_masked_proof #(.W(W)) u_hwm (
    .clk_i          (clk_i),
    .rst_ni         (rst_ni),
    .key_load_i     (key_load_pulse),
    .step_i         (step_pulse),
    .mask_en_i      (mask_en_r),
    .keyA_i         (keyA_r),
    .keyB_i         (keyB_r),
    .done_o         (hwm_done),
    .acc_unmasked_o (hwm_acc_unmasked)
  );

  // -------------------------------------------------------------------------
  // Run-sequencer FSM: on CTRL.run, issue NREP step_i pulses, waiting for
  // done_o between each, then assert STATUS.done.
  //
  //   IDLE     : wait for run_req
  //   STEP     : emit one step_pulse, go WAIT
  //   WAIT     : wait for hwm_done; if more reps -> STEP else -> finished
  // -------------------------------------------------------------------------
  localparam [1:0] S_IDLE = 2'd0, S_STEP = 2'd1, S_WAIT = 2'd2;
  reg [1:0]                  seq_q;
  reg [$clog2(NREP+1)-1:0]   rep_cnt_q;
  reg                        run_req;       // set by CTRL write, cleared when consumed
  reg                        status_done_q; // STATUS.done : 1 = idle / last run finished

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      keyA_r         <= {W{1'b0}};
      keyB_r         <= {W{1'b0}};
      mask_en_r      <= 1'b0;
      key_load_pulse <= 1'b0;
      step_pulse     <= 1'b0;
      seq_q          <= S_IDLE;
      rep_cnt_q      <= '0;
      run_req        <= 1'b0;
      status_done_q  <= 1'b1;   // idle out of reset
    end else begin
      // default: clear single-cycle pulses
      key_load_pulse <= 1'b0;
      step_pulse     <= 1'b0;

      // --- Register writes (address phase, immediate) ---
      if (obi_req_i && obi_we_i) begin
        case (reg_addr)
          ADDR_CTRL: begin
            mask_en_r <= obi_wdata_i[2];
            if (obi_wdata_i[0]) begin
              // key_load: pulse the wrapped instance with stored keys + mask_en
              key_load_pulse <= 1'b1;
            end
            if (obi_wdata_i[1] && seq_q == S_IDLE) begin
              // run: kick the step sequencer
              run_req       <= 1'b1;
              status_done_q <= 1'b0;
            end
          end
          ADDR_KEYA_IN: keyA_r <= obi_wdata_i[W-1:0];
          ADDR_KEYB_IN: keyB_r <= obi_wdata_i[W-1:0];
          default: ; // writes to read-only / unmapped ignored
        endcase
      end

      // --- Step sequencer FSM ---
      case (seq_q)
        S_IDLE: begin
          if (run_req) begin
            run_req   <= 1'b0;
            rep_cnt_q <= '0;
            seq_q     <= S_STEP;
          end
        end
        S_STEP: begin
          step_pulse <= 1'b1;   // one chi step
          seq_q      <= S_WAIT;
        end
        S_WAIT: begin
          if (hwm_done) begin
            if (rep_cnt_q == NREP-1) begin
              status_done_q <= 1'b1;   // all reps complete
              seq_q         <= S_IDLE;
            end else begin
              rep_cnt_q <= rep_cnt_q + 1'b1;
              seq_q     <= S_STEP;
            end
          end
        end
        default: seq_q <= S_IDLE;
      endcase
    end
  end

  // -------------------------------------------------------------------------
  // Read logic (response phase). rvalid registered; rdata combinational from
  // latched req_addr_q so it is valid on the cycle rvalid is asserted.
  // -------------------------------------------------------------------------
  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) obi_rvalid_o <= 1'b0;
    else         obi_rvalid_o <= req_pending_q;
  end

  always @(*) begin
    obi_rdata_o = 32'd0;
    if (!req_we_q) begin
      case (req_addr_q)
        ADDR_STATUS: obi_rdata_o = {30'd0, status_done_q, 1'b0}; // bit[1]=done
        default:     obi_rdata_o = 32'd0;
      endcase
    end
  end

endmodule
