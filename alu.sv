//==============================================================================
// RV32I ALU
//
// Supports all arithmetic/logic operations required by the RV32I base integer
// instruction set. Active-high zero flag provided for branch comparison.
//
// ALU Control Encoding:
//   4'b0000  ADD
//   4'b0001  SUB
//   4'b0010  AND
//   4'b0011  OR
//   4'b0100  XOR
//   4'b0101  SLT   (set less than, signed)
//   4'b0110  SLTU  (set less than, unsigned)
//   4'b0111  SLL   (shift left logical)
//   4'b1000  SRL   (shift right logical)
//   4'b1001  SRA   (shift right arithmetic)
//==============================================================================

module alu (
    input  logic [31:0] a,          // operand A (rs1)
    input  logic [31:0] b,          // operand B (rs2 or immediate)
    input  logic [3:0]  alu_ctrl,   // operation select
    output logic [31:0] result,     // ALU result
    output logic        zero        // result == 0
);

    // Shift amount is always lower 5 bits of operand B
    logic [4:0] shamt;
    assign shamt = b[4:0];

    always_comb begin
        case (alu_ctrl)
            4'b0000: result = a + b;                                // ADD
            4'b0001: result = a - b;                                // SUB
            4'b0010: result = a & b;                                // AND
            4'b0011: result = a | b;                                // OR
            4'b0100: result = a ^ b;                                // XOR
            4'b0101: result = {31'b0, $signed(a) < $signed(b)};     // SLT
            4'b0110: result = {31'b0, a < b};                       // SLTU
            4'b0111: result = a << shamt;                           // SLL
            4'b1000: result = a >> shamt;                           // SRL
            4'b1001: result = $signed(a) >>> shamt;                 // SRA
            default: result = 32'b0;
        endcase
    end

    assign zero = (result == 32'b0);

endmodule
