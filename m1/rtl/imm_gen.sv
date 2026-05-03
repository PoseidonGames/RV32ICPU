// ============================================================================
// Module: imm_gen
// Description: Immediate generator for RV32I. Extracts and sign-extends
//              the immediate field from a 32-bit instruction word.
//              Supports I, S, B, U, and J immediate formats as defined
//              in the canonical reference (§4).
// Author: Beaux Cable
// Date: April 2026
// Project: RV32I Pipelined Processor
// ============================================================================

module imm_gen (
  input  logic [31:0] inst_i,     // 32-bit instruction word
  input  logic [ 2:0] imm_type_i, // immediate format selector (see §4)
  output logic [31:0] imm_o       // sign-extended 32-bit immediate
);

  // --------------------------------------------------------------------------
  // Immediate type encoding constants (canonical-reference.md §4)
  // --------------------------------------------------------------------------
  localparam IMM_TYPE_I = 3'b000;
  localparam IMM_TYPE_S = 3'b001;
  localparam IMM_TYPE_B = 3'b010;
  localparam IMM_TYPE_U = 3'b011;
  localparam IMM_TYPE_J = 3'b100;

  // --------------------------------------------------------------------------
  // Immediate extraction and sign-extension
  //
  // The sign bit for ALL formats is inst[31]. This allows sign-extension to
  // occur in parallel with decode (canonical-reference.md §3 note).
  //
  // B-type and J-type immediates encode byte offsets with an implicit LSB of
  // 0 (all branch/jump targets are 2-byte aligned). The 1'b0 is inserted
  // explicitly here (gotchas.md #5).
  //
  // U-type is not sign-extended: it occupies inst[31:12] directly and the
  // lower 12 bits are forced to zero. inst[31] may be 1, but the full
  // 32-bit field is already the correctly-positioned value.
  // --------------------------------------------------------------------------
  always_comb begin
    // Default: drive zero to prevent latch inference (gotchas.md #1)
    imm_o = 32'h0;

    case (imm_type_i)

      // I-type: inst[31:20] sign-extended to 32 bits
      // Used by: ADDI, SLTI, SLTIU, XORI, ORI, ANDI, SLLI, SRLI, SRAI,
      //          loads (LB/LH/LW/LBU/LHU), JALR, FENCE, ECALL, EBREAK
      IMM_TYPE_I: begin
        imm_o = { {20{inst_i[31]}}, inst_i[31:20] };
      end

      // S-type: imm[11:5] = inst[31:25], imm[4:0] = inst[11:7]
      // The rd field (inst[11:7]) carries imm[4:0] — there is no rd
      // in S-type encoding (gotchas.md #4).
      // Used by: SB, SH, SW
      IMM_TYPE_S: begin
        imm_o = { {20{inst_i[31]}}, inst_i[31:25], inst_i[11:7] };
      end

      // B-type: scrambled encoding; implicit LSB = 0 (2-byte alignment)
      // Bits: imm[12|10:5] in inst[31:25], imm[4:1|11] in inst[11:7]
      // Resulting immediate: inst[31]=imm[12], inst[7]=imm[11],
      //                      inst[30:25]=imm[10:5], inst[11:8]=imm[4:1]
      // Used by: BEQ, BNE, BLT, BGE, BLTU, BGEU
      IMM_TYPE_B: begin
        imm_o = { {19{inst_i[31]}},
                  inst_i[31],
                  inst_i[7],
                  inst_i[30:25],
                  inst_i[11:8],
                  1'b0 };
      end

      // U-type: upper 20 bits placed in imm[31:12], lower 12 bits zeroed
      // No sign-extension needed — the full 32-bit word is already formed.
      // Used by: LUI, AUIPC
      IMM_TYPE_U: begin
        imm_o = { inst_i[31:12], 12'b0 };
      end

      // J-type: scrambled encoding; implicit LSB = 0 (2-byte alignment)
      // Bits: imm[20|10:1|11|19:12] packed into inst[31:12]
      // Resulting immediate: inst[31]=imm[20], inst[19:12]=imm[19:12],
      //                      inst[20]=imm[11], inst[30:21]=imm[10:1]
      // Used by: JAL
      IMM_TYPE_J: begin
        imm_o = { {11{inst_i[31]}},
                  inst_i[31],
                  inst_i[19:12],
                  inst_i[20],
                  inst_i[30:21],
                  1'b0 };
      end

      // Undefined imm_type: output zero (safe default)
      default: begin
        imm_o = 32'h0;
      end

    endcase
  end

endmodule
