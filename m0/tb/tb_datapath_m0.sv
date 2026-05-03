// ============================================================================
// Module: tb_datapath_m0
// Description: Self-checking testbench for datapath_m0. Derives expected
//              values from RV32I spec. Covers R-type, I-type, LUI, AUIPC,
//              S/B-type reg_write=0, rd_addr_o gating, x0 suppression.
//              M0 known limitation: AUIPC uses PC=0; JAL/JALR write ALU
//              result (not PC+4). All timing: stimulus at negedge (gotcha #11).
// Author: Beaux Cable
// Date: April 2026
// Project: TSI RV32I Pipelined Processor (TSMC 180nm)
// ============================================================================
//
// Spec references: canonical-reference.md
//   §1.1  R-type encodings and operations
//   §1.2  I-type ALU encodings and operations
//   §1.7  LUI / AUIPC operations
//   §1.4  Store instruction format (S-type, reg_write=0)
//   §1.5  Branch instruction format (B-type, reg_write=0)
//   §3    Bit-level instruction encoding formats
//   §6.3  Control signal truth table (reg_write column)
//   §9.2  Reset: async assert, all registers clear to 0
//
// Instruction encoding formats (canonical-reference.md §3):
//   R-type:  {funct7[6:0], rs2[4:0], rs1[4:0], funct3[2:0], rd[4:0], opcode[6:0]}
//   I-type:  {imm[11:0],              rs1[4:0], funct3[2:0], rd[4:0], opcode[6:0]}
//   S-type:  {imm[11:5],  rs2[4:0],  rs1[4:0], funct3[2:0], imm[4:0], opcode[6:0]}
//   B-type:  {imm[12],imm[10:5], rs2[4:0], rs1[4:0], funct3[2:0], imm[4:1], imm[11], opcode[6:0]}
//   U-type:  {imm[31:12],                            rd[4:0], opcode[6:0]}
//
// Opcodes (canonical-reference.md §2):
//   OP      = 7'b0110011
//   OP-IMM  = 7'b0010011
//   STORE   = 7'b0100011
//   BRANCH  = 7'b1100011
//   LUI     = 7'b0110111
//   AUIPC   = 7'b0010111
//
// Timing (gotchas.md #11):
//   - All stimulus driven at @(negedge clk)
//   - ALU result is combinational; check #1 after negedge
//   - Register writes captured on posedge clk
//   - For dependent sequences: negedge (drive) → posedge (capture) → negedge
//     (drive next) → #1 (check combinational output) → posedge (capture next)
// ============================================================================

`timescale 1ns/1ps

module tb_datapath_m0;

  // --------------------------------------------------------------------------
  // Clock, reset, DUT ports
  // --------------------------------------------------------------------------
  logic        clk;
  logic        rst_n;
  logic [31:0] instr_i;
  logic [31:0] alu_result_o;
  logic        reg_write_o;
  logic [ 4:0] rd_addr_o;
  logic [31:0] jalr_target_o;

  // --------------------------------------------------------------------------
  // Clock generation: 50 MHz (period=20 ns)
  // --------------------------------------------------------------------------
  initial clk = 1'b0;
  always #10 clk = ~clk;

  // --------------------------------------------------------------------------
  // DUT instantiation
  // --------------------------------------------------------------------------
  datapath_m0 dut (
    .clk           (clk),
    .rst_n         (rst_n),
    .instr_i       (instr_i),
    .pc_i          (32'h0),       // M0: no PC, tie to zero
    .alu_result_o  (alu_result_o),
    .reg_write_o   (reg_write_o),
    .rd_addr_o     (rd_addr_o),
    .jalr_target_o (jalr_target_o)
  );

  // --------------------------------------------------------------------------
  // Pass/fail counters
  // --------------------------------------------------------------------------
  integer pass_count;
  integer fail_count;

  // --------------------------------------------------------------------------
  // Check task: combinational result check (called after #1 post-negedge)
  // --------------------------------------------------------------------------
  task automatic check_result;
    input string       test_name;
    input logic [31:0] got_result;
    input logic [31:0] exp_result;
    input logic        got_rw;
    input logic        exp_rw;
    input logic [ 4:0] got_rd;
    input logic [ 4:0] exp_rd;
    begin
      if (got_result !== exp_result || got_rw !== exp_rw || got_rd !== exp_rd) begin
        $display("[FAIL] %s: alu_result_o=0x%08X (exp=0x%08X) reg_write_o=%b (exp=%b) rd_addr_o=%0d (exp=%0d)",
                 test_name, got_result, exp_result, got_rw, exp_rw, got_rd, exp_rd);
        fail_count = fail_count + 1;
      end else begin
        $display("[PASS] %s: alu_result_o=0x%08X reg_write_o=%b rd_addr_o=%0d",
                 test_name, got_result, got_rw, got_rd);
        pass_count = pass_count + 1;
      end
    end
  endtask

  // --------------------------------------------------------------------------
  // Instruction encoding helper parameters
  // All derived from canonical-reference.md §1, §2, §3
  // --------------------------------------------------------------------------

  // Opcodes
  localparam [6:0] OP_OP     = 7'b0110011;  // R-type ALU
  localparam [6:0] OP_IMM    = 7'b0010011;  // I-type ALU
  localparam [6:0] OP_STORE  = 7'b0100011;  // S-type store
  localparam [6:0] OP_BRANCH = 7'b1100011;  // B-type branch
  localparam [6:0] OP_LUI    = 7'b0110111;  // LUI
  localparam [6:0] OP_AUIPC  = 7'b0010111;  // AUIPC

  // funct3 values (canonical-reference.md §1.1, §1.2)
  localparam [2:0] F3_ADD_SUB = 3'b000;
  localparam [2:0] F3_SLL     = 3'b001;
  localparam [2:0] F3_SLT     = 3'b010;
  localparam [2:0] F3_SLTU    = 3'b011;
  localparam [2:0] F3_XOR     = 3'b100;
  localparam [2:0] F3_SRL_SRA = 3'b101;
  localparam [2:0] F3_OR      = 3'b110;
  localparam [2:0] F3_AND     = 3'b111;
  localparam [2:0] F3_SW      = 3'b010;
  localparam [2:0] F3_BEQ     = 3'b000;

  // funct7 values (canonical-reference.md §1.1)
  localparam [6:0] F7_ZERO    = 7'b0000000;  // ADD, SLL, SLT, SLTU, XOR, SRL, OR, AND
  localparam [6:0] F7_ALT     = 7'b0100000;  // SUB, SRA, SRAI

  // --------------------------------------------------------------------------
  // R-type instruction encoder function
  // {funct7, rs2, rs1, funct3, rd, opcode}
  // --------------------------------------------------------------------------
  function automatic logic [31:0] enc_rtype;
    input [6:0] funct7;
    input [4:0] rs2;
    input [4:0] rs1;
    input [2:0] funct3;
    input [4:0] rd;
    begin
      enc_rtype = {funct7, rs2, rs1, funct3, rd, OP_OP};
    end
  endfunction

  // --------------------------------------------------------------------------
  // I-type instruction encoder function (OP-IMM)
  // {imm[11:0], rs1, funct3, rd, opcode}
  // --------------------------------------------------------------------------
  function automatic logic [31:0] enc_itype;
    input [11:0] imm12;
    input [4:0]  rs1;
    input [2:0]  funct3;
    input [4:0]  rd;
    begin
      enc_itype = {imm12, rs1, funct3, rd, OP_IMM};
    end
  endfunction

  // --------------------------------------------------------------------------
  // ADDI encoder (I-type convenience wrapper)
  // Operation: rd = rs1 + sext(imm12)  (canonical-reference.md §1.2)
  // --------------------------------------------------------------------------
  function automatic logic [31:0] enc_addi;
    input [11:0] imm12;
    input [4:0]  rs1;
    input [4:0]  rd;
    begin
      enc_addi = enc_itype(imm12, rs1, F3_ADD_SUB, rd);
    end
  endfunction

  // --------------------------------------------------------------------------
  // Main test sequence
  // --------------------------------------------------------------------------
  initial begin
    pass_count = 0;
    fail_count = 0;

    // Idle instruction: NOP = ADDI x0, x0, 0 = 32'h00000013
    // (canonical-reference.md §7.3)
    instr_i = 32'h00000013;

    // ------------------------------------------------------------------
    // Reset: assert rst_n=0 for 2 cycles, deassert on posedge, wait 1
    // (canonical-reference.md §9.2: async assert, all regs clear to 0)
    // ------------------------------------------------------------------
    rst_n = 1'b0;
    @(posedge clk); // cycle 1 in reset
    @(posedge clk); // cycle 2 in reset
    @(posedge clk); // deassert synchronously on this posedge
    rst_n = 1'b1;
    @(posedge clk); // settle cycle
    #1;

    // ==================================================================
    // GROUP 1: R-type instructions
    // (canonical-reference.md §1.1, §3)
    // ==================================================================
    $display("\n--- Group 1: R-type instructions ---");

    // ------------------------------------------------------------------
    // Setup: write x1=5 via ADDI x1, x0, 5
    // Spec (§1.2): ADDI rd=x1, rs1=x0, imm=5 → x1 = 0 + 5 = 5
    // Encoding: {12'd5, 5'd0, F3_ADD_SUB, 5'd1, OP_IMM}
    // ------------------------------------------------------------------
    @(negedge clk);
    instr_i = enc_addi(12'd5, 5'd0, 5'd1);
    #1;
    @(posedge clk); #1; // capture: x1 ← 5

    // ------------------------------------------------------------------
    // Setup: write x2=3 via ADDI x2, x0, 3
    // Spec (§1.2): rd=x2, rs1=x0, imm=3 → x2 = 0 + 3 = 3
    // ------------------------------------------------------------------
    @(negedge clk);
    instr_i = enc_addi(12'd3, 5'd0, 5'd2);
    #1;
    @(posedge clk); #1; // capture: x2 ← 3

    // ------------------------------------------------------------------
    // ADD x3, x1, x2
    // Spec (§1.1): rd = rs1 + rs2 = 5 + 3 = 8
    // Encoding: {F7_ZERO, rs2=x2, rs1=x1, F3_ADD_SUB, rd=x3, OP_OP}
    // reg_write=1 (§6.3 R-type), rd_addr_o=3
    // ------------------------------------------------------------------
    @(negedge clk);
    instr_i = enc_rtype(F7_ZERO, 5'd2, 5'd1, F3_ADD_SUB, 5'd3);
    #1;
    check_result("ADD x3,x1,x2  (5+3=8)",
                 alu_result_o, 32'd8,
                 reg_write_o,  1'b1,
                 rd_addr_o,    5'd3);
    @(posedge clk); #1; // capture: x3 ← 8

    // ------------------------------------------------------------------
    // SUB x4, x1, x2
    // Spec (§1.1): rd = rs1 - rs2 = 5 - 3 = 2
    // Encoding: {F7_ALT, rs2=x2, rs1=x1, F3_ADD_SUB, rd=x4, OP_OP}
    // ------------------------------------------------------------------
    @(negedge clk);
    instr_i = enc_rtype(F7_ALT, 5'd2, 5'd1, F3_ADD_SUB, 5'd4);
    #1;
    check_result("SUB x4,x1,x2  (5-3=2)",
                 alu_result_o, 32'd2,
                 reg_write_o,  1'b1,
                 rd_addr_o,    5'd4);
    @(posedge clk); #1;

    // ------------------------------------------------------------------
    // AND x5, x1, x2
    // Spec (§1.1): rd = rs1 & rs2 = 5 & 3 = 0b101 & 0b011 = 0b001 = 1
    // ------------------------------------------------------------------
    @(negedge clk);
    instr_i = enc_rtype(F7_ZERO, 5'd2, 5'd1, F3_AND, 5'd5);
    #1;
    check_result("AND x5,x1,x2  (5&3=1)",
                 alu_result_o, 32'd1,
                 reg_write_o,  1'b1,
                 rd_addr_o,    5'd5);
    @(posedge clk); #1;

    // ------------------------------------------------------------------
    // OR x6, x1, x2
    // Spec (§1.1): rd = rs1 | rs2 = 5 | 3 = 0b101 | 0b011 = 0b111 = 7
    // ------------------------------------------------------------------
    @(negedge clk);
    instr_i = enc_rtype(F7_ZERO, 5'd2, 5'd1, F3_OR, 5'd6);
    #1;
    check_result("OR  x6,x1,x2  (5|3=7)",
                 alu_result_o, 32'd7,
                 reg_write_o,  1'b1,
                 rd_addr_o,    5'd6);
    @(posedge clk); #1;

    // ------------------------------------------------------------------
    // XOR x7, x1, x2
    // Spec (§1.1): rd = rs1 ^ rs2 = 5 ^ 3 = 0b101 ^ 0b011 = 0b110 = 6
    // ------------------------------------------------------------------
    @(negedge clk);
    instr_i = enc_rtype(F7_ZERO, 5'd2, 5'd1, F3_XOR, 5'd7);
    #1;
    check_result("XOR x7,x1,x2  (5^3=6)",
                 alu_result_o, 32'd6,
                 reg_write_o,  1'b1,
                 rd_addr_o,    5'd7);
    @(posedge clk); #1;

    // ------------------------------------------------------------------
    // SLT x8, x2, x1
    // Spec (§1.1): rd = (rs1 <s rs2) ? 1 : 0
    //   rs1=x2=3, rs2=x1=5 → signed(3) < signed(5) → 1
    // ------------------------------------------------------------------
    @(negedge clk);
    instr_i = enc_rtype(F7_ZERO, 5'd1, 5'd2, F3_SLT, 5'd8);
    #1;
    check_result("SLT x8,x2,x1  (3<5 signed=1)",
                 alu_result_o, 32'd1,
                 reg_write_o,  1'b1,
                 rd_addr_o,    5'd8);
    @(posedge clk); #1;

    // ------------------------------------------------------------------
    // SLTU x9, x2, x1
    // Spec (§1.1): rd = (rs1 <u rs2) ? 1 : 0
    //   rs1=x2=3, rs2=x1=5 → unsigned(3) < unsigned(5) → 1
    // ------------------------------------------------------------------
    @(negedge clk);
    instr_i = enc_rtype(F7_ZERO, 5'd1, 5'd2, F3_SLTU, 5'd9);
    #1;
    check_result("SLTU x9,x2,x1 (3<5 unsigned=1)",
                 alu_result_o, 32'd1,
                 reg_write_o,  1'b1,
                 rd_addr_o,    5'd9);
    @(posedge clk); #1;

    // ------------------------------------------------------------------
    // SLL x10, x2, x1
    // Spec (§1.1): rd = rs1 << rs2[4:0] = 3 << (5 & 0x1F) = 3 << 5
    //   = 0b11 << 5 = 0b1100000 = 96 (gotchas.md #3: only low 5 bits used)
    // ------------------------------------------------------------------
    @(negedge clk);
    instr_i = enc_rtype(F7_ZERO, 5'd1, 5'd2, F3_SLL, 5'd10);
    #1;
    check_result("SLL x10,x2,x1 (3<<5=96)",
                 alu_result_o, 32'd96,
                 reg_write_o,  1'b1,
                 rd_addr_o,    5'd10);
    @(posedge clk); #1;

    // ------------------------------------------------------------------
    // SRL x11, x2, x1
    // Spec (§1.1): rd = rs1 >> rs2[4:0] = 3 >> 5 (logical, zero-fill)
    //   = 0b11 >> 5 = 0 (result is 0 because 3 < 2^5=32, shift exceeds value)
    // ------------------------------------------------------------------
    @(negedge clk);
    instr_i = enc_rtype(F7_ZERO, 5'd1, 5'd2, F3_SRL_SRA, 5'd11);
    #1;
    check_result("SRL x11,x2,x1 (3>>5=0 logical)",
                 alu_result_o, 32'd0,
                 reg_write_o,  1'b1,
                 rd_addr_o,    5'd11);
    @(posedge clk); #1;

    // ------------------------------------------------------------------
    // Setup: write x12 = -4 = 0xFFFFFFFC via ADDI x12, x0, -4
    // Spec (§1.2): imm=-4 sign-extended = 12'hFFC = 12'b111111111100
    //   rd = 0 + sext(-4) = 0xFFFFFFFC
    // ------------------------------------------------------------------
    @(negedge clk);
    instr_i = enc_addi(12'hFFC, 5'd0, 5'd12);
    #1;
    @(posedge clk); #1; // capture: x12 ← 0xFFFFFFFC

    // ------------------------------------------------------------------
    // SRA x13, x12, x2
    // Spec (§1.1): rd = rs1 >>> rs2[4:0] (sign-extend fill)
    //   rs1=x12=0xFFFFFFFC (-4), rs2=x2=3 → shift amount = 3[4:0] = 3
    //   0xFFFFFFFC (-4) >>> 3 = -4/8 = -1 = 0xFFFFFFFF
    //   (sign bit=1, arithmetic shift fills with 1s)
    // ------------------------------------------------------------------
    @(negedge clk);
    instr_i = enc_rtype(F7_ALT, 5'd2, 5'd12, F3_SRL_SRA, 5'd13);
    #1;
    check_result("SRA x13,x12,x2 (0xFFFFFFFC>>>3=0xFFFFFFFF)",
                 alu_result_o, 32'hFFFFFFFF,
                 reg_write_o,  1'b1,
                 rd_addr_o,    5'd13);
    @(posedge clk); #1;

    // ==================================================================
    // GROUP 2: I-type ALU instructions
    // (canonical-reference.md §1.2, §3)
    // ==================================================================
    $display("\n--- Group 2: I-type ALU instructions ---");

    // ------------------------------------------------------------------
    // ADDI x1, x0, 100
    // Spec (§1.2): rd = rs1 + sext(imm) = 0 + 100 = 100
    // Encoding: {12'd100, rs1=x0, F3_ADD_SUB, rd=x1, OP_IMM}
    // reg_write=1 (§6.3 I-type ALU), rd_addr_o=1
    // ------------------------------------------------------------------
    @(negedge clk);
    instr_i = enc_addi(12'd100, 5'd0, 5'd1);
    #1;
    check_result("ADDI x1,x0,100 (0+100=100)",
                 alu_result_o, 32'd100,
                 reg_write_o,  1'b1,
                 rd_addr_o,    5'd1);
    @(posedge clk); #1; // capture: x1 ← 100

    // ------------------------------------------------------------------
    // ADDI x2, x0, -1
    // Spec (§1.2): rd = 0 + sext(-1) = 0 + 0xFFFFFFFF = 0xFFFFFFFF
    // imm=-1: 12'hFFF (twelve 1-bits), sign-extended → 32'hFFFFFFFF
    // ------------------------------------------------------------------
    @(negedge clk);
    instr_i = enc_addi(12'hFFF, 5'd0, 5'd2);
    #1;
    check_result("ADDI x2,x0,-1 (=0xFFFFFFFF)",
                 alu_result_o, 32'hFFFFFFFF,
                 reg_write_o,  1'b1,
                 rd_addr_o,    5'd2);
    @(posedge clk); #1; // capture: x2 ← 0xFFFFFFFF

    // ------------------------------------------------------------------
    // SLTI x3, x2, 0
    // Spec (§1.2): rd = (rs1 <s sext(imm)) ? 1 : 0
    //   rs1=x2=0xFFFFFFFF=-1 (signed), imm=0 → (-1) <s 0 → true → 1
    // Encoding: {12'd0, rs1=x2, F3_SLT, rd=x3, OP_IMM}
    // ------------------------------------------------------------------
    @(negedge clk);
    instr_i = enc_itype(12'd0, 5'd2, F3_SLT, 5'd3);
    #1;
    check_result("SLTI x3,x2,0  (-1<0 signed=1)",
                 alu_result_o, 32'd1,
                 reg_write_o,  1'b1,
                 rd_addr_o,    5'd3);
    @(posedge clk); #1;

    // ------------------------------------------------------------------
    // SLTIU x4, x0, 1
    // Spec (§1.2): rd = (rs1 <u sext(imm)) ? 1 : 0
    //   ⚠ imm IS sign-extended first, THEN compared unsigned (§1.2 note)
    //   rs1=x0=0, sext(1)=0x00000001 → unsigned(0) < unsigned(1) → 1
    // Encoding: {12'd1, rs1=x0, F3_SLTU, rd=x4, OP_IMM}
    // ------------------------------------------------------------------
    @(negedge clk);
    instr_i = enc_itype(12'd1, 5'd0, F3_SLTU, 5'd4);
    #1;
    check_result("SLTIU x4,x0,1 (0<1 unsigned=1)",
                 alu_result_o, 32'd1,
                 reg_write_o,  1'b1,
                 rd_addr_o,    5'd4);
    @(posedge clk); #1;

    // ------------------------------------------------------------------
    // ANDI x5, x2, 0xFF
    // Spec (§1.2): rd = rs1 & sext(imm)
    //   rs1=x2=0xFFFFFFFF, imm=0xFF → sext(0xFF)=0x000000FF (bit 7=0, no sign ext)
    //   0xFFFFFFFF & 0x000000FF = 0x000000FF
    // Encoding: {12'h0FF, rs1=x2, F3_AND, rd=x5, OP_IMM}
    // ------------------------------------------------------------------
    @(negedge clk);
    instr_i = enc_itype(12'h0FF, 5'd2, F3_AND, 5'd5);
    #1;
    check_result("ANDI x5,x2,0xFF (0xFFFFFFFF&0xFF=0xFF)",
                 alu_result_o, 32'h000000FF,
                 reg_write_o,  1'b1,
                 rd_addr_o,    5'd5);
    @(posedge clk); #1;

    // ------------------------------------------------------------------
    // ORI x6, x0, 0x55
    // Spec (§1.2): rd = rs1 | sext(imm)
    //   rs1=x0=0, sext(0x55)=0x00000055 → 0 | 0x55 = 0x55
    // ------------------------------------------------------------------
    @(negedge clk);
    instr_i = enc_itype(12'h055, 5'd0, F3_OR, 5'd6);
    #1;
    check_result("ORI  x6,x0,0x55 (0|0x55=0x55)",
                 alu_result_o, 32'h00000055,
                 reg_write_o,  1'b1,
                 rd_addr_o,    5'd6);
    @(posedge clk); #1;

    // ------------------------------------------------------------------
    // XORI x7, x2, 0xFF
    // Spec (§1.2): rd = rs1 ^ sext(imm)
    //   rs1=x2=0xFFFFFFFF, sext(0xFF)=0x000000FF (bit 7=0)
    //   0xFFFFFFFF ^ 0x000000FF = 0xFFFFFF00
    // ------------------------------------------------------------------
    @(negedge clk);
    instr_i = enc_itype(12'h0FF, 5'd2, F3_XOR, 5'd7);
    #1;
    check_result("XORI x7,x2,0xFF (0xFFFFFFFF^0xFF=0xFFFFFF00)",
                 alu_result_o, 32'hFFFFFF00,
                 reg_write_o,  1'b1,
                 rd_addr_o,    5'd7);
    @(posedge clk); #1;

    // ------------------------------------------------------------------
    // SLLI x8, x1, 2
    // Spec (§1.2): rd = rs1 << shamt; shamt in imm[4:0], imm[11:5]=0000000
    //   rs1=x1=100, shamt=2 → 100 << 2 = 400
    // Encoding: {7'b0000000, shamt=5'd2, rs1=x1, F3_SLL, rd=x8, OP_IMM}
    //   imm[11:0] = {7'b0000000, 5'd2} = 12'b000000000010 = 12'h002
    // ------------------------------------------------------------------
    @(negedge clk);
    instr_i = enc_itype({7'b0000000, 5'd2}, 5'd1, F3_SLL, 5'd8);
    #1;
    check_result("SLLI x8,x1,2  (100<<2=400)",
                 alu_result_o, 32'd400,
                 reg_write_o,  1'b1,
                 rd_addr_o,    5'd8);
    @(posedge clk); #1;

    // ------------------------------------------------------------------
    // SRLI x9, x1, 1
    // Spec (§1.2): rd = rs1 >> shamt (logical, zero-fill)
    //   rs1=x1=100, shamt=1 → 100 >> 1 = 50
    // Encoding: imm[11:0] = {7'b0000000, 5'd1} = 12'h001
    // ------------------------------------------------------------------
    @(negedge clk);
    instr_i = enc_itype({7'b0000000, 5'd1}, 5'd1, F3_SRL_SRA, 5'd9);
    #1;
    check_result("SRLI x9,x1,1  (100>>1=50 logical)",
                 alu_result_o, 32'd50,
                 reg_write_o,  1'b1,
                 rd_addr_o,    5'd9);
    @(posedge clk); #1;

    // ------------------------------------------------------------------
    // SRAI x10, x2, 4
    // Spec (§1.2): rd = rs1 >>> shamt (arithmetic, sign-extend fill)
    //   rs1=x2=0xFFFFFFFF (-1 signed), shamt=4
    //   0xFFFFFFFF >>> 4 = 0xFFFFFFFF (-1 arithmetic right shift keeps sign)
    // Encoding: funct7=0100000 → imm[11:5]=7'b0100000
    //   imm[11:0] = {7'b0100000, 5'd4} = 12'b010000000100 = 12'h204
    // ------------------------------------------------------------------
    @(negedge clk);
    instr_i = enc_itype({7'b0100000, 5'd4}, 5'd2, F3_SRL_SRA, 5'd10);
    #1;
    check_result("SRAI x10,x2,4 (0xFFFFFFFF>>>4=0xFFFFFFFF)",
                 alu_result_o, 32'hFFFFFFFF,
                 reg_write_o,  1'b1,
                 rd_addr_o,    5'd10);
    @(posedge clk); #1;

    // ==================================================================
    // GROUP 3: LUI
    // (canonical-reference.md §1.7, §3)
    // Spec: rd = imm[31:12] << 12 (lower 12 bits zeroed)
    // M0 note: ALU computes 0 + U-imm (alu_src_a=10 → zero; §6 LUI note)
    // U-type encoding: {imm[31:12], rd[4:0], opcode[6:0]}
    // ==================================================================
    $display("\n--- Group 3: LUI ---");

    // ------------------------------------------------------------------
    // LUI x1, 0x12345
    // Spec (§1.7): rd = 0x12345 << 12 = 0x12345000
    // Encoding: {20'h12345, rd=5'd1, OP_LUI}
    // reg_write=1 (§6.3 LUI), rd_addr_o=1
    // ------------------------------------------------------------------
    @(negedge clk);
    instr_i = {20'h12345, 5'd1, OP_LUI};
    #1;
    check_result("LUI x1,0x12345 (=0x12345000)",
                 alu_result_o, 32'h12345000,
                 reg_write_o,  1'b1,
                 rd_addr_o,    5'd1);
    @(posedge clk); #1;

    // ------------------------------------------------------------------
    // LUI x2, 0xABCDE
    // Spec (§1.7): rd = 0xABCDE << 12 = 0xABCDE000
    // Encoding: {20'hABCDE, rd=5'd2, OP_LUI}
    // ------------------------------------------------------------------
    @(negedge clk);
    instr_i = {20'hABCDE, 5'd2, OP_LUI};
    #1;
    check_result("LUI x2,0xABCDE (=0xABCDE000)",
                 alu_result_o, 32'hABCDE000,
                 reg_write_o,  1'b1,
                 rd_addr_o,    5'd2);
    @(posedge clk); #1;

    // ==================================================================
    // GROUP 4: AUIPC (M0 known limitation: PC=0)
    // (canonical-reference.md §1.7, §6.3, §6 AUIPC note)
    // Spec: rd = PC + (imm[31:12] << 12)
    // M0 limitation: PC is substituted with 0 (no PC in M0)
    //   → result = 0 + U-imm = U-imm (per design scope confirmed by ar)
    // U-type encoding: {imm[31:12], rd[4:0], opcode[6:0]}
    // ==================================================================
    $display("\n--- Group 4: AUIPC (PC=0 in M0) ---");

    // ------------------------------------------------------------------
    // AUIPC x3, 0x00001
    // Spec (§1.7): rd = PC + 0x00001000
    // M0: PC=0 → result = 0 + 0x00001000 = 0x00001000
    // Encoding: {20'h00001, rd=5'd3, OP_AUIPC}
    // reg_write=1 (§6.3 AUIPC), rd_addr_o=3
    // ------------------------------------------------------------------
    @(negedge clk);
    instr_i = {20'h00001, 5'd3, OP_AUIPC};
    #1;
    check_result("AUIPC x3,0x1  (PC=0, 0+0x1000=0x1000)",
                 alu_result_o, 32'h00001000,
                 reg_write_o,  1'b1,
                 rd_addr_o,    5'd3);
    @(posedge clk); #1;

    // ==================================================================
    // GROUP 5: S-type and B-type (reg_write=0)
    // (canonical-reference.md §6.3: STORE reg_write=0, BRANCH reg_write=0)
    // ==================================================================
    $display("\n--- Group 5: S-type and B-type (reg_write=0) ---");

    // ------------------------------------------------------------------
    // SW instruction (S-type, STORE)
    // Spec (§6.3): STORE → reg_write=0
    // Encoding: S-type {imm[11:5], rs2, rs1, funct3, imm[4:0], opcode}
    //   Use SW rs2=x2, rs1=x1, imm=0 for simplicity
    //   {7'b0000000, rs2=5'd2, rs1=5'd1, F3_SW=3'b010, 5'b00000, OP_STORE}
    // Expected: reg_write_o=0, rd_addr_o=5'b0 (gated; §6.3 + DUT rd_addr_o gating)
    // Note: alu_result_o is the store address (rs1+imm = x1+0), which
    //       depends on x1's current value after Group 2/3 setup writes.
    //       We only check reg_write_o and rd_addr_o here.
    // ------------------------------------------------------------------
    @(negedge clk);
    // SW x2, 0(x1): {imm[11:5]=7'b0, rs2=x2, rs1=x1, funct3=SW, imm[4:0]=5'b0, OP_STORE}
    instr_i = {7'b0000000, 5'd2, 5'd1, F3_SW, 5'b00000, OP_STORE};
    #1;
    // Only check reg_write_o and rd_addr_o (ALU result is a don't-care for this test)
    if (reg_write_o !== 1'b0 || rd_addr_o !== 5'b0) begin
      $display("[FAIL] SW reg_write_o=%b (exp=0) rd_addr_o=%0d (exp=0)",
               reg_write_o, rd_addr_o);
      fail_count = fail_count + 1;
    end else begin
      $display("[PASS] SW: reg_write_o=0, rd_addr_o=0");
      pass_count = pass_count + 1;
    end
    @(posedge clk); #1;

    // ------------------------------------------------------------------
    // BEQ instruction (B-type, BRANCH)
    // Spec (§6.3): BRANCH → reg_write=0
    // Encoding: B-type {imm[12], imm[10:5], rs2, rs1, funct3, imm[4:1], imm[11], opcode}
    //   Use BEQ x1, x2, offset=0: all imm bits = 0
    //   {1'b0, 6'b0, rs2=x2, rs1=x1, F3_BEQ=3'b000, 4'b0, 1'b0, OP_BRANCH}
    // Expected: reg_write_o=0, rd_addr_o=5'b0
    // ------------------------------------------------------------------
    @(negedge clk);
    // BEQ x1, x2, 0: all immediate bits zero
    instr_i = {1'b0, 6'b000000, 5'd2, 5'd1, F3_BEQ, 4'b0000, 1'b0, OP_BRANCH};
    #1;
    if (reg_write_o !== 1'b0 || rd_addr_o !== 5'b0) begin
      $display("[FAIL] BEQ reg_write_o=%b (exp=0) rd_addr_o=%0d (exp=0)",
               reg_write_o, rd_addr_o);
      fail_count = fail_count + 1;
    end else begin
      $display("[PASS] BEQ: reg_write_o=0, rd_addr_o=0");
      pass_count = pass_count + 1;
    end
    @(posedge clk); #1;

    // ==================================================================
    // GROUP 6: rd_addr_o gating for non-write instructions
    // (DUT spec: rd_addr_o must be 5'b0 when reg_write_o=0)
    // ==================================================================
    $display("\n--- Group 6: rd_addr_o gating ---");

    // ------------------------------------------------------------------
    // SW with non-zero bits in instr[11:7]
    // S-type: instr[11:7] = imm[4:0] (NOT rd — S-type has no rd field)
    // (canonical-reference.md §3, §1.4, gotchas.md #4)
    // Use imm[4:0]=5'b11111 (all 1s) so instr[11:7]=5'b11111 = 31 ≠ 0
    // This verifies the DUT does NOT leak imm bits as rd_addr_o
    // Encoding: SW rs2=x2, rs1=x1
    //   {imm[11:5]=7'b0000000, rs2=x2, rs1=x1, F3_SW, imm[4:0]=5'b11111, OP_STORE}
    //   → instr[11:7] = 5'b11111 = 31
    // Expected: reg_write_o=0, rd_addr_o=5'b0 (gated, NOT 5'd31)
    // ------------------------------------------------------------------
    @(negedge clk);
    instr_i = {7'b0000000, 5'd2, 5'd1, F3_SW, 5'b11111, OP_STORE};
    #1;
    if (reg_write_o !== 1'b0 || rd_addr_o !== 5'b0) begin
      $display("[FAIL] SW imm[4:0]=0x1F gating: reg_write_o=%b (exp=0) rd_addr_o=%0d (exp=0, NOT %0d)",
               reg_write_o, rd_addr_o, instr_i[11:7]);
      fail_count = fail_count + 1;
    end else begin
      $display("[PASS] SW imm[4:0]=0x1F: rd_addr_o=0 (correctly gated, not leaking imm bits)");
      pass_count = pass_count + 1;
    end
    @(posedge clk); #1;

    // ==================================================================
    // GROUP 7: x0 write suppression
    // (canonical-reference.md §9.2, §10.3; gotchas.md #8)
    // Spec: x0 is always 0. Writes to x0 must be suppressed by the
    //       register file (wr_addr_i=0 → no write). reg_write_o=1 from
    //       the decoder (ADDI with rd=x0 is a valid NOP-class instr) but
    //       the regfile must ignore the write.
    // ==================================================================
    $display("\n--- Group 7: x0 write suppression ---");

    // ------------------------------------------------------------------
    // Step 1: Attempt to write x0 via ADDI x0, x0, 99
    // Spec (§1.2): rd=x0, rs1=x0, imm=99 → decoder sets reg_write=1
    //   but regfile suppresses write to x0
    // The decoder output reg_write_o=1 is expected (decoder doesn't gate x0)
    // Encoding: {12'd99, rs1=x0, F3_ADD_SUB, rd=x0, OP_IMM}
    // Expected: alu_result_o=99 (correct ALU result), reg_write_o=1,
    //           rd_addr_o=0 (gating: reg_write=1 so rd_addr=instr[11:7]=0)
    // ------------------------------------------------------------------
    @(negedge clk);
    instr_i = enc_addi(12'd99, 5'd0, 5'd0);
    #1;
    // Check alu_result and reg_write; rd_addr_o=0 because rd=x0 (not gating, actual address)
    check_result("ADDI x0,x0,99 (alu=99, rw=1, rd=0)",
                 alu_result_o, 32'd99,
                 reg_write_o,  1'b1,
                 rd_addr_o,    5'd0);
    @(posedge clk); #1; // attempted write to x0 (regfile suppresses)

    // ------------------------------------------------------------------
    // Step 2: Read back x0 via ADD x1, x0, x0
    // Spec (§9.2): x0 always 0 after reset; writes suppressed
    //   rs1=x0=0, rs2=x0=0 → 0 + 0 = 0
    // If x0 suppression works: alu_result_o = 0
    // If x0 suppression FAILS: alu_result_o = 99 (previous ADDI value leaked)
    // Encoding: {F7_ZERO, rs2=x0, rs1=x0, F3_ADD_SUB, rd=x1, OP_OP}
    // ------------------------------------------------------------------
    @(negedge clk);
    instr_i = enc_rtype(F7_ZERO, 5'd0, 5'd0, F3_ADD_SUB, 5'd1);
    #1;
    check_result("ADD x1,x0,x0  (x0 suppressed: 0+0=0)",
                 alu_result_o, 32'd0,
                 reg_write_o,  1'b1,
                 rd_addr_o,    5'd1);
    @(posedge clk); #1;

    // ==================================================================
    // SUMMARY
    // ==================================================================
    $display("\n============================================================");
    $display("Testbench complete: %0d PASS, %0d FAIL", pass_count, fail_count);
    if (fail_count == 0)
      $display("ALL TESTS PASSED");
    else
      $display("FAILURES DETECTED — see [FAIL] lines above");
    $display("============================================================\n");

    $finish;
  end

endmodule
