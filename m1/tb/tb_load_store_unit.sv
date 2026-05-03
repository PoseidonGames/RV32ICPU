// ============================================================================
// Module: tb_load_store_unit
// Description: Self-checking testbench for load_store_unit.sv.
//              Expected values derived from canonical-reference.md S1.3, S1.4
//              and the memory interface decisions confirmed by ar, April 2026.
//
// Spec anchors used throughout:
//   S1.3  Load funct3 encodings and sign/zero extension rules
//   S1.4  Store funct3 encodings, byte-lane alignment, data_we generation
//   "Memory interface decisions" block in S1.4:
//     - data_we[3:0] is active-high, one bit per byte lane
//     - Store data is byte-lane-aligned
//     - Load extension (sign/zero) happens inside the core
//     - Misaligned access is undefined behavior
//
// Author: Beaux Cable
// Date: April 2026
// Project: RV32I Pipelined Processor
// ============================================================================

`timescale 1ns/1ps

module tb_load_store_unit;

  // --------------------------------------------------------------------------
  // DUT port connections
  // --------------------------------------------------------------------------
  logic [31:0] rs2_i;
  logic [31:0] addr_i;
  logic [2:0]  funct3_i;
  logic        mem_write_i;
  logic        mem_read_i;
  logic [31:0] store_data_o;
  logic [3:0]  data_we_o;
  logic [31:0] load_raw_i;
  logic [31:0] load_data_o;

  load_store_unit dut (
    .rs2_i       (rs2_i),
    .addr_i      (addr_i),
    .funct3_i    (funct3_i),
    .mem_write_i (mem_write_i),
    .mem_read_i  (mem_read_i),
    .store_data_o(store_data_o),
    .data_we_o   (data_we_o),
    .load_raw_i  (load_raw_i),
    .load_data_o (load_data_o)
  );

  // --------------------------------------------------------------------------
  // Clock (required by conventions even for combinational DUT)
  // --------------------------------------------------------------------------
  logic clk;
  initial clk = 0;
  always #10 clk = ~clk;

  // --------------------------------------------------------------------------
  // Counters
  // --------------------------------------------------------------------------
  int pass_count;
  int fail_count;

  // --------------------------------------------------------------------------
  // Check task: combinational — apply #1 propagation delay then check
  // --------------------------------------------------------------------------
  task automatic check_store(
    input string  test_name,
    input [31:0]  exp_store_data,
    input [3:0]   exp_data_we
  );
    #1;
    if (store_data_o !== exp_store_data || data_we_o !== exp_data_we) begin
      $display("FAIL  %s", test_name);
      $display("      rs2=0x%08h addr=0x%08h funct3=0b%03b mem_write=%b",
               rs2_i, addr_i, funct3_i, mem_write_i);
      $display("      store_data: got=0x%08h exp=0x%08h  data_we: got=0b%04b exp=0b%04b",
               store_data_o, exp_store_data, data_we_o, exp_data_we);
      fail_count++;
    end else begin
      $display("PASS  %s", test_name);
      pass_count++;
    end
  endtask

  task automatic check_load(
    input string  test_name,
    input [31:0]  exp_load_data
  );
    #1;
    if (load_data_o !== exp_load_data) begin
      $display("FAIL  %s", test_name);
      $display("      load_raw=0x%08h addr=0x%08h funct3=0b%03b mem_read=%b",
               load_raw_i, addr_i, funct3_i, mem_read_i);
      $display("      load_data: got=0x%08h exp=0x%08h",
               load_data_o, exp_load_data);
      fail_count++;
    end else begin
      $display("PASS  %s", test_name);
      pass_count++;
    end
  endtask

  // --------------------------------------------------------------------------
  // Helper: idle both paths (prevent X bleed between sections)
  // --------------------------------------------------------------------------
  task automatic idle;
    mem_write_i = 1'b0;
    mem_read_i  = 1'b0;
    rs2_i       = 32'h0;
    addr_i      = 32'h0;
    funct3_i    = 3'b000;
    load_raw_i  = 32'h0;
  endtask

  // ==========================================================================
  // Main stimulus
  // ==========================================================================
  initial begin
    pass_count = 0;
    fail_count = 0;

    idle;

    // ========================================================================
    // SECTION 1: mem_write_i = 0 => data_we_o must be 0 regardless of funct3
    // Spec: data_we driven only when mem_write_i=1 (S1.4 store path)
    // ========================================================================
    $display("\n-- Section 1: mem_write_i=0 gate --");

    // SB encoding with mem_write=0: data_we must remain 0
    rs2_i       = 32'hDEADBEEF;
    addr_i      = 32'h0000_0001;
    funct3_i    = 3'b000;   // SB funct3
    mem_write_i = 1'b0;
    mem_read_i  = 1'b0;
    check_store("mem_write=0 SB funct3 -> data_we=0", 32'h0, 4'b0000);

    // SH encoding with mem_write=0
    funct3_i    = 3'b001;   // SH funct3
    check_store("mem_write=0 SH funct3 -> data_we=0", 32'h0, 4'b0000);

    // SW encoding with mem_write=0
    funct3_i    = 3'b010;   // SW funct3
    check_store("mem_write=0 SW funct3 -> data_we=0", 32'h0, 4'b0000);

    // ========================================================================
    // SECTION 2: SB (funct3=000) at each byte offset
    // Spec S1.4: mem[rs1+imm][7:0] = rs2[7:0]
    //   store_data_o = {4{rs2[7:0]}}  (byte replicated to all lanes)
    //   data_we_o    = 4'b0001 << addr[1:0]
    // Test value: rs2=0xAABBCCDD => byte=0xDD
    //   Replicated: 0xDDDDDDDD
    // ========================================================================
    $display("\n-- Section 2: SB at each byte offset --");
    mem_write_i = 1'b1;
    mem_read_i  = 1'b0;
    funct3_i    = 3'b000;   // SB

    rs2_i  = 32'hAABBCCDD;
    // Expected store_data_o = {4{8'hDD}} = 32'hDDDDDDDD for all offsets

    addr_i = 32'h0000_1000;  // addr[1:0] = 2'b00
    // data_we = 4'b0001 << 0 = 4'b0001
    check_store("SB offset=0: store_data=0xDDDDDDDD data_we=0001",
                32'hDDDDDDDD, 4'b0001);

    addr_i = 32'h0000_1001;  // addr[1:0] = 2'b01
    // data_we = 4'b0001 << 1 = 4'b0010
    check_store("SB offset=1: store_data=0xDDDDDDDD data_we=0010",
                32'hDDDDDDDD, 4'b0010);

    addr_i = 32'h0000_1002;  // addr[1:0] = 2'b10
    // data_we = 4'b0001 << 2 = 4'b0100
    check_store("SB offset=2: store_data=0xDDDDDDDD data_we=0100",
                32'hDDDDDDDD, 4'b0100);

    addr_i = 32'h0000_1003;  // addr[1:0] = 2'b11
    // data_we = 4'b0001 << 3 = 4'b1000
    check_store("SB offset=3: store_data=0xDDDDDDDD data_we=1000",
                32'hDDDDDDDD, 4'b1000);

    // SB with MSB-set byte (negative byte value) — sign ext is memory's job,
    // store_data still just replicates rs2[7:0] to all lanes
    // rs2=0x1234_5680 => byte=0x80; replicated=0x80808080
    rs2_i  = 32'h1234_5680;
    addr_i = 32'h0000_1002;  // offset=2
    check_store("SB negative byte offset=2: store_data=0x80808080 data_we=0100",
                32'h80808080, 4'b0100);

    // ========================================================================
    // SECTION 3: SH (funct3=001) at addr[1]=0 and addr[1]=1
    // Spec S1.4: mem[rs1+imm][15:0] = rs2[15:0]
    //   store_data_o = {2{rs2[15:0]}}  (halfword replicated to both halfwords)
    //   data_we_o    = addr[1] ? 4'b1100 : 4'b0011
    // Test value: rs2=0xAABBCCDD => half=0xCCDD
    //   Replicated: 0xCCDDCCDD
    // ========================================================================
    $display("\n-- Section 3: SH at each halfword offset --");
    funct3_i = 3'b001;   // SH
    rs2_i    = 32'hAABBCCDD;
    // Expected store_data_o = {2{16'hCCDD}} = 32'hCCDDCCDD for both offsets

    addr_i = 32'h0000_2000;  // addr[1:0] = 2'b00 -> addr[1]=0
    // data_we = 4'b0011
    check_store("SH addr[1]=0: store_data=0xCCDDCCDD data_we=0011",
                32'hCCDDCCDD, 4'b0011);

    addr_i = 32'h0000_2002;  // addr[1:0] = 2'b10 -> addr[1]=1
    // data_we = 4'b1100
    check_store("SH addr[1]=1: store_data=0xCCDDCCDD data_we=1100",
                32'hCCDDCCDD, 4'b1100);

    // SH with negative halfword (MSB set): rs2=0xFFFF_8000 => half=0x8000
    // Replicated: 0x80008000
    rs2_i  = 32'hFFFF_8000;
    addr_i = 32'h0000_2000;  // addr[1]=0
    check_store("SH negative half addr[1]=0: store_data=0x80008000 data_we=0011",
                32'h80008000, 4'b0011);

    addr_i = 32'h0000_2002;  // addr[1]=1
    check_store("SH negative half addr[1]=1: store_data=0x80008000 data_we=1100",
                32'h80008000, 4'b1100);

    // ========================================================================
    // SECTION 4: SW (funct3=010)
    // Spec S1.4: mem[rs1+imm][31:0] = rs2[31:0]
    //   store_data_o = rs2; data_we_o = 4'b1111
    // ========================================================================
    $display("\n-- Section 4: SW full word --");
    funct3_i = 3'b010;   // SW

    rs2_i  = 32'hDEADBEEF;
    addr_i = 32'h0000_3000;
    check_store("SW 0xDEADBEEF: store_data=0xDEADBEEF data_we=1111",
                32'hDEADBEEF, 4'b1111);

    rs2_i  = 32'h0000_0000;
    check_store("SW 0x00000000: store_data=0x00000000 data_we=1111",
                32'h00000000, 4'b1111);

    rs2_i  = 32'hFFFF_FFFF;
    check_store("SW 0xFFFFFFFF: store_data=0xFFFFFFFF data_we=1111",
                32'hFFFFFFFF, 4'b1111);

    rs2_i  = 32'h8000_0000;
    check_store("SW 0x80000000: store_data=0x80000000 data_we=1111",
                32'h80000000, 4'b1111);

    // ========================================================================
    // SECTION 5: mem_read_i = 0 => load_data_o must be 0
    // Spec: load_data driven only when mem_read_i=1 (S1.3 load path)
    // ========================================================================
    $display("\n-- Section 5: mem_read_i=0 gate --");
    idle;

    load_raw_i  = 32'hDEADBEEF;
    addr_i      = 32'h0;
    funct3_i    = 3'b000;   // LB funct3
    mem_read_i  = 1'b0;
    check_load("mem_read=0 LB funct3 -> load_data=0", 32'h0);

    funct3_i = 3'b001;   // LH
    check_load("mem_read=0 LH funct3 -> load_data=0", 32'h0);

    funct3_i = 3'b010;   // LW
    check_load("mem_read=0 LW funct3 -> load_data=0", 32'h0);

    funct3_i = 3'b100;   // LBU
    check_load("mem_read=0 LBU funct3 -> load_data=0", 32'h0);

    funct3_i = 3'b101;   // LHU
    check_load("mem_read=0 LHU funct3 -> load_data=0", 32'h0);

    // ========================================================================
    // SECTION 6: LB (funct3=000) — sign-extended byte
    // Spec S1.3: rd = sext(mem[rs1+imm][7:0])
    //   byte_off=addr[1:0] selects byte lane from load_raw_i
    //   sign bit = selected_byte[7]
    //
    // Test word: load_raw_i = 0xAA_BB_CC_DD
    //   byte lane 0 ([7:0])  = 0xDD  -> MSB=1 -> sext = 0xFFFFFFDD
    //   byte lane 1 ([15:8]) = 0xCC  -> MSB=1 -> sext = 0xFFFFFFCC
    //   byte lane 2 ([23:16])= 0xBB  -> MSB=1 -> sext = 0xFFFFFFBB
    //   byte lane 3 ([31:24])= 0xAA  -> MSB=1 -> sext = 0xFFFFFFAA
    // ========================================================================
    $display("\n-- Section 6: LB sign extension at each byte offset --");
    mem_write_i = 1'b0;
    mem_read_i  = 1'b1;
    funct3_i    = 3'b000;   // LB
    load_raw_i  = 32'hAABBCCDD;

    addr_i = 32'h0;     // byte_off = 2'b00
    // byte = load_raw[7:0] = 0xDD; MSB=1 -> sext = 0xFFFFFFDD
    check_load("LB off=0 0xDD -> 0xFFFFFFDD", 32'hFFFFFFDD);

    addr_i = 32'h1;     // byte_off = 2'b01
    // byte = load_raw[15:8] = 0xCC; MSB=1 -> sext = 0xFFFFFFCC
    check_load("LB off=1 0xCC -> 0xFFFFFFCC", 32'hFFFFFFCC);

    addr_i = 32'h2;     // byte_off = 2'b10
    // byte = load_raw[23:16] = 0xBB; MSB=1 -> sext = 0xFFFFFFBB
    check_load("LB off=2 0xBB -> 0xFFFFFFBB", 32'hFFFFFFBB);

    addr_i = 32'h3;     // byte_off = 2'b11
    // byte = load_raw[31:24] = 0xAA; MSB=1 -> sext = 0xFFFFFFAA
    check_load("LB off=3 0xAA -> 0xFFFFFFAA", 32'hFFFFFFAA);

    // LB with positive byte (MSB=0): load_raw=0x7F_3C_5A_01
    //   byte lane 0 = 0x01 -> MSB=0 -> sext = 0x00000001
    //   byte lane 2 = 0x3C -> MSB=0 -> sext = 0x0000003C
    //   byte lane 3 = 0x7F -> MSB=0 -> sext = 0x0000007F
    load_raw_i = 32'h7F3C5A01;

    addr_i = 32'h0;     // byte_off = 2'b00; byte = 0x01
    check_load("LB off=0 0x01 -> 0x00000001", 32'h00000001);

    addr_i = 32'h2;     // byte_off = 2'b10; byte = 0x3C
    check_load("LB off=2 0x3C -> 0x0000003C", 32'h0000003C);

    addr_i = 32'h3;     // byte_off = 2'b11; byte = 0x7F
    check_load("LB off=3 0x7F -> 0x0000007F", 32'h0000007F);

    // LB boundary: 0x80 is the most negative signed byte = -128
    //   sext = 0xFFFFFF80
    load_raw_i = 32'h0000_0080;
    addr_i     = 32'h0;
    check_load("LB boundary 0x80 -> 0xFFFFFF80", 32'hFFFFFF80);

    // ========================================================================
    // SECTION 7: LBU (funct3=100) — zero-extended byte
    // Spec S1.3: rd = zext(mem[rs1+imm][7:0])
    //   Same byte lane selection as LB, but upper bits = 0.
    //
    // Test word: load_raw_i = 0xAABBCCDD
    //   byte lane 0 = 0xDD -> zext = 0x000000DD
    //   byte lane 1 = 0xCC -> zext = 0x000000CC
    //   byte lane 2 = 0xBB -> zext = 0x000000BB
    //   byte lane 3 = 0xAA -> zext = 0x000000AA
    // ========================================================================
    $display("\n-- Section 7: LBU zero extension at each byte offset --");
    funct3_i   = 3'b100;   // LBU
    load_raw_i = 32'hAABBCCDD;

    addr_i = 32'h0;     // byte_off = 2'b00; byte = 0xDD
    check_load("LBU off=0 0xDD -> 0x000000DD", 32'h000000DD);

    addr_i = 32'h1;     // byte_off = 2'b01; byte = 0xCC
    check_load("LBU off=1 0xCC -> 0x000000CC", 32'h000000CC);

    addr_i = 32'h2;     // byte_off = 2'b10; byte = 0xBB
    check_load("LBU off=2 0xBB -> 0x000000BB", 32'h000000BB);

    addr_i = 32'h3;     // byte_off = 2'b11; byte = 0xAA
    check_load("LBU off=3 0xAA -> 0x000000AA", 32'h000000AA);

    // LBU boundary: 0x80 must NOT sign-extend (contrast with LB above)
    //   LBU 0x80 -> 0x00000080 (zero-extended)
    load_raw_i = 32'h0000_0080;
    addr_i     = 32'h0;
    check_load("LBU boundary 0x80 -> 0x00000080 (no sign ext)", 32'h00000080);

    // LBU max byte: 0xFF -> 0x000000FF
    load_raw_i = 32'hFF00_0000;
    addr_i     = 32'h3;     // byte_off = 2'b11; byte = 0xFF
    check_load("LBU max 0xFF off=3 -> 0x000000FF", 32'h000000FF);

    // ========================================================================
    // SECTION 8: LH (funct3=001) — sign-extended halfword
    // Spec S1.3: rd = sext(mem[rs1+imm][15:0])
    //   addr[1]=0 -> load_raw[15:0]  (lower halfword)
    //   addr[1]=1 -> load_raw[31:16] (upper halfword)
    //   sign bit = selected_half[15]
    //
    // Test word: load_raw_i = 0x8001_7FFE
    //   lower half [15:0]  = 0x7FFE -> MSB=0 -> sext = 0x00007FFE
    //   upper half [31:16] = 0x8001 -> MSB=1 -> sext = 0xFFFF8001
    // ========================================================================
    $display("\n-- Section 8: LH sign extension at each halfword offset --");
    funct3_i   = 3'b001;   // LH
    load_raw_i = 32'h80017FFE;

    addr_i = 32'h0;     // addr[1]=0 -> lower half = 0x7FFE; MSB=0
    check_load("LH addr[1]=0 0x7FFE -> 0x00007FFE", 32'h00007FFE);

    addr_i = 32'h2;     // addr[1]=1 -> upper half = 0x8001; MSB=1
    check_load("LH addr[1]=1 0x8001 -> 0xFFFF8001", 32'hFFFF8001);

    // LH with all-ones negative: 0xFFFF -> sext = 0xFFFFFFFF
    load_raw_i = 32'hFFFF_0000;
    addr_i     = 32'h2;    // addr[1]=1 -> upper half = 0xFFFF
    check_load("LH max negative 0xFFFF -> 0xFFFFFFFF", 32'hFFFFFFFF);

    // LH boundary: 0x8000 = most negative signed halfword = -32768
    //   sext = 0xFFFF8000
    load_raw_i = 32'h8000_0000;
    addr_i     = 32'h2;    // addr[1]=1 -> upper half = 0x8000
    check_load("LH boundary 0x8000 -> 0xFFFF8000", 32'hFFFF8000);

    // LH max positive: 0x7FFF -> sext = 0x00007FFF
    load_raw_i = 32'h0000_7FFF;
    addr_i     = 32'h0;    // addr[1]=0 -> lower half = 0x7FFF
    check_load("LH max positive 0x7FFF -> 0x00007FFF", 32'h00007FFF);

    // ========================================================================
    // SECTION 9: LHU (funct3=101) — zero-extended halfword
    // Spec S1.3: rd = zext(mem[rs1+imm][15:0])
    //   Same halfword lane selection as LH, but upper bits = 0.
    //
    // Test word: load_raw_i = 0x8001_7FFE
    //   lower half [15:0]  = 0x7FFE -> zext = 0x00007FFE
    //   upper half [31:16] = 0x8001 -> zext = 0x00008001 (no sign ext!)
    // ========================================================================
    $display("\n-- Section 9: LHU zero extension at each halfword offset --");
    funct3_i   = 3'b101;   // LHU
    load_raw_i = 32'h80017FFE;

    addr_i = 32'h0;     // addr[1]=0 -> lower half = 0x7FFE
    check_load("LHU addr[1]=0 0x7FFE -> 0x00007FFE", 32'h00007FFE);

    addr_i = 32'h2;     // addr[1]=1 -> upper half = 0x8001; no sign ext
    check_load("LHU addr[1]=1 0x8001 -> 0x00008001", 32'h00008001);

    // LHU boundary: 0x8000 must NOT sign-extend (contrast with LH above)
    //   LHU 0x8000 -> 0x00008000
    load_raw_i = 32'h8000_0000;
    addr_i     = 32'h2;    // addr[1]=1 -> upper half = 0x8000
    check_load("LHU boundary 0x8000 -> 0x00008000 (no sign ext)", 32'h00008000);

    // LHU max: 0xFFFF -> 0x0000FFFF
    load_raw_i = 32'hFFFF_0000;
    addr_i     = 32'h2;    // addr[1]=1 -> upper half = 0xFFFF
    check_load("LHU max 0xFFFF -> 0x0000FFFF", 32'h0000FFFF);

    // ========================================================================
    // SECTION 10: LW (funct3=010) — full 32-bit passthrough
    // Spec S1.3: rd = mem[rs1+imm][31:0]
    //   load_data_o = load_raw_i  (no extension needed)
    //   addr[1:0] is irrelevant for LW (misaligned is UB per spec)
    // ========================================================================
    $display("\n-- Section 10: LW full word passthrough --");
    funct3_i = 3'b010;   // LW

    load_raw_i = 32'hDEADBEEF;
    addr_i     = 32'h0;
    check_load("LW 0xDEADBEEF -> 0xDEADBEEF", 32'hDEADBEEF);

    load_raw_i = 32'h00000000;
    check_load("LW 0x00000000 -> 0x00000000", 32'h00000000);

    load_raw_i = 32'hFFFFFFFF;
    check_load("LW 0xFFFFFFFF -> 0xFFFFFFFF", 32'hFFFFFFFF);

    load_raw_i = 32'h80000000;
    check_load("LW 0x80000000 -> 0x80000000 (most-neg, no change)", 32'h80000000);

    load_raw_i = 32'h7FFFFFFF;
    check_load("LW 0x7FFFFFFF -> 0x7FFFFFFF (max-pos, no change)", 32'h7FFFFFFF);

    // ========================================================================
    // SECTION 11: LB/LBU sign vs zero extension contrast (same byte, both)
    // Validates the critical distinction between signed and unsigned byte loads.
    // Spec S1.3: LB=sign-extend, LBU=zero-extend (same byte extraction path)
    //
    // Byte 0xB5 (MSB=1, value=181 unsigned / -75 signed):
    //   LB  -> 0xFFFFFFB5 (sign-extended because bit 7 = 1)
    //   LBU -> 0x000000B5 (zero-extended)
    // ========================================================================
    $display("\n-- Section 11: LB vs LBU contrast (0xB5 at offset 0) --");
    load_raw_i = 32'h1234_56B5;
    addr_i     = 32'h0;     // byte_off=0; byte = 0xB5

    funct3_i = 3'b000;   // LB
    check_load("LB  0xB5 off=0 -> 0xFFFFFFB5 (sign)", 32'hFFFFFFB5);

    funct3_i = 3'b100;   // LBU
    check_load("LBU 0xB5 off=0 -> 0x000000B5 (zero)", 32'h000000B5);

    // ========================================================================
    // SECTION 12: LH/LHU sign vs zero extension contrast (same halfword, both)
    // Spec S1.3: LH=sign-extend, LHU=zero-extend
    //
    // Halfword 0xC0DE (MSB=1):
    //   LH  -> 0xFFFFC0DE (sign-extended)
    //   LHU -> 0x0000C0DE (zero-extended)
    // ========================================================================
    $display("\n-- Section 12: LH vs LHU contrast (0xC0DE at addr[1]=0) --");
    load_raw_i = 32'hBADFC0DE;
    addr_i     = 32'h0;     // addr[1]=0 -> lower half = 0xC0DE

    funct3_i = 3'b001;   // LH
    check_load("LH  0xC0DE addr[1]=0 -> 0xFFFFC0DE (sign)", 32'hFFFFC0DE);

    funct3_i = 3'b101;   // LHU
    check_load("LHU 0xC0DE addr[1]=0 -> 0x0000C0DE (zero)", 32'h0000C0DE);

    // ========================================================================
    // SECTION 13: Store path gate — verify store outputs when mem_read_i=1
    // but mem_write_i=0 still yields data_we_o=0 (store path is mem_write gated)
    // ========================================================================
    $display("\n-- Section 13: mem_read=1, mem_write=0 -> data_we still 0 --");
    rs2_i       = 32'hDEADBEEF;
    addr_i      = 32'h0;
    funct3_i    = 3'b010;   // SW funct3
    mem_write_i = 1'b0;
    mem_read_i  = 1'b1;
    load_raw_i  = 32'hCAFEBABE;
    check_store("mem_read=1 mem_write=0 SW: data_we=0", 32'h0, 4'b0000);
    // Also verify load still works in same cycle
    check_load("mem_read=1 mem_write=0 LW: load_data=0xCAFEBABE", 32'hCAFEBABE);

    // ========================================================================
    // SECTION 14: Additional byte offset coverage — LBU at all 4 offsets
    // using a carefully constructed word so each byte is distinct and known.
    // load_raw_i = 0x11_22_33_44:
    //   byte_off=0 -> [7:0]  = 0x44
    //   byte_off=1 -> [15:8] = 0x33
    //   byte_off=2 -> [23:16]= 0x22
    //   byte_off=3 -> [31:24]= 0x11
    // ========================================================================
    $display("\n-- Section 14: LBU all offsets with distinct bytes --");
    mem_write_i = 1'b0;
    mem_read_i  = 1'b1;
    funct3_i    = 3'b100;   // LBU
    load_raw_i  = 32'h11223344;

    addr_i = 32'h0; check_load("LBU all-off=0 -> 0x00000044", 32'h00000044);
    addr_i = 32'h1; check_load("LBU all-off=1 -> 0x00000033", 32'h00000033);
    addr_i = 32'h2; check_load("LBU all-off=2 -> 0x00000022", 32'h00000022);
    addr_i = 32'h3; check_load("LBU all-off=3 -> 0x00000011", 32'h00000011);

    // ========================================================================
    // SECTION 15: SB byte replication corner — rs2 upper bytes must be ignored
    // Spec S1.4 SB: store_data = {4{rs2[7:0]}}; upper bits of rs2 irrelevant.
    // rs2 = 0xDEAD_BE_42 => byte = 0x42; replicated = 0x42424242
    // ========================================================================
    $display("\n-- Section 15: SB replication ignores rs2 upper bytes --");
    mem_write_i = 1'b1;
    mem_read_i  = 1'b0;
    funct3_i    = 3'b000;   // SB
    rs2_i       = 32'hDEADBE42;
    addr_i      = 32'h0;    // offset=0; data_we=4'b0001
    check_store("SB rs2=0xDEADBE42 -> 0x42424242 data_we=0001",
                32'h42424242, 4'b0001);

    // SH halfword replication: rs2 = 0xDEAD_AB_CD; half=0xABCD
    // Replicated: 0xABCDABCD
    funct3_i = 3'b001;   // SH
    rs2_i    = 32'hDEADABCD;
    addr_i   = 32'h0;    // addr[1]=0; data_we=4'b0011
    check_store("SH rs2=0xDEADABCD -> 0xABCDABCD data_we=0011",
                32'hABCDABCD, 4'b0011);

    // ========================================================================
    // SECTION 16: Boundary values — zero data
    // ========================================================================
    $display("\n-- Section 16: Zero data boundary --");

    // SB zero byte
    funct3_i = 3'b000;   // SB
    rs2_i    = 32'h0;
    addr_i   = 32'h0;
    check_store("SB rs2=0 offset=0: 0x00000000 data_we=0001",
                32'h00000000, 4'b0001);

    // SW zero word
    funct3_i = 3'b010;   // SW
    rs2_i    = 32'h0;
    check_store("SW rs2=0: 0x00000000 data_we=1111",
                32'h00000000, 4'b1111);

    // LB zero byte at each offset
    mem_write_i = 1'b0;
    mem_read_i  = 1'b1;
    funct3_i    = 3'b000;   // LB
    load_raw_i  = 32'h0;
    addr_i      = 32'h0;
    check_load("LB zero word -> 0x00000000", 32'h00000000);

    // LW zero word
    funct3_i = 3'b010;   // LW
    check_load("LW zero word -> 0x00000000", 32'h00000000);

    // ========================================================================
    // Print summary
    // ========================================================================
    $display("\n============================================================");
    $display("RESULTS: %0d passed, %0d failed  (total %0d)",
             pass_count, fail_count, pass_count + fail_count);
    if (fail_count == 0)
      $display("ALL TESTS PASSED");
    else
      $display("SOME TESTS FAILED -- see FAIL lines above");
    $display("============================================================\n");

    $finish;
  end

endmodule
