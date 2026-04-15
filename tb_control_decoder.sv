// ============================================================================
// Module: tb_control_decoder
// Description: Self-checking testbench for control_decoder.sv.
//              Expected values derived EXCLUSIVELY from:
//                canonical-reference.md §2 (opcode map)
//                canonical-reference.md §4 (immediate types)
//                canonical-reference.md §6 (control signal truth table)
//                canonical-reference.md §9.1 (halt/illegal_instr semantics)
//              Never reads RTL for expected values.
// Author: Beaux Cable
// Date: April 2026
// Project: TSI RV32I Pipelined Processor (TSMC 180nm)
// ============================================================================
//
// Coverage:
//   1. Normal operation  — all 12 valid opcodes from §2 opcode map
//   2. All instruction types — R, I-ALU, Load, Store, Branch, JAL, JALR,
//                              LUI, AUIPC, FENCE, SYSTEM, CUSTOM-0
//   3. Boundary / edge  — multiple illegal opcodes (not just default=all-1s),
//                         halt_o=0 for all non-SYSTEM instructions,
//                         illegal_instr_o=0 for all valid opcodes
//   4. x0 special cases — inst[19:15]=0 and inst[11:7]=0 (R-type to x0)
//   5. Illegal opcodes  — 7 distinct illegal patterns across the opcode space
//
// Don't-care policy:
//   §6.3 marks several signals "x" for specific opcodes
//   (mem_to_reg for STORE/BRANCH/FENCE/SYSTEM, alu_src for FENCE/SYSTEM,
//    imm_type for R-type/CUSTOM-0/FENCE/SYSTEM).
//   These are NOT checked for those opcodes — the spec does not constrain them.
//   A comment "// DC" marks each skipped check.
//
// Stimulus timing: inputs driven at @(negedge clk) per gotchas.md §11.
// DUT is combinational — output checked 1ns after input settles (#1).
// ============================================================================

`timescale 1ns/1ps

module tb_control_decoder;

  // --------------------------------------------------------------------------
  // Clock
  // --------------------------------------------------------------------------
  logic clk;
  initial clk = 1'b0;
  always #10 clk = ~clk; // 50 MHz

  // --------------------------------------------------------------------------
  // DUT ports
  // --------------------------------------------------------------------------
  logic [31:0] inst_i;

  logic        reg_write_o;
  logic        alu_src_o;
  logic [ 1:0] alu_src_a_o;
  logic        mem_read_o;
  logic        mem_write_o;
  logic        mem_to_reg_o;
  logic        branch_o;
  logic        jump_o;
  logic        jalr_o;
  logic [ 2:0] imm_type_o;
  logic [ 1:0] alu_op_o;
  logic        halt_o;
  logic        illegal_instr_o;

  // --------------------------------------------------------------------------
  // DUT instantiation
  // --------------------------------------------------------------------------
  control_decoder dut (
    .inst_i          (inst_i),
    .reg_write_o     (reg_write_o),
    .alu_src_o       (alu_src_o),
    .alu_src_a_o     (alu_src_a_o),
    .mem_read_o      (mem_read_o),
    .mem_write_o     (mem_write_o),
    .mem_to_reg_o    (mem_to_reg_o),
    .branch_o        (branch_o),
    .jump_o          (jump_o),
    .jalr_o          (jalr_o),
    .imm_type_o      (imm_type_o),
    .alu_op_o        (alu_op_o),
    .halt_o          (halt_o),
    .illegal_instr_o (illegal_instr_o)
  );

  // --------------------------------------------------------------------------
  // Test infrastructure
  // --------------------------------------------------------------------------
  int pass_count;
  int fail_count;
  string current_test;

  // Build a 32-bit instruction from its fields.
  // For control_decoder, only inst_i[6:0] (opcode) is architecturally decoded
  // at the opcode level.  Other fields are passed through to downstream modules.
  // We populate realistic fields so the full word can double as functional
  // stimulus in future integration tests, but the decoder only muxes on opcode.
  function automatic logic [31:0] make_rtype(
    input logic [6:0] op,
    input logic [4:0] rd,
    input logic [2:0] funct3,
    input logic [4:0] rs1,
    input logic [4:0] rs2,
    input logic [6:0] funct7
  );
    return {funct7, rs2, rs1, funct3, rd, op};
  endfunction

  function automatic logic [31:0] make_itype(
    input logic [6:0] op,
    input logic [4:0] rd,
    input logic [2:0] funct3,
    input logic [4:0] rs1,
    input logic [11:0] imm12
  );
    return {imm12, rs1, funct3, rd, op};
  endfunction

  function automatic logic [31:0] make_stype(
    input logic [6:0] op,
    input logic [4:0] rs1,
    input logic [4:0] rs2,
    input logic [2:0] funct3,
    input logic [11:0] imm12
  );
    // imm[11:5] -> [31:25], imm[4:0] -> [11:7]
    return {imm12[11:5], rs2, rs1, funct3, imm12[4:0], op};
  endfunction

  function automatic logic [31:0] make_btype(
    input logic [6:0] op,
    input logic [4:0] rs1,
    input logic [4:0] rs2,
    input logic [2:0] funct3,
    input logic [12:1] imm  // imm[0] implicit 0
  );
    // B-type bit layout (§3): [31]=imm[12] [30:25]=imm[10:5]
    //                          [11:8]=imm[4:1] [7]=imm[11]
    return {imm[12], imm[10:5], rs2, rs1, funct3,
            imm[4:1], imm[11], op};
  endfunction

  function automatic logic [31:0] make_utype(
    input logic [6:0] op,
    input logic [4:0] rd,
    input logic [31:12] imm_upper
  );
    return {imm_upper, rd, op};
  endfunction

  function automatic logic [31:0] make_jtype(
    input logic [6:0] op,
    input logic [4:0] rd,
    input logic [20:1] imm  // imm[0] implicit 0
  );
    // J-type bit layout (§3): [31]=imm[20] [30:21]=imm[10:1]
    //                          [20]=imm[11] [19:12]=imm[19:12]
    return {imm[20], imm[10:1], imm[11], imm[19:12], rd, op};
  endfunction

  // --------------------------------------------------------------------------
  // check_signal — helper for individual signal assertions
  // --------------------------------------------------------------------------
  task automatic check_signal(
    input string   sig_name,
    input logic [3:0] got,
    input logic [3:0] exp,
    input int          width
  );
    logic [3:0] mask;
    mask = (width == 1) ? 4'b0001 :
           (width == 2) ? 4'b0011 : 4'b1111;
    if ((got & mask) !== (exp & mask)) begin
      $display("  FAIL [%s] %s: got %0b, exp %0b",
               current_test, sig_name, got & mask, exp & mask);
      fail_count++;
    end else begin
      pass_count++;
    end
  endtask

  // --------------------------------------------------------------------------
  // check_opcode — verify all deterministic control signals for one opcode.
  //
  // Signals with "x" (don't-care) in §6.3 are passed as 1'bx / 2'bxx / 3'bxxx
  // and skipped when the top bit of the expected value is X.
  //
  // Parameters match §6.1 ordering.
  //   reg_write  : 1-bit
  //   mem_read   : 1-bit
  //   mem_write  : 1-bit
  //   mem_to_reg : 1-bit  (pass 1'bx = don't care)
  //   alu_src    : 1-bit  (pass 1'bx = don't care)
  //   alu_src_a  : 2-bit  (00=rs1, 01=PC, 10=zero)
  //   branch     : 1-bit
  //   jump       : 1-bit
  //   jalr       : 1-bit
  //   imm_type   : 3-bit  (pass 3'bxxx = don't care)
  //   alu_op     : 2-bit
  //   halt       : 1-bit
  //   illegal    : 1-bit
  // --------------------------------------------------------------------------
  task automatic check_opcode(
    input string      label,
    input logic [31:0] inst,
    input logic        exp_reg_write,
    input logic        exp_mem_read,
    input logic        exp_mem_write,
    input logic        exp_mem_to_reg,   // 1'bx = don't care
    input logic        exp_alu_src,      // 1'bx = don't care
    input logic [ 1:0] exp_alu_src_a,
    input logic        exp_branch,
    input logic        exp_jump,
    input logic        exp_jalr,
    input logic [ 2:0] exp_imm_type,     // 3'bxxx = don't care
    input logic [ 1:0] exp_alu_op,
    input logic        exp_halt,
    input logic        exp_illegal
  );
    current_test = label;

    // Drive stimulus at negedge per gotchas.md #11
    @(negedge clk);
    inst_i = inst;
    #1; // combinational settle

    // -- Deterministic checks (always verified) -------------------------
    check_signal("reg_write",     {3'b0, reg_write_o},
                                  {3'b0, exp_reg_write},     1);
    check_signal("mem_read",      {3'b0, mem_read_o},
                                  {3'b0, exp_mem_read},      1);
    check_signal("mem_write",     {3'b0, mem_write_o},
                                  {3'b0, exp_mem_write},     1);
    check_signal("branch",        {3'b0, branch_o},
                                  {3'b0, exp_branch},        1);
    check_signal("jump",          {3'b0, jump_o},
                                  {3'b0, exp_jump},          1);
    check_signal("jalr",          {3'b0, jalr_o},
                                  {3'b0, exp_jalr},          1);
    check_signal("halt",          {3'b0, halt_o},
                                  {3'b0, exp_halt},          1);
    check_signal("illegal_instr", {3'b0, illegal_instr_o},
                                  {3'b0, exp_illegal},       1);

    // -- Don't-care conditional checks ----------------------------------
    // All use 4-state X propagation (IEEE 1800-2017 §11.4.9):
    //   XOR-reduction of an all-X value produces X; !== X detects it.
    //   Single-bit fields use direct === 1'bx test.
    // These guards require 4-state simulation; 2-state mode would break them.

    // mem_to_reg: skip when exp_mem_to_reg === 1'bx
    if (exp_mem_to_reg !== 1'bx)
      check_signal("mem_to_reg",  {3'b0, mem_to_reg_o},
                                  {3'b0, exp_mem_to_reg},   1);

    // alu_src: skip when exp_alu_src === 1'bx
    if (exp_alu_src !== 1'bx)
      check_signal("alu_src",     {3'b0, alu_src_o},
                                  {3'b0, exp_alu_src},      1);

    // alu_src_a: skip when any bit is X (2'bxx) — §6.3 does not
    // constrain alu_src_a for illegal instructions
    if (^exp_alu_src_a !== 1'bx)
      check_signal("alu_src_a",   {2'b0, alu_src_a_o},
                                  {2'b0, exp_alu_src_a},    2);

    // imm_type: skip when any bit is X (3'bxxx)
    if (^exp_imm_type !== 1'bx)
      check_signal("imm_type",    {1'b0, imm_type_o},
                                  {1'b0, exp_imm_type},     3);

    // alu_op: skip when any bit is X (2'bxx) — §6.3 does not constrain
    // alu_op for illegal instructions
    if (^exp_alu_op !== 1'bx)
      check_signal("alu_op",      {2'b0, alu_op_o},
                                  {2'b0, exp_alu_op},       2);

  endtask

  // --------------------------------------------------------------------------
  // Main test sequence
  // --------------------------------------------------------------------------
  initial begin
    pass_count = 0;
    fail_count = 0;
    inst_i     = 32'h0;

    // Wait one full clock for simulator to settle
    @(posedge clk);
    #1;

    // ========================================================================
    // GROUP 1: R-type  (opcode = 0110011)
    // §6.3: reg_write=1, mem_read=0, mem_write=0, mem_to_reg=0,
    //        alu_src=0, alu_src_a=00, branch=0, jump=0, jalr=0,
    //        alu_op=10(R), halt=0, illegal=0.
    //        imm_type is don't-care for R-type (no immediate used).
    // ========================================================================

    // ADD x1, x2, x3  — funct7=0000000, funct3=000
    check_opcode("R-type ADD",
      make_rtype(7'b0110011, 5'd1, 3'b000, 5'd2, 5'd3, 7'b0000000),
      1'b1,   // reg_write
      1'b0,   // mem_read
      1'b0,   // mem_write
      1'b0,   // mem_to_reg
      1'b0,   // alu_src
      2'b00,  // alu_src_a = rs1
      1'b0,   // branch
      1'b0,   // jump
      1'b0,   // jalr
      3'bxxx, // imm_type (DC — R-type)
      2'b10,  // alu_op = R-type
      1'b0,   // halt
      1'b0    // illegal
    );

    // SUB x4, x5, x6  — funct7=0100000, funct3=000
    check_opcode("R-type SUB",
      make_rtype(7'b0110011, 5'd4, 3'b000, 5'd5, 5'd6, 7'b0100000),
      1'b1, 1'b0, 1'b0, 1'b0,
      1'b0, 2'b00, 1'b0, 1'b0, 1'b0,
      3'bxxx, 2'b10, 1'b0, 1'b0
    );

    // AND x7, x8, x9  — funct7=0000000, funct3=111
    check_opcode("R-type AND",
      make_rtype(7'b0110011, 5'd7, 3'b111, 5'd8, 5'd9, 7'b0000000),
      1'b1, 1'b0, 1'b0, 1'b0,
      1'b0, 2'b00, 1'b0, 1'b0, 1'b0,
      3'bxxx, 2'b10, 1'b0, 1'b0
    );

    // OR  x10, x11, x12 — funct3=110
    check_opcode("R-type OR",
      make_rtype(7'b0110011, 5'd10, 3'b110, 5'd11, 5'd12, 7'b0000000),
      1'b1, 1'b0, 1'b0, 1'b0,
      1'b0, 2'b00, 1'b0, 1'b0, 1'b0,
      3'bxxx, 2'b10, 1'b0, 1'b0
    );

    // SLL  (funct3=001)
    check_opcode("R-type SLL",
      make_rtype(7'b0110011, 5'd1, 3'b001, 5'd2, 5'd3, 7'b0000000),
      1'b1, 1'b0, 1'b0, 1'b0,
      1'b0, 2'b00, 1'b0, 1'b0, 1'b0,
      3'bxxx, 2'b10, 1'b0, 1'b0
    );

    // SLT  (funct3=010)
    check_opcode("R-type SLT",
      make_rtype(7'b0110011, 5'd1, 3'b010, 5'd2, 5'd3, 7'b0000000),
      1'b1, 1'b0, 1'b0, 1'b0,
      1'b0, 2'b00, 1'b0, 1'b0, 1'b0,
      3'bxxx, 2'b10, 1'b0, 1'b0
    );

    // SRA  (funct3=101, funct7=0100000)
    check_opcode("R-type SRA",
      make_rtype(7'b0110011, 5'd1, 3'b101, 5'd2, 5'd3, 7'b0100000),
      1'b1, 1'b0, 1'b0, 1'b0,
      1'b0, 2'b00, 1'b0, 1'b0, 1'b0,
      3'bxxx, 2'b10, 1'b0, 1'b0
    );

    // Edge: R-type writing to x0 — reg_write still 1 (decoder doesn't suppress;
    // register file suppresses at write port per §7.3 / gotchas.md #8).
    check_opcode("R-type x0 dst",
      make_rtype(7'b0110011, 5'd0, 3'b000, 5'd1, 5'd2, 7'b0000000),
      1'b1, 1'b0, 1'b0, 1'b0,
      1'b0, 2'b00, 1'b0, 1'b0, 1'b0,
      3'bxxx, 2'b10, 1'b0, 1'b0
    );

    // ========================================================================
    // GROUP 2: I-type ALU  (opcode = 0010011)
    // §6.3: reg_write=1, mem_read=0, mem_write=0, mem_to_reg=0,
    //        alu_src=1, alu_src_a=00, branch=0, jump=0, jalr=0,
    //        imm_type=000(I), alu_op=11(I-type), halt=0, illegal=0.
    // ========================================================================

    // ADDI x1, x2, 42
    check_opcode("I-ALU ADDI",
      make_itype(7'b0010011, 5'd1, 3'b000, 5'd2, 12'd42),
      1'b1, 1'b0, 1'b0, 1'b0,
      1'b1, 2'b00, 1'b0, 1'b0, 1'b0,
      3'b000, 2'b11, 1'b0, 1'b0
    );

    // SLTI x1, x2, -1  (imm = 12'hFFF = sign-extended -1)
    check_opcode("I-ALU SLTI",
      make_itype(7'b0010011, 5'd1, 3'b010, 5'd2, 12'hFFF),
      1'b1, 1'b0, 1'b0, 1'b0,
      1'b1, 2'b00, 1'b0, 1'b0, 1'b0,
      3'b000, 2'b11, 1'b0, 1'b0
    );

    // SLTIU x3, x4, 1
    check_opcode("I-ALU SLTIU",
      make_itype(7'b0010011, 5'd3, 3'b011, 5'd4, 12'd1),
      1'b1, 1'b0, 1'b0, 1'b0,
      1'b1, 2'b00, 1'b0, 1'b0, 1'b0,
      3'b000, 2'b11, 1'b0, 1'b0
    );

    // XORI x5, x6, -1  (NOT pattern: §1.2)
    check_opcode("I-ALU XORI",
      make_itype(7'b0010011, 5'd5, 3'b100, 5'd6, 12'hFFF),
      1'b1, 1'b0, 1'b0, 1'b0,
      1'b1, 2'b00, 1'b0, 1'b0, 1'b0,
      3'b000, 2'b11, 1'b0, 1'b0
    );

    // ORI x7, x8, 0xFF
    check_opcode("I-ALU ORI",
      make_itype(7'b0010011, 5'd7, 3'b110, 5'd8, 12'hFF),
      1'b1, 1'b0, 1'b0, 1'b0,
      1'b1, 2'b00, 1'b0, 1'b0, 1'b0,
      3'b000, 2'b11, 1'b0, 1'b0
    );

    // ANDI x9, x10, 0x0F
    check_opcode("I-ALU ANDI",
      make_itype(7'b0010011, 5'd9, 3'b111, 5'd10, 12'h0F),
      1'b1, 1'b0, 1'b0, 1'b0,
      1'b1, 2'b00, 1'b0, 1'b0, 1'b0,
      3'b000, 2'b11, 1'b0, 1'b0
    );

    // SLLI x1, x2, 7  (imm[11:5]=0000000)
    check_opcode("I-ALU SLLI",
      make_itype(7'b0010011, 5'd1, 3'b001, 5'd2, {7'b0000000, 5'd7}),
      1'b1, 1'b0, 1'b0, 1'b0,
      1'b1, 2'b00, 1'b0, 1'b0, 1'b0,
      3'b000, 2'b11, 1'b0, 1'b0
    );

    // SRLI x1, x2, 3  (imm[11:5]=0000000)
    check_opcode("I-ALU SRLI",
      make_itype(7'b0010011, 5'd1, 3'b101, 5'd2, {7'b0000000, 5'd3}),
      1'b1, 1'b0, 1'b0, 1'b0,
      1'b1, 2'b00, 1'b0, 1'b0, 1'b0,
      3'b000, 2'b11, 1'b0, 1'b0
    );

    // SRAI x1, x2, 3  (imm[11:5]=0100000)
    check_opcode("I-ALU SRAI",
      make_itype(7'b0010011, 5'd1, 3'b101, 5'd2, {7'b0100000, 5'd3}),
      1'b1, 1'b0, 1'b0, 1'b0,
      1'b1, 2'b00, 1'b0, 1'b0, 1'b0,
      3'b000, 2'b11, 1'b0, 1'b0
    );

    // NOP = ADDI x0, x0, 0  (§11 verification anchor)
    check_opcode("I-ALU NOP (ADDI x0,x0,0)",
      32'h00000013,
      1'b1, 1'b0, 1'b0, 1'b0,
      1'b1, 2'b00, 1'b0, 1'b0, 1'b0,
      3'b000, 2'b11, 1'b0, 1'b0
    );

    // ========================================================================
    // GROUP 3: LOAD  (opcode = 0000011)
    // §6.3: reg_write=1, mem_read=1, mem_write=0, mem_to_reg=1,
    //        alu_src=1, alu_src_a=00, branch=0, jump=0, jalr=0,
    //        imm_type=000(I), alu_op=00(ADD), halt=0, illegal=0.
    // ========================================================================

    // LW x1, 4(x2)
    check_opcode("LOAD LW",
      make_itype(7'b0000011, 5'd1, 3'b010, 5'd2, 12'd4),
      1'b1, 1'b1, 1'b0, 1'b1,
      1'b1, 2'b00, 1'b0, 1'b0, 1'b0,
      3'b000, 2'b00, 1'b0, 1'b0
    );

    // LB x3, -1(x4)
    check_opcode("LOAD LB",
      make_itype(7'b0000011, 5'd3, 3'b000, 5'd4, 12'hFFF),
      1'b1, 1'b1, 1'b0, 1'b1,
      1'b1, 2'b00, 1'b0, 1'b0, 1'b0,
      3'b000, 2'b00, 1'b0, 1'b0
    );

    // LH x5, 2(x6)
    check_opcode("LOAD LH",
      make_itype(7'b0000011, 5'd5, 3'b001, 5'd6, 12'd2),
      1'b1, 1'b1, 1'b0, 1'b1,
      1'b1, 2'b00, 1'b0, 1'b0, 1'b0,
      3'b000, 2'b00, 1'b0, 1'b0
    );

    // LBU x7, 0(x8)
    check_opcode("LOAD LBU",
      make_itype(7'b0000011, 5'd7, 3'b100, 5'd8, 12'd0),
      1'b1, 1'b1, 1'b0, 1'b1,
      1'b1, 2'b00, 1'b0, 1'b0, 1'b0,
      3'b000, 2'b00, 1'b0, 1'b0
    );

    // LHU x9, 100(x10)
    check_opcode("LOAD LHU",
      make_itype(7'b0000011, 5'd9, 3'b101, 5'd10, 12'd100),
      1'b1, 1'b1, 1'b0, 1'b1,
      1'b1, 2'b00, 1'b0, 1'b0, 1'b0,
      3'b000, 2'b00, 1'b0, 1'b0
    );

    // ========================================================================
    // GROUP 4: STORE  (opcode = 0100011)
    // §6.3: reg_write=0, mem_read=0, mem_write=1, mem_to_reg=x(DC),
    //        alu_src=1, alu_src_a=00, branch=0, jump=0, jalr=0,
    //        imm_type=001(S), alu_op=00(ADD), halt=0, illegal=0.
    // ========================================================================

    // SW x2, 8(x1)
    check_opcode("STORE SW",
      make_stype(7'b0100011, 5'd1, 5'd2, 3'b010, 12'd8),
      1'b0, 1'b0, 1'b1, 1'bx,  // mem_to_reg DC
      1'b1, 2'b00, 1'b0, 1'b0, 1'b0,
      3'b001, 2'b00, 1'b0, 1'b0
    );

    // SB x4, -4(x3)
    check_opcode("STORE SB",
      make_stype(7'b0100011, 5'd3, 5'd4, 3'b000, 12'hFFC),
      1'b0, 1'b0, 1'b1, 1'bx,
      1'b1, 2'b00, 1'b0, 1'b0, 1'b0,
      3'b001, 2'b00, 1'b0, 1'b0
    );

    // SH x6, 2(x5)
    check_opcode("STORE SH",
      make_stype(7'b0100011, 5'd5, 5'd6, 3'b001, 12'd2),
      1'b0, 1'b0, 1'b1, 1'bx,
      1'b1, 2'b00, 1'b0, 1'b0, 1'b0,
      3'b001, 2'b00, 1'b0, 1'b0
    );

    // ========================================================================
    // GROUP 5: BRANCH  (opcode = 1100011)
    // §6.3: reg_write=0, mem_read=0, mem_write=0, mem_to_reg=x(DC),
    //        alu_src=0, alu_src_a=00, branch=1, jump=0, jalr=0,
    //        imm_type=010(B), alu_op=01(BRANCH), halt=0, illegal=0.
    // ========================================================================

    // BEQ x1, x2, +16  (funct3=000; imm[12:1]=0x008, offset={imm,1'b0}=+16)
    check_opcode("BRANCH BEQ",
      make_btype(7'b1100011, 5'd1, 5'd2, 3'b000, 12'h008),
      1'b0, 1'b0, 1'b0, 1'bx,  // mem_to_reg DC
      1'b0, 2'b00, 1'b1, 1'b0, 1'b0,
      3'b010, 2'b01, 1'b0, 1'b0
    );

    // BNE x3, x4, +32  (funct3=001; imm[12:1]=0x010, offset={imm,1'b0}=+32)
    check_opcode("BRANCH BNE",
      make_btype(7'b1100011, 5'd3, 5'd4, 3'b001, 12'h010),
      1'b0, 1'b0, 1'b0, 1'bx,
      1'b0, 2'b00, 1'b1, 1'b0, 1'b0,
      3'b010, 2'b01, 1'b0, 1'b0
    );

    // BLT x5, x6, -16  (funct3=100; imm[12:1]=0xFF8, offset={imm,1'b0}=-16)
    check_opcode("BRANCH BLT",
      make_btype(7'b1100011, 5'd5, 5'd6, 3'b100, 12'hFF8),
      1'b0, 1'b0, 1'b0, 1'bx,
      1'b0, 2'b00, 1'b1, 1'b0, 1'b0,
      3'b010, 2'b01, 1'b0, 1'b0
    );

    // BGE x7, x8, +8  (funct3=101; imm[12:1]=0x004, offset={imm,1'b0}=+8)
    check_opcode("BRANCH BGE",
      make_btype(7'b1100011, 5'd7, 5'd8, 3'b101, 12'h004),
      1'b0, 1'b0, 1'b0, 1'bx,
      1'b0, 2'b00, 1'b1, 1'b0, 1'b0,
      3'b010, 2'b01, 1'b0, 1'b0
    );

    // BLTU x9, x10, +8  (funct3=110; imm[12:1]=0x004, offset={imm,1'b0}=+8)
    check_opcode("BRANCH BLTU",
      make_btype(7'b1100011, 5'd9, 5'd10, 3'b110, 12'h004),
      1'b0, 1'b0, 1'b0, 1'bx,
      1'b0, 2'b00, 1'b1, 1'b0, 1'b0,
      3'b010, 2'b01, 1'b0, 1'b0
    );

    // BGEU x11, x12, +8  (funct3=111; imm[12:1]=0x004, offset={imm,1'b0}=+8)
    check_opcode("BRANCH BGEU",
      make_btype(7'b1100011, 5'd11, 5'd12, 3'b111, 12'h004),
      1'b0, 1'b0, 1'b0, 1'bx,
      1'b0, 2'b00, 1'b1, 1'b0, 1'b0,
      3'b010, 2'b01, 1'b0, 1'b0
    );

    // ========================================================================
    // GROUP 6: JAL  (opcode = 1101111)
    // §6.3: reg_write=1, mem_read=0, mem_write=0, mem_to_reg=0,
    //        alu_src=1, alu_src_a=01(PC), branch=0, jump=1, jalr=0,
    //        imm_type=100(J), alu_op=00(ADD), halt=0, illegal=0.
    // §1.6: rd = PC+4; PC += sext(J-imm)
    // ========================================================================

    // JAL x1, +8  (unconditional jump forward; imm[20:1]=0x00004, offset={imm,1'b0}=+8)
    check_opcode("JAL",
      make_jtype(7'b1101111, 5'd1, 20'h00004),
      1'b1, 1'b0, 1'b0, 1'b0,
      1'b1, 2'b01, 1'b0, 1'b1, 1'b0,  // alu_src_a=01 (PC)
      3'b100, 2'b00, 1'b0, 1'b0
    );

    // JAL x0, +0  (branch-to-self; x0 link — decoder still sets reg_write=1,
    //              suppression is regfile's job per gotchas.md #8)
    check_opcode("JAL x0 (decoder reg_write=1, regfile suppresses x0)",
      make_jtype(7'b1101111, 5'd0, 20'h00000),
      1'b1, 1'b0, 1'b0, 1'b0,
      1'b1, 2'b01, 1'b0, 1'b1, 1'b0,
      3'b100, 2'b00, 1'b0, 1'b0
    );

    // ========================================================================
    // GROUP 7: JALR  (opcode = 1100111)
    // §6.3: reg_write=1, mem_read=0, mem_write=0, mem_to_reg=0,
    //        alu_src=1, alu_src_a=00(rs1), branch=0, jump=1, jalr=1,
    //        imm_type=000(I), alu_op=00(ADD), halt=0, illegal=0.
    // §1.6: target = (rs1 + sext(imm)) & ~1  (LSB clear in datapath)
    // ========================================================================

    // JALR x1, x2, 0
    check_opcode("JALR",
      make_itype(7'b1100111, 5'd1, 3'b000, 5'd2, 12'd0),
      1'b1, 1'b0, 1'b0, 1'b0,
      1'b1, 2'b00, 1'b0, 1'b1, 1'b1,  // alu_src_a=00 (rs1), jalr=1
      3'b000, 2'b00, 1'b0, 1'b0
    );

    // JALR x0, x1, 4  (function call return variant)
    check_opcode("JALR x0 (discard link)",
      make_itype(7'b1100111, 5'd0, 3'b000, 5'd1, 12'd4),
      1'b1, 1'b0, 1'b0, 1'b0,
      1'b1, 2'b00, 1'b0, 1'b1, 1'b1,
      3'b000, 2'b00, 1'b0, 1'b0
    );

    // ========================================================================
    // GROUP 8: LUI  (opcode = 0110111)
    // §6.3: reg_write=1, mem_read=0, mem_write=0, mem_to_reg=0,
    //        alu_src=1, alu_src_a=10(zero), branch=0, jump=0, jalr=0,
    //        imm_type=011(U), alu_op=00(ADD), halt=0, illegal=0.
    // §6.3 note: ALU computes 0 + U-imm = U-imm  (alu_src_a=10=zero)
    // ========================================================================

    // LUI x1, 0xDEADB  (§11 anchor)
    check_opcode("LUI 0xDEADB",
      make_utype(7'b0110111, 5'd1, 20'hDEADB),
      1'b1, 1'b0, 1'b0, 1'b0,
      1'b1, 2'b10, 1'b0, 1'b0, 1'b0,  // alu_src_a=10 (zero)
      3'b011, 2'b00, 1'b0, 1'b0
    );

    // LUI x0, 0xFFFFF  (boundary: all-1s upper imm)
    check_opcode("LUI all-1s imm",
      make_utype(7'b0110111, 5'd0, 20'hFFFFF),
      1'b1, 1'b0, 1'b0, 1'b0,
      1'b1, 2'b10, 1'b0, 1'b0, 1'b0,
      3'b011, 2'b00, 1'b0, 1'b0
    );

    // LUI x31, 0x00001  (boundary: all-0s upper imm with small nonzero)
    check_opcode("LUI small imm",
      make_utype(7'b0110111, 5'd31, 20'h00001),
      1'b1, 1'b0, 1'b0, 1'b0,
      1'b1, 2'b10, 1'b0, 1'b0, 1'b0,
      3'b011, 2'b00, 1'b0, 1'b0
    );

    // ========================================================================
    // GROUP 9: AUIPC  (opcode = 0010111)
    // §6.3: reg_write=1, mem_read=0, mem_write=0, mem_to_reg=0,
    //        alu_src=1, alu_src_a=01(PC), branch=0, jump=0, jalr=0,
    //        imm_type=011(U), alu_op=00(ADD), halt=0, illegal=0.
    // §1.7 / gotchas.md #7: uses current PC, not PC+4
    // ========================================================================

    // AUIPC x1, 0x12345  (§11 anchor operand)
    check_opcode("AUIPC 0x12345",
      make_utype(7'b0010111, 5'd1, 20'h12345),
      1'b1, 1'b0, 1'b0, 1'b0,
      1'b1, 2'b01, 1'b0, 1'b0, 1'b0,  // alu_src_a=01 (PC)
      3'b011, 2'b00, 1'b0, 1'b0
    );

    // AUIPC x5, 0x00000  (add 0 to PC — boundary)
    check_opcode("AUIPC zero imm",
      make_utype(7'b0010111, 5'd5, 20'h00000),
      1'b1, 1'b0, 1'b0, 1'b0,
      1'b1, 2'b01, 1'b0, 1'b0, 1'b0,
      3'b011, 2'b00, 1'b0, 1'b0
    );

    // ========================================================================
    // GROUP 10: FENCE  (opcode = 0001111)
    // §6.3: reg_write=0, mem_read=0, mem_write=0, mem_to_reg=x(DC),
    //        alu_src=x(DC), alu_src_a=00, branch=0, jump=0, jalr=0,
    //        imm_type=xxx(DC), alu_op=00(ADD), halt=0, illegal=0.
    // §1.8: single-hart system — FENCE is a NOP
    // ========================================================================

    // FENCE (canonical encoding per §1.8: funct3=000)
    check_opcode("FENCE",
      make_itype(7'b0001111, 5'd0, 3'b000, 5'd0, 12'h0FF),
      1'b0, 1'b0, 1'b0, 1'bx,  // mem_to_reg DC
      1'bx, 2'b00, 1'b0, 1'b0, 1'b0,  // alu_src DC
      3'bxxx, 2'b00, 1'b0, 1'b0  // imm_type DC
    );

    // ========================================================================
    // GROUP 11: SYSTEM — ECALL / EBREAK  (opcode = 1110011)
    // §6.3: reg_write=0, mem_read=0, mem_write=0, mem_to_reg=x(DC),
    //        alu_src=x(DC), alu_src_a=00, branch=0, jump=0, jalr=0,
    //        imm_type=xxx(DC), alu_op=00(ADD), halt=1, illegal=0.
    // §2: "ECALL/EBREAK → halt_o = 1 (not illegal_instr_o)"
    // §9.1: halt output pin asserted
    // ========================================================================

    // ECALL: funct3=000, imm[11:0]=000000000000
    check_opcode("SYSTEM ECALL",
      make_itype(7'b1110011, 5'd0, 3'b000, 5'd0, 12'h000),
      1'b0, 1'b0, 1'b0, 1'bx,
      1'bx, 2'b00, 1'b0, 1'b0, 1'b0,
      3'bxxx, 2'b00, 1'b1, 1'b0  // halt=1, illegal=0
    );

    // EBREAK: funct3=000, imm[11:0]=000000000001
    check_opcode("SYSTEM EBREAK",
      make_itype(7'b1110011, 5'd0, 3'b000, 5'd0, 12'h001),
      1'b0, 1'b0, 1'b0, 1'bx,
      1'bx, 2'b00, 1'b0, 1'b0, 1'b0,
      3'bxxx, 2'b00, 1'b1, 1'b0  // halt=1, illegal=0
    );

    // ========================================================================
    // GROUP 12: CUSTOM-0  (opcode = 0001011, R-type format)
    // §8.1: POPCOUNT, BREV, BEXT, BDEP — R-type layout.
    // §2 opcode map lists CUSTOM-0 as a valid opcode.
    // Expected: reg_write=1, alu_src=0(rs2), alu_src_a=00,
    //           mem_read=0, mem_write=0, mem_to_reg=0,
    //           branch=0, jump=0, jalr=0,
    //           imm_type=xxx(DC), alu_op=10(R-type), halt=0, illegal=0.
    // NOTE: §6.3 has no explicit CUSTOM-0 row. These expected values are
    //        inferred from §8.1 which specifies R-type format for CUSTOM-0,
    //        so control signals follow the R-type row of §6.3 by analogy
    //        (alu_src=0, alu_src_a=00, alu_op=10). If the spec adds a
    //        dedicated §6.3 row for CUSTOM-0, update these values to match.
    // ========================================================================

    // POPCOUNT: funct7=0000000, funct3=000
    check_opcode("CUSTOM-0 POPCOUNT",
      make_rtype(7'b0001011, 5'd1, 3'b000, 5'd2, 5'd0, 7'b0000000),
      1'b1, 1'b0, 1'b0, 1'b0,
      1'b0, 2'b00, 1'b0, 1'b0, 1'b0,
      3'bxxx, 2'b10, 1'b0, 1'b0  // alu_op=10(R-type), imm_type DC
    );

    // BREV: funct7=0000001, funct3=000
    check_opcode("CUSTOM-0 BREV",
      make_rtype(7'b0001011, 5'd1, 3'b000, 5'd2, 5'd0, 7'b0000001),
      1'b1, 1'b0, 1'b0, 1'b0,
      1'b0, 2'b00, 1'b0, 1'b0, 1'b0,
      3'bxxx, 2'b10, 1'b0, 1'b0
    );

    // BEXT: funct7=0000010, funct3=000  (binary: uses rs2)
    check_opcode("CUSTOM-0 BEXT",
      make_rtype(7'b0001011, 5'd3, 3'b000, 5'd4, 5'd5, 7'b0000010),
      1'b1, 1'b0, 1'b0, 1'b0,
      1'b0, 2'b00, 1'b0, 1'b0, 1'b0,
      3'bxxx, 2'b10, 1'b0, 1'b0
    );

    // BDEP: funct7=0000011, funct3=000  (binary: uses rs2)
    check_opcode("CUSTOM-0 BDEP",
      make_rtype(7'b0001011, 5'd3, 3'b000, 5'd4, 5'd5, 7'b0000011),
      1'b1, 1'b0, 1'b0, 1'b0,
      1'b0, 2'b00, 1'b0, 1'b0, 1'b0,
      3'bxxx, 2'b10, 1'b0, 1'b0
    );

    // ========================================================================
    // GROUP 13: Illegal opcodes (default case)
    // §2: "Any opcode not in this table → illegal_instr_o = 1"
    // Expected for all: reg_write=0, mem_read=0, mem_write=0, branch=0,
    //                   jump=0, jalr=0, halt=0, illegal=1.
    // We test 7 distinct illegal opcode patterns across the opcode space.
    // ========================================================================

    // Illegal: 7'b0000000 — all zeros (not in §2 table)
    // §6.3 only mandates illegal_instr=1; alu_src_a, alu_op, imm_type,
    // mem_to_reg, alu_src are all unconstrained → don't-care.
    check_opcode("Illegal 0x00",
      {25'h0, 7'b0000000},
      1'b0, 1'b0, 1'b0, 1'bx,
      1'bx, 2'bxx, 1'b0, 1'b0, 1'b0,
      3'bxxx, 2'bxx, 1'b0, 1'b1
    );

    // Illegal: 7'b1111111 — all ones
    check_opcode("Illegal 0x7F",
      {25'h0, 7'b1111111},
      1'b0, 1'b0, 1'b0, 1'bx,
      1'bx, 2'bxx, 1'b0, 1'b0, 1'b0,
      3'bxxx, 2'bxx, 1'b0, 1'b1
    );

    // Illegal: 7'b0101011 — opcode bit pattern not in table
    check_opcode("Illegal 0x2B",
      {25'h0, 7'b0101011},
      1'b0, 1'b0, 1'b0, 1'bx,
      1'bx, 2'bxx, 1'b0, 1'b0, 1'b0,
      3'bxxx, 2'bxx, 1'b0, 1'b1
    );

    // Illegal: 7'b1010101 — alternating bits
    check_opcode("Illegal 0x55",
      {25'h0, 7'b1010101},
      1'b0, 1'b0, 1'b0, 1'bx,
      1'bx, 2'bxx, 1'b0, 1'b0, 1'b0,
      3'bxxx, 2'bxx, 1'b0, 1'b1
    );

    // Illegal: 7'b0111111 — adjacent to valid R-type 0110011
    check_opcode("Illegal 0x3F (near R-type)",
      {25'h0, 7'b0111111},
      1'b0, 1'b0, 1'b0, 1'bx,
      1'bx, 2'bxx, 1'b0, 1'b0, 1'b0,
      3'bxxx, 2'bxx, 1'b0, 1'b1
    );

    // Illegal: 7'b1100001 — adjacent to valid BRANCH 1100011
    check_opcode("Illegal 0x61 (near BRANCH)",
      {25'h0, 7'b1100001},
      1'b0, 1'b0, 1'b0, 1'bx,
      1'bx, 2'bxx, 1'b0, 1'b0, 1'b0,
      3'bxxx, 2'bxx, 1'b0, 1'b1
    );

    // Illegal: 7'b1110001 — adjacent to valid SYSTEM 1110011
    check_opcode("Illegal 0x71 (near SYSTEM)",
      {25'h0, 7'b1110001},
      1'b0, 1'b0, 1'b0, 1'bx,
      1'bx, 2'bxx, 1'b0, 1'b0, 1'b0,
      3'bxxx, 2'bxx, 1'b0, 1'b1
    );

    // ========================================================================
    // GROUP 14: Cross-group boundary checks
    // Verify halt_o=0 for every non-SYSTEM valid opcode (spot-check 4 cases).
    // Verify illegal_instr_o=0 for every valid opcode (covered in each group).
    // These are explicit re-checks with fresh stimulus to satisfy requirement 5.
    // ========================================================================

    // halt_o must be 0 for R-type (not SYSTEM)
    @(negedge clk);
    inst_i = make_rtype(7'b0110011, 5'd1, 3'b000, 5'd2, 5'd3, 7'b0000000);
    #1;
    current_test = "halt=0 for R-type";
    if (halt_o !== 1'b0) begin
      $display("  FAIL [%s]: halt_o expected 0, got %b", current_test, halt_o);
      fail_count++;
    end else begin
      pass_count++;
    end

    // halt_o must be 0 for JAL
    @(negedge clk);
    inst_i = make_jtype(7'b1101111, 5'd1, 20'h00004);
    #1;
    current_test = "halt=0 for JAL";
    if (halt_o !== 1'b0) begin
      $display("  FAIL [%s]: halt_o expected 0, got %b", current_test, halt_o);
      fail_count++;
    end else begin
      pass_count++;
    end

    // halt_o must be 0 for LOAD
    @(negedge clk);
    inst_i = make_itype(7'b0000011, 5'd1, 3'b010, 5'd2, 12'd0);
    #1;
    current_test = "halt=0 for LOAD";
    if (halt_o !== 1'b0) begin
      $display("  FAIL [%s]: halt_o expected 0, got %b", current_test, halt_o);
      fail_count++;
    end else begin
      pass_count++;
    end

    // halt_o must be 0 for BRANCH
    @(negedge clk);
    inst_i = make_btype(7'b1100011, 5'd1, 5'd2, 3'b000, 12'h008);
    #1;
    current_test = "halt=0 for BRANCH";
    if (halt_o !== 1'b0) begin
      $display("  FAIL [%s]: halt_o expected 0, got %b", current_test, halt_o);
      fail_count++;
    end else begin
      pass_count++;
    end

    // halt_o must be 0 for LUI
    @(negedge clk);
    inst_i = make_utype(7'b0110111, 5'd1, 20'hDEADB);
    #1;
    current_test = "halt=0 for LUI";
    if (halt_o !== 1'b0) begin
      $display("  FAIL [%s]: halt_o expected 0, got %b", current_test, halt_o);
      fail_count++;
    end else begin
      pass_count++;
    end

    // halt_o must be 0 for AUIPC
    @(negedge clk);
    inst_i = make_utype(7'b0010111, 5'd1, 20'h12345);
    #1;
    current_test = "halt=0 for AUIPC";
    if (halt_o !== 1'b0) begin
      $display("  FAIL [%s]: halt_o expected 0, got %b", current_test, halt_o);
      fail_count++;
    end else begin
      pass_count++;
    end

    // halt_o must be 0 for FENCE
    @(negedge clk);
    inst_i = make_itype(7'b0001111, 5'd0, 3'b000, 5'd0, 12'h0FF);
    #1;
    current_test = "halt=0 for FENCE";
    if (halt_o !== 1'b0) begin
      $display("  FAIL [%s]: halt_o expected 0, got %b", current_test, halt_o);
      fail_count++;
    end else begin
      pass_count++;
    end

    // illegal_instr_o must be 0 for SYSTEM (ECALL) — halt, not illegal
    @(negedge clk);
    inst_i = make_itype(7'b1110011, 5'd0, 3'b000, 5'd0, 12'h000);
    #1;
    current_test = "illegal=0 for ECALL (halt, not illegal)";
    if (illegal_instr_o !== 1'b0) begin
      $display("  FAIL [%s]: illegal_instr_o expected 0, got %b",
               current_test, illegal_instr_o);
      fail_count++;
    end else begin
      pass_count++;
    end

    // ========================================================================
    // SUMMARY
    // ========================================================================
    @(negedge clk);
    $display("");
    $display("============================================================");
    $display("tb_control_decoder: %0d tests passed, %0d tests failed.",
             pass_count, fail_count);
    $display("============================================================");
    if (fail_count == 0)
      $display("RESULT: ALL PASS");
    else
      $display("RESULT: FAIL");
    $display("============================================================");

    $finish;
  end

endmodule
