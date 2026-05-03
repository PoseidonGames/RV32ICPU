// ============================================================================
// Module: tb_compressed_decoder
// Description: Self-checking testbench for compressed_decoder.sv.
//              Expands 16-bit RV32C instructions to 32-bit RV32I equivalents.
//              Expected values derived EXCLUSIVELY from:
//                canonical-reference.md §12 (RV32C encoding)
//                canonical-reference.md §3  (RV32I instruction formats)
//                canonical-reference.md §12.2 (compact register mapping)
//              Never reads RTL for expected values.
// Author: Beaux Cable (Verification Agent)
// Date: April 2026
// Project: RV32I Pipelined Processor
//
// RV32I encoding reference (canonical-reference.md §3):
//   R-type: {funct7[6:0], rs2[4:0], rs1[4:0], funct3[2:0], rd[4:0], opcode[6:0]}
//   I-type: {imm[11:0], rs1[4:0], funct3[2:0], rd[4:0], opcode[6:0]}
//   S-type: {imm[11:5], rs2[4:0], rs1[4:0], funct3[2:0], imm[4:0], opcode[6:0]}
//   B-type: {imm[12],imm[10:5],rs2,rs1,funct3,imm[4:1],imm[11],opcode}
//   U-type: {imm[31:12], rd[4:0], opcode[6:0]}
//   J-type: {imm[20],imm[10:1],imm[11],imm[19:12],rd[4:0],opcode[6:0]}
//
// Compact register mapping (canonical-reference.md §12.2):
//   full_reg[4:0] = {2'b01, compact_reg[2:0]}  -> x8..x15
//
// mk_btype / mk_jtype parameter convention (verified empirically):
//   The parameters logic [12:1] imm and logic [20:1] imm use indexed ranges,
//   so the passed VALUE V encodes imm[k] = (V >> (k-1)) & 1, meaning
//   V = N/2 to represent real offset N.  Equivalently: pass offset>>1.
//   Examples:
//     B-type offset=8  -> pass 12'd4    (8>>1)
//     B-type offset=-4 -> pass 12'hffe  ((-4>>1) & 0xfff)
//     J-type offset=2  -> pass 20'd1    (2>>1)
//     J-type offset=-2 -> pass 20'hfffff ((-2>>1) & 0xfffff)
//
// Coverage:
//   1. Normal operation   -- all 25 valid RV32C instructions
//   2. Boundary values    -- max/min immediates, all compact register values
//   3. All instruction types -- C0, C1, C2 quadrants
//   4. Sign extension corners -- negative immediates for ADDI, JAL, branches
//   5. Compact register mapping -- all 8 compact codes (x8..x15)
//   6. x0 / HINT special cases -- C.NOP, C.LI rd=x0, C.MV rd=x0, C.ADD rd=x0
//   7. Illegal encodings  -- all categories from §12.7
// ============================================================================

`timescale 1ns/1ps

module tb_compressed_decoder;

  // --------------------------------------------------------------------------
  // DUT ports
  // --------------------------------------------------------------------------
  logic [15:0] instr_i;
  logic [31:0] instr_o;
  logic        illegal_o;

  // --------------------------------------------------------------------------
  // DUT instantiation
  // --------------------------------------------------------------------------
  compressed_decoder dut (
    .instr_i  (instr_i),
    .instr_o  (instr_o),
    .illegal_o(illegal_o)
  );

  // --------------------------------------------------------------------------
  // Test counters
  // --------------------------------------------------------------------------
  integer pass_count;
  integer fail_count;

  // --------------------------------------------------------------------------
  // check32 -- assert 32-bit output matches expected
  // --------------------------------------------------------------------------
  task automatic check32(
    input string       label,
    input logic [31:0] got,
    input logic [31:0] exp
  );
    if (got !== exp) begin
      $display("  FAIL [%s] instr_o: got 32'h%08h, exp 32'h%08h",
               label, got, exp);
      fail_count = fail_count + 1;
    end else begin
      $display("  PASS [%s] instr_o = 32'h%08h", label, got);
      pass_count = pass_count + 1;
    end
  endtask

  // --------------------------------------------------------------------------
  // check1 -- assert 1-bit output matches expected
  // --------------------------------------------------------------------------
  task automatic check1(
    input string    label,
    input logic     got,
    input logic     exp
  );
    if (got !== exp) begin
      $display("  FAIL [%s] illegal_o: got %0b, exp %0b",
               label, got, exp);
      fail_count = fail_count + 1;
    end else begin
      $display("  PASS [%s] illegal_o = %0b", label, got);
      pass_count = pass_count + 1;
    end
  endtask

  // --------------------------------------------------------------------------
  // check_valid -- apply 16-bit input, check 32-bit output and illegal_o=0
  // --------------------------------------------------------------------------
  task automatic check_valid(
    input string       label,
    input logic [15:0] enc16,
    input logic [31:0] exp32
  );
    instr_i = enc16;
    #1;
    check32(label, instr_o, exp32);
    check1({label, "_legal"}, illegal_o, 1'b0);
  endtask

  // --------------------------------------------------------------------------
  // check_illegal -- apply 16-bit input, verify illegal_o=1, instr_o=0
  // --------------------------------------------------------------------------
  task automatic check_illegal(
    input string       label,
    input logic [15:0] enc16
  );
    instr_i = enc16;
    #1;
    check1({label, "_illegal"}, illegal_o, 1'b1);
    check32({label, "_zero"}, instr_o, 32'h00000000);
  endtask

  // ==========================================================================
  // 16-bit encoder helpers
  //
  // Each function assembles the 16-bit compressed encoding from named fields
  // exactly as described in canonical-reference.md §12.3-12.5.
  // ==========================================================================

  // --------------------------------------------------------------------------
  // C0 helpers
  // --------------------------------------------------------------------------

  // C.ADDI4SPN: 000 nzuimm[5:4|9:6|2|3] rd'[2:0] 00
  // Bit assignment (§12.3):
  //   nzuimm = {inst[10:7], inst[12:11], inst[5], inst[6], 2'b00}
  //   -> inst[10:7]=nzuimm[9:6], inst[12:11]=nzuimm[5:4],
  //      inst[5]=nzuimm[3], inst[6]=nzuimm[2]
  // Parameter: nzuimm_9_2 is logic [9:2] (8 bits, indices 9..2 of nzuimm).
  // SV [9:2] range: index k maps to physical bit (k-2), so
  //   nzuimm_9_2[k] = (VALUE >> (k-2)) & 1.
  // Pass VALUE = nzuimm >> 2 (i.e., the raw 8-bit nzuimm/4).
  function automatic logic [15:0] enc_caddi4spn(
    input logic [2:0] rdp,       // compact rd' (encodes x8..x15)
    input logic [7:0] nzuimm_div4 // nzuimm/4 -- actual nzuimm = nzuimm_div4 * 4
  );
    // nzuimm_div4[7:4] = nzuimm[9:6] -> inst[10:7]
    // nzuimm_div4[3:2] = nzuimm[5:4] -> inst[12:11]
    // nzuimm_div4[1]   = nzuimm[3]   -> inst[5]
    // nzuimm_div4[0]   = nzuimm[2]   -> inst[6]
    logic [15:0] r;
    r[1:0]   = 2'b00;
    r[4:2]   = rdp;
    r[5]     = nzuimm_div4[1];
    r[6]     = nzuimm_div4[0];
    r[10:7]  = nzuimm_div4[7:4];
    r[12:11] = nzuimm_div4[3:2];
    r[15:13] = 3'b000;
    return r;
  endfunction

  // C.LW: 010 uimm[5:3] rs1'[2:0] uimm[2|6] rd'[2:0] 00  (§12.3)
  // uimm = {inst[5], inst[12:10], inst[6], 2'b00}
  //   inst[5]=uimm[6], inst[12:10]=uimm[5:3], inst[6]=uimm[2]
  // Parameter: uimm_6_2 is logic [6:2] (5 bits, indices 6..2 of uimm).
  // Pass VALUE = (uimm >> 2) expressed as 5-bit: uimm[6]*16+uimm[5]*8+...
  function automatic logic [15:0] enc_clw(
    input logic [2:0] rs1p,
    input logic [2:0] rdp,
    input logic [4:0] uimm_6_2   // uimm bits [6:2]; uimm = uimm_6_2 * 4
  );
    // uimm_6_2[4] = uimm[6] -> inst[5]
    // uimm_6_2[3:1] = uimm[5:3] -> inst[12:10]
    // uimm_6_2[0] = uimm[2] -> inst[6]
    logic [15:0] r;
    r[1:0]   = 2'b00;
    r[4:2]   = rdp;
    r[5]     = uimm_6_2[4];
    r[6]     = uimm_6_2[0];
    r[9:7]   = rs1p;
    r[12:10] = uimm_6_2[3:1];
    r[15:13] = 3'b010;
    return r;
  endfunction

  // C.SW: 110 uimm[5:3] rs1'[2:0] uimm[2|6] rs2'[2:0] 00  (§12.3)
  // Same offset encoding as C.LW.
  function automatic logic [15:0] enc_csw(
    input logic [2:0] rs1p,
    input logic [2:0] rs2p,
    input logic [4:0] uimm_6_2
  );
    logic [15:0] r;
    r[1:0]   = 2'b00;
    r[4:2]   = rs2p;
    r[5]     = uimm_6_2[4];
    r[6]     = uimm_6_2[0];
    r[9:7]   = rs1p;
    r[12:10] = uimm_6_2[3:1];
    r[15:13] = 3'b110;
    return r;
  endfunction

  // Helper: compute uimm_6_2 value for C.LW/C.SW/C.LWSP given actual byte offset.
  // Spec: uimm = {uimm[6],uimm[5],uimm[4],uimm[3],uimm[2],2'b00} (byte offset).
  // uimm_6_2 = 5-bit VALUE encoding uimm[6:2]: value = uimm[6]*16+..+uimm[2]*1.
  // Since uimm_6_2 in [6:2] range and physical bit (k-2) maps to index k,
  // the VALUE = offset >> 2 (bottom 2 bits always 0, drop them).
  // But: the 5-bit VALUE passed to enc_clw/enc_csw must encode uimm[6:2] such that
  // bit[4] of the VALUE = uimm[6], bit[3] = uimm[5], etc.
  // VALUE[4] = uimm[6], VALUE[3] = uimm[5], VALUE[2] = uimm[4], VALUE[1] = uimm[3],
  // VALUE[0] = uimm[2].
  // So VALUE = (uimm[6]<<4)|(uimm[5]<<3)|(uimm[4]<<2)|(uimm[3]<<1)|uimm[2].
  // Since uimm[k] = (offset>>k)&1:
  //   VALUE = ((offset>>6)&1)<<4 | ((offset>>5)&1)<<3 | ((offset>>4)&1)<<2 |
  //           ((offset>>3)&1)<<1 | ((offset>>2)&1)
  // This is exactly offset >> 2 (keeping bits [6:2] as a 5-bit number) BUT
  // with the BIT ORDER MSB->LSB matching k=6->4, 5->3, etc.
  // Actually: VALUE[4]=uimm[6], VALUE[3]=uimm[5], ..., VALUE[0]=uimm[2]
  //         = {uimm[6],uimm[5],uimm[4],uimm[3],uimm[2]} = offset[6:2] as 5-bit.
  // offset[6:2] = offset>>2 (since offset[1:0]=00 always). So VALUE = offset>>2.
  // Wait: is that right? offset[6:2] is 5 bits where offset[6] is the MSB.
  // As a numeric value: offset[6]*16 + offset[5]*8 + offset[4]*4 + offset[3]*2 + offset[2]*1
  //                   = offset/4 (when offset[1:0]=0). YES! VALUE = offset/4.
  // But in [6:2] range with VALUE = offset/4:
  //   physical bit 4 = index 6 = uimm[6] = (offset/4 >> 4) & 1 = (offset>>6)&1. Correct!
  // So pass uimm_6_2 = offset/4 for C.LW/C.SW.
  // Example: offset=52, uimm_6_2 = 52/4 = 13.
  // Verify: 13 = 0b01101 -> uimm[6]=0,uimm[5]=1,uimm[4]=1,uimm[3]=0,uimm[2]=1.
  // Reconstructed uimm = 0*64+1*32+1*16+0*8+1*4+0+0 = 52. Correct!

  // --------------------------------------------------------------------------
  // C1 helpers
  // --------------------------------------------------------------------------

  // C.ADDI / C.NOP / C.LI / C.LUI / C.ADDI16SP share the same 16-bit shell:
  // funct3[2:0] nzimm[5] rd[4:0] nzimm[4:0] 01
  // Parameter imm6: raw 6-bit signed value, sign bit = imm6[5].
  function automatic logic [15:0] enc_c1_imm5(
    input logic [2:0] funct3,
    input logic [4:0] rd,
    input logic [5:0] imm6      // 6-bit immediate; sign bit is imm6[5]
  );
    logic [15:0] r;
    r[1:0]   = 2'b01;
    r[6:2]   = imm6[4:0];
    r[11:7]  = rd;
    r[12]    = imm6[5];
    r[15:13] = funct3;
    return r;
  endfunction

  // C.JAL / C.J: funct3=001/101, scrambled 11-bit immediate (§12.4)
  // Bit assignment:
  //   inst[12]=imm[11], inst[11]=imm[4], inst[10:9]=imm[9:8],
  //   inst[8]=imm[10],  inst[7]=imm[6],  inst[6]=imm[7],
  //   inst[5:3]=imm[3:1], inst[2]=imm[5]
  // Parameter: jimm is logic [11:1] representing bits [11:1] of the offset.
  // jimm[11]=imm[11] is the MSB. Pass actual_offset>>1 as the VALUE?
  // No: pass the actual offset BITS in the [11:1] indexed parameter:
  //   jimm[k] = imm[k], so pass the offset value directly (offset[11:1] as-is).
  // In SV [11:1] range: VALUE V, index k -> physical bit (k-1).
  // jimm[k] = (V >> (k-1)) & 1. For offset N: jimm[k]=1 when bit k of N is set.
  // So (V >> (k-1)) & 1 = (N >> k) & 1 -> V = N >> 1. Pass offset>>1.
  function automatic logic [15:0] enc_cjal_cj(
    input logic [2:0]  funct3,  // 001=C.JAL, 101=C.J
    input logic [10:0] jimm     // offset>>1 (so jimm represents imm[11:1]/2)
  );
    // jimm[10] = imm[11] -> inst[12]
    // jimm[3]  = imm[4]  -> inst[11]
    // jimm[9:8]= imm[10:9] -> ... but wait: the SV [11:1] parameter jimm
    // has index k, and jimm[k] = (VALUE >> (k-1)) & 1.
    // For imm[11] = jimm[11]: jimm[11]=(VALUE>>10)&1.
    // Mapping: inst[12]=imm[11]=jimm[11]=(VALUE>>10)&1
    //          inst[11]=imm[4] =jimm[4] =(VALUE>>3 )&1
    //          inst[10:9]=imm[9:8]: imm[9]=jimm[9]=(VALUE>>8)&1, imm[8]=jimm[8]=(VALUE>>7)&1
    //          inst[8]=imm[10]=jimm[10]=(VALUE>>9)&1
    //          inst[7]=imm[6] =jimm[6] =(VALUE>>5)&1
    //          inst[6]=imm[7] =jimm[7] =(VALUE>>6)&1
    //          inst[5:3]=imm[3:1]: each imm[k]=jimm[k]=(VALUE>>(k-1))&1
    //          inst[2]=imm[5]=jimm[5]=(VALUE>>4)&1
    logic [15:0] r;
    r[1:0]  = 2'b01;
    r[2]    = (jimm >> 4) & 1;  // imm[5]
    r[3]    = (jimm >> 0) & 1;  // imm[1]
    r[4]    = (jimm >> 1) & 1;  // imm[2]
    r[5]    = (jimm >> 2) & 1;  // imm[3]
    r[6]    = (jimm >> 6) & 1;  // imm[7]
    r[7]    = (jimm >> 5) & 1;  // imm[6]
    r[8]    = (jimm >> 9) & 1;  // imm[10]
    r[9]    = (jimm >> 7) & 1;  // imm[8]
    r[10]   = (jimm >> 8) & 1;  // imm[9]
    r[11]   = (jimm >> 3) & 1;  // imm[4]
    r[12]   = (jimm >> 10) & 1; // imm[11]
    r[15:13]= funct3;
    return r;
  endfunction

  // C.ADDI16SP special encoding (§12.4): funct3=011, rd=x2
  // nzimm = {inst[12], inst[4:3], inst[5], inst[2], inst[6], 4'b0000}
  //   inst[12]=nzimm[9], inst[6]=nzimm[4], inst[5]=nzimm[6],
  //   inst[4:3]=nzimm[8:7], inst[2]=nzimm[5]
  // Parameter: nzimm_9_4 is a 6-bit value representing nzimm bits [9:4].
  // In SV [9:4] range: index k -> physical bit (k-4).
  // nzimm[k] = (VALUE >> (k-4)) & 1. Pass VALUE = nzimm >> 4 (i.e., nzimm/16).
  // Example: nzimm=-16=10'b1111110000, nzimm[9:4]=6'b111110, VALUE=62.
  // Verify: nzimm[9]=(62>>5)&1=1, nzimm[8]=(62>>4)&1=1, nzimm[7]=(62>>3)&1=1,
  //         nzimm[6]=(62>>2)&1=1, nzimm[5]=(62>>1)&1=1, nzimm[4]=(62>>0)&1=0. Correct!
  function automatic logic [15:0] enc_caddi16sp(
    input logic [5:0] nzimm_div16  // nzimm/16 (the 6-bit nzimm[9:4] value)
  );
    // nzimm[9] = (nzimm_div16>>5)&1 -> inst[12]
    // nzimm[8] = (nzimm_div16>>4)&1 -> inst[4]
    // nzimm[7] = (nzimm_div16>>3)&1 -> inst[3]
    // nzimm[6] = (nzimm_div16>>2)&1 -> inst[5]
    // nzimm[5] = (nzimm_div16>>1)&1 -> inst[2]
    // nzimm[4] = (nzimm_div16>>0)&1 -> inst[6]
    logic [15:0] r;
    r[1:0]   = 2'b01;
    r[2]     = (nzimm_div16 >> 1) & 1;  // nzimm[5]
    r[3]     = (nzimm_div16 >> 3) & 1;  // nzimm[7]
    r[4]     = (nzimm_div16 >> 4) & 1;  // nzimm[8]
    r[5]     = (nzimm_div16 >> 2) & 1;  // nzimm[6]
    r[6]     = (nzimm_div16 >> 0) & 1;  // nzimm[4]
    r[11:7]  = 5'd2;                     // rd = x2
    r[12]    = (nzimm_div16 >> 5) & 1;  // nzimm[9]
    r[15:13] = 3'b011;
    return r;
  endfunction

  // C.SRLI / C.SRAI / C.ANDI: funct3=100, inst[11:10] encodes op (§12.4)
  // inst[12]=shamt[5]/sign, inst[9:7]=rd', inst[6:2]=shamt[4:0]/imm[4:0]
  function automatic logic [15:0] enc_c1_alu(
    input logic [1:0] op,        // 00=SRLI, 01=SRAI, 10=ANDI
    input logic [2:0] rdp,
    input logic [5:0] imm6       // shamt or signed imm (6-bit)
  );
    logic [15:0] r;
    r[1:0]   = 2'b01;
    r[6:2]   = imm6[4:0];
    r[9:7]   = rdp;
    r[11:10] = op;
    r[12]    = imm6[5];
    r[15:13] = 3'b100;
    return r;
  endfunction

  // C.SUB/C.XOR/C.OR/C.AND: funct3=100, inst[11:10]=11, inst[12]=0 (§12.4)
  // inst[9:7]=rd', inst[6:5]=op, inst[4:2]=rs2'
  function automatic logic [15:0] enc_c1_arith(
    input logic [1:0] op,        // 00=SUB, 01=XOR, 10=OR, 11=AND
    input logic [2:0] rdp,
    input logic [2:0] rs2p
  );
    logic [15:0] r;
    r[1:0]   = 2'b01;
    r[4:2]   = rs2p;
    r[6:5]   = op;
    r[9:7]   = rdp;
    r[11:10] = 2'b11;
    r[12]    = 1'b0;
    r[15:13] = 3'b100;
    return r;
  endfunction

  // C.BEQZ / C.BNEZ: funct3=110/111 (§12.4)
  // off = {inst[12],inst[6:5],inst[2],inst[11:10],inst[4:3],1'b0}
  //   inst[12]=off[8], inst[11:10]=off[4:3], inst[9:7]=rs1'
  //   inst[6:5]=off[7:6], inst[4:3]=off[2:1], inst[2]=off[5]
  // Parameter: off_8_1 is an 8-bit VALUE representing off[8:1].
  // off[8:1] in [8:1] SV range: index k -> physical bit (k-1).
  // off[k] = (VALUE >> (k-1)) & 1. For real offset OFF: off[k]=(OFF>>k)&1.
  // So (VALUE>>(k-1))&1 = (OFF>>k)&1 -> VALUE = OFF>>1. Pass offset>>1.
  function automatic logic [15:0] enc_cbranch(
    input logic [2:0] funct3,   // 110=BEQZ, 111=BNEZ
    input logic [2:0] rs1p,
    input logic [7:0] off_div2  // offset>>1 (pass actual_offset/2)
  );
    // off[k] = (off_div2 >> (k-1)) & 1 for k=1..8
    // Spec §12.4 bit assignment:
    //   inst[12] = off[8], inst[11:10] = off[4:3],
    //   inst[6:5] = off[7:6], inst[4:3] = off[2:1], inst[2] = off[5]
    logic [15:0] r;
    logic off1, off2, off3, off4, off5, off6, off7, off8;
    off1 = off_div2[0];  // (off_div2>>(1-1))&1 = off_div2[0]
    off2 = off_div2[1];
    off3 = off_div2[2];
    off4 = off_div2[3];
    off5 = off_div2[4];
    off6 = off_div2[5];
    off7 = off_div2[6];
    off8 = off_div2[7];
    r[1:0]   = 2'b01;
    r[2]     = off5;              // inst[2]  = off[5]
    r[3]     = off1;              // inst[3]  = off[1]
    r[4]     = off2;              // inst[4]  = off[2]
    r[5]     = off6;              // inst[5]  = off[6] (inst[6:5]=off[7:6])
    r[6]     = off7;              // inst[6]  = off[7]
    r[9:7]   = rs1p;              // inst[9:7] = rs1'
    r[10]    = off3;              // inst[10] = off[3] (inst[11:10]=off[4:3])
    r[11]    = off4;              // inst[11] = off[4]
    r[12]    = off8;              // inst[12] = off[8]
    r[15:13] = funct3;
    return r;
  endfunction

  // --------------------------------------------------------------------------
  // C2 helpers
  // --------------------------------------------------------------------------

  // C.SLLI: 000 shamt[5] rd[4:0] shamt[4:0] 10  (§12.5)
  function automatic logic [15:0] enc_cslli(
    input logic [4:0] rd,
    input logic [5:0] shamt      // 6-bit; shamt[5] must be 0 for legal RV32
  );
    logic [15:0] r;
    r[1:0]   = 2'b10;
    r[6:2]   = shamt[4:0];
    r[11:7]  = rd;
    r[12]    = shamt[5];
    r[15:13] = 3'b000;
    return r;
  endfunction

  // C.LWSP: 010 uimm[5] rd[4:0] uimm[4:2|7:6] 10  (§12.5)
  // uimm = {inst[3:2], inst[12], inst[6:4], 2'b00}
  //   inst[12]=uimm[5], inst[6:4]=uimm[4:2], inst[3:2]=uimm[7:6]
  // Parameter: uimm_7_2 is a 6-bit VALUE representing uimm bits [7:2].
  // In SV [7:2] range: index k -> physical bit (k-2).
  // uimm[k] = (VALUE >> (k-2)) & 1. For real offset U: uimm[k]=(U>>k)&1.
  // So VALUE = U >> 2 (i.e., offset/4). Pass offset/4.
  // Example: offset=16, VALUE=4. Verify: uimm[4]=(4>>2)&1=1 -> offset=16. Correct.
  function automatic logic [15:0] enc_clwsp(
    input logic [4:0] rd,
    input logic [5:0] uimm_div4  // uimm/4 (uimm[7:2] value)
  );
    // uimm[7] = (uimm_div4>>5)&1 -> inst[3]
    // uimm[6] = (uimm_div4>>4)&1 -> inst[2]
    // uimm[5] = (uimm_div4>>3)&1 -> inst[12]
    // uimm[4] = (uimm_div4>>2)&1 -> inst[6]
    // uimm[3] = (uimm_div4>>1)&1 -> inst[5]
    // uimm[2] = (uimm_div4>>0)&1 -> inst[4]
    logic [15:0] r;
    r[1:0]   = 2'b10;
    r[2]     = (uimm_div4 >> 4) & 1;  // inst[2] = uimm[6]
    r[3]     = (uimm_div4 >> 5) & 1;  // inst[3] = uimm[7]
    r[4]     = (uimm_div4 >> 0) & 1;  // inst[4] = uimm[2]
    r[5]     = (uimm_div4 >> 1) & 1;  // inst[5] = uimm[3]
    r[6]     = (uimm_div4 >> 2) & 1;  // inst[6] = uimm[4]
    r[11:7]  = rd;
    r[12]    = (uimm_div4 >> 3) & 1;  // inst[12] = uimm[5]
    r[15:13] = 3'b010;
    return r;
  endfunction

  // C.JR / C.MV / C.EBREAK / C.JALR / C.ADD: funct3=100  (§12.5)
  // inst[12]=bit12, inst[11:7]=rd_rs1, inst[6:2]=rs2
  function automatic logic [15:0] enc_c2_misc(
    input logic        bit12,
    input logic [4:0]  rd_rs1,
    input logic [4:0]  rs2
  );
    logic [15:0] r;
    r[1:0]   = 2'b10;
    r[6:2]   = rs2;
    r[11:7]  = rd_rs1;
    r[12]    = bit12;
    r[15:13] = 3'b100;
    return r;
  endfunction

  // C.SWSP: 110 uimm[5:2|7:6] rs2[4:0] 10  (§12.5)
  // uimm = {inst[8:7], inst[12:9], 2'b00}
  //   inst[12:9]=uimm[5:2], inst[8:7]=uimm[7:6]
  // Parameter: uimm_div4 = uimm/4 (offset/4).
  // uimm[k] = (uimm_div4 >> (k-2)) & 1 for k=2..7.
  function automatic logic [15:0] enc_cswsp(
    input logic [4:0] rs2,
    input logic [5:0] uimm_div4  // uimm/4 (offset/4)
  );
    // uimm[5] = (uimm_div4>>3)&1 -> inst[12]
    // uimm[4] = (uimm_div4>>2)&1 -> inst[11]
    // uimm[3] = (uimm_div4>>1)&1 -> inst[10]
    // uimm[2] = (uimm_div4>>0)&1 -> inst[9]
    // uimm[7] = (uimm_div4>>5)&1 -> inst[8]
    // uimm[6] = (uimm_div4>>4)&1 -> inst[7]
    logic [15:0] r;
    r[1:0]   = 2'b10;
    r[6:2]   = rs2;
    r[7]     = (uimm_div4 >> 4) & 1;  // inst[7] = uimm[6]
    r[8]     = (uimm_div4 >> 5) & 1;  // inst[8] = uimm[7]
    r[9]     = (uimm_div4 >> 0) & 1;  // inst[9] = uimm[2]
    r[10]    = (uimm_div4 >> 1) & 1;  // inst[10] = uimm[3]
    r[11]    = (uimm_div4 >> 2) & 1;  // inst[11] = uimm[4]
    r[12]    = (uimm_div4 >> 3) & 1;  // inst[12] = uimm[5]
    r[15:13] = 3'b110;
    return r;
  endfunction

  // ==========================================================================
  // RV32I 32-bit instruction builders  (canonical-reference.md §3)
  // ==========================================================================

  // I-type: {imm[11:0], rs1[4:0], funct3[2:0], rd[4:0], opcode[6:0]}
  function automatic logic [31:0] mk_itype(
    input logic [6:0]  opcode,
    input logic [4:0]  rd,
    input logic [2:0]  funct3,
    input logic [4:0]  rs1,
    input logic [11:0] imm12
  );
    return {imm12, rs1, funct3, rd, opcode};
  endfunction

  // S-type: {imm[11:5], rs2[4:0], rs1[4:0], funct3[2:0], imm[4:0], opcode[6:0]}
  function automatic logic [31:0] mk_stype(
    input logic [6:0]  opcode,
    input logic [4:0]  rs1,
    input logic [4:0]  rs2,
    input logic [2:0]  funct3,
    input logic [11:0] imm12
  );
    return {imm12[11:5], rs2, rs1, funct3, imm12[4:0], opcode};
  endfunction

  // R-type: {funct7[6:0], rs2[4:0], rs1[4:0], funct3[2:0], rd[4:0], opcode[6:0]}
  function automatic logic [31:0] mk_rtype(
    input logic [6:0] opcode,
    input logic [4:0] rd,
    input logic [2:0] funct3,
    input logic [4:0] rs1,
    input logic [4:0] rs2,
    input logic [6:0] funct7
  );
    return {funct7, rs2, rs1, funct3, rd, opcode};
  endfunction

  // U-type: {imm[31:12], rd[4:0], opcode[6:0]}
  function automatic logic [31:0] mk_utype(
    input logic [6:0]  opcode,
    input logic [4:0]  rd,
    input logic [19:0] imm_upper  // bits [31:12]
  );
    return {imm_upper, rd, opcode};
  endfunction

  // B-type: {imm[12],imm[10:5],rs2,rs1,funct3,imm[4:1],imm[11],opcode}
  // CONVENTION: The parameter logic [12:1] imm uses SV indexed range [12:1].
  // Physical bit (k-1) of the stored VALUE maps to imm[k].
  // So imm[k] = (VALUE >> (k-1)) & 1. To encode real offset OFF: imm[k]=(OFF>>k)&1.
  // Therefore: (VALUE>>(k-1))&1 = (OFF>>k)&1 -> VALUE = OFF>>1. Pass offset>>1.
  function automatic logic [31:0] mk_btype(
    input logic [6:0]  opcode,
    input logic [4:0]  rs1,
    input logic [4:0]  rs2,
    input logic [2:0]  funct3,
    input logic [12:1] imm      // PASS offset>>1 to get the desired branch offset
  );
    return {imm[12], imm[10:5], rs2, rs1, funct3, imm[4:1], imm[11], opcode};
  endfunction

  // J-type: {imm[20],imm[10:1],imm[11],imm[19:12],rd,opcode}
  // CONVENTION: Same as B-type -- pass offset>>1 to [20:1] parameter.
  function automatic logic [31:0] mk_jtype(
    input logic [6:0]  opcode,
    input logic [4:0]  rd,
    input logic [20:1] imm      // PASS offset>>1 to get the desired jump offset
  );
    return {imm[20], imm[10:1], imm[11], imm[19:12], rd, opcode};
  endfunction

  // ==========================================================================
  // Test body
  // ==========================================================================
  initial begin
    pass_count = 0;
    fail_count = 0;
    instr_i    = 16'h0;

    // ========================================================================
    // SECTION 1: Compact register mapping (§12.2)
    //
    // full_reg[4:0] = {2'b01, compact_reg[2:0]} -> x8..x15
    //
    // Verified via C.LW with rs1'=x8 (compact=000), varying rd' through 0..7.
    // C.LW with offset=0: LW rd', 0(rs1')
    // 32-bit: I-type, LW opcode=0000011, funct3=010
    //   {12'h0, rs1[4:0], 3'b010, rd[4:0], 7'b0000011}
    // ========================================================================
    $display("\n--- Section 1: Compact register mapping (§12.2) ---");
    begin
      integer compact;
      logic [4:0] full_reg;
      logic [15:0] enc16;
      logic [31:0] exp32;
      for (compact = 0; compact < 8; compact = compact + 1) begin
        full_reg = {2'b01, compact[2:0]};  // x8..x15
        // C.LW offset=0: uimm_6_2 = 0
        enc16 = enc_clw(3'b000, compact[2:0], 5'b00000);
        // LW full_reg, 0(x8)
        exp32 = mk_itype(7'b0000011, full_reg, 3'b010, 5'd8, 12'd0);
        check_valid(
          $sformatf("CReg_map_compact%0d_x%0d", compact, full_reg),
          enc16, exp32);
      end
    end

    // ========================================================================
    // SECTION 2: C0 Quadrant (bits[1:0]=00) (§12.3)
    // ========================================================================
    $display("\n--- Section 2: C0 Quadrant ---");

    // -----------------------------------------------------------------------
    // C.ADDI4SPN: ADDI rd', x2, nzuimm  (§12.3)
    // nzuimm = {inst[10:7], inst[12:11], inst[5], inst[6], 2'b00}
    //
    // Test 1: rd'=x8 (compact=000), nzuimm=32
    //   enc_caddi4spn argument = nzuimm/4 = 32/4 = 8 = 8'b00001000
    //   32-bit: ADDI x8, x2, 32 = {12'd32, x2, 3'b000, x8, 7'b0010011}
    // -----------------------------------------------------------------------
    check_valid("CADDI4SPN_x8_nzuimm32",
      enc_caddi4spn(3'b000, 8'd8),  // nzuimm=32 -> pass 8 (=32/4)
      mk_itype(7'b0010011, 5'd8, 3'b000, 5'd2, 12'd32));

    // Test 2: rd'=x9 (compact=001), nzuimm=4 (minimum non-zero)
    //   enc argument = 4/4 = 1 = 8'b00000001
    //   32-bit: ADDI x9, x2, 4
    check_valid("CADDI4SPN_x9_nzuimm4",
      enc_caddi4spn(3'b001, 8'd1),  // nzuimm=4 -> pass 1 (=4/4)
      mk_itype(7'b0010011, 5'd9, 3'b000, 5'd2, 12'd4));

    // Test 3: rd'=x10 (compact=010), nzuimm=252 (=63*4)
    //   enc argument = 252/4 = 63 = 8'b00111111
    //   32-bit: ADDI x10, x2, 252
    check_valid("CADDI4SPN_x10_nzuimm252",
      enc_caddi4spn(3'b010, 8'd63),  // nzuimm=252 -> pass 63
      mk_itype(7'b0010011, 5'd10, 3'b000, 5'd2, 12'd252));

    // Test 4: rd'=x11, nzuimm=1016 (=254*4)
    //   enc argument = 1016/4 = 254 = 8'b11111110
    //   32-bit: ADDI x11, x2, 1016
    check_valid("CADDI4SPN_x11_nzuimm1016",
      enc_caddi4spn(3'b011, 8'd254),  // nzuimm=1016 -> pass 254
      mk_itype(7'b0010011, 5'd11, 3'b000, 5'd2, 12'd1016));

    // -----------------------------------------------------------------------
    // C.LW: LW rd', uimm(rs1')  (§12.3)
    // uimm = {inst[5], inst[12:10], inst[6], 2'b00}
    // enc_clw uimm_6_2 argument = uimm/4 (5-bit, indices [6:2] of uimm / 4).
    //
    // Test 1: rs1'=x8, rd'=x9, offset=12 -> uimm_6_2 = 12/4 = 3 = 5'b00011
    //   32-bit: LW x9, 12(x8)
    // -----------------------------------------------------------------------
    check_valid("CLW_rs1x8_rdx9_off12",
      enc_clw(3'b000, 3'b001, 5'd3),  // offset=12 -> pass 3
      mk_itype(7'b0000011, 5'd9, 3'b010, 5'd8, 12'd12));

    // Test 2: rs1'=x9, rd'=x8, offset=0
    check_valid("CLW_rs1x9_rdx8_off0",
      enc_clw(3'b001, 3'b000, 5'd0),
      mk_itype(7'b0000011, 5'd8, 3'b010, 5'd9, 12'd0));

    // Test 3: rs1'=x15, rd'=x15, offset=124 (=31*4, max)
    //   uimm_6_2 = 124/4 = 31 = 5'b11111
    check_valid("CLW_rs1x15_rdx15_off124",
      enc_clw(3'b111, 3'b111, 5'd31),  // offset=124 -> pass 31
      mk_itype(7'b0000011, 5'd15, 3'b010, 5'd15, 12'd124));

    // Test 4: rs1'=x10, rd'=x11, offset=4 -> uimm_6_2 = 4/4 = 1
    check_valid("CLW_rs1x10_rdx11_off4",
      enc_clw(3'b010, 3'b011, 5'd1),
      mk_itype(7'b0000011, 5'd11, 3'b010, 5'd10, 12'd4));

    // -----------------------------------------------------------------------
    // C.SW: SW rs2', uimm(rs1')  (§12.3)
    // Same offset encoding as C.LW.
    //
    // Test 1: rs1'=x10, rs2'=x11, offset=8 -> uimm_6_2 = 8/4 = 2
    //   32-bit: SW x11, 8(x10)
    //   S-type: {imm[11:5]=7'b0000000, rs2=x11, rs1=x10, 3'b010,
    //            imm[4:0]=5'b01000, 7'b0100011}
    // -----------------------------------------------------------------------
    check_valid("CSW_rs1x10_rs2x11_off8",
      enc_csw(3'b010, 3'b011, 5'd2),  // offset=8 -> pass 2
      mk_stype(7'b0100011, 5'd10, 5'd11, 3'b010, 12'd8));

    // Test 2: rs1'=x8, rs2'=x8, offset=0
    check_valid("CSW_rs1x8_rs2x8_off0",
      enc_csw(3'b000, 3'b000, 5'd0),
      mk_stype(7'b0100011, 5'd8, 5'd8, 3'b010, 12'd0));

    // Test 3: rs1'=x8, rs2'=x9, offset=52 -> uimm_6_2 = 52/4 = 13 = 5'b01101
    //   52 = 0b110100: uimm[6]=0,uimm[5]=1,uimm[4]=1,uimm[3]=0,uimm[2]=1
    //   32-bit: SW x9, 52(x8)
    check_valid("CSW_rs1x8_rs2x9_off52",
      enc_csw(3'b000, 3'b001, 5'd13),  // offset=52 -> pass 13
      mk_stype(7'b0100011, 5'd8, 5'd9, 3'b010, 12'd52));

    // ========================================================================
    // SECTION 3: C1 Quadrant (bits[1:0]=01) (§12.4)
    // ========================================================================
    $display("\n--- Section 3: C1 Quadrant ---");

    // -----------------------------------------------------------------------
    // C.NOP: ADDI x0, x0, 0 = 32'h00000013  (§12.4)
    // funct3=000, rd=x0, imm6=0
    // -----------------------------------------------------------------------
    check_valid("CNOP",
      enc_c1_imm5(3'b000, 5'd0, 6'b000000),
      32'h00000013);

    // -----------------------------------------------------------------------
    // C.ADDI: ADDI rd, rd, sext(nzimm)  (§12.4, funct3=000, rd!=x0)
    //
    // Test 1: rd=x5, imm=+3 (6'b000011)
    //   32-bit: ADDI x5, x5, 3
    // -----------------------------------------------------------------------
    check_valid("CADDI_x5_p3",
      enc_c1_imm5(3'b000, 5'd5, 6'b000011),
      mk_itype(7'b0010011, 5'd5, 3'b000, 5'd5, 12'sd3));

    // Test 2: rd=x5, imm=-1 (6'b111111 sext -> 12'hFFF)
    check_valid("CADDI_x5_m1",
      enc_c1_imm5(3'b000, 5'd5, 6'b111111),
      mk_itype(7'b0010011, 5'd5, 3'b000, 5'd5, 12'hFFF));

    // Test 3: rd=x10, imm=+15 (6'b001111)
    check_valid("CADDI_x10_p15",
      enc_c1_imm5(3'b000, 5'd10, 6'b001111),
      mk_itype(7'b0010011, 5'd10, 3'b000, 5'd10, 12'sd15));

    // Test 4: rd=x1, imm=-16 (minimum 6-bit signed: 6'b110000 sext -> 12'hFF0)
    check_valid("CADDI_x1_m16",
      enc_c1_imm5(3'b000, 5'd1, 6'b110000),
      mk_itype(7'b0010011, 5'd1, 3'b000, 5'd1, 12'hFF0));

    // -----------------------------------------------------------------------
    // C.JAL: JAL x1, sext(imm)  (§12.4, funct3=001, RV32 only)
    //
    // enc_cjal_cj argument = jimm = offset>>1
    // mk_jtype argument = offset>>1 (see convention in file header)
    //
    // Test 1: offset=+2 -> jimm=1, mk_jtype pass 1
    //   32-bit: JAL x1, 2
    //   J-type: {imm[20],imm[10:1],imm[11],imm[19:12],x1,1101111}
    //   imm=2: only imm[1]=1. mk_jtype pass value=1.
    // -----------------------------------------------------------------------
    check_valid("CJAL_p2",
      enc_cjal_cj(3'b001, 11'd1),  // offset=2 -> jimm=2>>1=1
      mk_jtype(7'b1101111, 5'd1, 20'd1));  // offset=2 -> pass 2>>1=1

    // Test 2: offset=-2 -> jimm = (-2>>1) & 0x7FF = 0x7FF (all 11 bits set)
    //   mk_jtype pass (-2>>1) & 0xFFFFF = 0xFFFFF
    //   32-bit: JAL x1, -2
    check_valid("CJAL_m2",
      enc_cjal_cj(3'b001, 11'h7FF),  // offset=-2 -> jimm=-2>>1=(-1)&0x7FF=0x7FF
      mk_jtype(7'b1101111, 5'd1, 20'hFFFFF));  // -2>>1=-1 -> 0xFFFFF

    // Test 3: offset=+1024 -> jimm=1024>>1=512=20'b00000000001000000000... wait
    //   1024 = 0b10000000000. imm[10]=1.
    //   jimm = 1024>>1 = 512. mk_jtype pass 512.
    check_valid("CJAL_p1024",
      enc_cjal_cj(3'b001, 11'd512),  // offset=1024 -> jimm=512
      mk_jtype(7'b1101111, 5'd1, 20'd512));  // offset=1024 -> pass 512

    // -----------------------------------------------------------------------
    // C.LI: ADDI rd, x0, sext(imm)  (§12.4, funct3=010)
    //
    // Test 1: rd=x10, imm=+5 (6'b000101)
    //   32-bit: ADDI x10, x0, 5
    // -----------------------------------------------------------------------
    check_valid("CLI_x10_p5",
      enc_c1_imm5(3'b010, 5'd10, 6'b000101),
      mk_itype(7'b0010011, 5'd10, 3'b000, 5'd0, 12'sd5));

    // Test 2: rd=x10, imm=-1
    check_valid("CLI_x10_m1",
      enc_c1_imm5(3'b010, 5'd10, 6'b111111),
      mk_itype(7'b0010011, 5'd10, 3'b000, 5'd0, 12'hFFF));

    // Test 3: rd=x1, imm=-16 (sext 6'b110000 -> 12'hFF0)
    check_valid("CLI_x1_m16",
      enc_c1_imm5(3'b010, 5'd1, 6'b110000),
      mk_itype(7'b0010011, 5'd1, 3'b000, 5'd0, 12'hFF0));

    // -----------------------------------------------------------------------
    // C.LUI: LUI rd, sext(nzimm[17:12])  (§12.4, funct3=011, rd!={x0,x2})
    // nzimm = {inst[12], inst[6:2]} 6-bit signed -> sign-extended to U-type.
    // LUI rd, imm_upper where imm_upper = sext(nzimm[5:0]) at bits [31:12].
    //
    // Test 1: rd=x3, nzimm6=6'b010010 (=18, positive)
    //   sext(18) = 18 -> LUI x3, 18 -> imm_upper = 20'h00012
    //   32-bit: {20'h00012, x3, 7'b0110111}
    // -----------------------------------------------------------------------
    check_valid("CLUI_x3_nzimm18",
      enc_c1_imm5(3'b011, 5'd3, 6'b010010),
      mk_utype(7'b0110111, 5'd3, 20'h00012));

    // Test 2: rd=x4, nzimm6=6'b000001 (=1)
    //   LUI x4, 1 -> imm_upper = 20'h00001
    check_valid("CLUI_x4_nzimm1",
      enc_c1_imm5(3'b011, 5'd4, 6'b000001),
      mk_utype(7'b0110111, 5'd4, 20'h00001));

    // Test 3: rd=x3, nzimm6=6'b111111 (-1 signed)
    //   sext(-1) -> imm_upper = 20'hFFFFF
    //   LUI x3, 0xFFFFF -> rd = 0xFFFFF000
    check_valid("CLUI_x3_nzimm_m1",
      enc_c1_imm5(3'b011, 5'd3, 6'b111111),
      mk_utype(7'b0110111, 5'd3, 20'hFFFFF));

    // -----------------------------------------------------------------------
    // C.ADDI16SP: ADDI x2, x2, sext(nzimm)  (§12.4, funct3=011, rd=x2)
    // nzimm scaled x16 = {inst[12],inst[4:3],inst[5],inst[2],inst[6], 4'b0000}
    // enc_caddi16sp argument = nzimm/16 (nzimm[9:4] value).
    //
    // Test 1: nzimm=+32 -> nzimm/16 = 2 = 6'b000010
    //   32-bit: ADDI x2, x2, 32 = {12'sd32, x2, 3'b000, x2, 7'b0010011}
    // -----------------------------------------------------------------------
    check_valid("CADDI16SP_p32",
      enc_caddi16sp(6'd2),  // nzimm=32 -> pass 2
      mk_itype(7'b0010011, 5'd2, 3'b000, 5'd2, 12'sd32));

    // Test 2: nzimm=-16 -> nzimm/16 = -1 -> 6-bit signed = 6'b111111 = 63
    //   -16 in 10-bit signed: 0b1111110000. nzimm[9:4]=6'b111110=62.
    //   Wait: -16/16 = -1. In 6-bit range [9:4]: -1 = 0b111111 = 63.
    //   But nzimm[9:4] for nzimm=-16:
    //     -16 = 10'b11_1111_0000. nzimm[9]=1,nzimm[8]=1,...,nzimm[5]=1,nzimm[4]=0.
    //     VALUE for [9:4] = sum(nzimm[k]*2^(k-4)) = 0+2+4+8+16+32 = 62.
    //   Pass 62.
    //   32-bit: ADDI x2, x2, -16 (imm12 = 12'hFF0)
    //   Spec-expected: ADDI x2, x2, -16.
    check_valid("CADDI16SP_m16",
      enc_caddi16sp(6'd63),  // nzimm=-16: nzimm/16=-1, 6-bit=63
      mk_itype(7'b0010011, 5'd2, 3'b000, 5'd2, 12'hFF0));

    // Test 3: nzimm=+496 (max positive: 9-bit unsigned, nzimm[9:4]=6'b011111=31)
    //   496 = 0b0_1111_1_0000. nzimm[9]=0,nzimm[8]=1,...,nzimm[4]=0? Let me compute.
    //   496/16=31. Pass 31.
    //   32-bit: ADDI x2, x2, 496
    check_valid("CADDI16SP_p496",
      enc_caddi16sp(6'd31),  // nzimm=496 -> pass 31
      mk_itype(7'b0010011, 5'd2, 3'b000, 5'd2, 12'sd496));

    // -----------------------------------------------------------------------
    // C.SRLI: SRLI rd', rd', shamt  (§12.4, funct3=100, inst[11:10]=00)
    // shamt={inst[12],inst[6:2]}. shamt[5]=0 required for legal RV32.
    // 32-bit: I-type SRLI = {7'b0000000, shamt[4:0], rs1, 3'b101, rd, 7'b0010011}
    //
    // Test 1: rd'=x8 (compact=000), shamt=4
    // -----------------------------------------------------------------------
    check_valid("CSRLI_x8_shamt4",
      enc_c1_alu(2'b00, 3'b000, 6'b000100),
      mk_itype(7'b0010011, 5'd8, 3'b101, 5'd8,
               {7'b0000000, 5'd4}));

    // Test 2: rd'=x9, shamt=1
    check_valid("CSRLI_x9_shamt1",
      enc_c1_alu(2'b00, 3'b001, 6'b000001),
      mk_itype(7'b0010011, 5'd9, 3'b101, 5'd9,
               {7'b0000000, 5'd1}));

    // Test 3: rd'=x10, shamt=31 (max for RV32)
    check_valid("CSRLI_x10_shamt31",
      enc_c1_alu(2'b00, 3'b010, 6'b011111),
      mk_itype(7'b0010011, 5'd10, 3'b101, 5'd10,
               {7'b0000000, 5'd31}));

    // -----------------------------------------------------------------------
    // C.SRAI: SRAI rd', rd', shamt  (§12.4, funct3=100, inst[11:10]=01)
    // 32-bit: I-type SRAI = {7'b0100000, shamt[4:0], rs1, 3'b101, rd, 7'b0010011}
    //
    // Test 1: rd'=x9, shamt=3
    // -----------------------------------------------------------------------
    check_valid("CSRAI_x9_shamt3",
      enc_c1_alu(2'b01, 3'b001, 6'b000011),
      mk_itype(7'b0010011, 5'd9, 3'b101, 5'd9,
               {7'b0100000, 5'd3}));

    // Test 2: rd'=x8, shamt=7
    check_valid("CSRAI_x8_shamt7",
      enc_c1_alu(2'b01, 3'b000, 6'b000111),
      mk_itype(7'b0010011, 5'd8, 3'b101, 5'd8,
               {7'b0100000, 5'd7}));

    // Test 3: rd'=x15, shamt=1
    check_valid("CSRAI_x15_shamt1",
      enc_c1_alu(2'b01, 3'b111, 6'b000001),
      mk_itype(7'b0010011, 5'd15, 3'b101, 5'd15,
               {7'b0100000, 5'd1}));

    // -----------------------------------------------------------------------
    // C.ANDI: ANDI rd', rd', sext(imm)  (§12.4, funct3=100, inst[11:10]=10)
    //
    // Test 1: rd'=x10, imm=+7 (6'b000111 -> 12'sd7)
    // -----------------------------------------------------------------------
    check_valid("CANDI_x10_p7",
      enc_c1_alu(2'b10, 3'b010, 6'b000111),
      mk_itype(7'b0010011, 5'd10, 3'b111, 5'd10, 12'sd7));

    // Test 2: rd'=x10, imm=-1 (6'b111111 -> 12'hFFF)
    check_valid("CANDI_x10_m1",
      enc_c1_alu(2'b10, 3'b010, 6'b111111),
      mk_itype(7'b0010011, 5'd10, 3'b111, 5'd10, 12'hFFF));

    // Test 3: rd'=x11, imm=0 (HINT but valid)
    check_valid("CANDI_x11_0",
      enc_c1_alu(2'b10, 3'b011, 6'b000000),
      mk_itype(7'b0010011, 5'd11, 3'b111, 5'd11, 12'd0));

    // -----------------------------------------------------------------------
    // C.SUB: SUB rd', rd', rs2'  (§12.4, funct3=100, inst[11:10]=11, inst[6:5]=00)
    // R-type: SUB opcode=0110011, funct7=0100000, funct3=000
    //
    // Test: rd'=x8 (000), rs2'=x9 (001)
    //   32-bit: SUB x8, x8, x9
    // -----------------------------------------------------------------------
    check_valid("CSUB_x8_x9",
      enc_c1_arith(2'b00, 3'b000, 3'b001),
      mk_rtype(7'b0110011, 5'd8, 3'b000, 5'd8, 5'd9, 7'b0100000));

    // -----------------------------------------------------------------------
    // C.XOR: XOR rd', rd', rs2'  (funct3=100, inst[11:10]=11, inst[6:5]=01)
    // R-type: XOR opcode=0110011, funct7=0000000, funct3=100
    //
    // Test: rd'=x10 (010), rs2'=x11 (011)
    // -----------------------------------------------------------------------
    check_valid("CXOR_x10_x11",
      enc_c1_arith(2'b01, 3'b010, 3'b011),
      mk_rtype(7'b0110011, 5'd10, 3'b100, 5'd10, 5'd11, 7'b0000000));

    // -----------------------------------------------------------------------
    // C.OR: OR rd', rd', rs2'  (funct3=100, inst[11:10]=11, inst[6:5]=10)
    // R-type: OR opcode=0110011, funct7=0000000, funct3=110
    //
    // Test: rd'=x12 (100), rs2'=x13 (101)
    // -----------------------------------------------------------------------
    check_valid("COR_x12_x13",
      enc_c1_arith(2'b10, 3'b100, 3'b101),
      mk_rtype(7'b0110011, 5'd12, 3'b110, 5'd12, 5'd13, 7'b0000000));

    // -----------------------------------------------------------------------
    // C.AND: AND rd', rd', rs2'  (funct3=100, inst[11:10]=11, inst[6:5]=11)
    // R-type: AND opcode=0110011, funct7=0000000, funct3=111
    //
    // Test: rd'=x14 (110), rs2'=x15 (111)
    // -----------------------------------------------------------------------
    check_valid("CAND_x14_x15",
      enc_c1_arith(2'b11, 3'b110, 3'b111),
      mk_rtype(7'b0110011, 5'd14, 3'b111, 5'd14, 5'd15, 7'b0000000));

    // -----------------------------------------------------------------------
    // C.J: JAL x0, sext(imm)  (§12.4, funct3=101)
    // Same immediate encoding as C.JAL.
    //
    // Test 1: offset=+6 -> jimm=6>>1=3, mk_jtype pass 3
    //   32-bit: JAL x0, 6
    // -----------------------------------------------------------------------
    check_valid("CJ_p6",
      enc_cjal_cj(3'b101, 11'd3),  // offset=6 -> jimm=3
      mk_jtype(7'b1101111, 5'd0, 20'd3));  // offset=6 -> pass 3

    // Test 2: offset=-4 -> jimm = (-4>>1) & 0x7FF = 0x7FE
    //   mk_jtype pass (-4>>1) & 0xFFFFF = 0xFFFFE
    //   32-bit: JAL x0, -4
    check_valid("CJ_m4",
      enc_cjal_cj(3'b101, 11'h7FE),  // -4>>1=-2 -> 0x7FE (11-bit)
      mk_jtype(7'b1101111, 5'd0, 20'hFFFFE));  // -4>>1=-2 -> 0xFFFFE

    // -----------------------------------------------------------------------
    // C.BEQZ: BEQ rs1', x0, sext(off)  (§12.4, funct3=110)
    // off = {inst[12],inst[6:5],inst[2],inst[11:10],inst[4:3],1'b0}
    //
    // enc_cbranch argument = off>>1 (signed, 8-bit).
    // mk_btype argument = off>>1 (pass offset/2).
    //
    // Test 1: rs1'=x8 (compact=000), off=+8 -> off_div2=4
    //   32-bit: BEQ x8, x0, 8
    //   B-type: {imm[12]=0, imm[10:5]=000000, x0, x8, 3'b000,
    //            imm[4:1]=0010 (off[3]=1), imm[11]=0, 7'b1100011}
    //   mk_btype pass 8>>1 = 4.
    // -----------------------------------------------------------------------
    check_valid("CBEQZ_x8_p8",
      enc_cbranch(3'b110, 3'b000, 8'd4),  // off=8 -> off_div2=4
      mk_btype(7'b1100011, 5'd8, 5'd0, 3'b000, 12'd4));  // off=8 -> pass 4

    // Test 2: rs1'=x8, off=-8 -> off_div2 = (-8>>1) & 0xFF = 0xFC
    //   mk_btype pass (-8>>1) & 0xFFF = 0xFFC
    //   32-bit: BEQ x8, x0, -8
    check_valid("CBEQZ_x8_m8",
      enc_cbranch(3'b110, 3'b000, 8'hFC),  // off=-8 -> off_div2=0xFC
      mk_btype(7'b1100011, 5'd8, 5'd0, 3'b000, 12'hFFC));  // -8>>1=-4->0xFFC

    // -----------------------------------------------------------------------
    // C.BNEZ: BNE rs1', x0, sext(off)  (§12.4, funct3=111)
    // Same offset encoding as C.BEQZ.
    //
    // Test 1: rs1'=x9 (compact=001), off=-4 -> off_div2 = (-4>>1)&0xFF = 0xFE
    //   mk_btype pass (-4>>1)&0xFFF = 0xFFE
    //   32-bit: BNE x9, x0, -4
    // -----------------------------------------------------------------------
    check_valid("CBNEZ_x9_m4",
      enc_cbranch(3'b111, 3'b001, 8'hFE),  // off=-4 -> off_div2=0xFE
      mk_btype(7'b1100011, 5'd9, 5'd0, 3'b001, 12'hFFE));  // -4>>1=-2->0xFFE

    // Test 2: rs1'=x9, off=+4 -> off_div2=2
    //   mk_btype pass 2
    //   32-bit: BNE x9, x0, 4
    check_valid("CBNEZ_x9_p4",
      enc_cbranch(3'b111, 3'b001, 8'd2),  // off=4 -> off_div2=2
      mk_btype(7'b1100011, 5'd9, 5'd0, 3'b001, 12'd2));

    // ========================================================================
    // SECTION 4: C2 Quadrant (bits[1:0]=10) (§12.5)
    // ========================================================================
    $display("\n--- Section 4: C2 Quadrant ---");

    // -----------------------------------------------------------------------
    // C.SLLI: SLLI rd, rd, shamt  (§12.5, funct3=000)
    // shamt={inst[12],inst[6:2]}. shamt[5]=0 required for legal RV32.
    // 32-bit: I-type SLLI = {7'b0000000, shamt[4:0], rs1, 3'b001, rd, 7'b0010011}
    //
    // Test 1: rd=x5, shamt=7
    // -----------------------------------------------------------------------
    check_valid("CSLLI_x5_shamt7",
      enc_cslli(5'd5, 6'b000111),
      mk_itype(7'b0010011, 5'd5, 3'b001, 5'd5,
               {7'b0000000, 5'd7}));

    // Test 2: rd=x1, shamt=1
    check_valid("CSLLI_x1_shamt1",
      enc_cslli(5'd1, 6'b000001),
      mk_itype(7'b0010011, 5'd1, 3'b001, 5'd1,
               {7'b0000000, 5'd1}));

    // Test 3: rd=x10, shamt=31 (max for RV32, shamt[5]=0)
    check_valid("CSLLI_x10_shamt31",
      enc_cslli(5'd10, 6'b011111),
      mk_itype(7'b0010011, 5'd10, 3'b001, 5'd10,
               {7'b0000000, 5'd31}));

    // -----------------------------------------------------------------------
    // C.LWSP: LW rd, uimm(x2)  (§12.5, funct3=010, rd!=x0)
    // uimm = {inst[3:2], inst[12], inst[6:4], 2'b00} (zero-ext, x4)
    // enc_clwsp argument = uimm/4 (offset/4)
    //
    // Test 1: rd=x3, offset=16 -> uimm_div4=4
    //   32-bit: LW x3, 16(x2)
    // -----------------------------------------------------------------------
    check_valid("CLWSP_x3_off16",
      enc_clwsp(5'd3, 6'd4),  // offset=16 -> pass 4
      mk_itype(7'b0000011, 5'd3, 3'b010, 5'd2, 12'd16));

    // Test 2: rd=x1, offset=4 -> uimm_div4=1
    check_valid("CLWSP_x1_off4",
      enc_clwsp(5'd1, 6'd1),
      mk_itype(7'b0000011, 5'd1, 3'b010, 5'd2, 12'd4));

    // Test 3: rd=x2, offset=252 (max: uimm_div4=63)
    //   252/4=63. uimm=252 -> LW x2, 252(x2)
    check_valid("CLWSP_x2_off252",
      enc_clwsp(5'd2, 6'd63),  // offset=252 -> pass 63
      mk_itype(7'b0000011, 5'd2, 3'b010, 5'd2, 12'd252));

    // -----------------------------------------------------------------------
    // C.JR: JALR x0, 0(rs1)  (§12.5, funct3=100, inst[12]=0, rs2=0, rs1!=0)
    // 32-bit: {12'h0, rs1, 3'b000, x0, 7'b1100111}
    //
    // Test 1: rs1=x5
    // -----------------------------------------------------------------------
    check_valid("CJR_x5",
      enc_c2_misc(1'b0, 5'd5, 5'd0),
      mk_itype(7'b1100111, 5'd0, 3'b000, 5'd5, 12'd0));

    // Test 2: rs1=x1
    check_valid("CJR_x1",
      enc_c2_misc(1'b0, 5'd1, 5'd0),
      mk_itype(7'b1100111, 5'd0, 3'b000, 5'd1, 12'd0));

    // -----------------------------------------------------------------------
    // C.MV: ADD rd, x0, rs2  (§12.5, inst[12]=0, rs2!=0)
    // R-type: {7'b0000000, rs2, x0, 3'b000, rd, 7'b0110011}
    //
    // Test 1: rd=x3, rs2=x5
    // -----------------------------------------------------------------------
    check_valid("CMV_x3_x5",
      enc_c2_misc(1'b0, 5'd3, 5'd5),
      mk_rtype(7'b0110011, 5'd3, 3'b000, 5'd0, 5'd5, 7'b0000000));

    // Test 2: rd=x10, rs2=x1
    check_valid("CMV_x10_x1",
      enc_c2_misc(1'b0, 5'd10, 5'd1),
      mk_rtype(7'b0110011, 5'd10, 3'b000, 5'd0, 5'd1, 7'b0000000));

    // -----------------------------------------------------------------------
    // C.EBREAK: EBREAK = 32'h00100073  (§12.5)
    // inst[12]=1, rs2=0, rd/rs1=0
    // -----------------------------------------------------------------------
    check_valid("CEBREAK",
      enc_c2_misc(1'b1, 5'd0, 5'd0),
      32'h00100073);

    // -----------------------------------------------------------------------
    // C.JALR: JALR x1, 0(rs1)  (§12.5, inst[12]=1, rs2=0, rs1!=0)
    // 32-bit: {12'h0, rs1, 3'b000, x1, 7'b1100111}
    //
    // Test 1: rs1=x5
    // -----------------------------------------------------------------------
    check_valid("CJALR_x5",
      enc_c2_misc(1'b1, 5'd5, 5'd0),
      mk_itype(7'b1100111, 5'd1, 3'b000, 5'd5, 12'd0));

    // Test 2: rs1=x10
    check_valid("CJALR_x10",
      enc_c2_misc(1'b1, 5'd10, 5'd0),
      mk_itype(7'b1100111, 5'd1, 3'b000, 5'd10, 12'd0));

    // -----------------------------------------------------------------------
    // C.ADD: ADD rd, rd, rs2  (§12.5, inst[12]=1, rs2!=0)
    // R-type: {7'b0000000, rs2, rd, 3'b000, rd, 7'b0110011}
    //
    // Test 1: rd=x3, rs2=x5
    // -----------------------------------------------------------------------
    check_valid("CADD_x3_x5",
      enc_c2_misc(1'b1, 5'd3, 5'd5),
      mk_rtype(7'b0110011, 5'd3, 3'b000, 5'd3, 5'd5, 7'b0000000));

    // Test 2: rd=x7, rs2=x2
    check_valid("CADD_x7_x2",
      enc_c2_misc(1'b1, 5'd7, 5'd2),
      mk_rtype(7'b0110011, 5'd7, 3'b000, 5'd7, 5'd2, 7'b0000000));

    // -----------------------------------------------------------------------
    // C.SWSP: SW rs2, uimm(x2)  (§12.5, funct3=110)
    // uimm = {inst[8:7], inst[12:9], 2'b00} (zero-ext, x4)
    // enc_cswsp argument = uimm/4 (offset/4)
    //
    // Test 1: rs2=x5, offset=12 -> uimm_div4=3
    //   32-bit: SW x5, 12(x2)
    // -----------------------------------------------------------------------
    check_valid("CSWSP_x5_off12",
      enc_cswsp(5'd5, 6'd3),  // offset=12 -> pass 3
      mk_stype(7'b0100011, 5'd2, 5'd5, 3'b010, 12'd12));

    // Test 2: rs2=x1, offset=0
    check_valid("CSWSP_x1_off0",
      enc_cswsp(5'd1, 6'd0),
      mk_stype(7'b0100011, 5'd2, 5'd1, 3'b010, 12'd0));

    // Test 3: rs2=x10, offset=252 (max: uimm_div4=63)
    check_valid("CSWSP_x10_off252",
      enc_cswsp(5'd10, 6'd63),  // offset=252 -> pass 63
      mk_stype(7'b0100011, 5'd2, 5'd10, 3'b010, 12'd252));

    // ========================================================================
    // SECTION 5: Illegal encodings (§12.7)
    // All must set illegal_o=1 and instr_o=32'h00000000
    // ========================================================================
    $display("\n--- Section 5: Illegal encodings (§12.7) ---");

    // §12.7 rule 1: instr_i == 16'h0000 -- always illegal
    check_illegal("illegal_allzero", 16'h0000);

    // §12.7 rule 2: C0 funct3 in {001, 011, 100, 101, 111}
    // funct3=001 (C.FLD): [15:13]=001, [1:0]=00, middle bits arbitrary
    // NOTE: concatenation must be exactly 16 bits wide.
    check_illegal("illegal_C0_funct3_001",
      {3'b001, 5'b00000, 3'b000, 3'b000, 2'b00});
    // funct3=011 (C.FLW)
    check_illegal("illegal_C0_funct3_011",
      {3'b011, 5'b00000, 3'b000, 3'b000, 2'b00});
    // funct3=100 (reserved)
    check_illegal("illegal_C0_funct3_100",
      {3'b100, 5'b00000, 3'b000, 3'b000, 2'b00});
    // funct3=101 (C.FSD)
    check_illegal("illegal_C0_funct3_101",
      {3'b101, 5'b00000, 3'b000, 3'b000, 2'b00});
    // funct3=111 (C.FSW)
    check_illegal("illegal_C0_funct3_111",
      {3'b111, 5'b00000, 3'b000, 3'b000, 2'b00});

    // §12.7 rule 3: C2 funct3 in {001, 011, 101, 111}
    // funct3=001 (C.FLDSP): [15:13]=001, [1:0]=10
    // NOTE: concatenation must be exactly 16 bits wide.
    check_illegal("illegal_C2_funct3_001",
      {3'b001, 1'b0, 5'd1, 5'd0, 2'b10});
    // funct3=011 (C.FLWSP)
    check_illegal("illegal_C2_funct3_011",
      {3'b011, 1'b0, 5'd1, 5'd0, 2'b10});
    // funct3=101 (C.FSDSP)
    check_illegal("illegal_C2_funct3_101",
      {3'b101, 1'b0, 5'd1, 5'd0, 2'b10});
    // funct3=111 (C.FSWSP)
    check_illegal("illegal_C2_funct3_111",
      {3'b111, 1'b0, 5'd1, 5'd0, 2'b10});

    // §12.7 rule 4: C.ADDI4SPN with nzuimm=0
    // funct3=000, all imm bits clear, [1:0]=00
    check_illegal("illegal_CADDI4SPN_nzuimm0",
      {3'b000, 8'b00000000, 3'b000, 2'b00});

    // §12.7 rule 5: C.ADDI16SP with nzimm=0
    // funct3=011, rd=x2, all imm bits = 0
    check_illegal("illegal_CADDI16SP_nzimm0",
      {3'b011, 1'b0, 5'd2, 5'b00000, 2'b01});

    // §12.7 rule 6: C.LUI with nzimm=0
    // funct3=011, rd=x3 (not x0 or x2), all imm bits = 0
    check_illegal("illegal_CLUI_nzimm0",
      {3'b011, 1'b0, 5'd3, 5'b00000, 2'b01});

    // §12.7 rule 7: C.LWSP with rd=x0
    // funct3=010, rd=x0=5'd0, uimm bits nonzero (so it's not all-zero), [1:0]=10
    check_illegal("illegal_CLWSP_rd0",
      {3'b010, 1'b0, 5'd0, 5'b00001, 2'b10});

    // §12.7 rule 8: C.JR with rs1=x0
    // funct3=100, inst[12]=0, inst[11:7]=x0, inst[6:2]=0
    check_illegal("illegal_CJR_rs1_0",
      enc_c2_misc(1'b0, 5'd0, 5'd0));

    // §12.7 rule 9: C.SLLI with shamt[5]=1 (inst[12]=1)
    check_illegal("illegal_CSLLI_shamt5",
      enc_cslli(5'd5, 6'b100001));

    // C.SRLI with shamt[5]=1 (§12.4 C.SRLI note)
    check_illegal("illegal_CSRLI_shamt5",
      enc_c1_alu(2'b00, 3'b000, 6'b100001));

    // C.SRAI with shamt[5]=1
    check_illegal("illegal_CSRAI_shamt5",
      enc_c1_alu(2'b01, 3'b000, 6'b100001));

    // §12.7 rule 10: C1 funct3=100, inst[11:10]=11, inst[12]=1 (RV64 reserved)
    // Use inst[6:5]=00, inst[9:7]=rd'=000, inst[4:2]=rs2'=001
    check_illegal("illegal_C1_RV64_reserved",
      {3'b100, 1'b1, 2'b11, 3'b000, 2'b00, 3'b001, 2'b01});

    // ========================================================================
    // SECTION 6: Additional coverage -- boundary and corner cases
    // ========================================================================
    $display("\n--- Section 6: Additional corner cases ---");

    // C.ADDI with imm=0 (HINT -- rd!=x0, imm=0; spec says treat as NOP, still valid)
    // 32-bit: ADDI x5, x5, 0
    check_valid("CADDI_HINT_imm0",
      enc_c1_imm5(3'b000, 5'd5, 6'b000000),
      mk_itype(7'b0010011, 5'd5, 3'b000, 5'd5, 12'd0));

    // C.LI with rd=x0 (HINT per §12.4; still produces valid ADDI x0, x0, 1)
    check_valid("CLI_HINT_rd0",
      enc_c1_imm5(3'b010, 5'd0, 6'b000001),
      mk_itype(7'b0010011, 5'd0, 3'b000, 5'd0, 12'd1));

    // C.SLLI with rd=x0, shamt=1 (HINT per §12.5; shamt[5]=0 so not illegal)
    // 32-bit: SLLI x0, x0, 1
    check_valid("CSLLI_HINT_rd0",
      enc_cslli(5'd0, 6'b000001),
      mk_itype(7'b0010011, 5'd0, 3'b001, 5'd0,
               {7'b0000000, 5'd1}));

    // C.SLLI with shamt=0 (HINT on RV32 per §12.5; still valid encoding)
    check_valid("CSLLI_HINT_shamt0",
      enc_cslli(5'd5, 6'b000000),
      mk_itype(7'b0010011, 5'd5, 3'b001, 5'd5,
               {7'b0000000, 5'd0}));

    // C.SRLI with shamt=0 (HINT on RV32 per §12.4; still valid)
    check_valid("CSRLI_HINT_shamt0",
      enc_c1_alu(2'b00, 3'b000, 6'b000000),
      mk_itype(7'b0010011, 5'd8, 3'b101, 5'd8,
               {7'b0000000, 5'd0}));

    // C.MV with rd=x0 (ADD x0, x0, rs2 -- HINT but valid per §12.5 "any rd")
    check_valid("CMV_rd0",
      enc_c2_misc(1'b0, 5'd0, 5'd3),
      mk_rtype(7'b0110011, 5'd0, 3'b000, 5'd0, 5'd3, 7'b0000000));

    // C.ADD with rd=x0 (ADD x0, x0, rs2 -- HINT but valid per §12.5 "any rd")
    check_valid("CADD_rd0",
      enc_c2_misc(1'b1, 5'd0, 5'd5),
      mk_rtype(7'b0110011, 5'd0, 3'b000, 5'd0, 5'd5, 7'b0000000));

    // C.LW with max offset=124 (uimm_6_2 = 124/4 = 31 = 5'b11111)
    check_valid("CLW_maxoff_x8_x8",
      enc_clw(3'b000, 3'b000, 5'd31),  // offset=124 -> pass 31
      mk_itype(7'b0000011, 5'd8, 3'b010, 5'd8, 12'd124));

    // C.SW with max offset=124
    check_valid("CSW_maxoff_x8_x8",
      enc_csw(3'b000, 3'b000, 5'd31),  // offset=124 -> pass 31
      mk_stype(7'b0100011, 5'd8, 5'd8, 3'b010, 12'd124));

    // C.BEQZ max positive offset: off=254 -> off_div2=127
    // 32-bit: BEQ x8, x0, 254 -> mk_btype pass 127
    //   Spec derivation: off=254=0b011111110. off[7..1]=1, off[8]=0.
    //   B-type imm: {imm12=0, imm11=0, imm10:5=000111, imm4:1=1111}
    //   -> pass mk_btype value=127 (254>>1).
    check_valid("CBEQZ_x8_p254",
      enc_cbranch(3'b110, 3'b000, 8'd127),  // off=254 -> off_div2=127
      mk_btype(7'b1100011, 5'd8, 5'd0, 3'b000, 12'd127));  // 254>>1=127

    // ========================================================================
    // SECTION 7: Full rs2' register sweep via C.SW (all 8 compact rs2' values)
    // ========================================================================
    $display("\n--- Section 7: Full rs2' register sweep via C.SW ---");
    begin
      integer i;
      logic [4:0] rs2_full;
      for (i = 0; i < 8; i = i + 1) begin
        rs2_full = {2'b01, i[2:0]};  // x8..x15
        check_valid(
          $sformatf("CSW_rs2p_compact%0d_x%0d", i, rs2_full),
          enc_csw(3'b000, i[2:0], 5'd0),  // rs1'=x8, rs2'=compact_i, off=0
          mk_stype(7'b0100011, 5'd8, rs2_full, 3'b010, 12'd0));
      end
    end

    // ========================================================================
    // FINAL SUMMARY
    // ========================================================================
    $display("\n=== SUMMARY: %0d PASS, %0d FAIL ===",
             pass_count, fail_count);
    if (fail_count > 0)
      $fatal(1, "FAILURES detected -- %0d test(s) failed", fail_count);
    $finish;
  end

endmodule
