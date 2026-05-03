// ============================================================================
// Module: tb_alu_control
// Description: Self-checking testbench for alu_control.sv.
//              Expected values derived exclusively from:
//                - docs/canonical-reference.md §1.1, §1.2, §5, §6.2
//                - docs/gotchas.md #10, #13
//              NEVER derived from RTL.
// Author: Beaux Cable
// Date: April 2026
// Project: RV32I Pipelined Processor
// ============================================================================

`timescale 1ns/1ps

module tb_alu_control;

  // -------------------------------------------------------------------------
  // Clock and DUT port signals
  // -------------------------------------------------------------------------
  logic       clk;
  logic [1:0] alu_op_i;
  logic [2:0] funct3_i;
  logic       funct7b5_i;
  logic [3:0] alu_ctrl_o;
  logic       illegal_o;

  // Clock: 50 MHz (period = 20 ns)
  always #10 clk = ~clk;

  // -------------------------------------------------------------------------
  // DUT instantiation (explicit port connections, gotchas.md conventions)
  // -------------------------------------------------------------------------
  alu_control dut (
    .alu_op_i   (alu_op_i),
    .funct3_i   (funct3_i),
    .funct7b5_i (funct7b5_i),
    .alu_ctrl_o (alu_ctrl_o),
    .illegal_o  (illegal_o)
  );

  // -------------------------------------------------------------------------
  // ALU control encodings — canonical-reference.md §5
  // -------------------------------------------------------------------------
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

  // alu_op categories — canonical-reference.md §6.2
  localparam logic [1:0] ALUOP_ADD    = 2'b00;
  localparam logic [1:0] ALUOP_BRANCH = 2'b01;
  localparam logic [1:0] ALUOP_RTYPE  = 2'b10;
  localparam logic [1:0] ALUOP_ITYPE  = 2'b11;

  // funct3 encodings — canonical-reference.md §1.1 and §1.2
  localparam logic [2:0] F3_ADD_SUB = 3'b000;  // ADD/SUB, ADDI
  localparam logic [2:0] F3_SLL     = 3'b001;  // SLL,  SLLI
  localparam logic [2:0] F3_SLT     = 3'b010;  // SLT,  SLTI
  localparam logic [2:0] F3_SLTU    = 3'b011;  // SLTU, SLTIU
  localparam logic [2:0] F3_XOR     = 3'b100;  // XOR,  XORI
  localparam logic [2:0] F3_SRL_SRA = 3'b101;  // SRL/SRA, SRLI/SRAI
  localparam logic [2:0] F3_OR      = 3'b110;  // OR,  ORI
  localparam logic [2:0] F3_AND     = 3'b111;  // AND, ANDI

  // -------------------------------------------------------------------------
  // Scoreboard counters
  // -------------------------------------------------------------------------
  integer pass_count;
  integer fail_count;

  // -------------------------------------------------------------------------
  // Task: check — compare actual output to expected; print PASS/FAIL.
  //   !==  used to catch X/Z propagation mismatches.
  // -------------------------------------------------------------------------
  task automatic check (
    input string       test_name,
    input logic [3:0]  exp_ctrl,
    input logic        exp_illegal
  );
    if (alu_ctrl_o !== exp_ctrl || illegal_o !== exp_illegal) begin
      $display("FAIL  %s | alu_op=%b funct3=%b funct7b5=%b | got alu_ctrl=%b illegal=%b  exp alu_ctrl=%b illegal=%b",
               test_name, alu_op_i, funct3_i, funct7b5_i,
               alu_ctrl_o, illegal_o, exp_ctrl, exp_illegal);
      fail_count++;
    end else begin
      $display("PASS  %s", test_name);
      pass_count++;
    end
  endtask

  // -------------------------------------------------------------------------
  // Task: apply — drive stimulus and wait 1 ns for combinational settle.
  //   Driven at negedge so inputs are stable before the next posedge
  //   (gotchas.md #11: never race stimulus against posedge in seq DUT).
  //   alu_control is purely combinational but convention is kept.
  // -------------------------------------------------------------------------
  task automatic apply (
    input logic [1:0] op,
    input logic [2:0] f3,
    input logic       f7b5
  );
    @(negedge clk);
    alu_op_i   = op;
    funct3_i   = f3;
    funct7b5_i = f7b5;
    #1;
  endtask

  // -------------------------------------------------------------------------
  // Main stimulus
  // -------------------------------------------------------------------------
  initial begin
    clk        = 1'b0;
    alu_op_i   = 2'b0;
    funct3_i   = 3'b0;
    funct7b5_i = 1'b0;
    pass_count = 0;
    fail_count = 0;

    // No synchronous reset needed — module is purely combinational.
    // Wait two clock periods for simulator to stabilise.
    repeat (2) @(posedge clk);

    // =====================================================================
    // GROUP 1: alu_op=00 (ADD)
    //   Spec: canonical-reference.md §6.2 — "alu_ctrl = 4'b0000 always"
    //   Expected: alu_ctrl=4'b0000 regardless of funct3/funct7b5.
    // =====================================================================
    $display("\n--- GROUP 1: alu_op=00 ADD (always 4'b0000) ---");

    // Sweep every funct3 with funct7b5=0
    apply(ALUOP_ADD, F3_ADD_SUB, 1'b0);
    check("ADD/f3=000/f7b5=0", ALU_ADD, 1'b0);

    apply(ALUOP_ADD, F3_SLL, 1'b0);
    check("ADD/f3=001/f7b5=0", ALU_ADD, 1'b0);

    apply(ALUOP_ADD, F3_SLT, 1'b0);
    check("ADD/f3=010/f7b5=0", ALU_ADD, 1'b0);

    apply(ALUOP_ADD, F3_SLTU, 1'b0);
    check("ADD/f3=011/f7b5=0", ALU_ADD, 1'b0);

    apply(ALUOP_ADD, F3_XOR, 1'b0);
    check("ADD/f3=100/f7b5=0", ALU_ADD, 1'b0);

    apply(ALUOP_ADD, F3_SRL_SRA, 1'b0);
    check("ADD/f3=101/f7b5=0", ALU_ADD, 1'b0);

    apply(ALUOP_ADD, F3_OR, 1'b0);
    check("ADD/f3=110/f7b5=0", ALU_ADD, 1'b0);

    apply(ALUOP_ADD, F3_AND, 1'b0);
    check("ADD/f3=111/f7b5=0", ALU_ADD, 1'b0);

    // Sweep every funct3 with funct7b5=1 — must still be ADD
    apply(ALUOP_ADD, F3_ADD_SUB, 1'b1);
    check("ADD/f3=000/f7b5=1", ALU_ADD, 1'b0);

    apply(ALUOP_ADD, F3_SLL, 1'b1);
    check("ADD/f3=001/f7b5=1", ALU_ADD, 1'b0);

    apply(ALUOP_ADD, F3_SLT, 1'b1);
    check("ADD/f3=010/f7b5=1", ALU_ADD, 1'b0);

    apply(ALUOP_ADD, F3_SLTU, 1'b1);
    check("ADD/f3=011/f7b5=1", ALU_ADD, 1'b0);

    apply(ALUOP_ADD, F3_XOR, 1'b1);
    check("ADD/f3=100/f7b5=1", ALU_ADD, 1'b0);

    apply(ALUOP_ADD, F3_SRL_SRA, 1'b1);
    check("ADD/f3=101/f7b5=1", ALU_ADD, 1'b0);

    apply(ALUOP_ADD, F3_OR, 1'b1);
    check("ADD/f3=110/f7b5=1", ALU_ADD, 1'b0);

    apply(ALUOP_ADD, F3_AND, 1'b1);
    check("ADD/f3=111/f7b5=1", ALU_ADD, 1'b0);

    // =====================================================================
    // GROUP 2: alu_op=01 (BRANCH)
    //   Spec: canonical-reference.md §6.2 — "alu_control must output
    //         alu_ctrl=4'b0000 (ADD) as safe default; ALU result discarded"
    //   Gotchas.md #13: must be 4'b0000 regardless of funct3/funct7b5.
    // =====================================================================
    $display("\n--- GROUP 2: alu_op=01 BRANCH (safe default 4'b0000) ---");

    // BEQ: funct3=000, funct7b5 irrelevant
    apply(ALUOP_BRANCH, F3_ADD_SUB, 1'b0);
    check("BRANCH/BEQ/f3=000/f7b5=0", ALU_ADD, 1'b0);

    apply(ALUOP_BRANCH, F3_ADD_SUB, 1'b1);
    check("BRANCH/BEQ/f3=000/f7b5=1", ALU_ADD, 1'b0);

    // BNE: funct3=001
    apply(ALUOP_BRANCH, 3'b001, 1'b0);
    check("BRANCH/BNE/f3=001/f7b5=0", ALU_ADD, 1'b0);

    apply(ALUOP_BRANCH, 3'b001, 1'b1);
    check("BRANCH/BNE/f3=001/f7b5=1", ALU_ADD, 1'b0);

    // BLT: funct3=100
    apply(ALUOP_BRANCH, 3'b100, 1'b0);
    check("BRANCH/BLT/f3=100/f7b5=0", ALU_ADD, 1'b0);

    apply(ALUOP_BRANCH, 3'b100, 1'b1);
    check("BRANCH/BLT/f3=100/f7b5=1", ALU_ADD, 1'b0);

    // BGE: funct3=101
    apply(ALUOP_BRANCH, 3'b101, 1'b0);
    check("BRANCH/BGE/f3=101/f7b5=0", ALU_ADD, 1'b0);

    apply(ALUOP_BRANCH, 3'b101, 1'b1);
    check("BRANCH/BGE/f3=101/f7b5=1", ALU_ADD, 1'b0);

    // BLTU: funct3=110
    apply(ALUOP_BRANCH, 3'b110, 1'b0);
    check("BRANCH/BLTU/f3=110/f7b5=0", ALU_ADD, 1'b0);

    // BGEU: funct3=111
    apply(ALUOP_BRANCH, 3'b111, 1'b0);
    check("BRANCH/BGEU/f3=111/f7b5=0", ALU_ADD, 1'b0);

    // =====================================================================
    // GROUP 3: alu_op=10 (R-type)
    //   All 10 operations from canonical-reference.md §1.1.
    //   ADD:  funct3=000, funct7b5=0 → alu_ctrl=4'b0000
    //   SUB:  funct3=000, funct7b5=1 → alu_ctrl=4'b0001
    //   SLL:  funct3=001, funct7b5=0 → alu_ctrl=4'b0111
    //   SLT:  funct3=010, funct7b5=0 → alu_ctrl=4'b0101
    //   SLTU: funct3=011, funct7b5=0 → alu_ctrl=4'b0110
    //   XOR:  funct3=100, funct7b5=0 → alu_ctrl=4'b0100
    //   SRL:  funct3=101, funct7b5=0 → alu_ctrl=4'b1000
    //   SRA:  funct3=101, funct7b5=1 → alu_ctrl=4'b1001
    //   OR:   funct3=110, funct7b5=0 → alu_ctrl=4'b0011
    //   AND:  funct3=111, funct7b5=0 → alu_ctrl=4'b0010
    // =====================================================================
    $display("\n--- GROUP 3: alu_op=10 R-type (all 10 operations) ---");

    apply(ALUOP_RTYPE, F3_ADD_SUB, 1'b0);
    check("RTYPE/ADD/f3=000/f7b5=0", ALU_ADD, 1'b0);

    apply(ALUOP_RTYPE, F3_ADD_SUB, 1'b1);
    check("RTYPE/SUB/f3=000/f7b5=1", ALU_SUB, 1'b0);

    apply(ALUOP_RTYPE, F3_SLL, 1'b0);
    check("RTYPE/SLL/f3=001/f7b5=0", ALU_SLL, 1'b0);

    // SLL with funct7b5=1 is not a standard R-type encoding; the spec
    // defines no separate instruction for this combination, so the
    // implementation may fall through to a default.  We only verify the
    // defined case (funct7b5=0).

    apply(ALUOP_RTYPE, F3_SLT, 1'b0);
    check("RTYPE/SLT/f3=010/f7b5=0", ALU_SLT, 1'b0);

    apply(ALUOP_RTYPE, F3_SLTU, 1'b0);
    check("RTYPE/SLTU/f3=011/f7b5=0", ALU_SLTU, 1'b0);

    apply(ALUOP_RTYPE, F3_XOR, 1'b0);
    check("RTYPE/XOR/f3=100/f7b5=0", ALU_XOR, 1'b0);

    apply(ALUOP_RTYPE, F3_SRL_SRA, 1'b0);
    check("RTYPE/SRL/f3=101/f7b5=0", ALU_SRL, 1'b0);

    apply(ALUOP_RTYPE, F3_SRL_SRA, 1'b1);
    check("RTYPE/SRA/f3=101/f7b5=1", ALU_SRA, 1'b0);

    apply(ALUOP_RTYPE, F3_OR, 1'b0);
    check("RTYPE/OR/f3=110/f7b5=0", ALU_OR, 1'b0);

    apply(ALUOP_RTYPE, F3_AND, 1'b0);
    check("RTYPE/AND/f3=111/f7b5=0", ALU_AND, 1'b0);

    // =====================================================================
    // GROUP 4: alu_op=11 (I-type)
    //   canonical-reference.md §1.2 and gotchas.md #10.
    //
    //   ADDI:  funct3=000 → alu_ctrl=4'b0000 (ADD)
    //          funct7b5 must NOT affect this (gotchas.md #10: no SUBI)
    //   SLLI:  funct3=001, funct7b5=0 → alu_ctrl=4'b0111
    //   SLTI:  funct3=010 → alu_ctrl=4'b0101; funct7b5 irrelevant
    //   SLTIU: funct3=011 → alu_ctrl=4'b0110; funct7b5 irrelevant
    //   XORI:  funct3=100 → alu_ctrl=4'b0100; funct7b5 irrelevant
    //   SRLI:  funct3=101, funct7b5=0 → alu_ctrl=4'b1000
    //   SRAI:  funct3=101, funct7b5=1 → alu_ctrl=4'b1001
    //   ORI:   funct3=110 → alu_ctrl=4'b0011; funct7b5 irrelevant
    //   ANDI:  funct3=111 → alu_ctrl=4'b0010; funct7b5 irrelevant
    // =====================================================================
    $display("\n--- GROUP 4: alu_op=11 I-type (all 9 operations) ---");

    // ADDI: funct7b5=0 — normal case
    apply(ALUOP_ITYPE, F3_ADD_SUB, 1'b0);
    check("ITYPE/ADDI/f3=000/f7b5=0", ALU_ADD, 1'b0);

    // ADDI: funct7b5=1 — CRITICAL gotchas.md #10 check.
    // Spec: "funct7[5] only matters for R-type and I-type shifts.
    //        Do NOT check funct7 for non-shift I-type instructions."
    // Expected: alu_ctrl must STILL be 4'b0000 (ADD), NOT 4'b0001 (SUB).
    apply(ALUOP_ITYPE, F3_ADD_SUB, 1'b1);
    check("ITYPE/ADDI/f3=000/f7b5=1(gotcha#10)", ALU_ADD, 1'b0);

    // SLLI: funct7b5=0 (shift left, imm[11:5]=0000000)
    apply(ALUOP_ITYPE, F3_SLL, 1'b0);
    check("ITYPE/SLLI/f3=001/f7b5=0", ALU_SLL, 1'b0);

    // SLTI: funct7b5=0
    apply(ALUOP_ITYPE, F3_SLT, 1'b0);
    check("ITYPE/SLTI/f3=010/f7b5=0", ALU_SLT, 1'b0);

    // SLTI: funct7b5=1 — funct7b5 must not affect non-shift I-type
    apply(ALUOP_ITYPE, F3_SLT, 1'b1);
    check("ITYPE/SLTI/f3=010/f7b5=1(boundary)", ALU_SLT, 1'b0);

    // SLTIU: funct7b5=0
    apply(ALUOP_ITYPE, F3_SLTU, 1'b0);
    check("ITYPE/SLTIU/f3=011/f7b5=0", ALU_SLTU, 1'b0);

    // SLTIU: funct7b5=1 — funct7b5 must not affect non-shift I-type
    apply(ALUOP_ITYPE, F3_SLTU, 1'b1);
    check("ITYPE/SLTIU/f3=011/f7b5=1(boundary)", ALU_SLTU, 1'b0);

    // XORI: funct7b5=0
    apply(ALUOP_ITYPE, F3_XOR, 1'b0);
    check("ITYPE/XORI/f3=100/f7b5=0", ALU_XOR, 1'b0);

    // XORI: funct7b5=1 — must not affect non-shift I-type
    apply(ALUOP_ITYPE, F3_XOR, 1'b1);
    check("ITYPE/XORI/f3=100/f7b5=1(boundary)", ALU_XOR, 1'b0);

    // SRLI: funct7b5=0 (shift right logical, imm[11:5]=0000000)
    apply(ALUOP_ITYPE, F3_SRL_SRA, 1'b0);
    check("ITYPE/SRLI/f3=101/f7b5=0", ALU_SRL, 1'b0);

    // SRAI: funct7b5=1 (shift right arith, imm[11:5]=0100000)
    apply(ALUOP_ITYPE, F3_SRL_SRA, 1'b1);
    check("ITYPE/SRAI/f3=101/f7b5=1", ALU_SRA, 1'b0);

    // ORI: funct7b5=0
    apply(ALUOP_ITYPE, F3_OR, 1'b0);
    check("ITYPE/ORI/f3=110/f7b5=0", ALU_OR, 1'b0);

    // ORI: funct7b5=1 — must not affect non-shift I-type
    apply(ALUOP_ITYPE, F3_OR, 1'b1);
    check("ITYPE/ORI/f3=110/f7b5=1(boundary)", ALU_OR, 1'b0);

    // ANDI: funct7b5=0
    apply(ALUOP_ITYPE, F3_AND, 1'b0);
    check("ITYPE/ANDI/f3=111/f7b5=0", ALU_AND, 1'b0);

    // ANDI: funct7b5=1 — must not affect non-shift I-type
    apply(ALUOP_ITYPE, F3_AND, 1'b1);
    check("ITYPE/ANDI/f3=111/f7b5=1(boundary)", ALU_AND, 1'b0);

    // =====================================================================
    // GROUP 5: illegal_o
    //   Spec: canonical-reference.md §8.3 — 4'b1111 is the ONLY unallocated
    //   base code. The illegal_o signal must be 0 for all base RV32I
    //   operations tested above.  Separately verify it does not assert on
    //   any combination already tested.
    //
    //   The only way to trigger illegal_o=1 is for alu_ctrl_o to equal
    //   4'b1111 internally.  Base RV32I funct3/funct7 cannot produce any
    //   alu_ctrl_o >= 4'b1010, so illegal_o=1 is unreachable from base ISA
    //   inputs.  Groups 1-4 above cover all base RV32I operations and all
    //   already verify illegal_o=0.
    //
    //   This group validates that illegal_o stays 0 for every alu_op
    //   category with the most "dangerous" funct3/funct7b5 combinations
    //   (ones that could theoretically produce high alu_ctrl values in a
    //   buggy decode).
    // =====================================================================
    $display("\n--- GROUP 5: illegal_o stays 0 for all base RV32I ops ---");

    // R-type: all funct3 values with both funct7b5 polarities
    begin : g5_rtype
      logic [2:0] f3;
      logic       f7;
      for (int i = 0; i < 8; i++) begin
        for (int j = 0; j < 2; j++) begin
          f3 = i[2:0];
          f7 = j[0];
          @(negedge clk);
          alu_op_i   = ALUOP_RTYPE;
          funct3_i   = f3;
          funct7b5_i = f7;
          #1;
          if (illegal_o !== 1'b0) begin
            $display("FAIL  R-type/f3=%b/f7b5=%b illegal_o unexpectedly set",
                     f3, f7);
            fail_count++;
          end else begin
            pass_count++;
          end
        end
      end
    end

    // I-type: all funct3 values with both funct7b5 polarities
    begin : g5_itype
      logic [2:0] f3;
      logic       f7;
      for (int i = 0; i < 8; i++) begin
        for (int j = 0; j < 2; j++) begin
          f3 = i[2:0];
          f7 = j[0];
          @(negedge clk);
          alu_op_i   = ALUOP_ITYPE;
          funct3_i   = f3;
          funct7b5_i = f7;
          #1;
          if (illegal_o !== 1'b0) begin
            $display("FAIL  I-type/f3=%b/f7b5=%b illegal_o unexpectedly set",
                     f3, f7);
            fail_count++;
          end else begin
            pass_count++;
          end
        end
      end
    end

    // =====================================================================
    // GROUP 6: Boundary — funct7b5=1 has NO effect on non-shift I-types
    //   Gotchas.md #10: "Do NOT check funct7 for non-shift I-type."
    //   Non-shift funct3: 000 (ADDI), 010 (SLTI), 011 (SLTIU),
    //                     100 (XORI), 110 (ORI), 111 (ANDI)
    //   For each, result with funct7b5=1 must equal result with funct7b5=0.
    //   Shift funct3: 001 (SLLI), 101 (SRLI/SRAI) — excluded from this
    //   group because funct7b5 IS meaningful for shifts.
    // =====================================================================
    $display("\n--- GROUP 6: Boundary funct7b5 invariance on non-shift I-type ---");

    // Helper: capture alu_ctrl at funct7b5=0, then compare at funct7b5=1
    begin : g6_boundary
      logic [3:0] ctrl_f7b5_0;
      logic [3:0] ctrl_f7b5_1;
      // ADDI
      @(negedge clk); alu_op_i=ALUOP_ITYPE; funct3_i=F3_ADD_SUB;
      funct7b5_i=1'b0; #1; ctrl_f7b5_0 = alu_ctrl_o;
      @(negedge clk); alu_op_i=ALUOP_ITYPE; funct3_i=F3_ADD_SUB;
      funct7b5_i=1'b1; #1; ctrl_f7b5_1 = alu_ctrl_o;
      if (ctrl_f7b5_0 !== ctrl_f7b5_1) begin
        $display("FAIL  BOUNDARY/ADDI funct7b5 changes alu_ctrl: 0->%b 1->%b",
                 ctrl_f7b5_0, ctrl_f7b5_1);
        fail_count++;
      end else begin
        $display("PASS  BOUNDARY/ADDI funct7b5 invariant (both=%b)", ctrl_f7b5_0);
        pass_count++;
      end

      // SLTI
      @(negedge clk); alu_op_i=ALUOP_ITYPE; funct3_i=F3_SLT;
      funct7b5_i=1'b0; #1; ctrl_f7b5_0 = alu_ctrl_o;
      @(negedge clk); alu_op_i=ALUOP_ITYPE; funct3_i=F3_SLT;
      funct7b5_i=1'b1; #1; ctrl_f7b5_1 = alu_ctrl_o;
      if (ctrl_f7b5_0 !== ctrl_f7b5_1) begin
        $display("FAIL  BOUNDARY/SLTI funct7b5 changes alu_ctrl: 0->%b 1->%b",
                 ctrl_f7b5_0, ctrl_f7b5_1);
        fail_count++;
      end else begin
        $display("PASS  BOUNDARY/SLTI funct7b5 invariant (both=%b)", ctrl_f7b5_0);
        pass_count++;
      end

      // SLTIU
      @(negedge clk); alu_op_i=ALUOP_ITYPE; funct3_i=F3_SLTU;
      funct7b5_i=1'b0; #1; ctrl_f7b5_0 = alu_ctrl_o;
      @(negedge clk); alu_op_i=ALUOP_ITYPE; funct3_i=F3_SLTU;
      funct7b5_i=1'b1; #1; ctrl_f7b5_1 = alu_ctrl_o;
      if (ctrl_f7b5_0 !== ctrl_f7b5_1) begin
        $display("FAIL  BOUNDARY/SLTIU funct7b5 changes alu_ctrl: 0->%b 1->%b",
                 ctrl_f7b5_0, ctrl_f7b5_1);
        fail_count++;
      end else begin
        $display("PASS  BOUNDARY/SLTIU funct7b5 invariant (both=%b)", ctrl_f7b5_0);
        pass_count++;
      end

      // XORI
      @(negedge clk); alu_op_i=ALUOP_ITYPE; funct3_i=F3_XOR;
      funct7b5_i=1'b0; #1; ctrl_f7b5_0 = alu_ctrl_o;
      @(negedge clk); alu_op_i=ALUOP_ITYPE; funct3_i=F3_XOR;
      funct7b5_i=1'b1; #1; ctrl_f7b5_1 = alu_ctrl_o;
      if (ctrl_f7b5_0 !== ctrl_f7b5_1) begin
        $display("FAIL  BOUNDARY/XORI funct7b5 changes alu_ctrl: 0->%b 1->%b",
                 ctrl_f7b5_0, ctrl_f7b5_1);
        fail_count++;
      end else begin
        $display("PASS  BOUNDARY/XORI funct7b5 invariant (both=%b)", ctrl_f7b5_0);
        pass_count++;
      end

      // ORI
      @(negedge clk); alu_op_i=ALUOP_ITYPE; funct3_i=F3_OR;
      funct7b5_i=1'b0; #1; ctrl_f7b5_0 = alu_ctrl_o;
      @(negedge clk); alu_op_i=ALUOP_ITYPE; funct3_i=F3_OR;
      funct7b5_i=1'b1; #1; ctrl_f7b5_1 = alu_ctrl_o;
      if (ctrl_f7b5_0 !== ctrl_f7b5_1) begin
        $display("FAIL  BOUNDARY/ORI funct7b5 changes alu_ctrl: 0->%b 1->%b",
                 ctrl_f7b5_0, ctrl_f7b5_1);
        fail_count++;
      end else begin
        $display("PASS  BOUNDARY/ORI funct7b5 invariant (both=%b)", ctrl_f7b5_0);
        pass_count++;
      end

      // ANDI
      @(negedge clk); alu_op_i=ALUOP_ITYPE; funct3_i=F3_AND;
      funct7b5_i=1'b0; #1; ctrl_f7b5_0 = alu_ctrl_o;
      @(negedge clk); alu_op_i=ALUOP_ITYPE; funct3_i=F3_AND;
      funct7b5_i=1'b1; #1; ctrl_f7b5_1 = alu_ctrl_o;
      if (ctrl_f7b5_0 !== ctrl_f7b5_1) begin
        $display("FAIL  BOUNDARY/ANDI funct7b5 changes alu_ctrl: 0->%b 1->%b",
                 ctrl_f7b5_0, ctrl_f7b5_1);
        fail_count++;
      end else begin
        $display("PASS  BOUNDARY/ANDI funct7b5 invariant (both=%b)", ctrl_f7b5_0);
        pass_count++;
      end
    end

    // =====================================================================
    // Summary
    // =====================================================================
    $display("\n========================================");
    $display("tb_alu_control RESULTS: %0d PASS / %0d FAIL",
             pass_count, fail_count);
    $display("========================================\n");

    if (fail_count == 0)
      $display("ALL TESTS PASSED");
    else
      $display("SOME TESTS FAILED — see FAIL lines above");

    $finish;
  end

  // -------------------------------------------------------------------------
  // Timeout watchdog — in case DUT hangs the simulation
  // -------------------------------------------------------------------------
  initial begin
    #50000;
    $display("TIMEOUT: simulation did not complete within 50 us");
    $finish;
  end

endmodule
