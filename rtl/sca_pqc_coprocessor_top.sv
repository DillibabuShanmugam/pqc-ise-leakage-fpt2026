// ============================================================================
// SCA_Pro_PQC — Coprocessor Top
// 38-instruction ISE with Hamming-3 FSM, PRNG safety interlock
// CVXIF: IDLE → ISE_RESULT → RESULT_READY → IDLE (3 cycles/instruction)
// ============================================================================
`include "sca_pqc_pkg.sv"

module sca_pqc_coprocessor_top (
  input  wire        clk_i,
  input  wire        rst_ni,

  // CVXIF Issue interface
  input  wire        x_issue_valid_i,
  output reg         x_issue_ready_o,
  input  wire [31:0] x_issue_req_instr_i,
  input  wire [31:0] x_issue_req_rs1_i,
  input  wire [31:0] x_issue_req_rs2_i,
  output reg         x_issue_resp_accept_o,

  // CVXIF Result interface
  output reg         x_result_valid_o,
  input  wire        x_result_ready_i,
  output reg  [31:0] x_result_data_o,

  // CVXIF Commit interface (unused but wired)
  input  wire        x_commit_valid_i
);

  // =========================================================================
  // FSM states — Hamming-3 encoded for single-bit upset detection
  // =========================================================================
  localparam [2:0] ST_IDLE         = 3'b000;
  localparam [2:0] ST_ISE_RESULT   = 3'b011;
  localparam [2:0] ST_RESULT_READY = 3'b101;
  // ST_WAIT (xc7a100t retarget): generic multi-cycle wait for the tightly-coupled
  // A2B/B2A conversion cores and the state-resident DOM-masked Keccak. Issue is
  // stalled until the active core asserts done. Code 3'b110 keeps the same
  // pairwise Hamming-distance-2 spacing as the other three FSM states.
  localparam [2:0] ST_WAIT         = 3'b110;

  (* keep = "true" *) (* keep_hierarchy = "true" *) reg [2:0] state_q;
  reg [2:0] state_d;

  // =========================================================================
  // Instruction decode: opcode + funct3 + funct7[3:0] → 6-bit decoded_op
  // Also extract funct7[4] (bit 29) for dual-Q selection in mask ops
  // =========================================================================
  wire [6:0] instr_opcode    = x_issue_req_instr_i[6:0];
  wire [2:0] instr_funct3    = x_issue_req_instr_i[14:12];
  wire [3:0] instr_funct7_lo = x_issue_req_instr_i[28:25];
  wire       instr_funct7_4  = x_issue_req_instr_i[29]; // Q sel / wide_mode / share sel
  wire       instr_funct7_5  = x_issue_req_instr_i[30]; // A2B(0)/B2A(1) direction page

  reg [5:0] decoded_op;

  always @(*) begin
    decoded_op = `OP_INVALID;
    if (instr_opcode == `CUSTOM3_OPCODE) begin
      case (instr_funct3)
        `GRP_KECCAK: begin
          case (instr_funct7_lo)
            4'd0:  decoded_op = `OP_SET_C;
            4'd1:  decoded_op = `OP_BCOP32_AB;
            4'd2:  decoded_op = `OP_SET_HI;
            4'd3:  decoded_op = `OP_ROL32_L;
            4'd4:  decoded_op = `OP_ROL32_H;
            4'd5:  decoded_op = `OP_XOR3;
            // State-resident Keccak ops REINSTATED on the xc7a100t (funct7_lo 6..12).
            4'd6:  decoded_op = `OP_KECCAK_LDW;
            4'd7:  decoded_op = `OP_KECCAK_PERM;
            4'd8:  decoded_op = `OP_KECCAK_RDW;
            4'd9:  decoded_op = `OP_MKECCAK_SEED;
            4'd10: decoded_op = `OP_MKECCAK_LDW;
            4'd11: decoded_op = `OP_MKECCAK_PERM;
            4'd12: decoded_op = `OP_MKECCAK_RDW;
            default: decoded_op = `OP_INVALID;
          endcase
        end
        `GRP_MOD_ARITH: begin
          case (instr_funct7_lo)
            4'd0:  decoded_op = `OP_BARRETT_K;
            4'd1:  decoded_op = `OP_MONT_K;
            4'd2:  decoded_op = `OP_CADDQ;
            4'd3:  decoded_op = `OP_BARRETT_D;
            4'd4:  decoded_op = `OP_MONT_D;
            default: decoded_op = `OP_INVALID;
          endcase
        end
        `GRP_BUTTERFLY: begin
          case (instr_funct7_lo)
            4'd0:  decoded_op = `OP_NTT_BFLY_CT;
            4'd1:  decoded_op = `OP_NTT_BFLY_GS;
            4'd2:  decoded_op = `OP_NTT_BFLY_CT_MUL;
            4'd3:  decoded_op = `OP_NTT_BFLY_GS_MUL;
            default: decoded_op = `OP_INVALID;
          endcase
        end
        `GRP_CBD: begin
          case (instr_funct7_lo)
            4'd0:  decoded_op = `OP_CBD2_1;
            4'd1:  decoded_op = `OP_CBD2_2;
            4'd2:  decoded_op = `OP_CBD2_3;
            4'd3:  decoded_op = `OP_CBD2_4;
            4'd4:  decoded_op = `OP_CBD2_5;
            4'd5:  decoded_op = `OP_CBD2_6;
            4'd6:  decoded_op = `OP_CBD2_7;
            4'd7:  decoded_op = `OP_CBD2_8;
            4'd8:  decoded_op = `OP_CBD3_1;
            4'd9:  decoded_op = `OP_CBD3_2;
            4'd10: decoded_op = `OP_CBD3_3;
            4'd11: decoded_op = `OP_CBD3_4;
            default: decoded_op = `OP_INVALID;
          endcase
        end
        `GRP_COMPRESS: begin
          case (instr_funct7_lo)
            4'd0:  decoded_op = `OP_COMPRESS_1;
            4'd1:  decoded_op = `OP_COMPRESS_2;
            4'd2:  decoded_op = `OP_COMPRESS_3;
            4'd3:  decoded_op = `OP_COMPRESS_4;
            4'd4:  decoded_op = `OP_REJ_UNIFORM;
            4'd5:  decoded_op = `OP_COMPRESS_5;
            default: decoded_op = `OP_INVALID;
          endcase
        end
        `GRP_MLDSA: begin
          case (instr_funct7_lo)
            4'd0:  decoded_op = `OP_POWER2ROUND;
            4'd1:  decoded_op = `OP_DECOMPOSE;
            default: decoded_op = `OP_INVALID;
          endcase
        end
        `GRP_MASK: begin
          case (instr_funct7_lo)
            4'd0:  decoded_op = `OP_SECMUL_STEP;
            4'd1:  decoded_op = `OP_MASK_REFRESH;
            4'd2:  decoded_op = `OP_MASKED_AND;
            4'd3:  decoded_op = `OP_MASKED_XOR;
            4'd4:  decoded_op = `OP_SECMUL_LATCH;
            4'd5:  decoded_op = `OP_SECMUL_REUSE;
            4'd6:  decoded_op = `OP_AND_LATCH;
            4'd7:  decoded_op = `OP_AND_REUSE;
            4'd8:  decoded_op = `OP_CHI_LOADX;
            4'd9:  decoded_op = `OP_CHI_AND;
            4'd10: decoded_op = `OP_CHI_RDZ1;
            4'd11: decoded_op = `OP_CHI_ANDR;
            4'd12: decoded_op = `OP_CHI_RDZ0R;
            4'd13: decoded_op = `OP_CHI_RDZ1R;
            // A2B/B2A conversion: funct7[5] pages direction (0=A2B,1=B2A).
            4'd14: decoded_op = instr_funct7_5 ? `OP_B2A_CONV : `OP_A2B_CONV;
            4'd15: decoded_op = instr_funct7_5 ? `OP_B2A_RD1  : `OP_A2B_RD1;
            default: decoded_op = `OP_INVALID;
          endcase
        end
        `GRP_PRNG: begin
          case (instr_funct7_lo)
            4'd0:  decoded_op = `OP_SEED_PRNG;
            4'd1:  decoded_op = `OP_GET_RANDOM;
            default: decoded_op = `OP_INVALID;
          endcase
        end
        default: decoded_op = `OP_INVALID;
      endcase
    end
  end

  // =========================================================================
  // Registered operands
  // =========================================================================
  (* keep = "true" *) (* keep_hierarchy = "true" *) reg [31:0] rs1_reg;
  (* keep = "true" *) (* keep_hierarchy = "true" *) reg [31:0] rs2_reg;
  (* keep = "true" *) (* keep_hierarchy = "true" *) reg [5:0]  op_reg;
  (* keep = "true" *) (* keep_hierarchy = "true" *) reg        funct7_4_reg; // Q selector for mask ops
  (* keep = "true" *) (* keep_hierarchy = "true" *) reg [31:0] result_reg;

  // =========================================================================
  // ISE module outputs
  // =========================================================================
  wire [31:0] keccak_result;
  wire [31:0] mod_result;
  wire [31:0] bfly_result;
  wire [31:0] cbd_result;
  wire [31:0] compress_result;
  wire [31:0] mldsa_result;
  wire [31:0] mask_result;
  wire [31:0] prng_random;
  wire        prng_ready;

  // PRNG consume signal — asserted when masked ops or GET_RANDOM need randomness
  // GET_RANDOM must also consume so consecutive calls return different values.
  wire prng_consume;
  // PRNG-consuming ops: every op that draws fresh randomness from the PRNG.
  // *_LATCH ops draw fresh r AND latch it; *_REUSE ops do NOT advance PRNG
  // (they consume the captured r), preserving the +r/-r cancellation invariant.
  wire is_mask_op = (op_reg == `OP_CHI_AND)      ||
                    (op_reg == `OP_CHI_ANDR)     ||
                    (op_reg == `OP_SECMUL_STEP)  ||
                    (op_reg == `OP_MASK_REFRESH) ||
                    (op_reg == `OP_MASKED_AND)   ||
                    (op_reg == `OP_SECMUL_LATCH) ||
                    (op_reg == `OP_AND_LATCH);
  wire is_prng_consumer = is_mask_op || (op_reg == `OP_GET_RANDOM);

  // Multi-cycle (tightly-coupled) op detection — A2B/B2A + state-resident Keccak.
  wire is_a2b_conv = (op_reg == `OP_A2B_CONV);
  wire is_b2a_conv = (op_reg == `OP_B2A_CONV);
  wire is_conv     = is_a2b_conv | is_b2a_conv;
  wire is_kperm    = (op_reg == `OP_KECCAK_PERM);
  wire is_mkperm   = (op_reg == `OP_MKECCAK_PERM);
  wire is_perm     = is_kperm | is_mkperm;
  wire is_multicycle = is_conv | is_perm;

  // A2B/B2A cores pull a fresh PRNG word every cycle while running; advance the
  // PRNG through both ST_ISE_RESULT (start) and ST_WAIT (the conversion body),
  // so consecutive words differ (the X2X r_a != r_b invariant depends on it).
  wire conv_running = is_conv && ((state_q == ST_ISE_RESULT) || (state_q == ST_WAIT));
  assign prng_consume = (((state_q == ST_ISE_RESULT) && is_prng_consumer) || conv_running)
                        && prng_ready;

  // r_latched capture strobe: 1 cycle while a *_LATCH op is in result phase
  // and PRNG has presented its fresh word. Same condition as prng_consume,
  // but only for the LATCH variants.
  wire is_latch_op = (op_reg == `OP_SECMUL_LATCH) || (op_reg == `OP_AND_LATCH);
  wire latch_strobe = (state_q == ST_ISE_RESULT) && is_latch_op && prng_ready;

  // Masked-chi unit: latch X on LOADX, z1 on CHI_AND, partials on CHI_ANDR.
  wire chi_strobe = (state_q == ST_ISE_RESULT) &&
                    ((op_reg == `OP_CHI_LOADX) || (op_reg == `OP_CHI_AND) ||
                     (op_reg == `OP_CHI_ANDR));

  // PRNG seed signals
  wire prng_seed_valid = (state_q == ST_ISE_RESULT) && (op_reg == `OP_SEED_PRNG);

  // =========================================================================
  // State-resident Keccak units REMOVED (unmasked keccak_f + masked
  // keccak_f_masked, with their kstate_q / mstate_plain_q / mout banks and
  // PERM wait states). Keccak is now exclusively the loosely-coupled
  // masked-serial OBI peripheral (obi_keccak_masked @ UserBaseAddr+0x4000).
  // The ise_keccak_ops bit-manipulation helper below STAYS (it serves the
  // linear SET_C/BCOP32/ROL/XOR3 micro-ops, not the permutation).
  // =========================================================================

  // =========================================================================
  // ISE module instantiations
  // =========================================================================
  ise_keccak_ops u_keccak (
    .clk_i    (clk_i),
    .rst_ni   (rst_ni),
    .valid_i  (state_q == ST_ISE_RESULT),
    .op_i     (op_reg),
    .rs1_i    (rs1_reg),
    .rs2_i    (rs2_reg),
    .result_o (keccak_result)
  );

  ise_mod_reduce u_mod (
    .clk_i    (clk_i),
    .rst_ni   (rst_ni),
    .op_i     (op_reg),
    .rs1_i    (rs1_reg),
    .rs2_i    (rs2_reg),
    .result_o (mod_result)
  );

  ise_ntt_butterfly u_bfly (
    .clk_i    (clk_i),
    .rst_ni   (rst_ni),
    .op_i     (op_reg),
    .rs1_i    (rs1_reg),
    .rs2_i    (rs2_reg),
    .result_o (bfly_result)
  );

  ise_cbd u_cbd (
    .clk_i    (clk_i),
    .rst_ni   (rst_ni),
    .op_i     (op_reg),
    .rs1_i    (rs1_reg),
    .result_o (cbd_result)
  );

  ise_compress u_compress (
    .clk_i    (clk_i),
    .rst_ni   (rst_ni),
    .op_i     (op_reg),
    .rs1_i    (rs1_reg),
    .result_o (compress_result)
  );

  ise_mldsa_ops u_mldsa (
    .clk_i    (clk_i),
    .rst_ni   (rst_ni),
    .op_i     (op_reg),
    .rs1_i    (rs1_reg),
    .rs2_i    (rs2_reg),
    .result_o (mldsa_result)
  );

  wire mask_trap;
  ise_mask_ops u_mask (
    .clk_i          (clk_i),
    .rst_ni         (rst_ni),
    .op_i           (op_reg),
    .rs1_i          (rs1_reg),
    .rs2_i          (rs2_reg),
    .q_sel_i        (funct7_4_reg),
    .prng_random_i  (prng_random),
    .prng_ready_i   (prng_ready),
    .latch_strobe_i (latch_strobe),
    .chi_strobe_i   (chi_strobe),
    .result_o       (mask_result),
    .trap_o         (mask_trap)
  );

  // Atomicity-violation trap: a *_REUSE op fired without a prior LATCH
  // (or the latched random was invalidated by an intervening PRNG consumer
  // such as GET_RANDOM, MASK_REFRESH, MASKED_AND, or legacy SECMUL_STEP).
  // Latch the trap so software / SystemVerilog testbench can observe it
  // even if the trapping op is a single cycle.  Wire to CV-X-IF illegal
  // instruction signalling once the host fault-injection harness needs it.
  (* keep = "true" *) (* keep_hierarchy = "true" *) reg mask_trap_latched_q;
  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni)            mask_trap_latched_q <= 1'b0;
    else if (mask_trap)     mask_trap_latched_q <= 1'b1;
  end

  ise_prng u_prng (
    .clk_i       (clk_i),
    .rst_ni      (rst_ni),
    .seed_valid_i(prng_seed_valid),
    .seed_data_i (rs1_reg),
    .seed_idx_i  (rs2_reg[1:0]),
    .consume_i   (prng_consume),
    .random_o    (prng_random),
    .ready_o     (prng_ready)
  );

  // =========================================================================
  // A2B / B2A mask-conversion cores (X2X, ePrint 2024/114).
  // Reused unchanged from the OBI peripheral; here driven directly by the ISE
  // FSM. CONV start is a 1-cycle pulse out of ST_ISE_RESULT; the cores need
  // fresh PRNG words each cycle, so prng_consume is held through ST_WAIT.
  // =========================================================================
  wire        a2b_start = (state_q == ST_ISE_RESULT) && is_a2b_conv && !prng_stall;
  wire        b2a_start = (state_q == ST_ISE_RESULT) && is_b2a_conv && !prng_stall;
  wire        conv_wide = funct7_4_reg;   // 0=ML-KEM(13b), 1=ML-DSA(24b)

  wire [31:0] a2b_share0_o, a2b_share1_o;
  wire        a2b_done;
  a2b_core u_a2b (
    .clk_i      (clk_i),
    .rst_ni     (rst_ni),
    .start_i    (a2b_start),
    .share0_i   (rs1_reg),
    .share1_i   (rs2_reg),
    .random_i   (prng_random),
    .wide_mode_i(conv_wide),
    .share0_o   (a2b_share0_o),
    .share1_o   (a2b_share1_o),
    .done_o     (a2b_done)
  );

  wire [31:0] b2a_share0_o, b2a_share1_o;
  wire        b2a_done;
  b2a_core u_b2a (
    .clk_i      (clk_i),
    .rst_ni     (rst_ni),
    .start_i    (b2a_start),
    .share0_i   (rs1_reg),
    .share1_i   (rs2_reg),
    .random_i   (prng_random),
    .wide_mode_i(conv_wide),
    .share0_o   (b2a_share0_o),
    .share1_o   (b2a_share1_o),
    .done_o     (b2a_done)
  );

  // Latched second output share, read back by A2B_RD1 / B2A_RD1.
  (* keep = "true" *) reg [31:0] conv_share1_q;

  // =========================================================================
  // State-resident DOM-masked Keccak-f[1600] (lane-serial core).
  // Two in-ISE 1600-bit share banks loaded via LDW, permuted in place by PERM,
  // read back via RDW. mask_en=0 collapses to the plain permutation (Dout1=0).
  // =========================================================================
  (* keep = "true" *) reg [1599:0] kstate0_q;   // share-0 state bank
  (* keep = "true" *) reg [1599:0] kstate1_q;   // share-1 state bank
  reg [31:0] mkeccak_seed_q;                     // PRNG seed for masked perm
  reg        mkeccak_mask_en_q;                  // 1 = masked, 0 = plain

  wire           keccak_start   = (state_q == ST_ISE_RESULT) && is_perm;
  wire           keccak_mask_en = is_mkperm ? mkeccak_mask_en_q : 1'b0;
  wire [1599:0]  keccak_dout0, keccak_dout1;
  wire           keccak_status_d;   // 1 = idle / permutation complete

`ifdef NO_HW_KECCAK
  // ---------------------------------------------------------------------------
  // Software-masked Keccak build (open-source nextpnr fit). The HW lane-serial
  // DOM-masked Keccak-f[1600] (~33k cells, huge 1600-bit high-fanout buses) is
  // stubbed out so the design places on xc7a100t with the open-source placer.
  // MKECCAK_* ops become no-ops (status always "complete" so the FSM never
  // stalls); firmware MUST use the software DOM Keccak path (build WITHOUT
  // -DUSE_HW_MKECCAK). The HW-Keccak build (default, no NO_HW_KECCAK define) is
  // unchanged and is the synth/Verilator/host-KAT-verified configuration.
  // ---------------------------------------------------------------------------
  assign keccak_dout0    = 1600'b0;
  assign keccak_dout1    = 1600'b0;
  assign keccak_status_d = 1'b1;   // always idle/complete
`else
  keccak_f_masked_serial u_keccak_perm (
    .clk      (clk_i),
    .rst_n    (rst_ni),
    .start_i  (keccak_start),
    .mask_en_i(keccak_mask_en),
    .seed_i   (mkeccak_seed_q),
    .Din0     (kstate0_q),
    .Din1     (kstate1_q),
    .Dout0    (keccak_dout0),
    .Dout1    (keccak_dout1),
    .status_d (keccak_status_d)
  );
`endif

  // Permutation done: status_d is 1 at idle, drops to 0 once running, rises at
  // completion. seen_busy guards against latching the pre-start idle level.
  reg kperm_seen_busy_q;
  wire kperm_done = kperm_seen_busy_q && keccak_status_d;

  // Generic multi-cycle done (selects the active core).
  wire mc_done = is_conv ? (is_a2b_conv ? a2b_done : b2a_done)
               : is_perm ? kperm_done
               : 1'b1;

  // Keccak word read-back (clamped to the 50 valid 32-bit words).
  wire [5:0]  krd_idx_raw = rs1_reg[5:0];
  wire [5:0]  krd_idx     = (krd_idx_raw >= 6'd50) ? 6'd0 : krd_idx_raw;
  wire [31:0] kstate0_word = kstate0_q[32*krd_idx +: 32];
  wire [31:0] kstate1_word = kstate1_q[32*krd_idx +: 32];
  wire [31:0] keccak_rdw_word = (op_reg == `OP_MKECCAK_RDW && funct7_4_reg)
                                ? kstate1_word : kstate0_word;

  // =========================================================================
  // Result MUX
  // =========================================================================
  reg [31:0] ise_result;

  always @(*) begin
    case (op_reg)
      `OP_SET_C, `OP_BCOP32_AB, `OP_SET_HI,
      `OP_ROL32_L, `OP_ROL32_H, `OP_XOR3:
        ise_result = keccak_result;

      `OP_BARRETT_K, `OP_MONT_K, `OP_CADDQ,
      `OP_BARRETT_D, `OP_MONT_D:
        ise_result = mod_result;

      `OP_NTT_BFLY_CT, `OP_NTT_BFLY_GS,
      `OP_NTT_BFLY_CT_MUL, `OP_NTT_BFLY_GS_MUL:
        ise_result = bfly_result;

      `OP_CBD2_1, `OP_CBD2_2, `OP_CBD2_3, `OP_CBD2_4,
      `OP_CBD2_5, `OP_CBD2_6, `OP_CBD2_7, `OP_CBD2_8,
      `OP_CBD3_1, `OP_CBD3_2, `OP_CBD3_3, `OP_CBD3_4:
        ise_result = cbd_result;

      `OP_COMPRESS_1, `OP_COMPRESS_2, `OP_COMPRESS_3,
      `OP_COMPRESS_4, `OP_COMPRESS_5, `OP_REJ_UNIFORM:
        ise_result = compress_result;

      `OP_POWER2ROUND, `OP_DECOMPOSE:
        ise_result = mldsa_result;

      `OP_SECMUL_STEP,  `OP_MASK_REFRESH,
      `OP_MASKED_AND,   `OP_MASKED_XOR,
      `OP_SECMUL_LATCH, `OP_SECMUL_REUSE,
      `OP_AND_LATCH,    `OP_AND_REUSE:
        ise_result = mask_result;

      `OP_SEED_PRNG:
        ise_result = rs1_reg; // echo back seed word as ack

      `OP_GET_RANDOM:
        ise_result = prng_random;

      // Single-cycle Keccak load/seed acks and word read-back.
      `OP_KECCAK_LDW, `OP_MKECCAK_LDW, `OP_MKECCAK_SEED:
        ise_result = rs1_reg;            // echo data/seed as ack
      `OP_KECCAK_RDW, `OP_MKECCAK_RDW:
        ise_result = keccak_rdw_word;    // state word (share-selectable)

      // Single-cycle second-share read-back for the conversions.
      `OP_A2B_RD1, `OP_B2A_RD1:
        ise_result = conv_share1_q;

      // Multi-cycle ops (A2B/B2A CONV, KECCAK/MKECCAK PERM) are captured
      // directly into result_reg on mc_done in ST_WAIT; the mux value is unused.
      `OP_A2B_CONV, `OP_B2A_CONV, `OP_KECCAK_PERM, `OP_MKECCAK_PERM:
        ise_result = result_reg;

      default:
        ise_result = 32'd0;
    endcase
  end

  // =========================================================================
  // PRNG safety: stall in ISE_RESULT if a masked op (or an A2B/B2A conversion)
  // needs PRNG but it is not yet seeded.
  // =========================================================================
  wire prng_stall = (is_mask_op || is_conv) && !prng_ready;

  // =========================================================================
  // FSM
  // =========================================================================
  wire accept_issue = (decoded_op != `OP_INVALID);

  always @(*) begin
    state_d               = state_q;
    x_issue_ready_o       = 1'b0;
    x_issue_resp_accept_o = 1'b0;
    x_result_valid_o      = 1'b0;
    x_result_data_o       = 32'd0;

    case (state_q)
      ST_IDLE: begin
        x_issue_ready_o       = 1'b1;
        x_issue_resp_accept_o = accept_issue;
        if (x_issue_valid_i && accept_issue)
          state_d = ST_ISE_RESULT;
      end

      ST_ISE_RESULT: begin
        // Stall if a masked op / conversion needs the PRNG and it is not seeded.
        if (prng_stall) begin
          state_d = ST_ISE_RESULT;
        end else if (is_multicycle) begin
          // A2B/B2A CONV and KECCAK/MKECCAK PERM: pulse start (combinational,
          // gated on this state) and wait for the core to finish.
          state_d = ST_WAIT;
        end else begin
          // All other ops are single-cycle.
          state_d = ST_RESULT_READY;
        end
      end

      ST_WAIT: begin
        // Hold until the active multi-cycle core asserts done.
        if (mc_done)
          state_d = ST_RESULT_READY;
        else
          state_d = ST_WAIT;
      end

      ST_RESULT_READY: begin
        x_result_valid_o = 1'b1;
        x_result_data_o  = result_reg;
        if (x_result_ready_i)
          state_d = ST_IDLE;
      end

      default: state_d = ST_IDLE;
    endcase
  end

  // =========================================================================
  // Registered logic
  // =========================================================================
  // Keccak word indices for load (write) ops, clamped to the 50 valid words.
  wire [5:0] kwr_idx_raw = rs2_reg[5:0];
  wire [5:0] kwr_idx     = (kwr_idx_raw >= 6'd50) ? 6'd0 : kwr_idx_raw;
  wire       kwr_valid   = (kwr_idx_raw < 6'd50);

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q           <= ST_IDLE;
      rs1_reg           <= 32'd0;
      rs2_reg           <= 32'd0;
      op_reg            <= `OP_INVALID;
      funct7_4_reg      <= 1'b0;
      result_reg        <= 32'd0;
      conv_share1_q     <= 32'd0;
      kstate0_q         <= 1600'd0;
      kstate1_q         <= 1600'd0;
      mkeccak_seed_q    <= 32'd0;
      mkeccak_mask_en_q <= 1'b0;
      kperm_seen_busy_q <= 1'b0;
    end else begin
      state_q <= state_d;

      // Capture operands on issue accept
      if (state_q == ST_IDLE && x_issue_valid_i && accept_issue) begin
        rs1_reg      <= x_issue_req_rs1_i;
        rs2_reg      <= x_issue_req_rs2_i;
        op_reg       <= decoded_op;
        funct7_4_reg <= instr_funct7_4;
      end

      // ---- Single-cycle Keccak state-bank loads + seed (ST_ISE_RESULT) ----
      if (state_q == ST_ISE_RESULT) begin
        case (op_reg)
          `OP_KECCAK_LDW: if (kwr_valid) begin
            kstate0_q[32*kwr_idx +: 32] <= rs1_reg;
            kstate1_q[32*kwr_idx +: 32] <= 32'd0;   // plain: share1 = 0
          end
          `OP_MKECCAK_LDW: if (kwr_valid) begin
            if (funct7_4_reg) kstate1_q[32*kwr_idx +: 32] <= rs1_reg;
            else              kstate0_q[32*kwr_idx +: 32] <= rs1_reg;
          end
          `OP_MKECCAK_SEED: begin
            mkeccak_seed_q    <= rs1_reg;
            mkeccak_mask_en_q <= rs2_reg[0];
          end
          default: ;
        endcase
      end

      // ---- Keccak busy tracker: clear on start, set once running ----
      if (keccak_start)            kperm_seen_busy_q <= 1'b0;
      else if (!keccak_status_d)   kperm_seen_busy_q <= 1'b1;

      // ---- Result capture ----
      // Single-cycle ops: latch the mux output in ST_ISE_RESULT (not stalled,
      // not multi-cycle — the multi-cycle result is not ready yet).
      if (state_q == ST_ISE_RESULT && !prng_stall && !is_multicycle) begin
        result_reg <= ise_result;
      end

      // Multi-cycle ops: capture when the active core completes in ST_WAIT.
      if (state_q == ST_WAIT && mc_done) begin
        if (is_a2b_conv) begin
          result_reg    <= a2b_share0_o;
          conv_share1_q <= a2b_share1_o;
        end else if (is_b2a_conv) begin
          result_reg    <= b2a_share0_o;
          conv_share1_q <= b2a_share1_o;
        end else begin // is_perm: write permuted shares back to the banks
          kstate0_q  <= keccak_dout0;
          kstate1_q  <= keccak_dout1;
          result_reg <= 32'd0;          // PERM returns 0 ack in rd
        end
      end
    end
  end

endmodule
