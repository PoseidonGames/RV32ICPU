// ============================================================================
// Module: alu_control
// Description: Decodes coarse ALU category (alu_op) plus instruction
//              fields (funct3, funct7[5]) into the 4-bit alu_ctrl signal
//              fed to alu.sv. Combinational only. alu_ctrl 4'b1111 is
//              unallocated per §8.3 and asserts illegal_o=1 as a stub.
//              Codes 4'b1010-4'b1110 are M2a/M2b reserved — not flagged.
// Author: Beaux Cable
// Date: April 2026
// Project: TSI RV32I Pipelined Processor (TSMC 180nm)
// ============================================================================

module alu_control (
  input  logic [1:0] alu_op_i,    // coarse ALU category (§6.2)
  input  logic [2:0] funct3_i,    // instruction[14:12]
  input  logic       funct7b5_i,  // instruction[30]: ADD/SUB, SRL/SRA
  output logic [3:0] alu_ctrl_o,  // operation select → alu.sv
  output logic       illegal_o    // 1 = alu_ctrl 4'b1111 (unallocated per §8.3)
);

  // --------------------------------------------------------------------
  // ALU control encoding (canonical-reference.md §5)
  // --------------------------------------------------------------------
  localparam logic [3:0] ALU_ADD  = 4'b0000;
  localparam logic [3:0] ALU_SUB  = 4'b0001;
  localparam logic [3:0] ALU_AND  = 4'b0010;
  localparam logic [3:0] ALU_OR   = 4'b0011;
  localparam logic [3:0] ALU_XOR  = 4'b0100;
  localparam logic [3:0] ALU_SLT  = 4'b0101;
  localparam logic [3:0] ALU_SLTU = 4'b0110;
  localparam logic [3:0] ALU_SLL  = 4'b0111;
  localparam logic [3:0] ALU_SRL        = 4'b1000;
  localparam logic [3:0] ALU_SRA        = 4'b1001;
  localparam logic [3:0] ALU_UNALLOCATED = 4'b1111; // §8.3: not reserved

  // alu_op encoding (canonical-reference.md §6.2)
  localparam logic [1:0] ALUOP_ADD    = 2'b00;
  localparam logic [1:0] ALUOP_BRANCH = 2'b01;
  localparam logic [1:0] ALUOP_RTYPE  = 2'b10;
  localparam logic [1:0] ALUOP_ITYPE  = 2'b11;

  // funct3 encoding (canonical-reference.md §1.1, §1.2)
  localparam logic [2:0] F3_ADD_SUB = 3'b000;
  localparam logic [2:0] F3_SLL     = 3'b001;
  localparam logic [2:0] F3_SLT     = 3'b010;
  localparam logic [2:0] F3_SLTU    = 3'b011;
  localparam logic [2:0] F3_XOR     = 3'b100;
  localparam logic [2:0] F3_SRL_SRA = 3'b101;
  localparam logic [2:0] F3_OR      = 3'b110;
  localparam logic [2:0] F3_AND     = 3'b111;

  // --------------------------------------------------------------------
  // Internal signals
  // --------------------------------------------------------------------
  logic [3:0] rtype_ctrl;
  logic [3:0] itype_ctrl;

  // --------------------------------------------------------------------
  // R-type decode: funct3 + funct7b5 (canonical-reference.md §1.1)
  // --------------------------------------------------------------------
  always_comb begin
    rtype_ctrl = ALU_ADD;  // default prevents latch (gotchas.md #1)
    case (funct3_i)
      F3_ADD_SUB: rtype_ctrl = funct7b5_i ? ALU_SUB : ALU_ADD;
      F3_SLL:     rtype_ctrl = ALU_SLL;
      F3_SLT:     rtype_ctrl = ALU_SLT;
      F3_SLTU:    rtype_ctrl = ALU_SLTU;
      F3_XOR:     rtype_ctrl = ALU_XOR;
      F3_SRL_SRA: rtype_ctrl = funct7b5_i ? ALU_SRA : ALU_SRL;
      F3_OR:      rtype_ctrl = ALU_OR;
      F3_AND:     rtype_ctrl = ALU_AND;
      default:    rtype_ctrl = ALU_ADD;
    endcase
  end

  // --------------------------------------------------------------------
  // I-type decode: funct3 only; shifts also use funct7b5.
  // funct7b5 is NOT checked for non-shift I-type: ADDI has no SUBI
  // (canonical-reference.md §1.2; gotchas.md #10)
  // --------------------------------------------------------------------
  always_comb begin
    itype_ctrl = ALU_ADD;  // default prevents latch (gotchas.md #1)
    case (funct3_i)
      F3_ADD_SUB: itype_ctrl = ALU_ADD;    // ADDI
      F3_SLL:     itype_ctrl = ALU_SLL;    // SLLI
      F3_SLT:     itype_ctrl = ALU_SLT;    // SLTI
      F3_SLTU:    itype_ctrl = ALU_SLTU;   // SLTIU
      F3_XOR:     itype_ctrl = ALU_XOR;    // XORI
      F3_SRL_SRA: itype_ctrl =             // SRLI / SRAI
                    funct7b5_i ? ALU_SRA : ALU_SRL;
      F3_OR:      itype_ctrl = ALU_OR;     // ORI
      F3_AND:     itype_ctrl = ALU_AND;    // ANDI
      default:    itype_ctrl = ALU_ADD;
    endcase
  end

  // --------------------------------------------------------------------
  // Top-level mux: select alu_ctrl from alu_op category
  // --------------------------------------------------------------------
  always_comb begin
    // Defaults prevent latch inference (gotchas.md #1)
    alu_ctrl_o = ALU_ADD;
    illegal_o  = 1'b0;

    case (alu_op_i)
      ALUOP_ADD: begin
        // Loads, stores, LUI, AUIPC, JAL, JALR, FENCE, ECALL/EBREAK.
        // Always ADD regardless of funct fields (§6.2)
        alu_ctrl_o = ALU_ADD;
        illegal_o  = 1'b0;
      end

      ALUOP_BRANCH: begin
        // ALU result discarded; branch comparator handles comparison.
        // Output ADD as safe default (gotchas.md #13)
        alu_ctrl_o = ALU_ADD;
        illegal_o  = 1'b0;
      end

      ALUOP_RTYPE: begin
        // R-type: funct3 + funct7b5 (§1.1)
        alu_ctrl_o = rtype_ctrl;
        illegal_o  = 1'b0;
      end

      ALUOP_ITYPE: begin
        // I-type: funct3; shifts also use funct7b5 (§1.2)
        alu_ctrl_o = itype_ctrl;
        illegal_o  = 1'b0;
      end

      default: begin
        alu_ctrl_o = ALU_ADD;
        illegal_o  = 1'b0;
      end
    endcase

    // Stub for 4'b1111 only — the single truly unallocated code (§8.3).
    // Codes 4'b1010-4'b1110 are reserved for M2a/M2b (POPCOUNT, BREV,
    // BEXT, BDEP, MAC) and must NOT be flagged illegal here.
    // Base RV32I funct3/funct7 cannot produce any code >= 4'b1010,
    // so this guard is dead for M0/M1 — it activates only if future
    // M2a/M2b wiring mis-routes an unallocated code.
    if (alu_ctrl_o == ALU_UNALLOCATED) begin
      alu_ctrl_o = ALU_ADD;
      illegal_o  = 1'b1;
    end
  end

endmodule
