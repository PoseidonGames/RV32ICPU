// ============================================================================
// Module: control_decoder
// Description: Main instruction decoder for the RV32I M0 single-cycle
//              datapath. Takes a 32-bit instruction word and produces all
//              datapath control signals by decoding opcode[6:0], funct3,
//              and funct7[5] (bit 30). Combinational only — no state.
//              Encoding values from canonical-reference.md §2, §4, §6.
// Author: Beaux Cable
// Date: April 2026
// Project: RV32I Pipelined Processor
// ============================================================================

module control_decoder (
  input  logic [31:0] inst_i,          // 32-bit instruction word

  // Register file control
  output logic        reg_write_o,     // 1 = write rd in register file

  // ALU operand selects
  output logic        alu_src_o,       // 0 = rs2, 1 = immediate
  output logic [ 1:0] alu_src_a_o,    // ALU-A src: 00=rs1, 01=PC, 10=zero

  // Memory control
  output logic        mem_read_o,      // 1 = data memory read enable
  output logic        mem_write_o,     // 1 = data memory write enable

  // Writeback select
  output logic        mem_to_reg_o,    // 0 = ALU result, 1 = memory data

  // Branch / jump control
  output logic        branch_o,        // 1 = conditional branch (B-type)
  output logic        jump_o,          // 1 = JAL or JALR
  output logic        jalr_o,          // 1 = JALR specifically

  // Immediate type (feeds imm_gen imm_type_i; §4)
  output logic [ 2:0] imm_type_o,      // I=000, S=001, B=010, U=011, J=100

  // Coarse ALU class (feeds alu_control alu_op_i; §6.2)
  output logic [ 1:0] alu_op_o,        // 00=ADD, 01=branch, 10=R, 11=I-type

  // Fault / system (§9.1)
  output logic        halt_o,          // 1 = ECALL/EBREAK — assert halt/trap
  output logic        illegal_instr_o  // 1 = unrecognised opcode
);

  // --------------------------------------------------------------------------
  // Opcode constants (canonical-reference.md §2)
  // --------------------------------------------------------------------------
  localparam logic [6:0] OP_R_TYPE  = 7'b0110011; // ADD SUB SLL SLT …
  localparam logic [6:0] OP_I_ALU   = 7'b0010011; // ADDI SLTI … SLLI …
  localparam logic [6:0] OP_LOAD    = 7'b0000011; // LB LH LW LBU LHU
  localparam logic [6:0] OP_STORE   = 7'b0100011; // SB SH SW
  localparam logic [6:0] OP_BRANCH  = 7'b1100011; // BEQ BNE BLT BGE …
  localparam logic [6:0] OP_JAL     = 7'b1101111; // JAL
  localparam logic [6:0] OP_JALR    = 7'b1100111; // JALR
  localparam logic [6:0] OP_LUI     = 7'b0110111; // LUI
  localparam logic [6:0] OP_AUIPC   = 7'b0010111; // AUIPC
  localparam logic [6:0] OP_FENCE   = 7'b0001111; // FENCE (NOP on single-hart)
  localparam logic [6:0] OP_SYSTEM  = 7'b1110011; // ECALL EBREAK
  localparam logic [6:0] OP_CUSTOM0 = 7'b0001011; // CUSTOM-0 (M2a/M2b)

  // --------------------------------------------------------------------------
  // Immediate type encoding constants (canonical-reference.md §4)
  // Must match imm_gen.sv localparams exactly.
  // --------------------------------------------------------------------------
  localparam logic [2:0] IMM_TYPE_I = 3'b000;
  localparam logic [2:0] IMM_TYPE_S = 3'b001;
  localparam logic [2:0] IMM_TYPE_B = 3'b010;
  localparam logic [2:0] IMM_TYPE_U = 3'b011;
  localparam logic [2:0] IMM_TYPE_J = 3'b100;

  // --------------------------------------------------------------------------
  // ALU operation category constants (canonical-reference.md §6.2)
  // --------------------------------------------------------------------------
  localparam logic [1:0] ALU_OP_ADD    = 2'b00; // loads/stores/LUI/AUIPC/JAL
  localparam logic [1:0] ALU_OP_BRANCH = 2'b01; // branch comparison (unused)
  localparam logic [1:0] ALU_OP_RTYPE  = 2'b10; // R-type: funct3+funct7 used
  localparam logic [1:0] ALU_OP_ITYPE  = 2'b11; // I-type ALU: funct3 used

  // --------------------------------------------------------------------------
  // ALU-A source select encoding (alu_src_a_o; §6)
  // --------------------------------------------------------------------------
  localparam logic [1:0] ALU_SRCA_RS1  = 2'b00; // ALU-A = rs1 (default)
  localparam logic [1:0] ALU_SRCA_PC   = 2'b01; // ALU-A = PC (AUIPC, JAL)
  localparam logic [1:0] ALU_SRCA_ZERO = 2'b10; // ALU-A = 0  (LUI)

  // --------------------------------------------------------------------------
  // Field extraction (wires, not latched)
  // --------------------------------------------------------------------------
  logic [6:0] opcode;
  assign opcode = inst_i[6:0];

  // --------------------------------------------------------------------------
  // Combinational decode
  // All outputs assigned in every branch (gotchas.md #1).
  // --------------------------------------------------------------------------
  always_comb begin
    // -- Safe defaults: NOP / no-op behaviour for illegal instructions -------
    reg_write_o     = 1'b0;
    alu_src_o       = 1'b0;
    alu_src_a_o     = ALU_SRCA_RS1;
    mem_read_o      = 1'b0;
    mem_write_o    = 1'b0;
    mem_to_reg_o   = 1'b0;
    branch_o       = 1'b0;
    jump_o         = 1'b0;
    jalr_o         = 1'b0;
    imm_type_o      = IMM_TYPE_I;
    alu_op_o        = ALU_OP_ADD;
    halt_o          = 1'b0;
    illegal_instr_o = 1'b0;

    case (opcode)

      // ----------------------------------------------------------------------
      // R-type ALU  (canonical-reference.md §1.1)
      // reg_write=1, alu_src=0 (rs2), alu_op=10
      // imm_sel unused — R-type has no immediate.
      // imm_sel driven to IMM_TYPE_I as safe default (value is don't-care).
      // ----------------------------------------------------------------------
      OP_R_TYPE: begin
        reg_write_o    = 1'b1;
        alu_src_o      = 1'b0;
        alu_src_a_o    = ALU_SRCA_RS1;
        mem_read_o     = 1'b0;
        mem_write_o    = 1'b0;
        mem_to_reg_o   = 1'b0;
        branch_o       = 1'b0;
        jump_o         = 1'b0;
        jalr_o         = 1'b0;
        imm_type_o      = IMM_TYPE_I;
        alu_op_o       = ALU_OP_RTYPE;
        illegal_instr_o = 1'b0;
      end

      // ----------------------------------------------------------------------
      // I-type ALU  (canonical-reference.md §1.2)
      // reg_write=1, alu_src=1 (immediate), alu_op=11
      // ----------------------------------------------------------------------
      OP_I_ALU: begin
        reg_write_o    = 1'b1;
        alu_src_o      = 1'b1;
        alu_src_a_o    = ALU_SRCA_RS1;
        mem_read_o     = 1'b0;
        mem_write_o    = 1'b0;
        mem_to_reg_o   = 1'b0;
        branch_o       = 1'b0;
        jump_o         = 1'b0;
        jalr_o         = 1'b0;
        imm_type_o      = IMM_TYPE_I;
        alu_op_o       = ALU_OP_ITYPE;
        illegal_instr_o = 1'b0;
      end

      // ----------------------------------------------------------------------
      // Loads  (canonical-reference.md §1.3)
      // reg_write=1, mem_read=1, mem_to_reg=1, alu_src=1 (addr=rs1+imm)
      // alu_op=00 (ADD — address computation)
      // ----------------------------------------------------------------------
      OP_LOAD: begin
        reg_write_o    = 1'b1;
        alu_src_o      = 1'b1;
        alu_src_a_o    = ALU_SRCA_RS1;
        mem_read_o     = 1'b1;
        mem_write_o    = 1'b0;
        mem_to_reg_o   = 1'b1;
        branch_o       = 1'b0;
        jump_o         = 1'b0;
        jalr_o         = 1'b0;
        imm_type_o      = IMM_TYPE_I;
        alu_op_o       = ALU_OP_ADD;
        illegal_instr_o = 1'b0;
      end

      // ----------------------------------------------------------------------
      // Stores  (canonical-reference.md §1.4)
      // reg_write=0, mem_write=1, alu_src=1 (addr=rs1+S-imm)
      // alu_op=00 (ADD — address computation)
      // mem_to_reg is don't-care; driven 0 (no writeback).
      // ----------------------------------------------------------------------
      OP_STORE: begin
        reg_write_o    = 1'b0;
        alu_src_o      = 1'b1;
        alu_src_a_o    = ALU_SRCA_RS1;
        mem_read_o     = 1'b0;
        mem_write_o    = 1'b1;
        mem_to_reg_o   = 1'b0;
        branch_o       = 1'b0;
        jump_o         = 1'b0;
        jalr_o         = 1'b0;
        imm_type_o      = IMM_TYPE_S;
        alu_op_o       = ALU_OP_ADD;
        illegal_instr_o = 1'b0;
      end

      // ----------------------------------------------------------------------
      // Branches  (canonical-reference.md §1.5)
      // reg_write=0, branch=1, alu_src=0 (rs2 — branch comparator uses
      // raw rs1/rs2), alu_op=01.
      // Note: branch_comparator handles the actual comparison (§10.4).
      // ----------------------------------------------------------------------
      OP_BRANCH: begin
        reg_write_o    = 1'b0;
        alu_src_o      = 1'b0;
        alu_src_a_o    = ALU_SRCA_RS1;
        mem_read_o     = 1'b0;
        mem_write_o    = 1'b0;
        mem_to_reg_o   = 1'b0;
        branch_o       = 1'b1;
        jump_o         = 1'b0;
        jalr_o         = 1'b0;
        imm_type_o      = IMM_TYPE_B;
        alu_op_o       = ALU_OP_BRANCH;
        illegal_instr_o = 1'b0;
      end

      // ----------------------------------------------------------------------
      // JAL  (canonical-reference.md §1.6)
      // reg_write=1 (rd=PC+4), jump=1, alu_op=00.
      // ALU computes jump target: PC + sext(J-imm) via alu_src_a=PC,
      // alu_src_b=J-imm. PC+4 link address comes from the dedicated PC+4
      // adder and is selected for rd writeback when jump=1 (§6 note).
      // ----------------------------------------------------------------------
      OP_JAL: begin
        reg_write_o    = 1'b1;
        alu_src_o      = 1'b1;
        alu_src_a_o    = ALU_SRCA_PC;
        mem_read_o     = 1'b0;
        mem_write_o    = 1'b0;
        mem_to_reg_o   = 1'b0;
        branch_o       = 1'b0;
        jump_o         = 1'b1;
        jalr_o         = 1'b0;
        imm_type_o      = IMM_TYPE_J;
        alu_op_o       = ALU_OP_ADD;
        illegal_instr_o = 1'b0;
      end

      // ----------------------------------------------------------------------
      // JALR  (canonical-reference.md §1.6)
      // reg_write=1 (rd=PC+4), jump=1, jalr=1.
      // alu_src=1 (target = rs1 + sext(imm)), alu_op=00 (ADD).
      // Datapath must AND target with ~1 to clear LSB (gotchas.md #6).
      // imm_sel=I (12-bit immediate).
      // ----------------------------------------------------------------------
      OP_JALR: begin
        reg_write_o    = 1'b1;
        alu_src_o      = 1'b1;
        alu_src_a_o    = ALU_SRCA_RS1;
        mem_read_o     = 1'b0;
        mem_write_o    = 1'b0;
        mem_to_reg_o   = 1'b0;
        branch_o       = 1'b0;
        jump_o         = 1'b1;
        jalr_o         = 1'b1;
        imm_type_o      = IMM_TYPE_I;
        alu_op_o       = ALU_OP_ADD;
        illegal_instr_o = 1'b0;
      end

      // ----------------------------------------------------------------------
      // LUI  (canonical-reference.md §1.7)
      // reg_write=1, alu_src=1 (U-imm as ALU-B), alu_op=00 (ADD).
      // alu_src_a=ZERO: ALU computes 0 + U-imm = U-imm. Result written to rd.
      // Datapath ALU-A mux must support the zero leg (alu_src_a_o=2'b10).
      // ----------------------------------------------------------------------
      OP_LUI: begin
        reg_write_o    = 1'b1;
        alu_src_o      = 1'b1;
        alu_src_a_o    = ALU_SRCA_ZERO;
        mem_read_o     = 1'b0;
        mem_write_o    = 1'b0;
        mem_to_reg_o   = 1'b0;
        branch_o       = 1'b0;
        jump_o         = 1'b0;
        jalr_o         = 1'b0;
        imm_type_o      = IMM_TYPE_U;
        alu_op_o       = ALU_OP_ADD;
        illegal_instr_o = 1'b0;
      end

      // ----------------------------------------------------------------------
      // AUIPC  (canonical-reference.md §1.7)
      // reg_write=1, alu_src=1 (U-imm as ALU-B), alu_src_a=PC (ALU-A=PC).
      // alu_op=00 (ADD): result = PC + (imm[31:12] << 12).
      // MUST use current instruction PC, NOT PC+4 (gotchas.md #7).
      // ----------------------------------------------------------------------
      OP_AUIPC: begin
        reg_write_o    = 1'b1;
        alu_src_o      = 1'b1;
        alu_src_a_o    = ALU_SRCA_PC;
        mem_read_o     = 1'b0;
        mem_write_o    = 1'b0;
        mem_to_reg_o   = 1'b0;
        branch_o       = 1'b0;
        jump_o         = 1'b0;
        jalr_o         = 1'b0;
        imm_type_o      = IMM_TYPE_U;
        alu_op_o       = ALU_OP_ADD;
        illegal_instr_o = 1'b0;
      end

      // ----------------------------------------------------------------------
      // FENCE  (canonical-reference.md §1.8)
      // Single-hart system — treated as NOP. All outputs 0.
      // ----------------------------------------------------------------------
      OP_FENCE: begin
        reg_write_o    = 1'b0;
        alu_src_o      = 1'b0;
        alu_src_a_o    = ALU_SRCA_RS1;
        mem_read_o     = 1'b0;
        mem_write_o    = 1'b0;
        mem_to_reg_o   = 1'b0;
        branch_o       = 1'b0;
        jump_o         = 1'b0;
        jalr_o         = 1'b0;
        imm_type_o      = IMM_TYPE_I;
        alu_op_o       = ALU_OP_ADD;
        illegal_instr_o = 1'b0;
      end

      // ----------------------------------------------------------------------
      // ECALL / EBREAK  (canonical-reference.md §1.8, §9.1)
      // Assert halt_o to signal trap. All datapath signals 0.
      // Both share opcode 1110011; funct3/imm[11:0] distinguish them but
      // both halt — no further decode needed here.
      // halt_o maps to the chip-level halt output pin (§9.1).
      // ----------------------------------------------------------------------
      OP_SYSTEM: begin
        reg_write_o     = 1'b0;
        alu_src_o       = 1'b0;
        alu_src_a_o     = ALU_SRCA_RS1;
        mem_read_o      = 1'b0;
        mem_write_o     = 1'b0;
        mem_to_reg_o    = 1'b0;
        branch_o        = 1'b0;
        jump_o          = 1'b0;
        jalr_o          = 1'b0;
        imm_type_o      = IMM_TYPE_I;
        alu_op_o        = ALU_OP_ADD;
        halt_o          = 1'b1;
        illegal_instr_o = 1'b0;
      end

      // ----------------------------------------------------------------------
      // CUSTOM-0  (canonical-reference.md §8.1)
      // R-type format. alu_op=10 (R-type); alu_control will resolve
      // extended alu_ctrl codes 4'b1010–4'b1101 from funct7+funct3.
      // reg_write=1, alu_src=0 (rs2).
      // imm_sel unused — R-type format, driven to safe default.
      // ----------------------------------------------------------------------
      OP_CUSTOM0: begin
        reg_write_o    = 1'b1;
        alu_src_o      = 1'b0;
        alu_src_a_o    = ALU_SRCA_RS1;
        mem_read_o     = 1'b0;
        mem_write_o    = 1'b0;
        mem_to_reg_o   = 1'b0;
        branch_o       = 1'b0;
        jump_o         = 1'b0;
        jalr_o         = 1'b0;
        imm_type_o      = IMM_TYPE_I;
        alu_op_o       = ALU_OP_RTYPE;
        illegal_instr_o = 1'b0;
      end

      // ----------------------------------------------------------------------
      // Default — unrecognised opcode
      // All datapath signals 0 (NOP behaviour). illegal_instr=1.
      // Canonical §2: "Any opcode not in this table → illegal_instr = 1"
      // ----------------------------------------------------------------------
      default: begin
        reg_write_o     = 1'b0;
        alu_src_o       = 1'b0;
        alu_src_a_o     = ALU_SRCA_RS1;
        mem_read_o      = 1'b0;
        mem_write_o     = 1'b0;
        mem_to_reg_o    = 1'b0;
        branch_o        = 1'b0;
        jump_o          = 1'b0;
        jalr_o          = 1'b0;
        imm_type_o      = IMM_TYPE_I;
        alu_op_o        = ALU_OP_ADD;
        halt_o          = 1'b0;
        illegal_instr_o = 1'b1;
      end

    endcase
  end

endmodule
