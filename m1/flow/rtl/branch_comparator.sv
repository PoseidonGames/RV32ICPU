// ============================================================================
// Module: branch_comparator
// Description: Combinational branch condition evaluator for RV32I B-type
//              instructions. Decodes funct3 to select the correct comparison
//              and drives branch_taken_o high when the condition is met.
//              ALU is NOT used for branch comparison (canonical-ref S1.5).
// Author: Beaux Cable
// Date: April 2026
// Project: TSI RV32I Pipelined Processor (TSMC 180nm)
// ============================================================================

module branch_comparator (
  input  logic [31:0] rs1_data_i,    // Register source 1 data
  input  logic [31:0] rs2_data_i,    // Register source 2 data
  input  logic [ 2:0] funct3_i,      // Branch type selector (from instr[14:12])
  output logic        branch_taken_o // 1 = branch condition is true
);

  // -----------------------------------------------------------------------
  // Branch funct3 encoding constants (canonical-reference.md S1.5)
  // -----------------------------------------------------------------------
  localparam [2:0] FUNCT3_BEQ  = 3'b000; // Branch if equal
  localparam [2:0] FUNCT3_BNE  = 3'b001; // Branch if not equal
  localparam [2:0] FUNCT3_BLT  = 3'b100; // Branch if less than (signed)
  localparam [2:0] FUNCT3_BGE  = 3'b101; // Branch if greater/equal (signed)
  localparam [2:0] FUNCT3_BLTU = 3'b110; // Branch if less than (unsigned)
  localparam [2:0] FUNCT3_BGEU = 3'b111; // Branch if greater/equal (unsigned)

  // -----------------------------------------------------------------------
  // Branch condition evaluation (purely combinational)
  // -----------------------------------------------------------------------
  always_comb begin
    // Default: branch not taken (gotcha #1 — prevents latch inference;
    // also covers reserved funct3 encodings 010 and 011)
    branch_taken_o = 1'b0;

    case (funct3_i)
      FUNCT3_BEQ:  branch_taken_o = (rs1_data_i == rs2_data_i);

      FUNCT3_BNE:  branch_taken_o = (rs1_data_i != rs2_data_i);

      // Signed comparisons: $signed() cast required so < and >= treat
      // bit 31 as the sign bit rather than as a large magnitude
      FUNCT3_BLT:  branch_taken_o =
                     ($signed(rs1_data_i) < $signed(rs2_data_i));

      FUNCT3_BGE:  branch_taken_o =
                     ($signed(rs1_data_i) >= $signed(rs2_data_i));

      // Unsigned comparisons: plain operators on logic[31:0] suffice;
      // no cast needed because logic is inherently unsigned
      FUNCT3_BLTU: branch_taken_o = (rs1_data_i < rs2_data_i);

      FUNCT3_BGEU: branch_taken_o = (rs1_data_i >= rs2_data_i);

      // funct3 values 3'b010 and 3'b011 are not valid B-type encodings.
      // Default above already covers these; explicit default silences
      // synthesis warnings and documents intent.
      default:     branch_taken_o = 1'b0;
    endcase
  end

endmodule
