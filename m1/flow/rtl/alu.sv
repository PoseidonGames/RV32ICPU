// ============================================================================
// Module: alu
// Description: RV32I arithmetic/logic unit. Supports all 10 base integer
//              operations. Branch comparison is handled by branch_comparator.
// Author: Beaux Cable
// Date: April 2026
// Project: RV32I Pipelined Processor
// ============================================================================

module alu (
  input  logic [31:0] a_i,         // operand A (rs1 or PC)
  input  logic [31:0] b_i,         // operand B (rs2 or immediate)
  input  logic [3:0]  alu_ctrl_i,  // operation select
  output logic [31:0] result_o     // ALU result
);

  // ALU control encoding constants (canonical-reference.md §5)
  localparam logic [3:0] ALU_ADD  = 4'b0000;
  localparam logic [3:0] ALU_SUB  = 4'b0001;
  localparam logic [3:0] ALU_AND  = 4'b0010;
  localparam logic [3:0] ALU_OR   = 4'b0011;
  localparam logic [3:0] ALU_XOR  = 4'b0100;
  localparam logic [3:0] ALU_SLT  = 4'b0101;
  localparam logic [3:0] ALU_SLTU = 4'b0110;
  localparam logic [3:0] ALU_SLL  = 4'b0111;
  localparam logic [3:0] ALU_SRL  = 4'b1000;
  localparam logic [3:0] ALU_SRA  = 4'b1001;

  // Shift amount is always the lower 5 bits of operand B (gotchas.md #3)
  logic [4:0] shamt;
  assign shamt = b_i[4:0];

  always_comb begin
    result_o = 32'h0; // default: prevents latch inference
    case (alu_ctrl_i)
      ALU_ADD:  result_o = a_i + b_i;
      ALU_SUB:  result_o = a_i - b_i;
      ALU_AND:  result_o = a_i & b_i;
      ALU_OR:   result_o = a_i | b_i;
      ALU_XOR:  result_o = a_i ^ b_i;
      ALU_SLT:  result_o = {31'b0, $signed(a_i) < $signed(b_i)};
      ALU_SLTU: result_o = {31'b0, a_i < b_i};
      ALU_SLL:  result_o = a_i << shamt;
      ALU_SRL:  result_o = a_i >> shamt;
      ALU_SRA:  result_o = $unsigned($signed(a_i) >>> shamt);
      default:  result_o = 32'h0;
    endcase
  end

endmodule
