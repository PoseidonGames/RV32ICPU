// ============================================================================
// Module: alu
// Description: RV32I arithmetic/logic unit. Supports all 10 base integer
//              operations. Branch comparison is handled by branch_comparator.
// Author: Beaux Cable
// Date: April 2026
// Project: TSI RV32I Pipelined Processor (TSMC 180nm)
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
// ============================================================================
// Module: regfile
// Description: RV32I register file — 32×32 flip-flop based, no SRAM.
//              2 async read ports, 1 sync write port. x0 hardwired to zero.
// Author: Beaux Cable
// Date: April 2026
// Project: TSI RV32I Pipelined Processor (TSMC 180nm)
// ============================================================================

module regfile (
    input  logic        clk,
    input  logic        rst_n,          // active-low reset

    // Write port
    input  logic        wr_en_i,        // write enable
    input  logic [4:0]  wr_addr_i,      // destination register (rd)
    input  logic [31:0] wr_data_i,      // data to write

    // Read port A
    input  logic [4:0]  rd_addr_a_i,    // source register 1 (rs1)
    output logic [31:0] rd_data_a_o,    // read data 1

    // Read port B
    input  logic [4:0]  rd_addr_b_i,    // source register 2 (rs2)
    output logic [31:0] rd_data_b_o     // read data 2
);

    // 32 registers, each 32 bits wide
    logic [31:0] regs [31:0];

    // ----------------------------------------------------------
    // Read logic — asynchronous (combinational)
    // x0 always reads as zero regardless of what's stored
    // ----------------------------------------------------------
    assign rd_data_a_o = (rd_addr_a_i == 5'b0) ? 32'h0 : regs[rd_addr_a_i];
    assign rd_data_b_o = (rd_addr_b_i == 5'b0) ? 32'h0 : regs[rd_addr_b_i];

    // ----------------------------------------------------------
    // Write logic — synchronous, x0 is never written
    // Read-during-write returns OLD value; pipeline handles forwarding.
    // ----------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < 32; i++) begin
                regs[i] <= 32'h0;
            end
        end else if (wr_en_i && wr_addr_i != 5'b0) begin
            regs[wr_addr_i] <= wr_data_i;
        end
    end

endmodule
// ============================================================================
// Module: imm_gen
// Description: Immediate generator for RV32I. Extracts and sign-extends
//              the immediate field from a 32-bit instruction word.
//              Supports I, S, B, U, and J immediate formats as defined
//              in the canonical reference (§4).
// Author: Beaux Cable
// Date: April 2026
// Project: TSI RV32I Pipelined Processor (TSMC 180nm)
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
// ============================================================================
// Module: control_decoder
// Description: Main instruction decoder for the RV32I M0 single-cycle
//              datapath. Takes a 32-bit instruction word and produces all
//              datapath control signals by decoding opcode[6:0], funct3,
//              and funct7[5] (bit 30). Combinational only — no state.
//              Encoding values from canonical-reference.md §2, §4, §6.
// Author: Beaux Cable
// Date: April 2026
// Project: TSI RV32I Pipelined Processor (TSMC 180nm)
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
// ============================================================================
// Module: load_store_unit
// Description: Combinational LSU. Generates byte-lane-aligned store data and
//              write-enables for stores; performs sign/zero extension for
//              loads. Purely combinational — no clock or reset ports.
// Author: Beaux Cable
// Date: April 2026
// Project: TSI RV32I Pipelined Processor (TSMC 180nm)
// ============================================================================

module load_store_unit (
  // ---- Store path inputs -----------------------------------------------
  input  logic [31:0] rs2_i,       // Store source data
  input  logic [31:0] addr_i,      // Effective byte address (ALU result)
  input  logic [2:0]  funct3_i,    // Instruction funct3
  input  logic        mem_write_i, // 1 = store instruction
  input  logic        mem_read_i,  // 1 = load instruction

  // ---- Memory interface (store) ----------------------------------------
  output logic [31:0] store_data_o, // Byte-lane-aligned write data
  output logic [3:0]  data_we_o,    // Active-high byte write enables

  // ---- Memory interface (load) -----------------------------------------
  input  logic [31:0] load_raw_i,  // Raw 32-bit word from data memory
  output logic [31:0] load_data_o  // Sign/zero-extended load result
);

  // =========================================================================
  // Localparams — funct3 encodings (canonical-reference.md S1.3, S1.4)
  // =========================================================================

  // Load funct3
  localparam FUNCT3_LB  = 3'b000;
  localparam FUNCT3_LH  = 3'b001;
  localparam FUNCT3_LW  = 3'b010;
  localparam FUNCT3_LBU = 3'b100;
  localparam FUNCT3_LHU = 3'b101;

  // Store funct3
  localparam FUNCT3_SB  = 3'b000;
  localparam FUNCT3_SH  = 3'b001;
  localparam FUNCT3_SW  = 3'b010;

  // =========================================================================
  // Internal signals
  // =========================================================================

  // Byte offset within the aligned word
  logic [1:0] byte_off;
  assign byte_off = addr_i[1:0];

  // Extracted byte/halfword from raw load data, before extension
  logic [7:0]  load_byte;
  logic [15:0] load_half;

  // =========================================================================
  // Store path — byte-lane alignment
  //
  // Data is replicated to all relevant byte lanes; data_we selects which
  // lanes the memory actually writes.  The memory ignores inactive lanes.
  //
  // SB: replicate byte to all 4 lanes; data_we = 4'b0001 << byte_off
  // SH: replicate halfword to both halfwords; data_we depends on addr[1]
  // SW: pass full word; data_we = 4'b1111
  // =========================================================================

  always_comb begin
    // Defaults — prevent latch inference (gotcha #1)
    store_data_o = 32'h0;
    data_we_o    = 4'b0000;

    if (mem_write_i) begin
      case (funct3_i)
        FUNCT3_SB: begin
          // Replicate byte to all 4 lanes; memory selects via data_we
          store_data_o = {4{rs2_i[7:0]}};
          data_we_o    = 4'b0001 << byte_off;
        end

        FUNCT3_SH: begin
          // Replicate halfword to both halfwords; memory selects via data_we
          store_data_o = {2{rs2_i[15:0]}};
          data_we_o    = byte_off[1] ? 4'b1100 : 4'b0011;
        end

        FUNCT3_SW: begin
          store_data_o = rs2_i;
          data_we_o    = 4'b1111;
        end

        default: begin
          store_data_o = 32'h0;
          data_we_o    = 4'b0000;
        end
      endcase
    end
  end

  // =========================================================================
  // Load path — byte/halfword extraction
  //
  // byte_off selects which of the four bytes (or two halfwords) to extract
  // from the aligned 32-bit word returned by memory.  Misaligned access is
  // undefined behavior per the canonical reference — no trap logic required.
  // =========================================================================

  // -- Byte extraction: pick byte lane from raw load word ------------------
  always_comb begin
    // Default (gotcha #1)
    load_byte = 8'h0;
    case (byte_off)
      2'b00: load_byte = load_raw_i[7:0];
      2'b01: load_byte = load_raw_i[15:8];
      2'b10: load_byte = load_raw_i[23:16];
      2'b11: load_byte = load_raw_i[31:24];
      default: load_byte = 8'h0;
    endcase
  end

  // -- Halfword extraction: pick lower or upper halfword -------------------
  always_comb begin
    // Default (gotcha #1)
    load_half = 16'h0;
    case (byte_off[1])
      1'b0: load_half = load_raw_i[15:0];
      1'b1: load_half = load_raw_i[31:16];
      default: load_half = 16'h0;
    endcase
  end

  // -- Final load data mux: extension + instruction routing ----------------
  always_comb begin
    // Default (gotcha #1)
    load_data_o = 32'h0;

    if (mem_read_i) begin
      case (funct3_i)
        FUNCT3_LB:  load_data_o = {{24{load_byte[7]}}, load_byte};
        FUNCT3_LBU: load_data_o = {24'h0,              load_byte};
        FUNCT3_LH:  load_data_o = {{16{load_half[15]}}, load_half};
        FUNCT3_LHU: load_data_o = {16'h0,               load_half};
        FUNCT3_LW:  load_data_o = load_raw_i;
        default:    load_data_o = 32'h0;
      endcase
    end
  end

endmodule
// ============================================================================
// Module: forwarding_unit
// Description: WB-to-EX forwarding unit. Detects when a register written in
//              WB is needed as a source in EX and asserts the appropriate
//              forward enable signals. Combinational only — no state.
//
//              forward_rs1_o is additionally gated by alu_src_a == 2'b00 to
//              prevent corruption when ALU-A is PC (AUIPC/JAL) or zero (LUI).
//              forward_rs2_o is NOT gated because rs2 also feeds the store
//              data path, which must forward regardless of alu_src_a.
//
// Author: Beaux Cable
// Date: April 2026
// Project: TSI RV32I Pipelined Processor (TSMC 180nm)
// ============================================================================

module forwarding_unit (
  // WB stage — source of forwarded data
  input  logic        wb_reg_write_i,  // WB reg-file write enable
  input  logic [4:0]  wb_rd_i,         // WB destination register address

  // EX stage — consumers needing potentially-forwarded values
  input  logic [4:0]  ex_rs1_i,        // EX source register 1 address
  input  logic [4:0]  ex_rs2_i,        // EX source register 2 address
  input  logic [1:0]  alu_src_a_i,     // ALU-A mux select (00=rs1, 01=PC,
                                        //   10=zero)

  // Forward enable outputs
  output logic        forward_rs1_o,   // 1 = use wb_write_data for rs1
  output logic        forward_rs2_o    // 1 = use wb_write_data for rs2
);

  // -------------------------------------------------------------------------
  // Localparams
  // -------------------------------------------------------------------------
  localparam ALU_SRC_A_RS1 = 2'b00;  // ALU-A mux: register rs1 path

  // -------------------------------------------------------------------------
  // Forwarding logic (gotcha #8: x0 suppression; gotcha #12: alu_src_a gate)
  // -------------------------------------------------------------------------
  always_comb begin
    // Defaults prevent latch inference (gotcha #1)
    forward_rs1_o = 1'b0;
    forward_rs2_o = 1'b0;

    // rs1 forwarding: suppress when ALU-A is not driven from rs1
    // (alu_src_a != 00 means ALU-A is PC or zero — forwarding rs1 would
    // silently corrupt AUIPC, JAL, and LUI results; gotcha #12)
    forward_rs1_o = wb_reg_write_i
                    && (wb_rd_i  != 5'd0)           // gotcha #8
                    && (wb_rd_i  == ex_rs1_i)
                    && (alu_src_a_i == ALU_SRC_A_RS1);

    // rs2 forwarding: no alu_src_a gate — rs2 feeds both ALU-B mux and
    // the store data path; stores must forward even when alu_src_a != 00
    forward_rs2_o = wb_reg_write_i
                    && (wb_rd_i != 5'd0)            // gotcha #8
                    && (wb_rd_i == ex_rs2_i);
  end

endmodule
// ============================================================================
// Module: pipeline_top
// Description: RV32I 3-stage pipeline integration top-level (M1 milestone).
//              Stages: IF (fetch) -> EX (decode+execute+mem) -> WB (writeback).
//              Contains: PC register, PC+4 adder, IF/EX and EX/WB pipeline
//              registers, forwarding muxes, ALU-A/B muxes, WB mux, PC-next
//              mux, branch target adder, flush logic, and halt output.
//              Instantiates all 8 leaf modules: alu, regfile, imm_gen,
//              control_decoder, alu_control, branch_comparator,
//              load_store_unit, forwarding_unit.
// Author: Beaux Cable
// Date: April 2026
// Project: TSI RV32I Pipelined Processor (TSMC 180nm)
// ============================================================================

module pipeline_top (
  input  logic        clk,
  input  logic        rst_n,            // active-low async reset

  // Instruction memory interface (IF stage)
  output logic [31:0] instr_addr_o,     // PC -> instruction memory
  input  logic [31:0] instr_data_i,     // instruction word from memory

  // Data memory interface (EX stage)
  output logic [31:0] data_addr_o,      // effective address (ALU result)
  output logic [31:0] data_out_o,       // store data (byte-lane aligned)
  output logic [3:0]  data_we_o,        // byte write enables, active-high
  output logic        data_re_o,        // read enable (gated by valid)
  input  logic [31:0] data_in_i,        // load data from memory

  // Processor status
  output logic        halt_o            // ECALL/EBREAK or illegal instruction
);

  // ==========================================================================
  // Localparams
  // ==========================================================================

  // NOP = ADDI x0, x0, 0 (canonical-reference.md §7.3; gotcha #9)
  localparam logic [31:0] NOP_INSTR = 32'h00000013;

  // ALU-A source select encoding (canonical-reference.md §6.1)
  localparam logic [1:0] ALU_SRCA_RS1  = 2'b00;
  localparam logic [1:0] ALU_SRCA_PC   = 2'b01;
  localparam logic [1:0] ALU_SRCA_ZERO = 2'b10;

  // ==========================================================================
  // IF stage — PC register and PC+4 adder
  // ==========================================================================

  logic [31:0] pc_reg;       // current program counter
  logic [31:0] pc_plus_4;    // pc_reg + 4
  logic [31:0] pc_next;      // next-cycle PC value (resolved in EX)

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      pc_reg <= 32'h0;
    else
      pc_reg <= pc_next;
  end

  assign pc_plus_4    = pc_reg + 32'd4;
  assign instr_addr_o = pc_reg;

  // ==========================================================================
  // IF/EX pipeline register
  // Flush inserts NOP bubble on taken branch or any jump (gotcha #9).
  // ==========================================================================

  logic [31:0] if_ex_instr;     // latched instruction word
  logic [31:0] if_ex_pc;        // latched PC of this instruction
  logic [31:0] if_ex_pc_plus_4; // latched PC+4
  logic        if_ex_valid;     // 0 = bubble/NOP

  logic flush_if_ex;            // flush strobe (computed in EX)

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      if_ex_instr     <= NOP_INSTR;
      if_ex_pc        <= 32'h0;
      if_ex_pc_plus_4 <= 32'd4;
      if_ex_valid     <= 1'b0;
    end else if (flush_if_ex) begin
      // Insert NOP bubble; PC fields are don't-care but zeroed for tidiness
      if_ex_instr     <= NOP_INSTR;
      if_ex_pc        <= 32'h0;
      if_ex_pc_plus_4 <= 32'd4;
      if_ex_valid     <= 1'b0;
    end else begin
      if_ex_instr     <= instr_data_i;
      if_ex_pc        <= pc_reg;
      if_ex_pc_plus_4 <= pc_plus_4;
      if_ex_valid     <= 1'b1;
    end
  end

  // ==========================================================================
  // EX stage — instruction field extraction
  // ==========================================================================

  // Fields extracted from the latched instruction word
  logic [6:0] ex_opcode;
  logic [4:0] ex_rd_addr;
  logic [4:0] ex_rs1_addr;
  logic [4:0] ex_rs2_addr;
  logic [2:0] ex_funct3;
  logic       ex_funct7b5;

  assign ex_opcode   = if_ex_instr[6:0];
  assign ex_rd_addr  = if_ex_instr[11:7];
  assign ex_rs1_addr = if_ex_instr[19:15];
  assign ex_rs2_addr = if_ex_instr[24:20];
  assign ex_funct3   = if_ex_instr[14:12];
  assign ex_funct7b5 = if_ex_instr[30];    // funct7[5]

  // ==========================================================================
  // EX stage — control decoder outputs
  // ==========================================================================

  logic        ex_reg_write;
  logic        ex_alu_src;
  logic [1:0]  ex_alu_src_a;
  logic        ex_mem_read;
  logic        ex_mem_write;
  logic        ex_mem_to_reg;
  logic        ex_branch;
  logic        ex_jump;
  logic        ex_jalr;
  logic [2:0]  ex_imm_type;
  logic [1:0]  ex_alu_op;
  logic        ex_halt;
  logic        ex_illegal_instr;

  control_decoder ctrl_dec (
    .inst_i         (if_ex_instr),
    .reg_write_o    (ex_reg_write),
    .alu_src_o      (ex_alu_src),
    .alu_src_a_o    (ex_alu_src_a),
    .mem_read_o     (ex_mem_read),
    .mem_write_o    (ex_mem_write),
    .mem_to_reg_o   (ex_mem_to_reg),
    .branch_o       (ex_branch),
    .jump_o         (ex_jump),
    .jalr_o         (ex_jalr),
    .imm_type_o     (ex_imm_type),
    .alu_op_o       (ex_alu_op),
    .halt_o         (ex_halt),
    .illegal_instr_o(ex_illegal_instr)
  );

  // ==========================================================================
  // EX stage — immediate generator
  // ==========================================================================

  logic [31:0] ex_imm;

  imm_gen imm_generator (
    .inst_i    (if_ex_instr),
    .imm_type_i(ex_imm_type),
    .imm_o     (ex_imm)
  );

  // ==========================================================================
  // EX stage — register file
  // Read addresses come from EX instruction; write port driven from WB stage.
  // ==========================================================================

  logic [31:0] rs1_data;    // raw read-port A output
  logic [31:0] rs2_data;    // raw read-port B output

  // WB-stage signals (driven by EX/WB pipeline register below)
  logic [31:0] wb_write_data;
  logic [4:0]  wb_rd;
  logic        wb_reg_write;

  regfile reg_file (
    .clk        (clk),
    .rst_n      (rst_n),
    // Write port — driven from WB stage
    .wr_en_i    (wb_reg_write),
    .wr_addr_i  (wb_rd),
    .wr_data_i  (wb_write_data),
    // Read port A — rs1
    .rd_addr_a_i(ex_rs1_addr),
    .rd_data_a_o(rs1_data),
    // Read port B — rs2
    .rd_addr_b_i(ex_rs2_addr),
    .rd_data_b_o(rs2_data)
  );

  // ==========================================================================
  // EX stage — forwarding unit
  // ==========================================================================

  logic forward_rs1;
  logic forward_rs2;

  forwarding_unit fwd_unit (
    .wb_reg_write_i(wb_reg_write),
    .wb_rd_i       (wb_rd),
    .ex_rs1_i      (ex_rs1_addr),
    .ex_rs2_i      (ex_rs2_addr),
    .alu_src_a_i   (ex_alu_src_a),
    .forward_rs1_o (forward_rs1),
    .forward_rs2_o (forward_rs2)
  );

  // ==========================================================================
  // EX stage — forwarding muxes
  // ==========================================================================

  logic [31:0] rs1_fwd;  // rs1 after WB-to-EX forwarding
  logic [31:0] rs2_fwd;  // rs2 after WB-to-EX forwarding

  assign rs1_fwd = forward_rs1 ? wb_write_data : rs1_data;
  assign rs2_fwd = forward_rs2 ? wb_write_data : rs2_data;

  // ==========================================================================
  // EX stage — ALU-A and ALU-B muxes
  // ALU-A: 00=rs1_fwd (default), 01=if_ex_pc (AUIPC/JAL), 10=zero (LUI)
  // ALU-B: alu_src ? ex_imm : rs2_fwd
  // ==========================================================================

  logic [31:0] alu_a;
  logic [31:0] alu_b;

  always_comb begin
    // Default prevents latch inference (gotcha #1)
    alu_a = 32'h0;
    case (ex_alu_src_a)
      ALU_SRCA_RS1:  alu_a = rs1_fwd;    // rs1 with WB forwarding
      ALU_SRCA_PC:   alu_a = if_ex_pc;   // AUIPC/JAL: current PC (gotcha #7)
      ALU_SRCA_ZERO: alu_a = 32'h0;      // LUI: zero
      default:       alu_a = 32'h0;
    endcase
  end

  assign alu_b = ex_alu_src ? ex_imm : rs2_fwd;

  // ==========================================================================
  // EX stage — ALU control
  // ==========================================================================

  logic [3:0] alu_ctrl;
  logic       alu_ctrl_illegal;

  alu_control alu_ctrl_unit (
    .alu_op_i   (ex_alu_op),
    .funct3_i   (ex_funct3),
    .funct7b5_i (ex_funct7b5),
    .alu_ctrl_o (alu_ctrl),
    .illegal_o  (alu_ctrl_illegal)
  );

  // ==========================================================================
  // EX stage — ALU
  // ==========================================================================

  logic [31:0] alu_result;

  alu alu_unit (
    .a_i       (alu_a),
    .b_i       (alu_b),
    .alu_ctrl_i(alu_ctrl),
    .result_o  (alu_result)
  );

  // ==========================================================================
  // EX stage — JALR LSB clear (gotcha #6)
  // target = (rs1 + sext(imm)) & ~1; always formed from alu_result
  // ==========================================================================

  logic [31:0] jalr_target;
  assign jalr_target = {alu_result[31:1], 1'b0};

  // ==========================================================================
  // EX stage — branch target adder (separate from ALU; gotcha #7)
  // branch_target = if_ex_pc + B-imm (ex_imm when branch=1)
  // ==========================================================================

  logic [31:0] branch_target;
  assign branch_target = if_ex_pc + ex_imm;

  // ==========================================================================
  // EX stage — branch comparator
  // ==========================================================================

  logic branch_taken;

  branch_comparator br_comp (
    .rs1_data_i    (rs1_fwd),
    .rs2_data_i    (rs2_fwd),
    .funct3_i      (ex_funct3),
    .branch_taken_o(branch_taken)
  );

  // ==========================================================================
  // EX stage — load/store unit
  // Store data is rs2_fwd (forwarded); store data path bypasses ALU-B mux.
  // data_we/data_re gated by if_ex_valid to suppress memory access on bubbles.
  // ==========================================================================

  logic [31:0] store_data;
  logic [3:0]  lsu_data_we;
  logic [31:0] load_data;

  // Valid-gated memory control signals (single definition, used by LSU + I/O)
  logic ex_mem_write_gated;
  logic ex_mem_read_gated;
  assign ex_mem_write_gated = ex_mem_write && if_ex_valid;
  assign ex_mem_read_gated  = ex_mem_read  && if_ex_valid;

  load_store_unit lsu (
    .rs2_i       (rs2_fwd),
    .addr_i      (alu_result),
    .funct3_i    (ex_funct3),
    .mem_write_i (ex_mem_write_gated),
    .mem_read_i  (ex_mem_read_gated),
    .store_data_o(store_data),
    .data_we_o   (lsu_data_we),
    .load_raw_i  (data_in_i),
    .load_data_o (load_data)
  );

  // Memory interface outputs; data_we and data_re already gated inside LSU
  assign data_addr_o = alu_result;
  assign data_out_o  = store_data;
  assign data_we_o   = lsu_data_we;
  assign data_re_o   = ex_mem_read_gated;

  // ==========================================================================
  // EX stage — WB mux (select write-back value before latching into EX/WB)
  // Priority: jump (link) > mem_to_reg (load) > alu_result
  // ==========================================================================

  logic [31:0] ex_write_data;

  always_comb begin
    // Default prevents latch inference (gotcha #1)
    ex_write_data = alu_result;
    if (ex_jump)
      ex_write_data = if_ex_pc_plus_4; // JAL/JALR: rd = return address PC+4
    else if (ex_mem_to_reg)
      ex_write_data = load_data;       // load: rd = sign/zero-extended data
    else
      ex_write_data = alu_result;      // arithmetic/logic: rd = ALU result
  end

  // ==========================================================================
  // EX stage — PC-next mux
  // Priority: taken branch > JAL > JALR > sequential (PC+4)
  // Mux is qualified by if_ex_valid: a bubble must not redirect the PC.
  // ==========================================================================

  always_comb begin
    // Default: sequential execution
    pc_next = pc_plus_4;
    if (ex_branch && branch_taken && if_ex_valid)
      pc_next = branch_target;           // taken branch: PC + B-imm
    else if (ex_jump && !ex_jalr && if_ex_valid)
      pc_next = alu_result;              // JAL: PC + J-imm (from ALU)
    else if (ex_jump && ex_jalr && if_ex_valid)
      pc_next = jalr_target;            // JALR: {(rs1+imm)[31:1], 1'b0}
    else
      pc_next = pc_plus_4;              // sequential
  end

  // ==========================================================================
  // EX stage — flush logic
  // Flush IF/EX register on any taken branch or any jump (1-cycle bubble).
  // Qualified by if_ex_valid to avoid double-flush on a bubble.
  // ==========================================================================

  assign flush_if_ex =
    ((ex_branch && branch_taken) || ex_jump) && if_ex_valid;

  // ==========================================================================
  // EX/WB pipeline register
  // reg_write is gated by if_ex_valid: bubbles must not write the regfile.
  // ==========================================================================

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wb_write_data <= 32'h0;
      wb_rd         <= 5'b0;
      wb_reg_write  <= 1'b0;
    end else begin
      wb_write_data <= ex_write_data;
      wb_rd         <= ex_rd_addr;
      wb_reg_write  <= ex_reg_write && if_ex_valid;
    end
  end

  // ==========================================================================
  // Halt output
  // Assert when a valid EX instruction is ECALL/EBREAK or illegal opcode.
  // ==========================================================================

  assign halt_o = (ex_halt || ex_illegal_instr || alu_ctrl_illegal) && if_ex_valid;

endmodule
