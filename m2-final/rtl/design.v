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
  localparam logic [3:0] ALU_SRL      = 4'b1000;
  localparam logic [3:0] ALU_SRA      = 4'b1001;
  // M2a custom extensions (canonical-reference.md §8.1, §8.3)
  localparam logic [3:0] ALU_POPCOUNT = 4'b1010; // population count
  localparam logic [3:0] ALU_BREV     = 4'b1011; // bit reversal
  localparam logic [3:0] ALU_CLZ      = 4'b1111; // count leading zeros
  // M2b custom extension (canonical-reference.md §8.2)
  localparam logic [3:0] ALU_MUL16S   = 4'b1110; // signed 16x16 multiply

  // Shift amount is always the lower 5 bits of operand B (gotchas.md #3)
  logic [4:0] shamt;
  assign shamt = b_i[4:0];

  // Intermediate for POPCOUNT adder tree (range 0-32, needs 6 bits)
  logic [5:0] popcount_sum;

  // Intermediates for MUL16S signed 16x16 partial-product tree
  // (canonical-reference.md §8.2). Declared at module level: always_comb
  // case items cannot declare variables in many synthesis tools.
  logic signed [15:0] mul_op_a;  // sign-extended rs1[15:0]
  logic signed [15:0] mul_op_b;  // sign-extended rs2[15:0]
  logic        [15:0] mul_abs_a; // absolute value of mul_op_a
  logic        [15:0] mul_abs_b; // absolute value of mul_op_b
  logic               mul_negate; // 1 = result must be negated (signs differ)
  logic        [31:0] mul_sum;   // unsigned partial-product tree sum

  always_comb begin
    result_o     = 32'h0; // default: prevents latch inference
    popcount_sum = 6'h0;  // default: prevents latch inference
    // MUL16S defaults: prevents latch inference (gotchas.md #1)
    mul_op_a   = 16'sh0;
    mul_op_b   = 16'sh0;
    mul_abs_a  = 16'h0;
    mul_abs_b  = 16'h0;
    mul_negate = 1'b0;
    mul_sum    = 32'h0;
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

      // ------------------------------------------------------------------
      // M2a: POPCOUNT — count 1-bits in a_i (rs1).
      // Adder tree: sum all 32 individual bits. Result range 0–32 fits
      // in 6 bits; zero-extended to 32. rs2/b_i is ignored (unary op).
      // popcount_sum declared as 6-bit to give synthesis the right width.
      // canonical-reference.md §8.1
      // ------------------------------------------------------------------
      ALU_POPCOUNT: begin
        popcount_sum =
          {5'h0, a_i[ 0]} + {5'h0, a_i[ 1]} +
          {5'h0, a_i[ 2]} + {5'h0, a_i[ 3]} +
          {5'h0, a_i[ 4]} + {5'h0, a_i[ 5]} +
          {5'h0, a_i[ 6]} + {5'h0, a_i[ 7]} +
          {5'h0, a_i[ 8]} + {5'h0, a_i[ 9]} +
          {5'h0, a_i[10]} + {5'h0, a_i[11]} +
          {5'h0, a_i[12]} + {5'h0, a_i[13]} +
          {5'h0, a_i[14]} + {5'h0, a_i[15]} +
          {5'h0, a_i[16]} + {5'h0, a_i[17]} +
          {5'h0, a_i[18]} + {5'h0, a_i[19]} +
          {5'h0, a_i[20]} + {5'h0, a_i[21]} +
          {5'h0, a_i[22]} + {5'h0, a_i[23]} +
          {5'h0, a_i[24]} + {5'h0, a_i[25]} +
          {5'h0, a_i[26]} + {5'h0, a_i[27]} +
          {5'h0, a_i[28]} + {5'h0, a_i[29]} +
          {5'h0, a_i[30]} + {5'h0, a_i[31]};
        result_o = {26'h0, popcount_sum};
      end

      // ------------------------------------------------------------------
      // M2a: BREV — bit-reverse a_i (rs1).
      // Pure wire swizzle; zero area. rs2/b_i is ignored (unary op).
      // canonical-reference.md §8.1
      // ------------------------------------------------------------------
      ALU_BREV: result_o = {
        a_i[ 0], a_i[ 1], a_i[ 2], a_i[ 3],
        a_i[ 4], a_i[ 5], a_i[ 6], a_i[ 7],
        a_i[ 8], a_i[ 9], a_i[10], a_i[11],
        a_i[12], a_i[13], a_i[14], a_i[15],
        a_i[16], a_i[17], a_i[18], a_i[19],
        a_i[20], a_i[21], a_i[22], a_i[23],
        a_i[24], a_i[25], a_i[26], a_i[27],
        a_i[28], a_i[29], a_i[30], a_i[31]};

      // ------------------------------------------------------------------
      // M2b: MUL16S — signed 16x16→32 multiply.
      // No * operator. Sign-magnitude approach:
      //   1. Extract signed 16-bit operands from a_i[15:0] / b_i[15:0].
      //   2. Compute absolute values via two's complement negation.
      //   3. Sum 16 partial products (unsigned tree: AND + shift + add).
      //   4. If signs differ, negate result via two's complement.
      // Partial products: pp[i] = (mul_abs_a & {16{mul_abs_b[i]}}) << i,
      // zero-extended to 32 bits before shifting.
      // Uses +, <<, &, ~ only. No * operator. canonical-reference.md §8.2
      // ------------------------------------------------------------------
      ALU_MUL16S: begin
        mul_op_a   = $signed(a_i[15:0]);
        mul_op_b   = $signed(b_i[15:0]);
        mul_abs_a  = mul_op_a[15]
                       ? (~mul_op_a[15:0] + 16'd1) : mul_op_a[15:0];
        mul_abs_b  = mul_op_b[15]
                       ? (~mul_op_b[15:0] + 16'd1) : mul_op_b[15:0];
        mul_negate = mul_op_a[15] ^ mul_op_b[15];
        mul_sum =
          ({16'h0, mul_abs_a} & {32{mul_abs_b[ 0]}})        +
          (({16'h0, mul_abs_a} & {32{mul_abs_b[ 1]}}) <<  1) +
          (({16'h0, mul_abs_a} & {32{mul_abs_b[ 2]}}) <<  2) +
          (({16'h0, mul_abs_a} & {32{mul_abs_b[ 3]}}) <<  3) +
          (({16'h0, mul_abs_a} & {32{mul_abs_b[ 4]}}) <<  4) +
          (({16'h0, mul_abs_a} & {32{mul_abs_b[ 5]}}) <<  5) +
          (({16'h0, mul_abs_a} & {32{mul_abs_b[ 6]}}) <<  6) +
          (({16'h0, mul_abs_a} & {32{mul_abs_b[ 7]}}) <<  7) +
          (({16'h0, mul_abs_a} & {32{mul_abs_b[ 8]}}) <<  8) +
          (({16'h0, mul_abs_a} & {32{mul_abs_b[ 9]}}) <<  9) +
          (({16'h0, mul_abs_a} & {32{mul_abs_b[10]}}) << 10) +
          (({16'h0, mul_abs_a} & {32{mul_abs_b[11]}}) << 11) +
          (({16'h0, mul_abs_a} & {32{mul_abs_b[12]}}) << 12) +
          (({16'h0, mul_abs_a} & {32{mul_abs_b[13]}}) << 13) +
          (({16'h0, mul_abs_a} & {32{mul_abs_b[14]}}) << 14) +
          (({16'h0, mul_abs_a} & {32{mul_abs_b[15]}}) << 15);
        result_o = mul_negate ? (~mul_sum + 32'd1) : mul_sum;
      end

      // ------------------------------------------------------------------
      // M2a: CLZ — count leading zeros in a_i (rs1).
      // Priority encoder: scans from bit 31 down. Result range 0-32
      // fits in 6 bits; zero-extended to 32. rs2/b_i is ignored (unary).
      // casez with '?' wildcard (iverilog compatibility; synthesis equivalent).
      // Priority is first-match top-to-bottom; synthesis optimizes to tree.
      // All 33 patterns listed (positions 0-32) plus a redundant default.
      // canonical-reference.md §8.1
      // ------------------------------------------------------------------
      ALU_CLZ: begin
        casez (a_i)
          32'b1???????????????????????????????: result_o = 32'd0;
          32'b01??????????????????????????????: result_o = 32'd1;
          32'b001?????????????????????????????: result_o = 32'd2;
          32'b0001????????????????????????????: result_o = 32'd3;
          32'b00001???????????????????????????: result_o = 32'd4;
          32'b000001??????????????????????????: result_o = 32'd5;
          32'b0000001?????????????????????????: result_o = 32'd6;
          32'b00000001????????????????????????: result_o = 32'd7;
          32'b000000001???????????????????????: result_o = 32'd8;
          32'b0000000001??????????????????????: result_o = 32'd9;
          32'b00000000001?????????????????????: result_o = 32'd10;
          32'b000000000001????????????????????: result_o = 32'd11;
          32'b0000000000001???????????????????: result_o = 32'd12;
          32'b00000000000001??????????????????: result_o = 32'd13;
          32'b000000000000001?????????????????: result_o = 32'd14;
          32'b0000000000000001????????????????: result_o = 32'd15;
          32'b00000000000000001???????????????: result_o = 32'd16;
          32'b000000000000000001??????????????: result_o = 32'd17;
          32'b0000000000000000001?????????????: result_o = 32'd18;
          32'b00000000000000000001????????????: result_o = 32'd19;
          32'b000000000000000000001???????????: result_o = 32'd20;
          32'b0000000000000000000001??????????: result_o = 32'd21;
          32'b00000000000000000000001?????????: result_o = 32'd22;
          32'b000000000000000000000001????????: result_o = 32'd23;
          32'b0000000000000000000000001???????: result_o = 32'd24;
          32'b00000000000000000000000001??????: result_o = 32'd25;
          32'b000000000000000000000000001?????: result_o = 32'd26;
          32'b0000000000000000000000000001????: result_o = 32'd27;
          32'b00000000000000000000000000001???: result_o = 32'd28;
          32'b000000000000000000000000000001??: result_o = 32'd29;
          32'b0000000000000000000000000000001?: result_o = 32'd30;
          32'b00000000000000000000000000000001: result_o = 32'd31;
          32'b00000000000000000000000000000000: result_o = 32'd32;
          default: result_o = 32'd32;
        endcase
      end

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
// Project: RV32I Pipelined Processor
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
// ============================================================================
// Module: alu_control
// Description: Decodes coarse ALU category (alu_op) plus instruction
//              fields (funct3, funct7[5]) into the 4-bit alu_ctrl signal
//              fed to alu.sv. Combinational only. All 4-bit alu_ctrl codes
//              0000-1111 are allocated (§8.3); no unallocated code guard.
// Author: Beaux Cable
// Date: April 2026
// Project: RV32I Pipelined Processor
// ============================================================================

module alu_control (
  input  logic [1:0] alu_op_i,   // coarse ALU category (§6.2)
  input  logic [2:0] funct3_i,   // instruction[14:12]
  input  logic [6:0] funct7_i,   // instruction[31:25] (full funct7)
  input  logic [6:0] opcode_i,   // instruction[6:0] (distinguish CUSTOM-0)
  output logic [3:0] alu_ctrl_o, // operation select → alu.sv
  output logic       illegal_o   // 1 = unrecognised funct7/funct3 under CUSTOM-0
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
  localparam logic [3:0] ALU_SRL         = 4'b1000;
  localparam logic [3:0] ALU_SRA         = 4'b1001;
  // M2a custom extensions (canonical-reference.md §8.1, §8.3)
  localparam logic [3:0] ALU_POPCOUNT = 4'b1010;
  localparam logic [3:0] ALU_BREV     = 4'b1011;
  localparam logic [3:0] ALU_CLZ      = 4'b1111; // count leading zeros
  // M2b custom extension (canonical-reference.md §8.2)
  localparam logic [3:0] ALU_MUL16S   = 4'b1110; // signed 16x16 multiply

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

  // Opcode for CUSTOM-0 R-type (canonical-reference.md §2, §8.1)
  localparam logic [6:0] OP_CUSTOM0 = 7'b0001011;

  // funct7 values for M2a custom instructions (§8.1)
  localparam logic [6:0] F7_POPCOUNT = 7'b0000000;
  localparam logic [6:0] F7_BREV     = 7'b0000001;
  localparam logic [6:0] F7_MUL16S   = 7'b0000100; // reserved for M2b
  localparam logic [6:0] F7_CLZ      = 7'b0000101; // count leading zeros

  // --------------------------------------------------------------------
  // Internal signals
  // --------------------------------------------------------------------
  logic [3:0] rtype_ctrl;
  logic [3:0] itype_ctrl;

  // Derive funct7b5 from full funct7 for existing R/I-type decode.
  // Keeping this internal avoids any change to rtype_ctrl/itype_ctrl logic.
  logic funct7b5;
  assign funct7b5 = funct7_i[5];

  // --------------------------------------------------------------------
  // R-type decode: funct3 + funct7b5 (canonical-reference.md §1.1)
  // Uses internal funct7b5 derived from funct7_i[5].
  // --------------------------------------------------------------------
  always_comb begin
    rtype_ctrl = ALU_ADD;  // default prevents latch (gotchas.md #1)
    case (funct3_i)
      F3_ADD_SUB: rtype_ctrl = funct7b5 ? ALU_SUB : ALU_ADD;
      F3_SLL:     rtype_ctrl = ALU_SLL;
      F3_SLT:     rtype_ctrl = ALU_SLT;
      F3_SLTU:    rtype_ctrl = ALU_SLTU;
      F3_XOR:     rtype_ctrl = ALU_XOR;
      F3_SRL_SRA: rtype_ctrl = funct7b5 ? ALU_SRA : ALU_SRL;
      F3_OR:      rtype_ctrl = ALU_OR;
      F3_AND:     rtype_ctrl = ALU_AND;
      default:    rtype_ctrl = ALU_ADD;
    endcase
  end

  // --------------------------------------------------------------------
  // I-type decode: funct3 only; shifts also use funct7b5.
  // funct7b5 is NOT checked for non-shift I-type: ADDI has no SUBI
  // (canonical-reference.md §1.2; gotchas.md #10)
  // Uses internal funct7b5 derived from funct7_i[5].
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
                    funct7b5 ? ALU_SRA : ALU_SRL;
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
        // R-type path. Check opcode first: CUSTOM-0 has its own decode.
        // Regular R-type and CUSTOM-0 both arrive here with alu_op=10.
        if (opcode_i == OP_CUSTOM0) begin
          // ----------------------------------------------------------
          // CUSTOM-0 R-type: decode funct7 + funct3 for M2a extensions
          // (canonical-reference.md §8.1)
          // All confirmed M2a instructions use funct3=000.
          // Any unrecognised funct7/funct3 combo sets illegal_o=1.
          // ----------------------------------------------------------
          alu_ctrl_o = ALU_ADD; // safe default; overwritten below
          illegal_o  = 1'b0;
          if (funct3_i == F3_ADD_SUB) begin
            case (funct7_i)
              F7_POPCOUNT: alu_ctrl_o = ALU_POPCOUNT; // POPCOUNT rs1
              F7_BREV:     alu_ctrl_o = ALU_BREV;     // BREV rs1
              F7_MUL16S:   alu_ctrl_o = ALU_MUL16S;   // MUL16S rs1,rs2
              F7_CLZ:      alu_ctrl_o = ALU_CLZ;      // CLZ rs1
              default: begin
                alu_ctrl_o = ALU_ADD;
                illegal_o  = 1'b1;
              end
            endcase
          end else begin
            // Unsupported funct3 under CUSTOM-0
            alu_ctrl_o = ALU_ADD;
            illegal_o  = 1'b1;
          end
        end else begin
          // Regular RV32I R-type: funct3 + funct7b5 (§1.1)
          alu_ctrl_o = rtype_ctrl;
          illegal_o  = 1'b0;
        end
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

    // NOTE: 4-bit alu_ctrl space is fully allocated (§8.3).
    // All codes 4'b0000-4'b1111 map to valid operations.
    // No unallocated code guard needed.
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
// Project: RV32I Pipelined Processor
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
// Project: RV32I Pipelined Processor
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
// Project: RV32I Pipelined Processor
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
// Module: compressed_decoder
// Description: Pre-decode expansion of RV32C 16-bit compressed instructions
//              to 32-bit RV32I equivalents (M2c milestone).
//              Pure combinational — no state.
//              Illegal encodings produce instr_o=32'h0, illegal_o=1.
//              The 32'h0 output (opcode 7'h00) is caught by control_decoder
//              as illegal_instr_o=1, driving halt_o through existing path.
// Author: Beaux Cable
// Date: April 2026
// Project: RV32I Pipelined Processor
// ============================================================================

module compressed_decoder (
  input  logic [15:0] instr_i,
  output logic [31:0] instr_o,
  output logic        illegal_o
);

  // --------------------------------------------------------------------------
  // Opcode constants (canonical-reference.md §2)
  // --------------------------------------------------------------------------
  localparam logic [6:0] OP_R    = 7'b0110011; // R-type ALU
  localparam logic [6:0] OP_I    = 7'b0010011; // I-type ALU
  localparam logic [6:0] OP_LOAD = 7'b0000011; // Loads
  localparam logic [6:0] OP_STOR = 7'b0100011; // Stores
  localparam logic [6:0] OP_BR   = 7'b1100011; // Branches
  localparam logic [6:0] OP_JAL  = 7'b1101111; // JAL
  localparam logic [6:0] OP_JALR = 7'b1100111; // JALR
  localparam logic [6:0] OP_LUI  = 7'b0110111; // LUI
  localparam logic [6:0] OP_SYS  = 7'b1110011; // SYSTEM (EBREAK)

  // NOP = ADDI x0, x0, 0  (canonical-reference.md §7.3)
  localparam logic [31:0] NOP_32 = 32'h00000013;

  // --------------------------------------------------------------------------
  // Expansion logic
  // --------------------------------------------------------------------------

  // Compact register fields expanded to x8-x15
  // (canonical-reference.md §12.2): {2'b01, 3-bit}
  logic [4:0] rd_c;   // instr_i[4:2]  -> x8-x15
  logic [4:0] rs1_c;  // instr_i[9:7]  -> x8-x15
  logic [4:0] rs2_c;  // instr_i[4:2]  -> x8-x15

  assign rd_c  = {2'b01, instr_i[4:2]};
  assign rs1_c = {2'b01, instr_i[9:7]};
  assign rs2_c = {2'b01, instr_i[4:2]};

  // Full-width register fields (used by C2 and some C1 instructions)
  logic [4:0] rd_full;   // instr_i[11:7]
  logic [4:0] rs2_full;  // instr_i[6:2]

  assign rd_full  = instr_i[11:7];
  assign rs2_full = instr_i[6:2];

  // --------------------------------------------------------------------------
  // Immediate construction helpers — all declared as signals so always_comb
  // can reference them without declaring inside a procedural block.
  // --------------------------------------------------------------------------

  // C.ADDI4SPN: nzuimm[9:0] = {inst[10:7],inst[12:11],inst[5],inst[6],2'b00}
  // zero-extended to 12 bits for I-type ADDI rd', x2, nzuimm
  logic [11:0] imm_addi4spn;
  assign imm_addi4spn = {2'b00,
                          instr_i[10:7],
                          instr_i[12:11],
                          instr_i[5],
                          instr_i[6],
                          2'b00};

  // C.LW / C.SW: uimm[6:0] = {inst[5],inst[12:10],inst[6],2'b00}
  // zero-extended to 12 bits for I-type (LW) or split for S-type (SW)
  logic [6:0] uimm_lw;
  assign uimm_lw = {instr_i[5], instr_i[12:10], instr_i[6], 2'b00};

  // C.ADDI / C.LI / C.ANDI: sext({inst[12], inst[6:2]}) to 12 bits
  logic [11:0] imm_addi;
  assign imm_addi = {{6{instr_i[12]}}, instr_i[12], instr_i[6:2]};

  // C.JAL / C.J: sext 12-bit offset to 21-bit J-type immediate.
  // Raw 12-bit: bit[11]=inst[12](sign), bit[10]=inst[8], bits[9:8]=inst[10:9],
  //             bit[7]=inst[6], bit[6]=inst[7], bit[5]=inst[2],
  //             bit[4]=inst[11], bits[3:1]=inst[5:3], bit[0]=1'b0.
  // Sign-extended: bits[20:12] = {9{inst[12]}}, bit[11] = inst[12] itself.
  // Total 21 bits: 9+1+1+2+1+1+1+1+3+1 = 21. (canonical-ref §12.4)
  logic [20:0] imm_jal_21;
  assign imm_jal_21 = {{9{instr_i[12]}},
                        instr_i[12],    // bit[11]: sign bit of raw 12-bit
                        instr_i[8],     // bit[10]
                        instr_i[10:9],  // bits[9:8]
                        instr_i[6],     // bit[7]
                        instr_i[7],     // bit[6]
                        instr_i[2],     // bit[5]
                        instr_i[11],    // bit[4]
                        instr_i[5:3],   // bits[3:1]
                        1'b0};          // bit[0]: LSB always 0 (×2)

  // C.LUI: nzimm placed in U-type upper 20 bits
  // nzimm[17:12] = {inst[12], inst[6:2]}, lower 12 bits zero
  // For U-type instr_o[31:12] = sign-extended nzimm[17:12] expanded to 20b
  logic [19:0] imm_lui_20;
  assign imm_lui_20 = {{14{instr_i[12]}}, instr_i[12], instr_i[6:2]};

  // C.ADDI16SP: sext({inst[12],inst[4:3],inst[5],inst[2],inst[6],4'b0}) 12-bit
  logic [11:0] imm_addi16sp;
  assign imm_addi16sp = {{2{instr_i[12]}},
                          instr_i[12],
                          instr_i[4:3],
                          instr_i[5],
                          instr_i[2],
                          instr_i[6],
                          4'b0000};

  // C.BEQZ / C.BNEZ: sext 9-bit offset to 13-bit B-type immediate.
  // Raw 9-bit: bit[8]=inst[12](sign), bits[7:6]=inst[6:5], bit[5]=inst[2],
  //            bits[4:3]=inst[11:10], bits[2:1]=inst[4:3], bit[0]=1'b0.
  // 13-bit: bits[12:9]={4{inst[12]}}, bit[8]=inst[12] itself, then rest.
  // Total: 4+1+2+1+2+2+1 = 13. (canonical-ref §12.4)
  logic [12:0] imm_br_13;
  assign imm_br_13 = {{4{instr_i[12]}},
                       instr_i[12],     // bit[8]: sign bit of raw 9-bit
                       instr_i[6:5],    // bits[7:6]
                       instr_i[2],      // bit[5]
                       instr_i[11:10],  // bits[4:3]
                       instr_i[4:3],    // bits[2:1]
                       1'b0};           // bit[0]: LSB always 0 (×2)

  // C.LWSP: uimm[7:0] = {inst[3:2], inst[12], inst[6:4], 2'b00}
  // zero-extended to 12 bits for I-type LW rd, uimm(x2)
  logic [11:0] imm_lwsp;
  assign imm_lwsp = {4'b0000,
                     instr_i[3:2], instr_i[12], instr_i[6:4],
                     2'b00};

  // C.SWSP: uimm[7:0] = {inst[8:7], inst[12:9], 2'b00}
  // placed as S-type immediate split: imm[11:5] and imm[4:0]
  logic [7:0] uimm_swsp;
  assign uimm_swsp = {instr_i[8:7], instr_i[12:9], 2'b00};

  // Shift amount: {inst[12], inst[6:2]} — used by SRLI, SRAI, SLLI
  logic [5:0] shamt;
  assign shamt = {instr_i[12], instr_i[6:2]};

  // --------------------------------------------------------------------------
  // Primary dispatch: {funct3[2:0], quadrant[1:0]} = {inst[15:13], inst[1:0]}
  // --------------------------------------------------------------------------

  always_comb begin
    // Defaults — prevent latch inference (gotcha #1)
    instr_o  = NOP_32;
    illegal_o = 1'b0;

    // All-zeros is always illegal (canonical-reference.md §12.1)
    if (instr_i == 16'h0000) begin
      instr_o  = 32'h00000000;
      illegal_o = 1'b1;
    end else begin
      case ({instr_i[15:13], instr_i[1:0]})

        // ====================================================================
        // C0: Quadrant 0 (inst[1:0] = 00)
        // ====================================================================

        // C.ADDI4SPN -> ADDI rd', x2, nzuimm
        5'b000_00: begin
          if (imm_addi4spn == 12'h000) begin
            // nzuimm = 0 is illegal (§12.7 rule 4)
            instr_o  = 32'h00000000;
            illegal_o = 1'b1;
          end else begin
            // I-type: {imm[11:0], rs1[4:0], funct3[2:0], rd[4:0], opcode}
            instr_o = {imm_addi4spn, 5'd2, 3'b000, rd_c, OP_I};
          end
        end

        // C0 funct3=001: F-extension C.FLD — illegal (§12.7 rule 2)
        5'b001_00: begin
          instr_o  = 32'h00000000;
          illegal_o = 1'b1;
        end

        // C.LW -> LW rd', uimm(rs1')
        5'b010_00: begin
          // I-type: {imm[11:0], rs1[4:0], funct3, rd[4:0], opcode}
          // funct3=010 for LW; uimm zero-extended to 12 bits
          instr_o = {{5'b00000, uimm_lw}, rs1_c, 3'b010, rd_c, OP_LOAD};
        end

        // C0 funct3=011: F-extension C.FLW — illegal (§12.7 rule 2)
        5'b011_00: begin
          instr_o  = 32'h00000000;
          illegal_o = 1'b1;
        end

        // C0 funct3=100: reserved — illegal (§12.7 rule 2)
        5'b100_00: begin
          instr_o  = 32'h00000000;
          illegal_o = 1'b1;
        end

        // C0 funct3=101: F-extension C.FSD — illegal (§12.7 rule 2)
        5'b101_00: begin
          instr_o  = 32'h00000000;
          illegal_o = 1'b1;
        end

        // C.SW -> SW rs2', uimm(rs1')
        5'b110_00: begin
          // S-type: {imm[11:5], rs2, rs1, funct3, imm[4:0], opcode}
          // funct3=010 for SW
          instr_o = {5'b00000, uimm_lw[6:5],
                     rs2_c, rs1_c,
                     3'b010,
                     uimm_lw[4:0], OP_STOR};
        end

        // C0 funct3=111: F-extension C.FSW — illegal (§12.7 rule 2)
        5'b111_00: begin
          instr_o  = 32'h00000000;
          illegal_o = 1'b1;
        end

        // ====================================================================
        // C1: Quadrant 1 (inst[1:0] = 01)
        // ====================================================================

        // C.NOP / C.ADDI -> ADDI rd, rd, sext(nzimm)
        // rd=x0 with imm=0 => C.NOP (expand to NOP_32)
        // rd=x0 with imm!=0 => HINT (treat as NOP_32)
        // rd!=x0 with imm=0 => HINT (still a valid ADDI, pass through)
        5'b000_01: begin
          // I-type: {imm[11:0], rs1[4:0], 3'b000, rd[4:0], OP_I}
          // rd_full = inst[11:7], imm_addi is sext 12-bit
          instr_o = {imm_addi, rd_full, 3'b000, rd_full, OP_I};
        end

        // C.JAL -> JAL x1, sext(imm)
        // J-type: {imm[20],imm[10:1],imm[11],imm[19:12],rd[4:0],opcode}
        5'b001_01: begin
          instr_o = {imm_jal_21[20],
                     imm_jal_21[10:1],
                     imm_jal_21[11],
                     imm_jal_21[19:12],
                     5'd1,          // rd = x1 (link register)
                     OP_JAL};
        end

        // C.LI -> ADDI rd, x0, sext(imm)
        5'b010_01: begin
          // I-type with rs1=x0
          instr_o = {imm_addi, 5'd0, 3'b000, rd_full, OP_I};
        end

        // C.LUI / C.ADDI16SP (rd=x2 selects ADDI16SP)
        5'b011_01: begin
          if (rd_full == 5'd2) begin
            // C.ADDI16SP -> ADDI x2, x2, sext(nzimm)
            if (imm_addi16sp == 12'h000) begin
              // nzimm=0 is illegal (§12.7 rule 5)
              instr_o  = 32'h00000000;
              illegal_o = 1'b1;
            end else begin
              instr_o = {imm_addi16sp, 5'd2, 3'b000, 5'd2, OP_I};
            end
          end else if (rd_full == 5'd0) begin
            // rd=x0 is reserved/HINT — treat as NOP
            instr_o = NOP_32;
          end else begin
            // C.LUI -> LUI rd, nzimm[17:12]
            // U-type: {imm[31:12], rd[4:0], opcode}
            // nzimm=0 is illegal (§12.7 rule 6)
            if (imm_lui_20 == 20'h00000) begin
              instr_o  = 32'h00000000;
              illegal_o = 1'b1;
            end else begin
              instr_o = {imm_lui_20, rd_full, OP_LUI};
            end
          end
        end

        // C1 funct3=100: SRLI / SRAI / ANDI / SUB / XOR / OR / AND
        5'b100_01: begin
          case (instr_i[11:10])
            // C.SRLI -> SRLI rd', rd', shamt
            2'b00: begin
              // shamt[5]=inst[12]; must be 0 on RV32 (§12.7 rule 9 for SLLI,
              // same constraint applies to SRLI/SRAI per spec)
              // treat shamt[5]=1 as illegal on RV32
              if (shamt[5]) begin
                instr_o  = 32'h00000000;
                illegal_o = 1'b1;
              end else begin
                // I-type shift: funct7=0000000, funct3=101, OP_I
                // {7'b0000000, shamt[4:0], rs1, 3'b101, rd, OP_I}
                instr_o = {7'b0000000,
                            shamt[4:0],
                            rs1_c,
                            3'b101,
                            rs1_c,   // rd = rs1 (same register)
                            OP_I};
              end
            end

            // C.SRAI -> SRAI rd', rd', shamt
            2'b01: begin
              if (shamt[5]) begin
                instr_o  = 32'h00000000;
                illegal_o = 1'b1;
              end else begin
                // I-type shift: funct7=0100000, funct3=101, OP_I
                instr_o = {7'b0100000,
                            shamt[4:0],
                            rs1_c,
                            3'b101,
                            rs1_c,
                            OP_I};
              end
            end

            // C.ANDI -> ANDI rd', rd', sext(imm)
            2'b10: begin
              // I-type: {imm[11:0], rs1, 3'b111, rd, OP_I}
              instr_o = {imm_addi, rs1_c, 3'b111, rs1_c, OP_I};
            end

            // Sub-sub-decode: C.SUB / C.XOR / C.OR / C.AND
            2'b11: begin
              if (instr_i[12]) begin
                // inst[12]=1 with inst[11:10]=11 is reserved on RV32
                // (would be RV64 C.SUBW/C.ADDW; §12.7 rule 10)
                instr_o  = 32'h00000000;
                illegal_o = 1'b1;
              end else begin
                case (instr_i[6:5])
                  // C.SUB -> SUB rd', rd', rs2'
                  2'b00: begin
                    // R-type: {7'b0100000, rs2, rs1, 3'b000, rd, OP_R}
                    instr_o = {7'b0100000,
                                rs2_c, rs1_c,
                                3'b000, rs1_c,
                                OP_R};
                  end
                  // C.XOR -> XOR rd', rd', rs2'
                  2'b01: begin
                    instr_o = {7'b0000000,
                                rs2_c, rs1_c,
                                3'b100, rs1_c,
                                OP_R};
                  end
                  // C.OR -> OR rd', rd', rs2'
                  2'b10: begin
                    instr_o = {7'b0000000,
                                rs2_c, rs1_c,
                                3'b110, rs1_c,
                                OP_R};
                  end
                  // C.AND -> AND rd', rd', rs2'
                  2'b11: begin
                    instr_o = {7'b0000000,
                                rs2_c, rs1_c,
                                3'b111, rs1_c,
                                OP_R};
                  end
                  default: begin
                    instr_o  = 32'h00000000;
                    illegal_o = 1'b1;
                  end
                endcase
              end
            end

            default: begin
              instr_o  = 32'h00000000;
              illegal_o = 1'b1;
            end
          endcase
        end

        // C.J -> JAL x0, sext(imm)  (same encoding as C.JAL but rd=x0)
        5'b101_01: begin
          instr_o = {imm_jal_21[20],
                     imm_jal_21[10:1],
                     imm_jal_21[11],
                     imm_jal_21[19:12],
                     5'd0,          // rd = x0 (discard link)
                     OP_JAL};
        end

        // C.BEQZ -> BEQ rs1', x0, sext(off)
        5'b110_01: begin
          // B-type: {imm[12],imm[10:5],rs2,rs1,funct3,imm[4:1],imm[11],opcode}
          // funct3=000 for BEQ; rs2=x0
          instr_o = {imm_br_13[12],
                     imm_br_13[10:5],
                     5'd0,          // rs2 = x0
                     rs1_c,
                     3'b000,        // BEQ
                     imm_br_13[4:1],
                     imm_br_13[11],
                     OP_BR};
        end

        // C.BNEZ -> BNE rs1', x0, sext(off)
        5'b111_01: begin
          // Same as BEQZ but funct3=001 for BNE
          instr_o = {imm_br_13[12],
                     imm_br_13[10:5],
                     5'd0,          // rs2 = x0
                     rs1_c,
                     3'b001,        // BNE
                     imm_br_13[4:1],
                     imm_br_13[11],
                     OP_BR};
        end

        // ====================================================================
        // C2: Quadrant 2 (inst[1:0] = 10)
        // ====================================================================

        // C.SLLI -> SLLI rd, rd, shamt
        5'b000_10: begin
          // shamt[5]=inst[12]=1 is reserved on RV32 (§12.7 rule 9)
          if (shamt[5]) begin
            instr_o  = 32'h00000000;
            illegal_o = 1'b1;
          end else begin
            // I-type shift: {7'b0000000, shamt[4:0], rs1, 3'b001, rd, OP_I}
            instr_o = {7'b0000000,
                        shamt[4:0],
                        rd_full,    // rs1 = rd (same register)
                        3'b001,
                        rd_full,
                        OP_I};
          end
        end

        // C2 funct3=001: F-extension C.FLDSP — illegal (§12.7 rule 3)
        5'b001_10: begin
          instr_o  = 32'h00000000;
          illegal_o = 1'b1;
        end

        // C.LWSP -> LW rd, uimm(x2)
        5'b010_10: begin
          // rd=x0 is reserved (§12.7 rule 7)
          if (rd_full == 5'd0) begin
            instr_o  = 32'h00000000;
            illegal_o = 1'b1;
          end else begin
            // I-type: {imm[11:0], rs1=x2, 3'b010, rd, OP_LOAD}
            instr_o = {imm_lwsp, 5'd2, 3'b010, rd_full, OP_LOAD};
          end
        end

        // C2 funct3=011: F-extension C.FLWSP — illegal (§12.7 rule 3)
        5'b011_10: begin
          instr_o  = 32'h00000000;
          illegal_o = 1'b1;
        end

        // C2 funct3=100: JR / MV / EBREAK / JALR / ADD
        5'b100_10: begin
          if (!instr_i[12]) begin
            // inst[12] = 0
            if (instr_i[6:2] == 5'b00000) begin
              // rs2 = 0
              if (rd_full == 5'd0) begin
                // rs1=x0 is reserved (§12.7 rule 8)
                instr_o  = 32'h00000000;
                illegal_o = 1'b1;
              end else begin
                // C.JR -> JALR x0, 0(rs1)
                // I-type: {12'h000, rs1, 3'b000, rd=x0, OP_JALR}
                instr_o = {12'h000, rd_full, 3'b000, 5'd0, OP_JALR};
              end
            end else begin
              // rs2 != 0: C.MV -> ADD rd, x0, rs2
              // R-type: {7'b0000000, rs2, rs1=x0, 3'b000, rd, OP_R}
              instr_o = {7'b0000000,
                          rs2_full,
                          5'd0,      // rs1 = x0
                          3'b000,
                          rd_full,
                          OP_R};
            end
          end else begin
            // inst[12] = 1
            if (instr_i[6:2] == 5'b00000) begin
              // rs2 = 0
              if (rd_full == 5'd0) begin
                // C.EBREAK -> EBREAK = 32'h00100073
                instr_o = 32'h00100073;
              end else begin
                // C.JALR -> JALR x1, 0(rs1)
                instr_o = {12'h000, rd_full, 3'b000, 5'd1, OP_JALR};
              end
            end else begin
              // rs2 != 0: C.ADD -> ADD rd, rd, rs2
              // R-type: {7'b0000000, rs2, rs1=rd, 3'b000, rd, OP_R}
              instr_o = {7'b0000000,
                          rs2_full,
                          rd_full,   // rs1 = rd
                          3'b000,
                          rd_full,
                          OP_R};
            end
          end
        end

        // C2 funct3=101: F-extension C.FSDSP — illegal (§12.7 rule 3)
        5'b101_10: begin
          instr_o  = 32'h00000000;
          illegal_o = 1'b1;
        end

        // C.SWSP -> SW rs2, uimm(x2)
        5'b110_10: begin
          // S-type: {imm[11:5], rs2, rs1=x2, funct3=010, imm[4:0], OP_STOR}
          // uimm_swsp[7:0]; imm[11:5] = {0,0,0,0, uimm[7:6], uimm[5]}
          //               = {4'b0, uimm_swsp[7:6], uimm_swsp[5]}
          // imm[4:0] = uimm_swsp[4:0] = {uimm_swsp[4:2], 2'b00}
          // uimm_swsp = {inst[8:7], inst[12:9], 2'b00} — bits[7:0]
          instr_o = {4'b0000,
                     uimm_swsp[7:5],    // imm[11:5] upper part (zero-ext)
                     rs2_full,
                     5'd2,             // rs1 = x2 (sp)
                     3'b010,           // SW
                     uimm_swsp[4:0],   // imm[4:0]
                     OP_STOR};
        end

        // C2 funct3=111: F-extension C.FSWSP — illegal (§12.7 rule 3)
        5'b111_10: begin
          instr_o  = 32'h00000000;
          illegal_o = 1'b1;
        end

        // Catch-all: unknown encoding
        default: begin
          instr_o  = 32'h00000000;
          illegal_o = 1'b1;
        end

      endcase
    end
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
// Project: RV32I Pipelined Processor
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

  // RV32C alignment buffer signals (M2c)
  logic [15:0] upper_buf;        // saved upper halfword of prior fetch
  logic        upper_valid;      // upper_buf holds a valid halfword
  logic        is_compressed;    // current instruction is 16-bit
  logic [31:0] pc_plus_2;        // pc_reg + 2 (compressed increment)
  logic [31:0] pc_increment;     // 2 or 4 depending on is_compressed
  logic [15:0] selected_hw;      // halfword being decoded this cycle
  logic [31:0] raw_instr;        // assembled 32-bit word (pre-expansion)
  logic [31:0] expanded_instr_c; // compressed_decoder output
  logic [31:0] expanded_instr;   // final instruction to pipeline
  logic        c_illegal;        // illegal signal from compressed_decoder

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      pc_reg <= 32'h0;
    else
      pc_reg <= pc_next;
  end

  assign pc_plus_4 = pc_reg + 32'd4;
  assign pc_plus_2 = pc_reg + 32'd2;

  // Word-aligned fetch; when buffer holds upper half, fetch the next word
  assign instr_addr_o = upper_valid
    ? {pc_reg[31:2] + 30'd1, 2'b00}
    : {pc_reg[31:2], 2'b00};

  // Halfword selection and compression detection
  assign selected_hw   = upper_valid ? upper_buf : instr_data_i[15:0];
  assign is_compressed = (selected_hw[1:0] != 2'b11);

  // Full instruction assembly (3 cases)
  always_comb begin
    // Default prevents latch inference (gotcha #1)
    raw_instr = instr_data_i;
    if (is_compressed)
      raw_instr = {16'h0000, selected_hw}; // decoder sees [15:0]
    else if (upper_valid)
      raw_instr = {instr_data_i[15:0], upper_buf};  // straddling 32-bit
    else
      raw_instr = instr_data_i;              // word-aligned 32-bit
  end

  // Compressed decoder instantiation
  compressed_decoder c_dec (
    .instr_i  (selected_hw),
    .instr_o  (expanded_instr_c),
    .illegal_o(c_illegal)
  );

  // Final instruction: expanded if compressed, raw otherwise
  assign expanded_instr = is_compressed ? expanded_instr_c : raw_instr;

  // PC increment: 2 for compressed, 4 for 32-bit
  assign pc_increment = is_compressed ? pc_plus_2 : pc_plus_4;

  // ==========================================================================
  // IF/EX pipeline register
  // Flush inserts NOP bubble on taken branch or any jump (gotcha #9).
  // if_ex_pc_plus_n holds PC+2 or PC+4 depending on instruction width (M2c).
  // ==========================================================================

  logic [31:0] if_ex_instr;       // latched instruction word
  logic [31:0] if_ex_pc;          // latched PC of this instruction
  logic [31:0] if_ex_pc_plus_n;   // latched PC+2 or PC+4 (return address)
  logic        if_ex_valid;       // 0 = bubble/NOP

  logic flush_if_ex;              // flush strobe (computed in EX)

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      if_ex_instr     <= NOP_INSTR;
      if_ex_pc        <= 32'h0;
      if_ex_pc_plus_n <= 32'd4;
      if_ex_valid     <= 1'b0;
    end else if (flush_if_ex) begin
      // Insert NOP bubble; PC fields are don't-care but zeroed for tidiness
      if_ex_instr     <= NOP_INSTR;
      if_ex_pc        <= 32'h0;
      if_ex_pc_plus_n <= 32'd4;
      if_ex_valid     <= 1'b0;
    end else begin
      if_ex_instr     <= expanded_instr;  // M2c: expanded instruction
      if_ex_pc        <= pc_reg;
      if_ex_pc_plus_n <= pc_increment;     // M2c: PC+2 or PC+4
      if_ex_valid     <= 1'b1;
    end
  end

  // ==========================================================================
  // IF stage — alignment buffer (M2c)
  // Holds the upper halfword of a fetched word when the lower half was a
  // compressed instruction. Cleared on reset and flush.
  // 4 cases per cycle (canonical-reference.md §12.6):
  //   !upper_valid, is_compressed:  store upper half, upper_valid <- 1
  //   !upper_valid, !is_compressed: word-aligned 32-bit; clear buffer
  //   upper_valid, is_compressed:   consumed upper_buf; clear buffer
  //   upper_valid, !is_compressed:  straddling 32-bit; store new upper half
  // ==========================================================================

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      upper_buf   <= 16'h0;
      upper_valid <= 1'b0;
    end else if (flush_if_ex) begin
      upper_buf   <= 16'h0;
      upper_valid <= 1'b0;
    end else if (is_compressed && !upper_valid) begin
      // Lower half was compressed; save upper half for next cycle
      upper_buf   <= instr_data_i[31:16];
      upper_valid <= 1'b1;
    end else if (is_compressed && upper_valid) begin
      // Consumed the buffered halfword; buffer now empty
      upper_valid <= 1'b0;
    end else if (!is_compressed && upper_valid) begin
      // Straddling 32-bit consumed upper_buf; save new upper half
      upper_buf   <= instr_data_i[31:16];
      upper_valid <= 1'b1;
    end else begin
      // Word-aligned 32-bit; no buffering needed
      upper_valid <= 1'b0;
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
  logic       ex_funct7b5; // kept for reference; alu_control now uses ex_funct7
  logic [6:0] ex_funct7;

  assign ex_opcode   = if_ex_instr[6:0];
  assign ex_rd_addr  = if_ex_instr[11:7];
  assign ex_rs1_addr = if_ex_instr[19:15];
  assign ex_rs2_addr = if_ex_instr[24:20];
  assign ex_funct3   = if_ex_instr[14:12];
  assign ex_funct7b5 = if_ex_instr[30];    // funct7[5] — retained for debug
  assign ex_funct7   = if_ex_instr[31:25]; // full funct7 for CUSTOM-0 decode

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
    .funct7_i   (ex_funct7),
    .opcode_i   (ex_opcode),
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
      ex_write_data = if_ex_pc_plus_n; // JAL/JALR: rd = return address (M2c)
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
    // Default: sequential execution (M2c: increment by 2 or 4)
    pc_next = pc_increment;
    if (ex_branch && branch_taken && if_ex_valid)
      pc_next = branch_target;           // taken branch: PC + B-imm
    else if (ex_jump && !ex_jalr && if_ex_valid)
      pc_next = alu_result;              // JAL: PC + J-imm (from ALU)
    else if (ex_jump && ex_jalr && if_ex_valid)
      pc_next = jalr_target;            // JALR: {(rs1+imm)[31:1], 1'b0}
    else
      pc_next = pc_increment;           // sequential (M2c: 2 or 4)
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
// ============================================================================
// Module: chip_top
// Description: MMIO wrapper for RV32I core. Command-register bus
//              interface: load imem/dmem, run the CPU, read results.
//              Contains: 2-FF reset synchronizer, 4-state FSM,
//              FF instruction memory (IMEM_DEPTH words), FF data memory
//              (DMEM_DEPTH words), memory mux, and pipeline_top instance.
// Author: Beaux Cable
// Date: April 2026
// Project: RV32I Pipelined Processor
// ============================================================================

module chip_top #(
  parameter integer IMEM_DEPTH = 64,
  parameter integer DMEM_DEPTH = 64
) (
  input  logic        clk,
  input  logic        rst_n,       // pad-level active-low async reset
  input  logic [31:0] data_i,      // host write data bus
  output logic [31:0] data_o,      // host read data bus
  input  logic [2:0]  addr_cmd_i,  // register/command select
  input  logic        wr_en_i,     // write strobe
  input  logic        rd_en_i,     // read strobe
  output logic        busy_o,      // wrapper processing
  output logic        done_o       // CPU halted
);

  // --------------------------------------------------------------------------
  // Localparams — FSM state encodings (canonical-reference.md §13.5)
  // --------------------------------------------------------------------------
  localparam logic [3:0] ST_IDLE    = 4'h0;
  localparam logic [3:0] ST_LOADING = 4'h1;
  localparam logic [3:0] ST_RUNNING = 4'h2;
  localparam logic [3:0] ST_DONE    = 4'h3;

  // CMD codes (canonical-reference.md §13.3)
  localparam logic [3:0] CMD_NOP       = 4'h0;
  localparam logic [3:0] CMD_LOAD_IMEM = 4'h1;
  localparam logic [3:0] CMD_LOAD_DMEM = 4'h2;
  localparam logic [3:0] CMD_RUN       = 4'h3;
  localparam logic [3:0] CMD_HALT      = 4'h4;
  localparam logic [3:0] CMD_READ_DMEM = 4'h5;
  localparam logic [3:0] CMD_READ_IMEM = 4'h6;

  // Address register/command select codes
  localparam logic [2:0] REG_CMD       = 3'h0;
  localparam logic [2:0] REG_ADDR      = 3'h1;
  localparam logic [2:0] REG_WDATA     = 3'h2;
  localparam logic [2:0] REG_RDATA     = 3'h3;
  localparam logic [2:0] REG_STATUS    = 3'h4;
  localparam logic [2:0] REG_PC        = 3'h5;
  localparam logic [2:0] REG_CYCLE_CNT = 3'h6;

  // Derived address widths
  localparam integer IMEM_AW = $clog2(IMEM_DEPTH);
  localparam integer DMEM_AW = $clog2(DMEM_DEPTH);

  // --------------------------------------------------------------------------
  // Internal signal declarations
  // --------------------------------------------------------------------------

  // Reset synchronizer
  logic rst_sync_ff1;
  logic rst_sync_ff2;
  logic rst_n_sync;          // all internal logic uses this

  // FSM state
  logic [3:0] state;
  logic [3:0] state_next;

  // Command registers
  logic [3:0]  cmd_reg;      // latched CMD code
  logic [31:0] addr_reg;     // target word address
  logic [31:0] wdata_reg;    // write data
  logic [31:0] rdata_reg;    // read data result
  logic [31:0] cycle_cnt;    // running cycle counter

  // Remembered load type across LOADING state
  logic        load_cmd;     // 0 = loading imem, 1 = loading dmem

  // FF memories
  logic [31:0] imem [0:IMEM_DEPTH-1];
  logic [31:0] dmem [0:DMEM_DEPTH-1];

  // Memory mux signals
  logic                  mem_sel;   // 1 = CPU drives, 0 = wrapper drives
  logic [IMEM_AW-1:0]    imem_addr;
  logic [DMEM_AW-1:0]    dmem_addr;
  logic [31:0]           imem_rdata;
  logic [31:0]           dmem_rdata;

  // pipeline_top connections
  logic        cpu_rst_n;
  logic [31:0] cpu_instr_addr;
  logic [31:0] cpu_data_addr;
  logic [31:0] cpu_data_out;
  logic [3:0]  cpu_data_we;
  logic        cpu_data_re;
  logic [31:0] cpu_data_in;
  logic        cpu_halt;
  logic        halt_latched;

  // --------------------------------------------------------------------------
  // 2-FF reset synchronizer — async assert, sync deassert
  // --------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rst_sync_ff1 <= 1'b0;
      rst_sync_ff2 <= 1'b0;
    end else begin
      rst_sync_ff1 <= 1'b1;
      rst_sync_ff2 <= rst_sync_ff1;
    end
  end

  assign rst_n_sync = rst_sync_ff2;

  // --------------------------------------------------------------------------
  // pipeline_top instantiation
  // --------------------------------------------------------------------------
  pipeline_top u_core (
    .clk          (clk),
    .rst_n        (cpu_rst_n),
    .instr_addr_o (cpu_instr_addr),
    .instr_data_i (imem_rdata),
    .data_addr_o  (cpu_data_addr),
    .data_out_o   (cpu_data_out),
    .data_we_o    (cpu_data_we),
    .data_re_o    (cpu_data_re),
    .data_in_i    (cpu_data_in),
    .halt_o       (cpu_halt)
  );

  // cpu_rst_n released (high) only in RUNNING state
  assign cpu_rst_n = rst_n_sync && (state == ST_RUNNING);

  // --------------------------------------------------------------------------
  // Memory mux — CPU in RUNNING, wrapper in all other states
  // --------------------------------------------------------------------------
  assign mem_sel = (state == ST_RUNNING);

  always_comb begin
    if (mem_sel) begin
      imem_addr = cpu_instr_addr[IMEM_AW+1:2];
      dmem_addr = cpu_data_addr[DMEM_AW+1:2];
    end else begin
      imem_addr = addr_reg[IMEM_AW-1:0];
      dmem_addr = addr_reg[DMEM_AW-1:0];
    end
  end

  assign imem_rdata  = imem[imem_addr];
  assign dmem_rdata  = dmem[dmem_addr];
  assign cpu_data_in = dmem_rdata;

  // --------------------------------------------------------------------------
  // Instruction memory — synchronous write (wrapper LOADING, imem path)
  // --------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (state == ST_LOADING && !load_cmd)
      imem[addr_reg[IMEM_AW-1:0]] <= wdata_reg;
  end

  // --------------------------------------------------------------------------
  // Data memory — synchronous writes
  //   CPU: byte-lane writes in RUNNING
  //   Wrapper: full-word write in LOADING (dmem path)
  // --------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (state == ST_RUNNING) begin
      for (int i = 0; i < 4; i++) begin
        if (cpu_data_we[i])
          dmem[cpu_data_addr[DMEM_AW+1:2]][i*8 +: 8] <=
            cpu_data_out[i*8 +: 8];
      end
    end else if (state == ST_LOADING && load_cmd) begin
      dmem[addr_reg[DMEM_AW-1:0]] <= wdata_reg;
    end
  end

  // --------------------------------------------------------------------------
  // Halt latching — register cpu_halt for DONE transition / done_o
  // --------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n_sync) begin
    if (!rst_n_sync)
      halt_latched <= 1'b0;
    else
      halt_latched <= cpu_halt;
  end

  // --------------------------------------------------------------------------
  // FSM next-state logic (combinational)
  // --------------------------------------------------------------------------
  always_comb begin
    state_next = state;  // default: hold state
    case (state)
      ST_IDLE: begin
        if (wr_en_i && addr_cmd_i == REG_CMD) begin
          case (data_i[3:0])
            CMD_LOAD_IMEM: state_next = ST_LOADING;
            CMD_LOAD_DMEM: state_next = ST_LOADING;
            CMD_RUN:       state_next = ST_RUNNING;
            default:       state_next = ST_IDLE;
          endcase
        end
      end
      ST_LOADING: begin
        // single-cycle transient: auto-return to IDLE
        state_next = ST_IDLE;
      end
      ST_RUNNING: begin
        if (halt_latched)
          state_next = ST_DONE;
        else if (wr_en_i && addr_cmd_i == REG_CMD &&
                 data_i[3:0] == CMD_HALT)
          state_next = ST_IDLE;
        else
          state_next = ST_RUNNING;
      end
      ST_DONE: begin
        if (wr_en_i && addr_cmd_i == REG_CMD &&
            data_i[3:0] == CMD_HALT)
          state_next = ST_IDLE;
        else
          state_next = ST_DONE;
      end
      default: state_next = ST_IDLE;
    endcase
  end

  // --------------------------------------------------------------------------
  // Sequential: FSM state register, command registers, cycle counter
  // --------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n_sync) begin
    if (!rst_n_sync) begin
      state     <= ST_IDLE;
      cmd_reg   <= 4'h0;
      addr_reg  <= 32'h0;
      wdata_reg <= 32'h0;
      rdata_reg <= 32'h0;
      cycle_cnt <= 32'h0;
      load_cmd  <= 1'b0;
    end else begin
      state <= state_next;

      // Cycle counter increments only while in RUNNING
      if (state == ST_RUNNING)
        cycle_cnt <= cycle_cnt + 32'h1;

      // Capture writable registers on wr_en_i
      if (wr_en_i) begin
        case (addr_cmd_i)
          REG_CMD: begin
            cmd_reg <= data_i[3:0];
            // Latch which memory type is being loaded
            if (data_i[3:0] == CMD_LOAD_IMEM)
              load_cmd <= 1'b0;
            else if (data_i[3:0] == CMD_LOAD_DMEM)
              load_cmd <= 1'b1;
          end
          REG_ADDR:  addr_reg  <= data_i;
          REG_WDATA: wdata_reg <= data_i;
          default: ; // read-only registers ignore writes
        endcase
      end

      // READ_DMEM / READ_IMEM: latch addressed word into rdata_reg
      if (wr_en_i && addr_cmd_i == REG_CMD) begin
        case (data_i[3:0])
          CMD_READ_DMEM:
            rdata_reg <= dmem[addr_reg[DMEM_AW-1:0]];
          CMD_READ_IMEM:
            rdata_reg <= imem[addr_reg[IMEM_AW-1:0]];
          default: ;
        endcase
      end
    end
  end

  // --------------------------------------------------------------------------
  // Output assignments
  // --------------------------------------------------------------------------
  assign busy_o = (state == ST_LOADING) || (state == ST_RUNNING);
  assign done_o = (state == ST_DONE);

  // Combinational read mux — data_o valid same cycle as rd_en_i
  always_comb begin
    data_o = 32'h0;  // default prevents latch inference
    if (rd_en_i) begin
      case (addr_cmd_i)
        REG_CMD:       data_o = 32'h0;
        REG_ADDR:      data_o = 32'h0;
        REG_WDATA:     data_o = 32'h0;
        REG_RDATA:     data_o = rdata_reg;
        REG_STATUS:    data_o = {28'h0, state};
        REG_PC:        data_o = cpu_instr_addr;
        REG_CYCLE_CNT: data_o = cycle_cnt;
        default:       data_o = 32'h0;
      endcase
    end
  end

endmodule
