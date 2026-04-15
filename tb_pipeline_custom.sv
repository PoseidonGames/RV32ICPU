// ============================================================================
// Module: tb_pipeline_custom
// Description: Self-checking testbench for POPCOUNT and BREV custom
//              instructions (CUSTOM-0 opcode) at the pipeline_top level.
//              Derives ALL expected values from canonical-reference.md §8.1
//              and m2a-verification-plan.md §4. Tests: basic execution,
//              WB→EX forwarding, branch interaction, x0 suppression,
//              halt/illegal encoding.
// Author: Beaux Cable (Verification Agent)
// Date: April 2026
// Project: TSI RV32I Pipelined Processor (TSMC 180nm)
//
// Instruction encoding reference: canonical-reference.md §3 and §8.1
//   CUSTOM-0 opcode: 7'b0001011
//   POPCOUNT: funct7=0000000, funct3=000, R-type (rd=popcount(rs1))
//   BREV:     funct7=0000001, funct3=000, R-type (rd=bitreverse(rs1))
//   Both unary: rs2 field is don't-care (encoded as 5'd0 here).
//
// Pipeline timing (canonical-reference.md §7.1):
//   Cycle N  : instruction fetched from imem[N]
//   Cycle N+1: instruction in EX stage
//   Cycle N+2: result written to regfile (WB)
//   WB→EX forwarding: instruction at word N+1 (in EX when word N writes WB)
//   can see the result of word N via forwarding. Word N+2 (no gap) does not
//   get forwarding from word N — it is in EX the cycle after WB completes.
//
// Gotchas applied:
//   #8  x0 write/forward suppression — tested explicitly in §4.4
//   #11 stimulus race — ALL stimulus driven at @(negedge clk)
//   #12 forwarding: custom uses alu_src_a==2'b00 (rs1) so forwarding IS active
// ============================================================================

`timescale 1ns/1ps

module tb_pipeline_custom;

  // ==========================================================================
  // DUT ports
  // ==========================================================================
  logic        clk;
  logic        rst_n;
  logic [31:0] instr_addr_o;
  logic [31:0] instr_data_i;
  logic [31:0] data_addr_o;
  logic [31:0] data_out_o;
  logic [3:0]  data_we_o;
  logic        data_re_o;
  logic [31:0] data_in_i;
  logic        halt_o;

  // ==========================================================================
  // DUT instantiation
  // ==========================================================================
  pipeline_top dut (
    .clk          (clk),
    .rst_n        (rst_n),
    .instr_addr_o (instr_addr_o),
    .instr_data_i (instr_data_i),
    .data_addr_o  (data_addr_o),
    .data_out_o   (data_out_o),
    .data_we_o    (data_we_o),
    .data_re_o    (data_re_o),
    .data_in_i    (data_in_i),
    .halt_o       (halt_o)
  );

  // ==========================================================================
  // Memory models
  // Instruction memory: word-addressed via instr_addr_o[9:2] (256 words).
  // Data memory: byte-addressed; TB applies data_we_o byte enables for writes
  //              and returns data_in_i for reads (always driven from dmem).
  // ==========================================================================
  logic [31:0] imem [0:255];   // instruction memory
  logic [7:0]  dmem [0:1023];  // data memory (byte array, 1 KiB)

  // Drive instruction memory (word-addressed by PC[9:2])
  assign instr_data_i = imem[instr_addr_o[9:2]];

  // Drive data read port (word-aligned; addr_o[1:0] assumed 0 for LW)
  assign data_in_i = {
    dmem[data_addr_o[9:0] + 3],
    dmem[data_addr_o[9:0] + 2],
    dmem[data_addr_o[9:0] + 1],
    dmem[data_addr_o[9:0]]
  };

  // Handle data memory writes via byte enables (active-high AXI convention,
  // canonical-reference.md §1.4)
  always_ff @(posedge clk) begin
    if (data_we_o[0]) dmem[data_addr_o[9:0]]     <= data_out_o[7:0];
    if (data_we_o[1]) dmem[data_addr_o[9:0] + 1] <= data_out_o[15:8];
    if (data_we_o[2]) dmem[data_addr_o[9:0] + 2] <= data_out_o[23:16];
    if (data_we_o[3]) dmem[data_addr_o[9:0] + 3] <= data_out_o[31:24];
  end

  // ==========================================================================
  // Clock: 10 ns half-period = 50 MHz (conventions.md)
  // ==========================================================================
  initial clk = 1'b0;
  always #10 clk = ~clk;

  // ==========================================================================
  // Test counters
  // ==========================================================================
  integer pass_count;
  integer fail_count;

  // ==========================================================================
  // Helper tasks
  // ==========================================================================

  // Check a 32-bit value, print PASS/FAIL
  task automatic check32(
    input string   test_name,
    input [31:0]   got,
    input [31:0]   expected
  );
    if (got !== expected) begin
      $display("FAIL  %s: got=0x%08X expected=0x%08X",
               test_name, got, expected);
      fail_count++;
    end else begin
      $display("PASS  %s: 0x%08X", test_name, got);
      pass_count++;
    end
  endtask

  task automatic check1(
    input string test_name,
    input        got,
    input        expected
  );
    if (got !== expected) begin
      $display("FAIL  %s: got=%b expected=%b", test_name, got, expected);
      fail_count++;
    end else begin
      $display("PASS  %s: %b", test_name, got);
      pass_count++;
    end
  endtask

  // Reset pipeline and memories; fill imem with NOPs.
  // Gotcha #11: drive stimulus at negedge to avoid races.
  // Conventions: assert rst_n=0 for 2 cycles, deassert on negedge,
  //              wait 1 cycle before loading program.
  task automatic do_reset();
    integer i;
    for (i = 0; i < 256; i++) imem[i] = 32'h00000013; // NOP
    for (i = 0; i < 1024; i++) dmem[i] = 8'h00;
    @(negedge clk);
    rst_n = 1'b0;
    @(negedge clk);
    @(negedge clk);
    @(negedge clk);
    rst_n = 1'b1;
    #1;
  endtask

  // Run N clock cycles to drain the pipeline
  task automatic run_cycles(input integer n);
    integer i;
    for (i = 0; i < n; i++) @(posedge clk);
    #1;
  endtask

  // ==========================================================================
  // Instruction encoding helpers
  // All encodings derived from canonical-reference.md §3.
  // ==========================================================================

  // R-type: {funct7, rs2, rs1, funct3, rd, opcode}
  function automatic [31:0] enc_r(
    input [6:0] funct7,
    input [4:0] rs2, rs1,
    input [2:0] funct3,
    input [4:0] rd,
    input [6:0] opcode
  );
    enc_r = {funct7, rs2, rs1, funct3, rd, opcode};
  endfunction

  // I-type: {imm[11:0], rs1, funct3, rd, opcode}
  function automatic [31:0] enc_i(
    input [11:0] imm,
    input [4:0]  rs1,
    input [2:0]  funct3,
    input [4:0]  rd,
    input [6:0]  opcode
  );
    enc_i = {imm, rs1, funct3, rd, opcode};
  endfunction

  // S-type: {imm[11:5], rs2, rs1, funct3, imm[4:0], opcode}
  function automatic [31:0] enc_s(
    input [11:0] imm,
    input [4:0]  rs2, rs1,
    input [2:0]  funct3,
    input [6:0]  opcode
  );
    enc_s = {imm[11:5], rs2, rs1, funct3, imm[4:0], opcode};
  endfunction

  // B-type: {imm[12],imm[10:5],rs2,rs1,funct3,imm[4:1],imm[11],opcode}
  function automatic [31:0] enc_b(
    input [12:0] imm,
    input [4:0]  rs2, rs1,
    input [2:0]  funct3,
    input [6:0]  opcode
  );
    enc_b = {imm[12], imm[10:5], rs2, rs1,
             funct3, imm[4:1], imm[11], opcode};
  endfunction

  // U-type: {imm[31:12], rd, opcode}
  function automatic [31:0] enc_u(
    input [19:0] imm_upper,
    input [4:0]  rd,
    input [6:0]  opcode
  );
    enc_u = {imm_upper, rd, opcode};
  endfunction

  // J-type: {imm[20],imm[10:1],imm[11],imm[19:12],rd,opcode}
  function automatic [31:0] enc_j(
    input [20:0] imm,
    input [4:0]  rd,
    input [6:0]  opcode
  );
    enc_j = {imm[20], imm[10:1], imm[11], imm[19:12], rd, opcode};
  endfunction

  // ==========================================================================
  // Opcode constants (canonical-reference.md §2)
  // ==========================================================================
  localparam [6:0] OP_R     = 7'b0110011; // R-type ALU
  localparam [6:0] OP_IALU  = 7'b0010011; // I-type ALU (ADDI etc.)
  localparam [6:0] OP_LOAD  = 7'b0000011; // Loads
  localparam [6:0] OP_STOR  = 7'b0100011; // Stores
  localparam [6:0] OP_BRNC  = 7'b1100011; // Branches
  localparam [6:0] OP_JAL   = 7'b1101111; // JAL
  localparam [6:0] OP_JALR  = 7'b1100111; // JALR
  localparam [6:0] OP_LUI   = 7'b0110111; // LUI
  localparam [6:0] OP_AUIPC = 7'b0010111; // AUIPC
  localparam [6:0] OP_SYS   = 7'b1110011; // ECALL/EBREAK
  // CUSTOM-0: canonical-reference.md §2 and §8.1
  localparam [6:0] OP_CUST0 = 7'b0001011;

  // NOP = ADDI x0, x0, 0 (canonical-reference.md §7.3)
  localparam [31:0] NOP = 32'h00000013;

  // ==========================================================================
  // dmem readback helper
  // Read a 32-bit word from data memory at byte_addr (little-endian).
  // ==========================================================================
  function automatic [31:0] dmem_word(input [9:0] byte_addr);
    dmem_word = {dmem[byte_addr+3], dmem[byte_addr+2],
                 dmem[byte_addr+1], dmem[byte_addr]};
  endfunction

  // ==========================================================================
  // Reference model functions (m2a-verification-plan.md §6.3)
  // Expected values derived from canonical-reference.md §8.1:
  //   POPCOUNT: rd = popcount(rs1) = number of set bits in rs1
  //   BREV:     rd = bitreverse(rs1), result[i] = input[31-i]
  // ==========================================================================

  // ref_popcount: count 1-bits in val.
  // No * operator used — iterative addition only.
  function automatic [31:0] ref_popcount(input [31:0] val);
    integer k;
    ref_popcount = 32'h0;
    for (k = 0; k < 32; k = k + 1)
      ref_popcount = ref_popcount + {31'b0, val[k]};
  endfunction

  // ref_brev: reverse bit order.
  // result[i] = val[31-i] for i = 0..31.
  function automatic [31:0] ref_brev(input [31:0] val);
    integer k;
    for (k = 0; k < 32; k = k + 1)
      ref_brev[k] = val[31-k];
  endfunction

  // ==========================================================================
  // TEST SUITE
  // ==========================================================================
  initial begin
    pass_count = 0;
    fail_count = 0;

    // ========================================================================
    // TEST 1: POPCOUNT basic
    // m2a-verification-plan.md §4.1
    // Spec (canonical-reference.md §8.1):
    //   POPCOUNT: rd = popcount(rs1)
    //   Input: x2 = 0xFF = 0x000000FF (8 bits set)
    //   Expected: x1 = 8
    // Sequence:
    //   imem[0] ADDI x2, x0, 0xFF  -> x2 = 0x000000FF
    //   imem[1] NOP                 (gap: x2 WB before POPCOUNT EX)
    //   imem[2] POPCOUNT x1, x2    -> x1 = popcount(0xFF) = 8
    //   imem[3] NOP
    //   imem[4] SW x1, 0x200(x0)   -> dmem[0x200] = x1
    //   imem[5..8] NOPs (drain)
    // ========================================================================
    $display("\n--- TEST 1: POPCOUNT basic (x2=0xFF -> x1=8) ---");
    do_reset();
    // ADDI x2, x0, 0xFF
    imem[0] = enc_i(12'hFF, 5'd0, 3'b000, 5'd2, OP_IALU);
    imem[1] = NOP;
    // POPCOUNT x1, x2: funct7=0000000, rs2=x0(dc), rs1=x2, funct3=000,
    //   rd=x1, opcode=CUSTOM-0 (canonical-reference.md §8.1)
    imem[2] = enc_r(7'b0000000, 5'd0, 5'd2, 3'b000, 5'd1, OP_CUST0);
    imem[3] = NOP;
    // SW x1, 0x200(x0)
    imem[4] = enc_s(12'h200, 5'd1, 5'd0, 3'b010, OP_STOR);
    imem[5] = NOP; imem[6] = NOP; imem[7] = NOP; imem[8] = NOP;
    run_cycles(12);
    // ref: popcount(0xFF) = 8 = 0x00000008
    check32("POPCOUNT x2=0xFF -> x1=8",
            dmem_word(10'h200), 32'h00000008);

    // ========================================================================
    // TEST 2: BREV basic
    // m2a-verification-plan.md §4.1
    // Spec (canonical-reference.md §8.1):
    //   BREV: rd = bitreverse(rs1), result[i] = input[31-i]
    //   Input: x2 = 0x00000001 (bit 0 set)
    //   Expected: x1 = 0x80000000 (bit 31 set, bit 0 -> bit 31)
    // Sequence:
    //   imem[0] ADDI x2, x0, 1     -> x2 = 0x00000001
    //   imem[1] NOP
    //   imem[2] BREV x1, x2        -> x1 = brev(0x00000001) = 0x80000000
    //   imem[3] NOP
    //   imem[4] SW x1, 0x200(x0)
    //   imem[5..8] NOPs
    // ========================================================================
    $display("\n--- TEST 2: BREV basic (x2=1 -> x1=0x80000000) ---");
    do_reset();
    imem[0] = enc_i(12'h001, 5'd0, 3'b000, 5'd2, OP_IALU); // ADDI x2,x0,1
    imem[1] = NOP;
    // BREV x1, x2: funct7=0000001 (canonical-reference.md §8.1)
    imem[2] = enc_r(7'b0000001, 5'd0, 5'd2, 3'b000, 5'd1, OP_CUST0);
    imem[3] = NOP;
    imem[4] = enc_s(12'h200, 5'd1, 5'd0, 3'b010, OP_STOR);
    imem[5] = NOP; imem[6] = NOP; imem[7] = NOP; imem[8] = NOP;
    run_cycles(12);
    // ref: brev(0x00000001): bit 0 maps to bit 31 -> 0x80000000
    check32("BREV x2=0x00000001 -> x1=0x80000000",
            dmem_word(10'h200), 32'h80000000);

    // ========================================================================
    // TEST 3: POPCOUNT then ADD
    // m2a-verification-plan.md §4.1
    // Spec: POPCOUNT x1,x2 (x2=0xFF -> x1=8);
    //       then ADD x3,x1,x1 -> x3 = 8+8 = 16
    // NOP between ADDI and POPCOUNT ensures x2 is committed (no forwarding
    // hazard on the ADDI→POPCOUNT path).
    // NOP between POPCOUNT and ADD ensures x1 is committed before ADD reads it.
    // ========================================================================
    $display("\n--- TEST 3: POPCOUNT then ADD (x3 == 16) ---");
    do_reset();
    imem[0] = enc_i(12'hFF, 5'd0, 3'b000, 5'd2, OP_IALU); // ADDI x2,x0,0xFF
    imem[1] = NOP;
    // POPCOUNT x1, x2
    imem[2] = enc_r(7'b0000000, 5'd0, 5'd2, 3'b000, 5'd1, OP_CUST0);
    imem[3] = NOP;
    // ADD x3, x1, x1 (§1.1 funct7=0000000, funct3=000)
    imem[4] = enc_r(7'b0000000, 5'd1, 5'd1, 3'b000, 5'd3, OP_R);
    imem[5] = NOP;
    imem[6] = enc_s(12'h200, 5'd3, 5'd0, 3'b010, OP_STOR);
    imem[7] = NOP; imem[8] = NOP; imem[9] = NOP; imem[10] = NOP;
    run_cycles(14);
    // ref: popcount(0xFF)=8; ADD(8,8)=16=0x00000010
    check32("POPCOUNT(0xFF)->8, ADD x1,x1 -> x3=16",
            dmem_word(10'h200), 32'h00000010);

    // ========================================================================
    // TEST 4: BREV then BREV (self-inverse property)
    // m2a-verification-plan.md §4.1 and §2.2
    // Spec: brev(brev(x)) == x for all x.
    //   x2 = 0x7F = 0x0000007F
    //   BREV x1, x2 -> x1 = brev(0x0000007F) = 0xFE000000
    //   BREV x3, x1 -> x3 = brev(0xFE000000) = 0x0000007F
    //   Expect x3 == x2 == 0x0000007F
    // NOP gaps ensure no forwarding hazard between the setup ADDI and
    // each BREV.
    // ========================================================================
    $display("\n--- TEST 4: BREV self-inverse (0x7F round-trip) ---");
    do_reset();
    imem[0] = enc_i(12'h07F, 5'd0, 3'b000, 5'd2, OP_IALU); // ADDI x2,x0,0x7F
    imem[1] = NOP;
    // BREV x1, x2
    imem[2] = enc_r(7'b0000001, 5'd0, 5'd2, 3'b000, 5'd1, OP_CUST0);
    imem[3] = NOP;
    // BREV x3, x1
    imem[4] = enc_r(7'b0000001, 5'd0, 5'd1, 3'b000, 5'd3, OP_CUST0);
    imem[5] = NOP;
    imem[6] = enc_s(12'h200, 5'd3, 5'd0, 3'b010, OP_STOR);
    imem[7] = NOP; imem[8] = NOP; imem[9] = NOP; imem[10] = NOP;
    run_cycles(14);
    // ref: brev(brev(0x7F)) == 0x7F = 0x0000007F (self-inverse)
    check32("BREV(BREV(0x7F)) == 0x7F (self-inverse)",
            dmem_word(10'h200), 32'h0000007F);

    // ========================================================================
    // TEST 5: Forwarding — Custom->base (WB->EX)
    // m2a-verification-plan.md §4.2
    // Spec: POPCOUNT result forwarded from WB into back-to-back ADD EX.
    //   x2 = 0xFF (8 bits set)
    //   POPCOUNT x1, x2  -> x1 = 8 (WB at cycle N+2)
    //   ADD x3, x1, x0   -> x3 = x1 forwarded (8) + x0 (0) = 8
    //   back-to-back: ADD is in EX at cycle N+2 when POPCOUNT is in WB
    // Gotcha #12: CUSTOM-0 uses alu_src_a=2'b00 (rs1), forwarding is active.
    // ========================================================================
    $display("\n--- TEST 5: Forwarding custom->base (POPCOUNT->ADD) ---");
    do_reset();
    imem[0] = enc_i(12'hFF, 5'd0, 3'b000, 5'd2, OP_IALU); // ADDI x2,x0,0xFF
    imem[1] = NOP;
    // POPCOUNT x1, x2
    imem[2] = enc_r(7'b0000000, 5'd0, 5'd2, 3'b000, 5'd1, OP_CUST0);
    // ADD x3, x1, x0 — back-to-back, WB->EX forward
    imem[3] = enc_r(7'b0000000, 5'd0, 5'd1, 3'b000, 5'd3, OP_R);
    imem[4] = NOP;
    imem[5] = enc_s(12'h200, 5'd3, 5'd0, 3'b010, OP_STOR);
    imem[6] = NOP; imem[7] = NOP; imem[8] = NOP; imem[9] = NOP;
    run_cycles(13);
    // ref: popcount(0xFF)=8; ADD(8,0)=8=0x00000008
    check32("Fwd custom->base: POPCOUNT->ADD x3=8",
            dmem_word(10'h200), 32'h00000008);

    // ========================================================================
    // TEST 6: Forwarding — Base->custom (WB->EX)
    // m2a-verification-plan.md §4.2
    // Spec: ADD result forwarded into back-to-back POPCOUNT EX.
    //   x2 = 5, x3 = 3
    //   ADD x1, x2, x3  -> x1 = 8 (WB at cycle N+2)
    //   POPCOUNT x4, x1 -> x4 = popcount(8) = 1
    //   back-to-back: POPCOUNT is in EX at cycle N+2 when ADD is in WB
    // ========================================================================
    $display("\n--- TEST 6: Forwarding base->custom (ADD->POPCOUNT) ---");
    do_reset();
    imem[0] = enc_i(12'h005, 5'd0, 3'b000, 5'd2, OP_IALU); // ADDI x2,x0,5
    imem[1] = enc_i(12'h003, 5'd0, 3'b000, 5'd3, OP_IALU); // ADDI x3,x0,3
    imem[2] = NOP;
    // ADD x1, x2, x3
    imem[3] = enc_r(7'b0000000, 5'd3, 5'd2, 3'b000, 5'd1, OP_R);
    // POPCOUNT x4, x1 — back-to-back, WB->EX forward from ADD
    imem[4] = enc_r(7'b0000000, 5'd0, 5'd1, 3'b000, 5'd4, OP_CUST0);
    imem[5] = NOP;
    imem[6] = enc_s(12'h200, 5'd4, 5'd0, 3'b010, OP_STOR);
    imem[7] = NOP; imem[8] = NOP; imem[9] = NOP; imem[10] = NOP;
    run_cycles(14);
    // ref: 5+3=8=0b1000; popcount(8)=1=0x00000001
    check32("Fwd base->custom: ADD(5+3=8)->POPCOUNT x4=1",
            dmem_word(10'h200), 32'h00000001);

    // ========================================================================
    // TEST 7: Forwarding — Custom->custom (WB->EX)
    // m2a-verification-plan.md §4.2
    // Spec: POPCOUNT result forwarded into back-to-back BREV.
    //   x2 = 0xFF -> popcount = 8 = 0x00000008
    //   POPCOUNT x1, x2  -> x1 = 8
    //   BREV x3, x1      -> x3 = brev(8) = brev(0x00000008)
    //   brev(0x00000008): bit 3 set -> result has bit 28 set = 0x10000000
    // back-to-back: BREV is in EX when POPCOUNT is in WB -> WB->EX forward
    // ========================================================================
    $display("\n--- TEST 7: Forwarding custom->custom (POPCOUNT->BREV) ---");
    do_reset();
    imem[0] = enc_i(12'hFF, 5'd0, 3'b000, 5'd2, OP_IALU); // ADDI x2,x0,0xFF
    imem[1] = NOP;
    // POPCOUNT x1, x2
    imem[2] = enc_r(7'b0000000, 5'd0, 5'd2, 3'b000, 5'd1, OP_CUST0);
    // BREV x3, x1 — back-to-back WB->EX forward from POPCOUNT
    imem[3] = enc_r(7'b0000001, 5'd0, 5'd1, 3'b000, 5'd3, OP_CUST0);
    imem[4] = NOP;
    imem[5] = enc_s(12'h200, 5'd3, 5'd0, 3'b010, OP_STOR);
    imem[6] = NOP; imem[7] = NOP; imem[8] = NOP; imem[9] = NOP;
    run_cycles(13);
    // ref: popcount(0xFF)=8=0x00000008
    //      brev(0x00000008): bit 3 -> bit 28: result = 0x10000000
    check32("Fwd custom->custom: POPCOUNT(0xFF)->BREV x3=0x10000000",
            dmem_word(10'h200), 32'h10000000);

    // ========================================================================
    // TEST 8: WB->EX with NOP gap (no forwarding needed — regfile commit)
    // m2a-verification-plan.md §4.2
    // Spec: ADD result committed to regfile, then POPCOUNT reads from regfile.
    //   x2=5, x3=3; ADD x1,x2,x3 -> x1=8; NOP; POPCOUNT x4,x1 -> x4=1
    //   The NOP means POPCOUNT is in EX one cycle AFTER ADD finishes WB,
    //   so POPCOUNT reads x1 from the regfile (no forwarding path needed).
    // ========================================================================
    $display("\n--- TEST 8: No-forward gap: ADD NOP POPCOUNT ---");
    do_reset();
    imem[0] = enc_i(12'h005, 5'd0, 3'b000, 5'd2, OP_IALU); // ADDI x2,x0,5
    imem[1] = enc_i(12'h003, 5'd0, 3'b000, 5'd3, OP_IALU); // ADDI x3,x0,3
    imem[2] = NOP;
    // ADD x1, x2, x3
    imem[3] = enc_r(7'b0000000, 5'd3, 5'd2, 3'b000, 5'd1, OP_R);
    imem[4] = NOP; // x1 committed to regfile before POPCOUNT EX
    // POPCOUNT x4, x1
    imem[5] = enc_r(7'b0000000, 5'd0, 5'd1, 3'b000, 5'd4, OP_CUST0);
    imem[6] = NOP;
    imem[7] = enc_s(12'h200, 5'd4, 5'd0, 3'b010, OP_STOR);
    imem[8] = NOP; imem[9] = NOP; imem[10] = NOP; imem[11] = NOP;
    run_cycles(15);
    // ref: 5+3=8; popcount(8)=1=0x00000001
    check32("No-fwd gap: ADD(5+3=8) NOP POPCOUNT x4=1",
            dmem_word(10'h200), 32'h00000001);

    // ========================================================================
    // TEST 9: Branch interaction — custom after taken branch (flush)
    // m2a-verification-plan.md §4.3
    // Spec: BEQ x0,x0 always taken (canonical-reference.md §1.5).
    //   Branch offset = +8 (2 instructions forward).
    //   The instruction immediately after BEQ is flushed (1-cycle penalty,
    //   canonical-reference.md §7.3).
    //   POPCOUNT in the flushed slot must NOT write x1.
    //
    // Layout:
    //   imem[0] ADDI x1, x0, 42   (x1 = 42, sentinel value)
    //   imem[1] ADDI x2, x0, 0xFF (x2 = 0xFF for potential POPCOUNT input)
    //   imem[2] NOP
    //   imem[3] BEQ x0, x0, +8    -> PC = 3*4 + 8 = 20 = imem[5]
    //   imem[4] POPCOUNT x1, x2   <- flushed, x1 must stay 42
    //   imem[5] NOP                <- branch target (ADD x3,x0,x0 safe NOP)
    //   imem[6] NOP
    //   imem[7] SW x1, 0x200(x0)
    //   imem[8..11] NOPs
    //
    // B-type imm encoding for offset +8:
    //   imm = 13'h008 (bits[12:0], bit0=0, offset in bytes)
    //   BEQ: funct3=000, opcode=1100011
    // ========================================================================
    $display("\n--- TEST 9: POPCOUNT flushed by taken branch ---");
    do_reset();
    imem[0] = enc_i(12'h02A, 5'd0, 3'b000, 5'd1, OP_IALU); // ADDI x1,x0,42
    imem[1] = enc_i(12'hFF,  5'd0, 3'b000, 5'd2, OP_IALU); // ADDI x2,x0,0xFF
    imem[2] = NOP;
    // BEQ x0, x0, +8: offset=8 bytes from BEQ PC=12 -> target=20=imem[5]
    imem[3] = enc_b(13'd8, 5'd0, 5'd0, 3'b000, OP_BRNC);
    // POPCOUNT x1,x2 -- this slot is flushed by the taken branch
    imem[4] = enc_r(7'b0000000, 5'd0, 5'd2, 3'b000, 5'd1, OP_CUST0);
    imem[5] = NOP; // branch target
    imem[6] = NOP;
    imem[7] = enc_s(12'h200, 5'd1, 5'd0, 3'b010, OP_STOR);
    imem[8] = NOP; imem[9] = NOP; imem[10] = NOP; imem[11] = NOP;
    run_cycles(15);
    // ref: x1 must still be 42 = 0x0000002A (POPCOUNT was flushed)
    check32("Flushed POPCOUNT: x1 unchanged == 42",
            dmem_word(10'h200), 32'h0000002A);

    // ========================================================================
    // TEST 10: Branch interaction — custom before branch (not-taken)
    // m2a-verification-plan.md §4.3
    // Spec: POPCOUNT x1,x2 executes, then BEQ x1,x0 is NOT taken (x1==8 != 0).
    //   ADDI x3,x0,99 after branch target executes and is verified.
    //
    // Layout:
    //   imem[0] ADDI x2, x0, 0xFF (x2=0xFF)
    //   imem[1] NOP
    //   imem[2] POPCOUNT x1, x2   (x1 = 8)
    //   imem[3] NOP
    //   imem[4] BEQ x1, x0, +16  -- NOT taken (x1=8, x0=0, 8 != 0)
    //   imem[5] ADDI x3, x0, 99  -- executes (fall-through)
    //   imem[6] NOP
    //   imem[7] SW x3, 0x200(x0)
    //   imem[8..11] NOPs
    // ========================================================================
    $display("\n--- TEST 10: POPCOUNT before not-taken branch ---");
    do_reset();
    imem[0] = enc_i(12'hFF,  5'd0, 3'b000, 5'd2, OP_IALU); // ADDI x2,x0,0xFF
    imem[1] = NOP;
    imem[2] = enc_r(7'b0000000, 5'd0, 5'd2, 3'b000, 5'd1, OP_CUST0);
    imem[3] = NOP;
    // BEQ x1, x0, +16: funct3=000; not taken since x1=8, x0=0
    imem[4] = enc_b(13'd16, 5'd0, 5'd1, 3'b000, OP_BRNC);
    imem[5] = enc_i(12'h063, 5'd0, 3'b000, 5'd3, OP_IALU); // ADDI x3,x0,99
    imem[6] = NOP;
    imem[7] = enc_s(12'h200, 5'd3, 5'd0, 3'b010, OP_STOR);
    imem[8] = NOP; imem[9] = NOP; imem[10] = NOP; imem[11] = NOP;
    run_cycles(15);
    // ref: x1=8 != x0=0, BEQ not taken; ADDI x3=99=0x00000063
    check32("POPCOUNT before not-taken BEQ: x3=99",
            dmem_word(10'h200), 32'h00000063);

    // ========================================================================
    // TEST 11: x0 suppression — POPCOUNT to x0
    // m2a-verification-plan.md §4.4, gotcha #8
    // Spec (canonical-reference.md §9.2, §7.3):
    //   Writes to x0 suppressed in register file (x0 always reads as 0).
    //   POPCOUNT x0, x2 must NOT change x0.
    // Verification: after POPCOUNT x0, x2, use ADD x3,x0,x0 -> x3 must be 0.
    //
    // Layout:
    //   imem[0] ADDI x2, x0, -1    (x2 = 0xFFFFFFFF, 32 ones)
    //   imem[1] NOP
    //   imem[2] POPCOUNT x0, x2    (rd=x0, suppressed; x0 stays 0)
    //   imem[3] ADD x3, x0, x0     (x3 = x0 + x0 = 0 + 0 = 0)
    //   imem[4] NOP
    //   imem[5] SW x3, 0x200(x0)
    //   imem[6..9] NOPs
    // ========================================================================
    $display("\n--- TEST 11: POPCOUNT to x0 suppressed ---");
    do_reset();
    // ADDI x2, x0, -1: imm = 12'hFFF (sign-extended = -1 = 0xFFFFFFFF)
    imem[0] = enc_i(12'hFFF, 5'd0, 3'b000, 5'd2, OP_IALU);
    imem[1] = NOP;
    // POPCOUNT x0, x2: rd=5'd0 (write suppressed by regfile, canonical §9.2)
    imem[2] = enc_r(7'b0000000, 5'd0, 5'd2, 3'b000, 5'd0, OP_CUST0);
    // ADD x3, x0, x0 — back-to-back: if x0 forwarding occurred, x3 would be 32
    imem[3] = enc_r(7'b0000000, 5'd0, 5'd0, 3'b000, 5'd3, OP_R);
    imem[4] = NOP;
    imem[5] = enc_s(12'h200, 5'd3, 5'd0, 3'b010, OP_STOR);
    imem[6] = NOP; imem[7] = NOP; imem[8] = NOP; imem[9] = NOP;
    run_cycles(13);
    // ref: x0 always 0; ADD(0,0)=0=0x00000000
    check32("POPCOUNT rd=x0 suppressed: ADD(x0,x0)=0",
            dmem_word(10'h200), 32'h00000000);

    // ========================================================================
    // TEST 12: x0 suppression — BREV to x0
    // m2a-verification-plan.md §4.4, gotcha #8
    // Spec: BREV x0, x2 must not write x0.
    //   x2 = 0x00000001; brev = 0x80000000
    //   After BREV x0, x2: ADD x3, x0, x0 must give 0, not 0x80000000.
    // ========================================================================
    $display("\n--- TEST 12: BREV to x0 suppressed ---");
    do_reset();
    imem[0] = enc_i(12'h001, 5'd0, 3'b000, 5'd2, OP_IALU); // ADDI x2,x0,1
    imem[1] = NOP;
    // BREV x0, x2
    imem[2] = enc_r(7'b0000001, 5'd0, 5'd2, 3'b000, 5'd0, OP_CUST0);
    // ADD x3, x0, x0
    imem[3] = enc_r(7'b0000000, 5'd0, 5'd0, 3'b000, 5'd3, OP_R);
    imem[4] = NOP;
    imem[5] = enc_s(12'h200, 5'd3, 5'd0, 3'b010, OP_STOR);
    imem[6] = NOP; imem[7] = NOP; imem[8] = NOP; imem[9] = NOP;
    run_cycles(13);
    // ref: x0 always 0; ADD(0,0)=0=0x00000000
    check32("BREV rd=x0 suppressed: ADD(x0,x0)=0",
            dmem_word(10'h200), 32'h00000000);

    // ========================================================================
    // TEST 13: Custom then ECALL — halt_o asserts after POPCOUNT
    // m2a-verification-plan.md §4.5
    // Spec (canonical-reference.md §1.8):
    //   ECALL: opcode=1110011, funct3=000, imm=0 -> assert halt_o
    // Verify x1 was written correctly before halt.
    //
    // Layout:
    //   imem[0] ADDI x2, x0, 0xFF (x2=0xFF)
    //   imem[1] NOP
    //   imem[2] POPCOUNT x1, x2   (x1=8)
    //   imem[3] NOP
    //   imem[4] ECALL              -> halt_o asserts
    //   imem[5] SW x1, 0x200(x0)  (may not execute; test halt_o timing)
    //   imem[6] NOP (ensure pipeline drains to ECALL)
    //
    // Strategy: run enough cycles for POPCOUNT to commit, then ECALL to
    // reach EX. Check x1 via SW BEFORE ECALL, then check halt_o.
    // Revised layout that ensures SW executes before ECALL halts:
    //   imem[0] ADDI x2, x0, 0xFF
    //   imem[1] NOP
    //   imem[2] POPCOUNT x1, x2
    //   imem[3] NOP
    //   imem[4] SW x1, 0x200(x0)   (store result first)
    //   imem[5] NOP
    //   imem[6] ECALL               (halt after SW committed)
    //   imem[7..10] NOPs
    // ========================================================================
    $display("\n--- TEST 13: Custom then ECALL (halt) ---");
    do_reset();
    imem[0] = enc_i(12'hFF, 5'd0, 3'b000, 5'd2, OP_IALU); // ADDI x2,x0,0xFF
    imem[1] = NOP;
    imem[2] = enc_r(7'b0000000, 5'd0, 5'd2, 3'b000, 5'd1, OP_CUST0);
    imem[3] = NOP;
    imem[4] = enc_s(12'h200, 5'd1, 5'd0, 3'b010, OP_STOR); // SW x1,0x200(x0)
    imem[5] = NOP;
    // ECALL: I-type, imm=0, rs1=x0, funct3=000, rd=x0, opcode=SYS
    imem[6] = enc_i(12'h000, 5'd0, 3'b000, 5'd0, OP_SYS);
    imem[7] = NOP; imem[8] = NOP; imem[9] = NOP; imem[10] = NOP;
    // SW at imem[4] commits result; run enough cycles for it
    run_cycles(8);
    // ref: popcount(0xFF)=8=0x00000008
    check32("Custom+ECALL: x1=8 before halt",
            dmem_word(10'h200), 32'h00000008);
    // ECALL at imem[6]: fetched at cycle 6, enters EX at cycle 7.
    // halt_o is transient (1 cycle in EX). Need to catch it.
    // We're at cycle 8; ECALL already left EX. Re-run from reset
    // with precise timing to catch halt_o.
    do_reset();
    imem[0] = enc_i(12'hFF, 5'd0, 3'b000, 5'd2, OP_IALU);
    imem[1] = NOP;
    imem[2] = enc_r(7'b0000000, 5'd0, 5'd2, 3'b000,
                     5'd1, OP_CUST0);
    imem[3] = NOP;
    imem[4] = enc_s(12'h200, 5'd1, 5'd0, 3'b010, OP_STOR);
    imem[5] = NOP;
    imem[6] = enc_i(12'h000, 5'd0, 3'b000, 5'd0, OP_SYS);
    imem[7] = NOP; imem[8] = NOP;
    // ECALL at word 6: enters EX after 7 posedges from reset
    run_cycles(7);
    check1("Custom+ECALL: halt_o==1", halt_o, 1'b1);

    // ========================================================================
    // TEST 14: Illegal custom funct7 -> halt_o (illegal instruction)
    // m2a-verification-plan.md §4.5
    // Spec (canonical-reference.md §2):
    //   Any opcode/funct7/funct3 not in the encoding table -> illegal_instr_o=1
    //   which drives halt_o (canonical-reference.md §9.1 note on halt pin).
    //   opcode=0001011, funct7=1111111 is not POPCOUNT (0000000) or BREV
    //   (0000001) -> illegal.
    // ========================================================================
    $display("\n--- TEST 14: Illegal CUSTOM-0 funct7 -> halt_o ---");
    do_reset();
    // Illegal: funct7=1111111, funct3=000, opcode=CUSTOM-0
    imem[0] = enc_r(7'b1111111, 5'd0, 5'd1, 3'b000, 5'd2, OP_CUST0);
    imem[1] = NOP; imem[2] = NOP; imem[3] = NOP; imem[4] = NOP;
    // Illegal instr at imem[0]: enters EX after 1 posedge.
    // halt_o is transient — check while instruction is in EX.
    run_cycles(1);
    check1("Illegal CUSTOM-0 funct7: halt_o==1", halt_o, 1'b1);

    // ========================================================================
    // TEST 15: POPCOUNT boundary — all-zeros input
    // Spec (canonical-reference.md §8.1):
    //   popcount(0x00000000) = 0
    // ========================================================================
    $display("\n--- TEST 15: POPCOUNT(0) = 0 ---");
    do_reset();
    // x2 = 0 (register reset to 0; ADDI x2,x0,0 explicit)
    imem[0] = enc_i(12'h000, 5'd0, 3'b000, 5'd2, OP_IALU); // ADDI x2,x0,0
    imem[1] = NOP;
    imem[2] = enc_r(7'b0000000, 5'd0, 5'd2, 3'b000, 5'd1, OP_CUST0);
    imem[3] = NOP;
    imem[4] = enc_s(12'h200, 5'd1, 5'd0, 3'b010, OP_STOR);
    imem[5] = NOP; imem[6] = NOP; imem[7] = NOP; imem[8] = NOP;
    run_cycles(12);
    // ref: popcount(0) = 0 = 0x00000000
    check32("POPCOUNT(0x00000000) = 0",
            dmem_word(10'h200), 32'h00000000);

    // ========================================================================
    // TEST 16: POPCOUNT boundary — all-ones input (0xFFFFFFFF)
    // Spec: popcount(0xFFFFFFFF) = 32 = 0x00000020
    // Use ADDI x2, x0, -1 to load 0xFFFFFFFF.
    // ========================================================================
    $display("\n--- TEST 16: POPCOUNT(0xFFFFFFFF) = 32 ---");
    do_reset();
    // ADDI x2, x0, -1: imm=12'hFFF (sign-ext -1 = 0xFFFFFFFF)
    imem[0] = enc_i(12'hFFF, 5'd0, 3'b000, 5'd2, OP_IALU);
    imem[1] = NOP;
    imem[2] = enc_r(7'b0000000, 5'd0, 5'd2, 3'b000, 5'd1, OP_CUST0);
    imem[3] = NOP;
    imem[4] = enc_s(12'h200, 5'd1, 5'd0, 3'b010, OP_STOR);
    imem[5] = NOP; imem[6] = NOP; imem[7] = NOP; imem[8] = NOP;
    run_cycles(12);
    // ref: popcount(0xFFFFFFFF) = 32 = 0x00000020
    check32("POPCOUNT(0xFFFFFFFF) = 32",
            dmem_word(10'h200), 32'h00000020);

    // ========================================================================
    // TEST 17: BREV boundary — all-zeros
    // Spec: brev(0x00000000) = 0x00000000 (all bits stay 0)
    // ========================================================================
    $display("\n--- TEST 17: BREV(0x00000000) = 0x00000000 ---");
    do_reset();
    imem[0] = enc_i(12'h000, 5'd0, 3'b000, 5'd2, OP_IALU); // ADDI x2,x0,0
    imem[1] = NOP;
    imem[2] = enc_r(7'b0000001, 5'd0, 5'd2, 3'b000, 5'd1, OP_CUST0);
    imem[3] = NOP;
    imem[4] = enc_s(12'h200, 5'd1, 5'd0, 3'b010, OP_STOR);
    imem[5] = NOP; imem[6] = NOP; imem[7] = NOP; imem[8] = NOP;
    run_cycles(12);
    // ref: brev(0) = 0
    check32("BREV(0x00000000) = 0x00000000",
            dmem_word(10'h200), 32'h00000000);

    // ========================================================================
    // TEST 18: BREV boundary — all-ones
    // Spec: brev(0xFFFFFFFF) = 0xFFFFFFFF (every bit set stays set)
    // ========================================================================
    $display("\n--- TEST 18: BREV(0xFFFFFFFF) = 0xFFFFFFFF ---");
    do_reset();
    imem[0] = enc_i(12'hFFF, 5'd0, 3'b000, 5'd2, OP_IALU); // ADDI x2,x0,-1
    imem[1] = NOP;
    imem[2] = enc_r(7'b0000001, 5'd0, 5'd2, 3'b000, 5'd1, OP_CUST0);
    imem[3] = NOP;
    imem[4] = enc_s(12'h200, 5'd1, 5'd0, 3'b010, OP_STOR);
    imem[5] = NOP; imem[6] = NOP; imem[7] = NOP; imem[8] = NOP;
    run_cycles(12);
    // ref: brev(0xFFFFFFFF) = 0xFFFFFFFF
    check32("BREV(0xFFFFFFFF) = 0xFFFFFFFF",
            dmem_word(10'h200), 32'hFFFFFFFF);

    // ========================================================================
    // TEST 19: BREV known pattern — 0x0000000F -> 0xF0000000
    // Spec: brev(0x0000000F):
    //   bits 0..3 set -> bits 31..28 set in result = 0xF0000000
    // ========================================================================
    $display("\n--- TEST 19: BREV(0x0000000F) = 0xF0000000 ---");
    do_reset();
    imem[0] = enc_i(12'h00F, 5'd0, 3'b000, 5'd2, OP_IALU); // ADDI x2,x0,15
    imem[1] = NOP;
    imem[2] = enc_r(7'b0000001, 5'd0, 5'd2, 3'b000, 5'd1, OP_CUST0);
    imem[3] = NOP;
    imem[4] = enc_s(12'h200, 5'd1, 5'd0, 3'b010, OP_STOR);
    imem[5] = NOP; imem[6] = NOP; imem[7] = NOP; imem[8] = NOP;
    run_cycles(12);
    // ref: brev(0x0000000F): bits[3:0] set -> bits[31:28] set = 0xF0000000
    check32("BREV(0x0000000F) = 0xF0000000",
            dmem_word(10'h200), 32'hF0000000);

    // ========================================================================
    // TEST 20: POPCOUNT alternating bits 0x55555555
    // Spec: popcount(0x55555555) = 16 (every even bit set, 16 total)
    // Load 0x55555555:
    //   LUI x2, 0x55556 -> x2 = 0x55556000
    //   ADDI x2, x2, 0x555 -> 0x55556000 + 0x555 = 0x55556555
    //   That's wrong. Use ORI instead.
    // Correct approach:
    //   LUI x2, 0x55555 -> x2 = 0x55555000
    //   ORI x2, x2, 0x555 -> x2 = 0x55555555
    // ORI: I-type, funct3=110, opcode=IALU
    // ========================================================================
    $display("\n--- TEST 20: POPCOUNT(0x55555555) = 16 ---");
    do_reset();
    // LUI x2, 0x55555 -> x2[31:12] = 0x55555, x2[11:0] = 0
    imem[0] = enc_u(20'h55555, 5'd2, OP_LUI);
    // ORI x2, x2, 0x555 -> x2 = 0x55555000 | 0x555 = 0x55555555
    imem[1] = enc_i(12'h555, 5'd2, 3'b110, 5'd2, OP_IALU);
    imem[2] = NOP;
    imem[3] = enc_r(7'b0000000, 5'd0, 5'd2, 3'b000, 5'd1, OP_CUST0);
    imem[4] = NOP;
    imem[5] = enc_s(12'h200, 5'd1, 5'd0, 3'b010, OP_STOR);
    imem[6] = NOP; imem[7] = NOP; imem[8] = NOP; imem[9] = NOP;
    run_cycles(13);
    // ref: 0x55555555 = 0101_0101..._0101; 16 ones = 0x00000010
    check32("POPCOUNT(0x55555555) = 16",
            dmem_word(10'h200), 32'h00000010);

    // ========================================================================
    // TEST 21: rs2 field ignored for POPCOUNT (unary operation)
    // Spec (canonical-reference.md §8.1): rs2 is don't-care for unary ops.
    // Test: same rs1, different rs2 encoded — result must be identical.
    //   POPCOUNT x1, x2 with rs2=x0 (encoded as 5'd0)
    //   POPCOUNT x4, x2 with rs2=x5 (encoded as 5'd5) — x5=0 from reset
    //   Both must give popcount(x2) = popcount(0xFF) = 8
    // ========================================================================
    $display("\n--- TEST 21: POPCOUNT rs2 field ignored (unary) ---");
    do_reset();
    imem[0] = enc_i(12'hFF, 5'd0, 3'b000, 5'd2, OP_IALU); // ADDI x2,x0,0xFF
    imem[1] = NOP;
    // POPCOUNT x1, x2 with rs2=x0 (5'd0)
    imem[2] = enc_r(7'b0000000, 5'd0, 5'd2, 3'b000, 5'd1, OP_CUST0);
    imem[3] = NOP;
    // POPCOUNT x4, x2 with rs2=x5 (5'd5, x5=0 after reset, but rs2 is dc)
    imem[4] = enc_r(7'b0000000, 5'd5, 5'd2, 3'b000, 5'd4, OP_CUST0);
    imem[5] = NOP;
    imem[6] = enc_s(12'h200, 5'd1, 5'd0, 3'b010, OP_STOR); // SW x1
    imem[7] = enc_s(12'h204, 5'd4, 5'd0, 3'b010, OP_STOR); // SW x4
    imem[8] = NOP; imem[9] = NOP; imem[10] = NOP; imem[11] = NOP;
    run_cycles(15);
    // ref: both = popcount(0xFF) = 8 = 0x00000008
    check32("POPCOUNT rs2=x0: x1=8",
            dmem_word(10'h200), 32'h00000008);
    check32("POPCOUNT rs2=x5(dc): x4=8 (rs2 ignored)",
            dmem_word(10'h204), 32'h00000008);

    // ========================================================================
    // TEST 22: POPCOUNT single-bit inputs (spot check)
    // Spec: popcount(2^k) = 1 for any k in 0..31.
    //   x2 = 1 (bit 0): popcount = 1
    //   x2 = 0x8000 (bit 15): popcount = 1
    // Load 0x8000: ADDI x2,x0, +0x800 would sign-extend to negative.
    //   Use LUI x2, 0x00001 -> x2=0x00001000; SLLI x2,x2,3 -> 0x00008000
    //   SLLI: I-type, funct3=001, funct7+shamt: imm={0000000,5'd3}
    // ========================================================================
    $display("\n--- TEST 22: POPCOUNT single-bit (bit0 and bit15) ---");
    do_reset();
    // popcount(0x00000001) = 1
    imem[0] = enc_i(12'h001, 5'd0, 3'b000, 5'd2, OP_IALU); // ADDI x2,x0,1
    imem[1] = NOP;
    imem[2] = enc_r(7'b0000000, 5'd0, 5'd2, 3'b000, 5'd1, OP_CUST0);
    imem[3] = NOP;
    imem[4] = enc_s(12'h200, 5'd1, 5'd0, 3'b010, OP_STOR);
    imem[5] = NOP; imem[6] = NOP; imem[7] = NOP; imem[8] = NOP;
    run_cycles(12);
    check32("POPCOUNT(0x00000001) = 1",
            dmem_word(10'h200), 32'h00000001);

    do_reset();
    // Load 0x00008000 = 2^15:
    //   ADDI x2,x0,1 -> x2=1; SLLI x2,x2,15 -> x2=0x00008000
    //   SLLI imm encoding: {0000000, shamt[4:0]} = {7'b0000000, 5'd15}=12'h00F
    imem[0] = enc_i(12'h001, 5'd0, 3'b000, 5'd2, OP_IALU); // ADDI x2,x0,1
    imem[1] = enc_i(12'h00F, 5'd2, 3'b001, 5'd2, OP_IALU); // SLLI x2,x2,15
    imem[2] = NOP;
    imem[3] = enc_r(7'b0000000, 5'd0, 5'd2, 3'b000, 5'd1, OP_CUST0);
    imem[4] = NOP;
    imem[5] = enc_s(12'h200, 5'd1, 5'd0, 3'b010, OP_STOR);
    imem[6] = NOP; imem[7] = NOP; imem[8] = NOP; imem[9] = NOP;
    run_cycles(13);
    // ref: popcount(0x00008000) = 1 = 0x00000001
    check32("POPCOUNT(0x00008000) = 1 (bit 15)",
            dmem_word(10'h200), 32'h00000001);

    // ========================================================================
    // TEST 23: BREV MSB<->LSB swap
    // Spec: brev(0x80000000): bit 31 set -> bit 0 set = 0x00000001
    // Load 0x80000000: LUI x2, 0x80000 -> x2 = 0x80000000
    // ========================================================================
    $display("\n--- TEST 23: BREV(0x80000000) = 0x00000001 ---");
    do_reset();
    // LUI x2, 0x80000 -> x2 = 0x80000000 (canonical-reference.md §1.7)
    imem[0] = enc_u(20'h80000, 5'd2, OP_LUI);
    imem[1] = NOP;
    imem[2] = enc_r(7'b0000001, 5'd0, 5'd2, 3'b000, 5'd1, OP_CUST0);
    imem[3] = NOP;
    imem[4] = enc_s(12'h200, 5'd1, 5'd0, 3'b010, OP_STOR);
    imem[5] = NOP; imem[6] = NOP; imem[7] = NOP; imem[8] = NOP;
    run_cycles(12);
    // ref: brev(0x80000000): bit 31 -> bit 0 = 0x00000001
    check32("BREV(0x80000000) = 0x00000001",
            dmem_word(10'h200), 32'h00000001);

    // ========================================================================
    // FINAL SUMMARY
    // ========================================================================
    $display("\n----------------------------------------------");
    $display("RESULT: %0d PASSED, %0d FAILED",
             pass_count, fail_count);
    $display("----------------------------------------------");
    if (fail_count == 0)
      $display("ALL TESTS PASSED");
    else
      $display("FAILURES DETECTED -- see FAIL lines above");
    $finish;
  end

  // Timeout watchdog: 100000 ns = 100 us; prevents infinite loops
  initial begin
    #100000;
    $display("TIMEOUT: simulation exceeded 100 us");
    $finish;
  end

endmodule
