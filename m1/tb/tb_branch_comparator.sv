// ============================================================================
// Module: tb_branch_comparator
// Description: Self-checking testbench for branch_comparator.sv
//              All expected values derived from canonical-reference.md S1.5
//              and S10.4. Never derived from RTL.
// Author: Beaux Cable
// Date: April 2026
// Project: RV32I Pipelined Processor
// ============================================================================
//
// Spec basis (canonical-reference.md S1.5):
//   BEQ  (funct3=000): branch_taken = (rs1 == rs2)          unsigned equality
//   BNE  (funct3=001): branch_taken = (rs1 != rs2)
//   BLT  (funct3=100): branch_taken = signed(rs1) < signed(rs2)
//   BGE  (funct3=101): branch_taken = signed(rs1) >= signed(rs2)
//   BLTU (funct3=110): branch_taken = unsigned(rs1) < unsigned(rs2)
//   BGEU (funct3=111): branch_taken = unsigned(rs1) >= unsigned(rs2)
//   Reserved (funct3=010, 011): branch_taken = 0 (no valid B-type encoding)
//
// Combinational DUT: stimulus applied then #1 settle, output checked.
// No clock required; this module is purely combinational.
// ============================================================================

`timescale 1ns/1ps

module tb_branch_comparator;

  // -------------------------------------------------------------------------
  // DUT port connections
  // -------------------------------------------------------------------------
  logic [31:0] rs1_data_i;
  logic [31:0] rs2_data_i;
  logic [ 2:0] funct3_i;
  logic        branch_taken_o;

  branch_comparator dut (
    .rs1_data_i    (rs1_data_i),
    .rs2_data_i    (rs2_data_i),
    .funct3_i      (funct3_i),
    .branch_taken_o(branch_taken_o)
  );

  // -------------------------------------------------------------------------
  // Test tracking
  // -------------------------------------------------------------------------
  integer pass_count;
  integer fail_count;

  // -------------------------------------------------------------------------
  // Check task
  // Description: applies rs1/rs2/funct3, waits 1ns for combinational settle,
  //              then compares branch_taken_o against expected.
  // -------------------------------------------------------------------------
  task automatic check(
    input  logic [31:0] rs1,
    input  logic [31:0] rs2,
    input  logic [ 2:0] f3,
    input  logic        expected,
    input  string       test_name
  );
    rs1_data_i = rs1;
    rs2_data_i = rs2;
    funct3_i   = f3;
    #1;
    if (branch_taken_o !== expected) begin
      $display("FAIL  [%s]  rs1=%08h rs2=%08h funct3=%03b  got=%b  exp=%b",
               test_name, rs1, rs2, f3, branch_taken_o, expected);
      fail_count = fail_count + 1;
    end else begin
      $display("PASS  [%s]", test_name);
      pass_count = pass_count + 1;
    end
  endtask

  // -------------------------------------------------------------------------
  // Constant definitions for readability
  // -------------------------------------------------------------------------
  // Spec: canonical-reference.md S1.5
  localparam [2:0] BEQ  = 3'b000;
  localparam [2:0] BNE  = 3'b001;
  // 3'b010 and 3'b011 are reserved (no B-type encoding defined)
  localparam [2:0] BLT  = 3'b100;
  localparam [2:0] BGE  = 3'b101;
  localparam [2:0] BLTU = 3'b110;
  localparam [2:0] BGEU = 3'b111;

  // Useful data constants
  // MAX_POS = 0x7FFFFFFF = +2147483647 (largest 32-bit signed positive)
  // MIN_NEG = 0x80000000 = -2147483648 (most-negative 32-bit signed value)
  // ALL_ONES = 0xFFFFFFFF = -1 signed / 4294967295 unsigned
  localparam [31:0] ZERO    = 32'h0000_0000;
  localparam [31:0] ONE     = 32'h0000_0001;
  localparam [31:0] MAX_POS = 32'h7FFF_FFFF; // +2147483647 (signed)
  localparam [31:0] MIN_NEG = 32'h8000_0000; // -2147483648 (signed)
  localparam [31:0] NEG_ONE = 32'hFFFF_FFFF; // -1 signed / 0xFFFFFFFF unsigned
  localparam [31:0] POS_42  = 32'd42;
  localparam [31:0] POS_43  = 32'd43;

  // -------------------------------------------------------------------------
  // Main test sequence
  // -------------------------------------------------------------------------
  initial begin
    pass_count = 0;
    fail_count = 0;

    // Default drive (prevents X on first check)
    rs1_data_i = 32'h0;
    rs2_data_i = 32'h0;
    funct3_i   = 3'b000;

    $display("========================================");
    $display("  tb_branch_comparator — begin");
    $display("  Spec: canonical-reference.md S1.5");
    $display("========================================");

    // =====================================================================
    // 1. BEQ (funct3 = 000): taken when rs1 == rs2
    //    Spec: "BEQ | 000 | rs1 == rs2"
    // =====================================================================
    $display("--- BEQ (funct3=000) ---");

    // 1.1 BEQ taken: both zero
    // Spec: 0 == 0 -> taken = 1
    check(ZERO, ZERO, BEQ, 1'b1, "BEQ zero==zero taken");

    // 1.2 BEQ taken: equal non-zero values
    // Spec: 0x12345678 == 0x12345678 -> taken = 1
    check(32'h1234_5678, 32'h1234_5678, BEQ, 1'b1,
          "BEQ equal nonzero taken");

    // 1.3 BEQ not taken: rs1 < rs2 (unsigned)
    // Spec: 1 != 2 -> taken = 0
    check(ONE, 32'd2, BEQ, 1'b0, "BEQ 1!=2 not taken");

    // 1.4 BEQ not taken: all-ones vs zero
    // Spec: 0xFFFFFFFF != 0x00000000 -> taken = 0
    check(NEG_ONE, ZERO, BEQ, 1'b0, "BEQ 0xFFFFFFFF!=0 not taken");

    // 1.5 BEQ taken: both max-positive
    // Spec: 0x7FFFFFFF == 0x7FFFFFFF -> taken = 1
    check(MAX_POS, MAX_POS, BEQ, 1'b1, "BEQ MAX_POS==MAX_POS taken");

    // 1.6 BEQ not taken: MAX_POS vs MIN_NEG (differ in sign bit only)
    // Spec: 0x7FFFFFFF != 0x80000000 -> taken = 0
    check(MAX_POS, MIN_NEG, BEQ, 1'b0, "BEQ MAX_POS!=MIN_NEG not taken");

    // =====================================================================
    // 2. BNE (funct3 = 001): taken when rs1 != rs2
    //    Spec: "BNE | 001 | rs1 != rs2"
    // =====================================================================
    $display("--- BNE (funct3=001) ---");

    // 2.1 BNE taken: different values
    // Spec: 1 != 2 -> taken = 1
    check(ONE, 32'd2, BNE, 1'b1, "BNE 1!=2 taken");

    // 2.2 BNE taken: zero vs all-ones
    // Spec: 0x00000000 != 0xFFFFFFFF -> taken = 1
    check(ZERO, NEG_ONE, BNE, 1'b1, "BNE zero!=0xFFFFFFFF taken");

    // 2.3 BNE not taken: equal values
    // Spec: 0xABCD1234 == 0xABCD1234 -> taken = 0
    check(32'hABCD_1234, 32'hABCD_1234, BNE, 1'b0,
          "BNE equal not taken");

    // 2.4 BNE not taken: both zero
    // Spec: 0 == 0 -> taken = 0
    check(ZERO, ZERO, BNE, 1'b0, "BNE zero==zero not taken");

    // 2.5 BNE taken: MAX_POS vs MIN_NEG
    // Spec: 0x7FFFFFFF != 0x80000000 -> taken = 1
    check(MAX_POS, MIN_NEG, BNE, 1'b1, "BNE MAX_POS!=MIN_NEG taken");

    // =====================================================================
    // 3. BLT (funct3 = 100): taken when signed(rs1) < signed(rs2)
    //    Spec: "BLT | 100 | signed(rs1) < signed(rs2)"
    // =====================================================================
    $display("--- BLT (funct3=100) signed ---");

    // 3.1 BLT taken: normal positive case
    // Spec: signed(1) < signed(2) -> taken = 1
    check(ONE, 32'd2, BLT, 1'b1, "BLT 1<2 taken");

    // 3.2 BLT not taken: equal values
    // Spec: signed(5) < signed(5) is false -> taken = 0
    check(32'd5, 32'd5, BLT, 1'b0, "BLT 5==5 not taken");

    // 3.3 BLT not taken: rs1 > rs2 (positive)
    // Spec: signed(10) < signed(3) is false -> taken = 0
    check(32'd10, 32'd3, BLT, 1'b0, "BLT 10>3 not taken");

    // 3.4 BLT taken: -1 < 0 (signed)
    // Spec: signed(0xFFFFFFFF)=-1, signed(0)=0; -1 < 0 -> taken = 1
    check(NEG_ONE, ZERO, BLT, 1'b1, "BLT -1<0 taken signed");

    // 3.5 BLT not taken: 0 vs -1 (signed, opposite direction)
    // Spec: signed(0)=0, signed(0xFFFFFFFF)=-1; 0 < -1 is false -> taken = 0
    check(ZERO, NEG_ONE, BLT, 1'b0, "BLT 0>-1 not taken signed");

    // 3.6 BLT taken: MIN_NEG < MAX_POS
    // Spec: signed(0x80000000)=-2147483648 < signed(0x7FFFFFFF)=+2147483647
    //       -> taken = 1
    check(MIN_NEG, MAX_POS, BLT, 1'b1, "BLT MIN_NEG<MAX_POS taken");

    // 3.7 BLT not taken: MAX_POS vs MIN_NEG (reversed)
    // Spec: signed(0x7FFFFFFF)=+2147483647 < signed(0x80000000)=-2147483648
    //       is false -> taken = 0
    check(MAX_POS, MIN_NEG, BLT, 1'b0, "BLT MAX_POS>MIN_NEG not taken");

    // 3.8 BLT not taken: both MIN_NEG equal
    // Spec: signed(0x80000000) < signed(0x80000000) is false -> taken = 0
    check(MIN_NEG, MIN_NEG, BLT, 1'b0, "BLT MIN_NEG==MIN_NEG not taken");

    // 3.9 BLT taken: -1 < 0 via MAX_POS boundary
    // Spec: signed(0x7FFFFFFE) < signed(0x7FFFFFFF) -> taken = 1
    check(32'h7FFF_FFFE, MAX_POS, BLT, 1'b1,
          "BLT MAX_POS-1 < MAX_POS taken");

    // =====================================================================
    // 4. BGE (funct3 = 101): taken when signed(rs1) >= signed(rs2)
    //    Spec: "BGE | 101 | signed(rs1) >= signed(rs2)"
    // =====================================================================
    $display("--- BGE (funct3=101) signed ---");

    // 4.1 BGE taken: equal values
    // Spec: signed(5) >= signed(5) -> taken = 1
    check(32'd5, 32'd5, BGE, 1'b1, "BGE 5>=5 equal taken");

    // 4.2 BGE taken: rs1 > rs2 (positive)
    // Spec: signed(10) >= signed(3) -> taken = 1
    check(32'd10, 32'd3, BGE, 1'b1, "BGE 10>=3 taken");

    // 4.3 BGE not taken: rs1 < rs2 (positive)
    // Spec: signed(1) >= signed(2) is false -> taken = 0
    check(ONE, 32'd2, BGE, 1'b0, "BGE 1<2 not taken");

    // 4.4 BGE taken: 0 >= -1 (signed)
    // Spec: signed(0)=0 >= signed(0xFFFFFFFF)=-1 -> taken = 1
    check(ZERO, NEG_ONE, BGE, 1'b1, "BGE 0>=-1 taken signed");

    // 4.5 BGE not taken: -1 < 0 (signed)
    // Spec: signed(0xFFFFFFFF)=-1 >= signed(0)=0 is false -> taken = 0
    check(NEG_ONE, ZERO, BGE, 1'b0, "BGE -1<0 not taken signed");

    // 4.6 BGE taken: MAX_POS >= MIN_NEG
    // Spec: signed(0x7FFFFFFF)=+2147483647 >= signed(0x80000000)=-2147483648
    //       -> taken = 1
    check(MAX_POS, MIN_NEG, BGE, 1'b1, "BGE MAX_POS>=MIN_NEG taken");

    // 4.7 BGE not taken: MIN_NEG vs MAX_POS (reversed)
    // Spec: signed(0x80000000)=-2147483648 >= signed(0x7FFFFFFF)=+2147483647
    //       is false -> taken = 0
    check(MIN_NEG, MAX_POS, BGE, 1'b0, "BGE MIN_NEG<MAX_POS not taken");

    // 4.8 BGE taken: both zero equal
    // Spec: signed(0) >= signed(0) -> taken = 1
    check(ZERO, ZERO, BGE, 1'b1, "BGE zero>=zero taken");

    // 4.9 BGE taken: both MIN_NEG equal
    // Spec: signed(0x80000000) >= signed(0x80000000) -> taken = 1
    check(MIN_NEG, MIN_NEG, BGE, 1'b1, "BGE MIN_NEG>=MIN_NEG taken");

    // =====================================================================
    // 5. BLTU (funct3 = 110): taken when unsigned(rs1) < unsigned(rs2)
    //    Spec: "BLTU | 110 | unsigned(rs1) < unsigned(rs2)"
    // =====================================================================
    $display("--- BLTU (funct3=110) unsigned ---");

    // 5.1 BLTU taken: normal positive case
    // Spec: unsigned(1) < unsigned(2) -> taken = 1
    check(ONE, 32'd2, BLTU, 1'b1, "BLTU 1<2 taken");

    // 5.2 BLTU not taken: equal values
    // Spec: unsigned(5) < unsigned(5) is false -> taken = 0
    check(32'd5, 32'd5, BLTU, 1'b0, "BLTU 5==5 not taken");

    // 5.3 BLTU not taken: rs1 > rs2
    // Spec: unsigned(10) < unsigned(3) is false -> taken = 0
    check(32'd10, 32'd3, BLTU, 1'b0, "BLTU 10>3 not taken");

    // 5.4 BLTU taken: 0 vs 0xFFFFFFFF
    // Spec: unsigned(0x00000000)=0 < unsigned(0xFFFFFFFF)=4294967295
    //       -> taken = 1
    // Key unsigned edge case: 0xFFFFFFFF is maximum unsigned, not -1
    check(ZERO, NEG_ONE, BLTU, 1'b1, "BLTU 0<0xFFFFFFFF taken");

    // 5.5 BLTU not taken: 0xFFFFFFFF vs 0
    // Spec: unsigned(0xFFFFFFFF)=4294967295 < unsigned(0)=0 is false
    //       -> taken = 0
    check(NEG_ONE, ZERO, BLTU, 1'b0, "BLTU 0xFFFFFFFF>0 not taken");

    // 5.6 BLTU taken: 0 vs MAX_POS
    // Spec: unsigned(0) < unsigned(0x7FFFFFFF) -> taken = 1
    check(ZERO, MAX_POS, BLTU, 1'b1, "BLTU 0<MAX_POS taken");

    // 5.7 BLTU taken: MAX_POS vs 0xFFFFFFFF
    // Spec: unsigned(0x7FFFFFFF)=2147483647 < unsigned(0xFFFFFFFF)=4294967295
    //       -> taken = 1
    // Signed boundary: MAX_POS is positive but unsigned less than all-ones
    check(MAX_POS, NEG_ONE, BLTU, 1'b1,
          "BLTU MAX_POS<0xFFFFFFFF taken unsigned");

    // 5.8 BLTU not taken: MIN_NEG vs MAX_POS (unsigned comparison)
    // Spec: unsigned(0x80000000)=2147483648 < unsigned(0x7FFFFFFF)=2147483647
    //       is false (MIN_NEG is LARGER in unsigned space)
    //       -> taken = 0
    // Key signed/unsigned asymmetry: MIN_NEG is negative signed but > MAX_POS
    // in unsigned space
    check(MIN_NEG, MAX_POS, BLTU, 1'b0,
          "BLTU MIN_NEG>MAX_POS unsigned not taken");

    // 5.9 BLTU taken: MAX_POS vs MIN_NEG (unsigned)
    // Spec: unsigned(0x7FFFFFFF) < unsigned(0x80000000) -> taken = 1
    check(MAX_POS, MIN_NEG, BLTU, 1'b1,
          "BLTU MAX_POS<MIN_NEG unsigned taken");

    // 5.10 BLTU not taken: both zero
    // Spec: unsigned(0) < unsigned(0) is false -> taken = 0
    check(ZERO, ZERO, BLTU, 1'b0, "BLTU zero==zero not taken");

    // =====================================================================
    // 6. BGEU (funct3 = 111): taken when unsigned(rs1) >= unsigned(rs2)
    //    Spec: "BGEU | 111 | unsigned(rs1) >= unsigned(rs2)"
    // =====================================================================
    $display("--- BGEU (funct3=111) unsigned ---");

    // 6.1 BGEU taken: equal values
    // Spec: unsigned(5) >= unsigned(5) -> taken = 1
    check(32'd5, 32'd5, BGEU, 1'b1, "BGEU 5>=5 equal taken");

    // 6.2 BGEU taken: rs1 > rs2
    // Spec: unsigned(10) >= unsigned(3) -> taken = 1
    check(32'd10, 32'd3, BGEU, 1'b1, "BGEU 10>=3 taken");

    // 6.3 BGEU not taken: rs1 < rs2
    // Spec: unsigned(1) >= unsigned(2) is false -> taken = 0
    check(ONE, 32'd2, BGEU, 1'b0, "BGEU 1<2 not taken");

    // 6.4 BGEU taken: 0xFFFFFFFF vs 0
    // Spec: unsigned(0xFFFFFFFF)=4294967295 >= unsigned(0)=0 -> taken = 1
    check(NEG_ONE, ZERO, BGEU, 1'b1, "BGEU 0xFFFFFFFF>=0 taken");

    // 6.5 BGEU not taken: 0 vs 0xFFFFFFFF
    // Spec: unsigned(0) >= unsigned(0xFFFFFFFF) is false -> taken = 0
    check(ZERO, NEG_ONE, BGEU, 1'b0, "BGEU 0<0xFFFFFFFF not taken");

    // 6.6 BGEU taken: both zero equal
    // Spec: unsigned(0) >= unsigned(0) -> taken = 1
    check(ZERO, ZERO, BGEU, 1'b1, "BGEU zero>=zero taken");

    // 6.7 BGEU taken: MIN_NEG vs MAX_POS (unsigned)
    // Spec: unsigned(0x80000000)=2147483648 >= unsigned(0x7FFFFFFF)=2147483647
    //       -> taken = 1 (MIN_NEG is LARGER in unsigned space)
    check(MIN_NEG, MAX_POS, BGEU, 1'b1,
          "BGEU MIN_NEG>=MAX_POS unsigned taken");

    // 6.8 BGEU not taken: MAX_POS vs MIN_NEG (unsigned)
    // Spec: unsigned(0x7FFFFFFF) >= unsigned(0x80000000) is false -> taken = 0
    check(MAX_POS, MIN_NEG, BGEU, 1'b0,
          "BGEU MAX_POS<MIN_NEG unsigned not taken");

    // 6.9 BGEU taken: both 0xFFFFFFFF equal
    // Spec: unsigned(0xFFFFFFFF) >= unsigned(0xFFFFFFFF) -> taken = 1
    check(NEG_ONE, NEG_ONE, BGEU, 1'b1,
          "BGEU 0xFFFFFFFF>=0xFFFFFFFF taken");

    // =====================================================================
    // 7. x0 special cases (rs1=0 or rs2=0 interactions)
    //    Spec: x0 always reads as zero (all comparisons with 0x00000000)
    //    These cover the canonical register x0 = zero sentinel.
    // =====================================================================
    $display("--- x0 special cases (zero register) ---");

    // 7.1 BEQ with both rs1=x0=0 and rs2=x0=0: taken
    // Spec: BEQ 0 == 0 -> taken = 1
    check(ZERO, ZERO, BEQ, 1'b1, "BEQ x0==x0 taken");

    // 7.2 BNE with rs1=x0=0 vs rs2=1: taken
    // Spec: BNE 0 != 1 -> taken = 1
    check(ZERO, ONE, BNE, 1'b1, "BNE x0!=1 taken");

    // 7.3 BLT with rs1=x0=0 vs rs2=1 (positive): taken
    // Spec: signed(0) < signed(1) -> taken = 1
    check(ZERO, ONE, BLT, 1'b1, "BLT x0<1 taken");

    // 7.4 BLT with rs1=x0=0 vs rs2=NEG_ONE (signed -1): not taken
    // Spec: signed(0)=0 < signed(0xFFFFFFFF)=-1 is false -> taken = 0
    check(ZERO, NEG_ONE, BLT, 1'b0, "BLT x0 vs -1 not taken");

    // 7.5 BGE with rs1=x0=0 vs rs2=x0=0: taken (equal)
    // Spec: signed(0) >= signed(0) -> taken = 1
    check(ZERO, ZERO, BGE, 1'b1, "BGE x0>=x0 taken");

    // 7.6 BLTU with rs1=x0=0 vs rs2=1: taken
    // Spec: unsigned(0) < unsigned(1) -> taken = 1
    check(ZERO, ONE, BLTU, 1'b1, "BLTU x0<1 taken");

    // 7.7 BGEU with rs1=x0=0 vs rs2=x0=0: taken
    // Spec: unsigned(0) >= unsigned(0) -> taken = 1
    check(ZERO, ZERO, BGEU, 1'b1, "BGEU x0>=x0 taken");

    // =====================================================================
    // 8. Reserved funct3 encodings: 010 and 011
    //    Spec: only BEQ/BNE/BLT/BGE/BLTU/BGEU are valid B-type encodings
    //    (canonical-reference.md S1.5 lists exactly 6 instructions).
    //    No valid B-type instruction uses funct3=010 or funct3=011.
    //    m1-pipeline-plan.md: "Default: branch_taken_o = 1'b0"
    //    Expected: branch_taken_o = 0 for all inputs.
    // =====================================================================
    $display("--- Reserved funct3=010 and funct3=011 ---");

    // 8.1 Reserved funct3=010, equal operands: branch_taken must be 0
    // Spec: no instruction defined for funct3=010 -> taken = 0
    check(ZERO, ZERO, 3'b010, 1'b0,
          "reserved funct3=010 equal inputs -> 0");

    // 8.2 Reserved funct3=010, unequal operands: branch_taken must be 0
    check(ONE, 32'd2, 3'b010, 1'b0,
          "reserved funct3=010 unequal inputs -> 0");

    // 8.3 Reserved funct3=010, operands that would trigger BEQ: must be 0
    check(32'hDEAD_BEEF, 32'hDEAD_BEEF, 3'b010, 1'b0,
          "reserved funct3=010 equal 0xDEADBEEF -> 0");

    // 8.4 Reserved funct3=011, equal operands: branch_taken must be 0
    check(ZERO, ZERO, 3'b011, 1'b0,
          "reserved funct3=011 equal inputs -> 0");

    // 8.5 Reserved funct3=011, unequal operands: branch_taken must be 0
    check(ONE, 32'd2, 3'b011, 1'b0,
          "reserved funct3=011 unequal inputs -> 0");

    // 8.6 Reserved funct3=011, operands that would trigger BNE: must be 0
    check(ONE, 32'd99, 3'b011, 1'b0,
          "reserved funct3=011 unequal values -> 0");

    // =====================================================================
    // 9. Boundary and stress values
    // =====================================================================
    $display("--- Boundary and stress values ---");

    // 9.1 BEQ: boundary walk — each bit position
    // Spec: BEQ taken only when rs1==rs2 exactly
    // Test one-bit difference at MSB: taken=0
    check(32'h8000_0000, 32'h0000_0000, BEQ, 1'b0,
          "BEQ bit31 difference not taken");

    // 9.2 BEQ: one-bit difference at bit 0: taken=0
    check(32'h0000_0001, 32'h0000_0000, BEQ, 1'b0,
          "BEQ bit0 difference not taken");

    // 9.3 BLT: -1 vs -2 (both negative, -1 > -2 signed)
    // Spec: signed(0xFFFFFFFF)=-1, signed(0xFFFFFFFE)=-2;
    //       -1 < -2 is false -> taken = 0
    check(NEG_ONE, 32'hFFFF_FFFE, BLT, 1'b0,
          "BLT -1 vs -2 signed: -1 > -2 not taken");

    // 9.4 BLT: -2 vs -1 (both negative, -2 < -1 signed)
    // Spec: signed(0xFFFFFFFE)=-2 < signed(0xFFFFFFFF)=-1 -> taken = 1
    check(32'hFFFF_FFFE, NEG_ONE, BLT, 1'b1,
          "BLT -2 vs -1 signed: -2 < -1 taken");

    // 9.5 BGE: MAX_POS vs MAX_POS equal
    // Spec: signed(0x7FFFFFFF) >= signed(0x7FFFFFFF) -> taken = 1
    check(MAX_POS, MAX_POS, BGE, 1'b1, "BGE MAX_POS==MAX_POS taken");

    // 9.6 BLTU: adjacent values at unsigned max boundary
    // Spec: unsigned(0xFFFFFFFE) < unsigned(0xFFFFFFFF) -> taken = 1
    check(32'hFFFF_FFFE, NEG_ONE, BLTU, 1'b1,
          "BLTU 0xFFFFFFFE < 0xFFFFFFFF taken");

    // 9.7 BGEU: adjacent values at unsigned max boundary
    // Spec: unsigned(0xFFFFFFFF) >= unsigned(0xFFFFFFFE) -> taken = 1
    check(NEG_ONE, 32'hFFFF_FFFE, BGEU, 1'b1,
          "BGEU 0xFFFFFFFF >= 0xFFFFFFFE taken");

    // 9.8 BNE: one-bit difference at bit 31 (sign bit)
    // Spec: 0x80000000 != 0x00000000 -> taken = 1
    check(32'h8000_0000, ZERO, BNE, 1'b1,
          "BNE sign-bit differs taken");

    // 9.9 BLT: positive one vs zero (boundary near zero)
    // Spec: signed(0) < signed(1) -> taken = 1
    check(ZERO, ONE, BLT, 1'b1, "BLT 0<1 taken boundary");

    // 9.10 BGE: zero vs positive one (boundary near zero, not taken)
    // Spec: signed(0) >= signed(1) is false -> taken = 0
    check(ZERO, ONE, BGE, 1'b0, "BGE 0<1 not taken boundary");

    // 9.11 BLTU: arbitrary midrange values
    // Spec: unsigned(0x00000100) < unsigned(0x00000101) -> taken = 1
    check(32'h0000_0100, 32'h0000_0101, BLTU, 1'b1,
          "BLTU 0x100 < 0x101 taken");

    // 9.12 BGEU: rs1==rs2 all-ones boundary
    // Spec: unsigned(0xFFFFFFFF) >= unsigned(0xFFFFFFFF) -> taken = 1
    check(NEG_ONE, NEG_ONE, BGEU, 1'b1,
          "BGEU all-ones equal taken");

    // =====================================================================
    // Final summary
    // =====================================================================
    $display("========================================");
    $display("  tb_branch_comparator — complete");
    $display("  PASSED: %0d", pass_count);
    $display("  FAILED: %0d", fail_count);
    $display("========================================");

    if (fail_count == 0)
      $display("ALL TESTS PASSED");
    else
      $display("SOME TESTS FAILED — see FAIL lines above");

    $finish;
  end

endmodule
