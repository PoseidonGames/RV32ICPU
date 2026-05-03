// ============================================================================
// Module: tb_imm_gen
// Description: Self-checking directed testbench for imm_gen.sv.
//              All expected values derived from canonical-reference.md §4
//              (Immediate Extraction table) and §3 (Instruction Formats).
//              Does NOT derive expected values from RTL.
//
// Coverage:
//   1. Normal operation — typical immediate values for each format
//   2. Boundary values — zero, max positive, max negative (most negative)
//   3. All immediate types — I, S, B, U, J (all 5 formats)
//   4. Sign-extension corners — positive (inst[31]=0), negative (inst[31]=1)
//   8. Edge cases — default (unknown imm_type) outputs zero
//
// Expected value derivation (canonical-reference.md §4):
//   I-type (3'b000): { {20{inst[31]}}, inst[31:20] }
//   S-type (3'b001): { {20{inst[31]}}, inst[31:25], inst[11:7] }
//   B-type (3'b010): { {19{inst[31]}}, inst[31], inst[7], inst[30:25],
//                       inst[11:8], 1'b0 }
//   U-type (3'b011): { inst[31:12], 12'b0 }
//   J-type (3'b100): { {11{inst[31]}}, inst[31], inst[19:12], inst[20],
//                       inst[30:21], 1'b0 }
//
// Author: Beaux Cable
// Date: April 2026
// Project: RV32I Pipelined Processor
// ============================================================================

`timescale 1ns/1ps

module tb_imm_gen;

  // --------------------------------------------------------------------------
  // DUT port connections
  // --------------------------------------------------------------------------
  logic [31:0] inst_i;
  logic [ 2:0] imm_type_i;
  logic [31:0] imm_o;

  imm_gen dut (
    .inst_i     (inst_i),
    .imm_type_i (imm_type_i),
    .imm_o      (imm_o)
  );

  // --------------------------------------------------------------------------
  // Clock (50 MHz — conventions.md); not used by combinational DUT but
  // present to match project testbench style.
  // --------------------------------------------------------------------------
  logic clk;
  initial clk = 1'b0;
  always #10 clk = ~clk;

  // --------------------------------------------------------------------------
  // Test infrastructure
  // --------------------------------------------------------------------------
  integer pass_count = 0;
  integer fail_count = 0;

  // check: apply inputs, wait 1 ns for combinational settle, compare.
  // Displays PASS/FAIL with enough context to diagnose any mismatch.
  task automatic check(
    input string   test_name,
    input [31:0]   expected
  );
    #1; // combinational settle
    if (imm_o === expected) begin
      $display("  PASS  %-28s  inst=%08h  imm_type=%03b  imm_o=%08h",
               test_name, inst_i, imm_type_i, imm_o);
      pass_count++;
    end else begin
      $display("  FAIL  %-28s  inst=%08h  imm_type=%03b  imm_o=%08h  (expected %08h)",
               test_name, inst_i, imm_type_i, imm_o, expected);
      fail_count++;
    end
  endtask

  // --------------------------------------------------------------------------
  // Test sequence
  // --------------------------------------------------------------------------
  initial begin
    $display("============================================================");
    $display(" RV32I Immediate Generator — Directed Test Suite");
    $display(" Expected values from canonical-reference.md §4");
    $display("============================================================");

    // ========================================================================
    // I-TYPE  imm_type = 3'b000
    // Spec §4: { {20{inst[31]}}, inst[31:20] }
    // Sign bit = inst[31].  12-bit signed range: -2048 .. +2047.
    // ========================================================================
    $display("\n--- I-type (imm_type=3'b000) ---");
    imm_type_i = 3'b000;

    // Zero immediate.
    // inst[31:20]=12'h000 → 20 zero sign-ext bits + 000h = 0x00000000
    // Using ADDI x0,x0,0 = 32'h00000013 (canonical NOP, ref §11)
    inst_i = 32'h00000013;
    check("I zero",              32'h00000000);

    // Immediate = +1.
    // inst[31:20]=12'h001, inst[31]=0 → sign-ext=0
    // Encoded: bits[31:20]=001, rest unimportant for imm extraction.
    // Using ADDI encoding with rs1=x0, rd=x0, funct3=000:
    //   bits[31:20]=001h → inst=32'h00100013
    inst_i = 32'h00100013;
    check("I positive small (+1)", 32'h00000001);

    // Maximum positive I-immediate: +2047 = 0x7FF.
    // inst[31:20]=12'h7FF, inst[31]=0 → sign-ext fills 20 zeros
    // Spec §11 anchor: "Max positive I-imm: 32'h7FF = 2047"
    // bits[31:20]=7FF → inst=32'h7FF00013
    inst_i = 32'h7FF00013;
    check("I max positive (+2047)", 32'h000007FF);

    // Maximum negative I-immediate: -2048 = 0xFFFFF800 (sign-extended).
    // inst[31:20]=12'h800, inst[31]=1 → 20 ones sign-extended
    // Spec §11 anchor: "Max negative I-imm: 32'h800 sign-ext = 32'hFFFFF800 = -2048"
    // bits[31:20]=800 → inst[31]=1, inst[30:20]=000 0000 0000
    // inst = 32'h80000013
    inst_i = 32'h80000013;
    check("I max negative (-2048)", 32'hFFFFF800);

    // Immediate = -1 = 0xFFFFFFFF sign-extended from 12'hFFF.
    // inst[31:20]=12'hFFF, inst[31]=1 → {20{1'b1}, 12'hFFF} = 0xFFFFFFFF
    // bits[31:20]=FFF → inst=32'hFFF00013
    inst_i = 32'hFFF00013;
    check("I all-ones (-1)",       32'hFFFFFFFF);

    // Immediate = -5 = 0xFFFFFFFB sign-extended from 12'hFFB.
    // inst[31:20]=12'hFFB, inst[31]=1 → {20{1},FFB} = 0xFFFFFFFB
    // bits[31:20]=FFB → inst=32'hFFB00013
    inst_i = 32'hFFB00013;
    check("I negative mid (-5)",   32'hFFFFFFFB);

    // ========================================================================
    // S-TYPE  imm_type = 3'b001
    // Spec §4: { {20{inst[31]}}, inst[31:25], inst[11:7] }
    // imm[11:5] = inst[31:25]; imm[4:0] = inst[11:7]
    // 12-bit signed range: -2048 .. +2047.
    // Instruction note (§3): S-type has NO rd — inst[11:7] carries imm[4:0].
    // Opcode 0100011 (store) used for background bits in all vectors.
    // ========================================================================
    $display("\n--- S-type (imm_type=3'b001) ---");
    imm_type_i = 3'b001;

    // Zero immediate.
    // inst[31:25]=7'h00, inst[11:7]=5'h00
    // SW x0,x0,0 = 32'h00000023
    inst_i = 32'h00000023;
    check("S zero",              32'h00000000);

    // imm = +4 = 0x004.
    // imm[11:5]=0000000, imm[4:0]=00100
    // inst[31:25]=7'h00 (inst[31]=0), inst[11:7]=5'b00100
    // inst[11:8]=0010, inst[7]=0
    // Binary: 0000_0000_0000_0000_0000_0010_0010_0011 = 32'h00000223
    inst_i = 32'h00000223;
    check("S positive small (+4)", 32'h00000004);

    // Maximum positive S-immediate: +2047 = 0x7FF.
    // imm[11:5]=0111111, imm[4:0]=11111
    // inst[31]=imm[11]=0, inst[30:25]=imm[10:5]=111111,
    // inst[11:7]=imm[4:0]=11111
    // Binary: 0_111111_00000_00000_000_11111_0100011
    //   bits[31:24]=0111_1110=0x7E, bits[23:16]=0x00,
    //   bits[15:8]=0000_1111=0x0F, bits[7:0]=1010_0011=0xA3
    // inst = 32'h7E000FA3
    inst_i = 32'h7E000FA3;
    check("S max positive (+2047)", 32'h000007FF);

    // Maximum negative S-immediate: -2048 = 0xFFFFF800.
    // imm[11:5]=1000000, imm[4:0]=00000
    // inst[31]=imm[11]=1, inst[30:25]=imm[10:5]=000000,
    // inst[11:7]=imm[4:0]=00000
    // Binary: 1_000000_00000_00000_000_00000_0100011 = 32'h80000023
    inst_i = 32'h80000023;
    check("S max negative (-2048)", 32'hFFFFF800);

    // imm = -1 = 0xFFFFFFFF.
    // imm[11:5]=1111111, imm[4:0]=11111
    // inst[31]=1, inst[30:25]=111111, inst[11:7]=11111
    // Binary: 1_111111_00000_00000_000_11111_0100011
    //   bits[31:24]=0xFE, bits[23:16]=0x00,
    //   bits[15:8]=0x0F, bits[7:0]=0xA3
    // inst = 32'hFE000FA3
    inst_i = 32'hFE000FA3;
    check("S all-ones (-1)",       32'hFFFFFFFF);

    // ========================================================================
    // B-TYPE  imm_type = 3'b010
    // Spec §4: { {19{inst[31]}}, inst[31], inst[7], inst[30:25],
    //            inst[11:8], 1'b0 }
    // 13-bit signed offset (LSB always 0): -4096 .. +4094, step 2.
    // Opcode 1100011 (branch) used for background bits.
    // ========================================================================
    $display("\n--- B-type (imm_type=3'b010) ---");
    imm_type_i = 3'b010;

    // Zero offset.
    // All imm bits zero → inst = 32'h00000063
    inst_i = 32'h00000063;
    check("B zero",              32'h00000000);

    // offset = +4.
    // imm[12]=0, imm[11]=0, imm[10:5]=000000, imm[4:1]=0010, imm[0]=0
    // inst[31]=0, inst[7]=0, inst[30:25]=000000, inst[11:8]=0010
    // Binary: 0_000000_00000_00000_000_0010_0_1100011 = 32'h00000263
    inst_i = 32'h00000263;
    check("B positive small (+4)", 32'h00000004);

    // Maximum positive B-immediate: +4094 = 0xFFE.
    // 13-bit: bit12=0 (positive), bits11:1=all-1, bit0=0
    // imm[12]=0, imm[11]=1, imm[10:5]=111111, imm[4:1]=1111
    // inst[31]=0, inst[7]=1, inst[30:25]=111111, inst[11:8]=1111
    // Binary: 0_111111_00000_00000_000_1111_1_1100011
    //   bits[31:24]=0x7E, bits[23:16]=0x00,
    //   bits[15:8]=0x0F, bits[7:0]=1110_0011=0xE3
    // inst = 32'h7E000FE3
    inst_i = 32'h7E000FE3;
    check("B max positive (+4094)", 32'h00000FFE);

    // Most negative B-immediate: -4096.
    // 13-bit: bit12=1, bits11:1=all-0, bit0=0
    // imm[12]=1, imm[11]=0, imm[10:5]=000000, imm[4:1]=0000
    // inst[31]=1, inst[7]=0, inst[30:25]=000000, inst[11:8]=0000
    // Binary: 1_000000_00000_00000_000_0000_0_1100011 = 32'h80000063
    inst_i = 32'h80000063;
    check("B most negative (-4096)", 32'hFFFFF000);

    // offset = -2 (all imm bits set except imm[0]=0).
    // imm[12]=1, imm[11]=1, imm[10:5]=111111, imm[4:1]=1111
    // inst[31]=1, inst[7]=1, inst[30:25]=111111, inst[11:8]=1111
    // Binary: 1_111111_00000_00000_000_1111_1_1100011
    //   bits[31:24]=0xFE, bits[23:16]=0x00,
    //   bits[15:8]=0x0F, bits[7:0]=1110_0011=0xE3
    // inst = 32'hFE000FE3
    inst_i = 32'hFE000FE3;
    check("B all-ones (-2)",      32'hFFFFFFFE);

    // offset = +8 (two instructions forward).
    // imm[12]=0, imm[11]=0, imm[10:5]=000000, imm[4:1]=0100
    // inst[31]=0, inst[7]=0, inst[30:25]=000000, inst[11:8]=0100
    // Binary: 0_000000_00000_00000_000_0100_0_1100011 = 32'h00000463
    inst_i = 32'h00000463;
    check("B positive (+8)",     32'h00000008);

    // ========================================================================
    // U-TYPE  imm_type = 3'b011
    // Spec §4: { inst[31:12], 12'b0 }
    // No sign-extension: inst[31:12] placed directly in result[31:12];
    // result[11:0] = 0.  Used by LUI and AUIPC.
    // ========================================================================
    $display("\n--- U-type (imm_type=3'b011) ---");
    imm_type_i = 3'b011;

    // Zero upper immediate.
    // inst[31:12]=0 → 32'h00000000
    // LUI x0, 0 = 32'h00000037
    inst_i = 32'h00000037;
    check("U zero",              32'h00000000);

    // LUI 0xDEADB — canonical reference §11 anchor.
    // inst = 32'hDEADB137 → imm_o = 32'hDEADB000
    inst_i = 32'hDEADB137;
    check("U LUI 0xDEADB (ref§11)", 32'hDEADB000);

    // inst[31]=1, inst[30:12]=0: result[31]=1, result[30:0]=0.
    // LUI rd, 0x80000 → inst[31:12]=0x80000 → imm_o=32'h80000000
    // inst = 32'h80000037
    inst_i = 32'h80000037;
    check("U high bit set",      32'h80000000);

    // All upper bits set: inst[31:12]=0xFFFFF → imm_o=32'hFFFFF000
    // inst = 32'hFFFFF037
    inst_i = 32'hFFFFF037;
    check("U all-ones upper",    32'hFFFFF000);

    // Small positive upper: inst[31:12]=0x00001 → imm_o=32'h00001000
    // inst = 32'h00001037
    inst_i = 32'h00001037;
    check("U small positive",    32'h00001000);

    // inst[31:12]=0xABCDE → imm_o=32'hABCDE000
    // inst = 32'hABCDE037
    inst_i = 32'hABCDE037;
    check("U pattern ABCDE",     32'hABCDE000);

    // ========================================================================
    // J-TYPE  imm_type = 3'b100
    // Spec §4: { {11{inst[31]}}, inst[31], inst[19:12], inst[20],
    //            inst[30:21], 1'b0 }
    // 21-bit signed offset (LSB always 0): -1048576 .. +1048574, step 2.
    // Bit scramble: imm[20]=inst[31], imm[19:12]=inst[19:12],
    //               imm[11]=inst[20], imm[10:1]=inst[30:21]
    // Opcode 1101111 (JAL) used for background bits.
    // ========================================================================
    $display("\n--- J-type (imm_type=3'b100) ---");
    imm_type_i = 3'b100;

    // Zero offset.
    // All imm bits zero → JAL x0,0 = 32'h0000006F
    inst_i = 32'h0000006F;
    check("J zero",              32'h00000000);

    // offset = +4.
    // imm[20]=0, imm[19:12]=0x00, imm[11]=0, imm[10:1]=0b0000000010
    // inst[31]=0, inst[19:12]=0x00, inst[20]=0, inst[30:21]=0b0000000010
    // inst[30:21]: bit30=0..bit22=1,bit21=0 → bit22=1
    // bit22 = 2^22 = 0x00400000; opcode=0x6F; rd=x0
    // inst = 32'h0040006F
    inst_i = 32'h0040006F;
    check("J positive small (+4)", 32'h00000004);

    // Maximum positive J-immediate: +1048574 = 0x000FFFFE.
    // 21-bit: bit20=0 (positive), bits19:1=all-1, bit0=0
    // imm[20]=0, imm[19:12]=0xFF, imm[11]=1, imm[10:1]=0b1111111111
    // inst[31]=0, inst[30:21]=1111111111, inst[20]=1, inst[19:12]=0xFF
    // bits[31:12]: 0_1111111111_1_11111111 = 0x7FFFF
    // inst = 32'h7FFFF06F
    inst_i = 32'h7FFFF06F;
    check("J max positive (+1048574)", 32'h000FFFFE);

    // Most negative J-immediate: -1048576 = 0xFFF00000.
    // imm[20]=1, all others zero.
    // inst[31]=1, inst[30:21]=0000000000, inst[20]=0, inst[19:12]=0x00
    // bits[31:12]: 1_0000000000_0_00000000 = 0x80000
    // inst = 32'h8000006F
    inst_i = 32'h8000006F;
    check("J most negative (-1048576)", 32'hFFF00000);

    // offset = -2 (all imm bits set except bit0=0).
    // imm[20]=1, imm[19:12]=0xFF, imm[11]=1, imm[10:1]=0b1111111111
    // inst[31]=1, inst[30:21]=1111111111, inst[20]=1, inst[19:12]=0xFF
    // bits[31:12]: 1_1111111111_1_11111111 = 0xFFFFF
    // inst = 32'hFFFFF06F
    inst_i = 32'hFFFFF06F;
    check("J all-ones (-2)",     32'hFFFFFFFE);

    // offset = +8.
    // imm[10:1]=0b0000000100 (imm[3]=1 → bit position 2 of the 10-bit field)
    // inst[30:21] = imm[10:1], mapping one-to-one:
    //   inst[30]=imm[10]=0, inst[29]=imm[9]=0, ..., inst[23]=imm[3]=1,
    //   inst[22]=imm[2]=0, inst[21]=imm[1]=0
    // bit23 = 2^23 = 0x00800000; opcode=0x6F; rd=x0
    // inst = 32'h0080006F
    inst_i = 32'h0080006F;
    check("J positive (+8)",     32'h00000008);

    // imm[11] isolation: verify inst[20] correctly maps to imm[11].
    // offset = +2048 = 0x800: imm[11]=1, all other imm bits 0.
    // inst[20]=1, inst[31]=0, inst[30:21]=0, inst[19:12]=0
    // bit20=1 → 2^20=0x00100000; opcode=0x6F; rd=x0
    // inst = 32'h00100000 | 0x0000006F = 32'h0010006F
    inst_i = 32'h0010006F;
    check("J imm[11] isolation (+2048)", 32'h00000800);

    // imm[19:12] isolation: verify inst[19:12] maps correctly.
    // offset = +0x01000 = 4096: imm[12]=1 → but imm[12] maps to bit12 of offset
    // which is imm[12], stored in inst[19:12] bit12=... let me pick offset=0x1000
    // imm[12]=1, others 0. inst[19:12]=0b00000001(imm[12]=bit0 of inst[19:12] field)
    // Spec: imm[19:12]=inst[19:12] → inst[12]=imm[12]=1 → bit12=1=2^12=0x1000
    // inst[19:12]=0x01 → bit12=1; inst=32'h00001000|0x6F=32'h0000106F
    inst_i = 32'h0000106F;
    check("J imm[12] isolation (+4096)", 32'h00001000);

    // ========================================================================
    // EDGE CASE: undefined imm_type
    // Spec §4: no entry for imm_type >= 3'b101 → module default case = 32'h0
    // ========================================================================
    $display("\n--- Edge case: undefined imm_type ---");

    inst_i     = 32'hFFFFFFFF; // all bits set, ensures default isn't hiding bits
    imm_type_i = 3'b101;
    check("Undefined type 3'b101",  32'h00000000);

    imm_type_i = 3'b110;
    check("Undefined type 3'b110",  32'h00000000);

    imm_type_i = 3'b111;
    check("Undefined type 3'b111",  32'h00000000);

    // ========================================================================
    // Summary
    // ========================================================================
    $display("\n============================================================");
    $display(" Results: %0d passed, %0d failed", pass_count, fail_count);
    $display("============================================================");

    if (fail_count == 0)
      $display(" ALL TESTS PASSED");
    else
      $display(" SOME TESTS FAILED — review output above");

    $finish;
  end

endmodule
