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
// Module: datapath_m0
// Description: M0 single-cycle datapath top-level. Wires alu, regfile,
//              imm_gen, control_decoder, and alu_control together for the
//              instruction → decode → regfile read → ALU → writeback path.
//              No PC, no instruction memory, no data memory, no branches,
//              no loads/stores, no forwarding. M0 scope per ar April 2026.
// M0 known limitations (to be resolved in M1):
//   - JAL/JALR: rd receives ALU result, NOT PC+4 (no PC available in M0).
//   - AUIPC: result is 0+imm (pc_val=32'h0 placeholder; wrong but expected).
//   - jalr_target_o is wired out (gotchas.md #6); connect to PC mux in M1.
//   - halt_nc/illegal_instr_nc must be promoted to top-level ports in M1.
// Author: Beaux Cable
// Date: April 2026
// Project: TSI RV32I Pipelined Processor (TSMC 180nm)
// ============================================================================

module datapath_m0 (
  input  logic        clk,
  input  logic        rst_n,           // active-low async reset

  input  logic [31:0] instr_i,         // instruction word (from testbench)
  input  logic [31:0] pc_i,            // current PC (M0: tie to 32'h0)

  // Testbench observability outputs
  output logic [31:0] alu_result_o,    // ALU result this cycle
  output logic        reg_write_o,     // register file write enable (control)
  output logic [ 4:0] rd_addr_o,       // dest reg (5'b0 when reg_write=0)
  output logic [31:0] jalr_target_o    // JALR PC-next: (rs1+imm)&~1 (gotcha #6)
);

  // --------------------------------------------------------------------------
  // Instruction field extraction (canonical-reference.md §3)
  // --------------------------------------------------------------------------
  logic [4:0] rs1_addr;
  logic [4:0] rs2_addr;
  logic [4:0] rd_addr;
  logic [2:0] funct3;
  logic       funct7b5;

  assign rs1_addr = instr_i[19:15];
  assign rs2_addr = instr_i[24:20];
  assign rd_addr  = instr_i[11:7];
  assign funct3   = instr_i[14:12];
  assign funct7b5 = instr_i[30];

  // --------------------------------------------------------------------------
  // Internal signal declarations
  // --------------------------------------------------------------------------

  // Used control signals
  logic        reg_write;
  logic        alu_src;
  logic [ 1:0] alu_src_a;
  logic [ 2:0] imm_type;
  logic [ 1:0] alu_op;

  // Unused control_decoder outputs in M0 scope.
  // Connected to named signals (not left truly floating) so that synthesis
  // does not warn on undriven nets while the M0 scope limitation is explicit.
  logic        mem_read_nc;       // loads: unused in M0
  logic        mem_write_nc;      // stores: unused in M0
  logic        mem_to_reg_nc;     // WB mux sel: unused in M0
  logic        branch_nc;         // branch enable: unused in M0
  logic        jump_nc;           // JAL/JALR: unused in M0
  logic        jalr_nc;           // JALR distinguish: unused in M0
  // ⚠ M1 TODO: promote halt_nc and illegal_instr_nc to top-level output
  // ports before tape-out so illegal opcodes / ECALL are externally visible.
  logic        halt_nc;           // ECALL/EBREAK halt: unused in M0
  logic        illegal_instr_nc;  // illegal opcode: unused in M0

  // alu_control illegal_o: unused in M0 (no trap path yet)
  logic        alu_illegal_nc;

  // Immediate generator output
  logic [31:0] imm;

  // ALU control select
  logic [ 3:0] alu_ctrl;

  // Register file read data
  logic [31:0] rs1_data;
  logic [31:0] rs2_data;

  // ALU operand mux results
  logic [31:0] alu_a;
  logic [31:0] alu_b;

  // ALU result (wire from alu instance to output and regfile write data)
  logic [31:0] alu_result;

  // JALR LSB-clear (gotchas.md #6). Ownership is here per spec.
  // Exposed as jalr_target_o so synthesis cannot prune it and M1 has a
  // direct port to connect to the PC-next mux (selected when jalr_o=1).
  logic [31:0] jalr_target;
  assign jalr_target   = {alu_result[31:1], 1'b0};
  assign jalr_target_o = jalr_target;


  // --------------------------------------------------------------------------
  // ALU operand A mux (canonical-reference.md §6 LUI/AUIPC note; §6.1)
  //   2'b00 → rs1_data  (R-type, I-type ALU, loads, stores, JALR)
  //   2'b01 → pc_i      (AUIPC/JAL: current PC; M0 tie to 32'h0)
  //   2'b10 → 32'h0     (zero — correct for LUI: 0 + U-imm = U-imm)
  // --------------------------------------------------------------------------
  always_comb begin
    alu_a = 32'h0; // default: prevents latch inference (gotchas.md #1)
    case (alu_src_a)
      2'b00:   alu_a = rs1_data;
      2'b01:   alu_a = pc_i;     // AUIPC/JAL: current PC (M0: tied to 0)
      2'b10:   alu_a = 32'h0;   // zero (LUI: 0 + U-imm = U-imm)
      default: alu_a = 32'h0;
    endcase
  end

  // --------------------------------------------------------------------------
  // ALU operand B mux (canonical-reference.md §6.1)
  //   1'b0 → rs2_data  (R-type)
  //   1'b1 → imm       (I-type, S-type, U-type, B-type, J-type)
  // --------------------------------------------------------------------------
  always_comb begin
    alu_b = 32'h0; // default: prevents latch inference (gotchas.md #1)
    case (alu_src)
      1'b0:    alu_b = rs2_data;
      1'b1:    alu_b = imm;
      default: alu_b = 32'h0;
    endcase
  end

  // --------------------------------------------------------------------------
  // Observable outputs
  // --------------------------------------------------------------------------
  assign reg_write_o  = reg_write;
  assign alu_result_o = alu_result;
  // rd_addr_o: valid only when reg_write=1. Gate to 5'b0 otherwise so
  // testbenches don't misread instr[11:7] as a destination for S/B-type.
  assign rd_addr_o = reg_write ? rd_addr : 5'b0;

  // --------------------------------------------------------------------------
  // Sub-module instantiations
  // --------------------------------------------------------------------------

  // -- Control decoder -------------------------------------------------------
  // Unused M0 outputs (mem_read_o, mem_write_o, mem_to_reg_o, branch_o,
  // jump_o, jalr_o, halt_o, illegal_instr_o) are captured in _nc wires
  // rather than left unconnected to keep the port binding list complete and
  // avoid lint false-positives for undriven outputs.
  control_decoder ctrl_dec (
    .inst_i          (instr_i),
    .reg_write_o     (reg_write),
    .alu_src_o       (alu_src),
    .alu_src_a_o     (alu_src_a),
    .mem_read_o      (mem_read_nc),
    .mem_write_o     (mem_write_nc),
    .mem_to_reg_o    (mem_to_reg_nc),
    .branch_o        (branch_nc),
    .jump_o          (jump_nc),
    .jalr_o          (jalr_nc),
    .imm_type_o      (imm_type),
    .alu_op_o        (alu_op),
    .halt_o          (halt_nc),
    .illegal_instr_o (illegal_instr_nc)
  );

  // -- Immediate generator ---------------------------------------------------
  imm_gen imm_gen_unit (
    .inst_i     (instr_i),
    .imm_type_i (imm_type),
    .imm_o      (imm)
  );

  // -- ALU control -----------------------------------------------------------
  alu_control alu_ctrl_unit (
    .alu_op_i   (alu_op),
    .funct3_i   (funct3),
    .funct7b5_i (funct7b5),
    .alu_ctrl_o (alu_ctrl),
    .illegal_o  (alu_illegal_nc)
  );

  // -- Register file ---------------------------------------------------------
  // Write port: alu_result written to rd on posedge clk when reg_write=1.
  // x0 write suppression is inside regfile.sv (wr_addr_i != 5'b0 guard).
  // Read-during-write returns OLD value (no forwarding in M0).
  regfile reg_file (
    .clk         (clk),
    .rst_n       (rst_n),
    .wr_en_i     (reg_write),
    .wr_addr_i   (rd_addr),
    .wr_data_i   (alu_result),
    .rd_addr_a_i (rs1_addr),
    .rd_data_a_o (rs1_data),
    .rd_addr_b_i (rs2_addr),
    .rd_data_b_o (rs2_data)
  );

  // -- ALU -------------------------------------------------------------------
  // alu.sv exposes no zero_o port; zero flag is internal to the ALU module.
  alu alu_unit (
    .a_i        (alu_a),
    .b_i        (alu_b),
    .alu_ctrl_i (alu_ctrl),
    .result_o   (alu_result)
  );

endmodule
