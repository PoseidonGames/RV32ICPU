// ============================================================================
// Module: tb_pipeline_clz_mul
// Description: Self-checking testbench for CLZ and MUL16S custom instructions
//              (CUSTOM-0 opcode) at the pipeline_top level.
//              Derives ALL expected values from canonical-reference.md §8.1
//              and §8.2. Tests: basic execution, WB->EX forwarding,
//              x0 suppression, and CLZ->MUL16S chaining.
// Author: Beaux Cable (Verification Agent)
// Date: April 2026
// Project: RV32I Pipelined Processor
//
// Instruction encoding reference: canonical-reference.md §3, §8.1, §8.2
//   CUSTOM-0 opcode: 7'b0001011
//   CLZ:    funct7=0000101, funct3=000, R-type unary (rd=clz(rs1), rs2 dc)
//   MUL16S: funct7=0000100, funct3=000, R-type binary
//
// CLZ result (canonical-reference.md §8.1):
//   Range 0-32. Returns 32 when rs1=0. Returns 0 when rs1[31]=1.
//
// MUL16S (canonical-reference.md §8.2):
//   Signed 16x16->32. rd = sext(rs1[15:0]) x sext(rs2[15:0]).
//   Scoped to lower 16 bits of each operand.
//
// Pipeline timing (canonical-reference.md §7.1):
//   Cycle N  : instruction fetched from imem[N]
//   Cycle N+1: instruction in EX stage
//   Cycle N+2: result written to regfile (WB)
//   WB->EX forwarding: instruction N+1 sees result of N via forwarding mux.
//
// Pattern follows tb_pipeline_custom.sv exactly (imem/dmem model, SW
// readback, negedge stimulus, run_cycles drain).
// ============================================================================

`timescale 1ns/1ps

module tb_pipeline_clz_mul;

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

  // Reset pipeline and memories; fill imem with NOPs.
  // Gotcha #11: drive stimulus at negedge to avoid races.
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

  // U-type: {imm[31:12], rd, opcode}
  function automatic [31:0] enc_u(
    input [19:0] imm_upper,
    input [4:0]  rd,
    input [6:0]  opcode
  );
    enc_u = {imm_upper, rd, opcode};
  endfunction

  // ==========================================================================
  // Opcode constants (canonical-reference.md §2)
  // ==========================================================================
  localparam [6:0] OP_IALU  = 7'b0010011; // I-type ALU (ADDI etc.)
  localparam [6:0] OP_STOR  = 7'b0100011; // Stores
  localparam [6:0] OP_R     = 7'b0110011; // R-type ALU
  localparam [6:0] OP_LUI   = 7'b0110111; // LUI
  // CUSTOM-0: canonical-reference.md §2, §8.1
  localparam [6:0] OP_CUST0 = 7'b0001011;

  // funct7 codes for custom instructions
  // canonical-reference.md §8.1: CLZ funct7=0000101
  localparam [6:0] F7_CLZ    = 7'b0000101;
  // canonical-reference.md §8.2: MUL16S funct7=0000100
  localparam [6:0] F7_MUL16S = 7'b0000100;

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
  // TEST SUITE
  //
  // Expected value derivations (from canonical-reference.md §8.1 and §8.2):
  //
  //   CLZ(0x00000000) = 32 = 0x00000020
  //     Spec §8.1: "32 when rs1=0"
  //
  //   CLZ(0x80000000) = 0 = 0x00000000
  //     Spec §8.1: "0 when rs1[31]=1"; bit 31 is set, so 0 leading zeros.
  //
  //   CLZ(0x00000001) = 31 = 0x0000001F
  //     Spec §8.1: highest set bit is bit 0; bits 31..1 are all zero -> 31.
  //
  //   CLZ(0x00000004) = 29 = 0x0000001D
  //     Spec §8.1: 4 = binary 100; highest set bit is bit 2;
  //     bits 31..3 are zero -> 29 leading zeros.
  //
  //   MUL16S(5, 3) = 15 = 0x0000000F
  //     Spec §8.2: sext(5[15:0])=5, sext(3[15:0])=3; 5 x 3 = 15.
  //
  //   MUL16S(0xFFFFFFFF, 7) = -7 = 0xFFFFFFF9
  //     Spec §8.2: rs1[15:0]=0xFFFF -> sext=-1; rs2[15:0]=0x0007 -> sext=7;
  //     signed: -1 x 7 = -7 = 0xFFFFFFF9.
  //
  //   MUL16S(6, 6) = 36 = 0x00000024
  //     Spec §8.2: sext(6)=6, sext(6)=6; 6 x 6 = 36.
  //
  //   MUL16S(29, 2) = 58 = 0x0000003A
  //     Spec §8.2: sext(29)=29, sext(2)=2; 29 x 2 = 58.
  // ==========================================================================
  initial begin
    pass_count = 0;
    fail_count = 0;

    // ========================================================================
    // TEST 1a: CLZ basic — rs1=0, expect 32
    // Spec (canonical-reference.md §8.1):
    //   CLZ: rd = clz(rs1). Returns 32 when rs1=0.
    //   Input: x1=0 (ADDI x1, x0, 0)
    //   Expected: x2 = 32 = 0x00000020
    // Sequence:
    //   imem[0] ADDI x1, x0, 0    -> x1 = 0
    //   imem[1] NOP               (gap: x1 WB before CLZ EX)
    //   imem[2] CLZ x2, x1        -> x2 = 32
    //   imem[3] NOP
    //   imem[4] SW x2, 0x200(x0)
    //   imem[5..8] NOPs (drain)
    // ========================================================================
    $display("\n--- TEST 1a: CLZ(0) = 32 ---");
    do_reset();
    imem[0] = enc_i(12'h000, 5'd0, 3'b000, 5'd1, OP_IALU); // ADDI x1,x0,0
    imem[1] = NOP;
    // CLZ x2, x1: funct7=0000101, rs2=x0(dc), rs1=x1, funct3=000, rd=x2
    imem[2] = enc_r(F7_CLZ, 5'd0, 5'd1, 3'b000, 5'd2, OP_CUST0);
    imem[3] = NOP;
    imem[4] = enc_s(12'h200, 5'd2, 5'd0, 3'b010, OP_STOR); // SW x2,0x200(x0)
    imem[5] = NOP; imem[6] = NOP; imem[7] = NOP; imem[8] = NOP;
    run_cycles(12);
    // ref: clz(0) = 32 = 0x00000020 (canonical §8.1)
    check32("CLZ(x1=0) -> x2=32", dmem_word(10'h200), 32'h00000020);

    // ========================================================================
    // TEST 1b: CLZ basic — rs1=0x80000000, expect 0
    // Spec (canonical-reference.md §8.1):
    //   CLZ result is 0 when rs1[31]=1.
    //   Input: x3 = 0x80000000 (LUI x3, 0x80000: §1.7 LUI sets rd=imm<<12)
    //   LUI imm_upper=20'h80000: rd = 0x80000_000 = 0x80000000
    //   Expected: x4 = 0 = 0x00000000
    // Sequence:
    //   imem[0] LUI x3, 0x80000   -> x3 = 0x80000000
    //   imem[1] NOP
    //   imem[2] CLZ x4, x3        -> x4 = 0
    //   imem[3] NOP
    //   imem[4] SW x4, 0x200(x0)
    //   imem[5..8] NOPs
    // ========================================================================
    $display("\n--- TEST 1b: CLZ(0x80000000) = 0 ---");
    do_reset();
    // LUI x3, 0x80000: imm_upper=20'h80000, rd=x3, opcode=LUI
    imem[0] = enc_u(20'h80000, 5'd3, OP_LUI);
    imem[1] = NOP;
    // CLZ x4, x3
    imem[2] = enc_r(F7_CLZ, 5'd0, 5'd3, 3'b000, 5'd4, OP_CUST0);
    imem[3] = NOP;
    imem[4] = enc_s(12'h200, 5'd4, 5'd0, 3'b010, OP_STOR);
    imem[5] = NOP; imem[6] = NOP; imem[7] = NOP; imem[8] = NOP;
    run_cycles(12);
    // ref: clz(0x80000000) = 0; rs1[31]=1 -> 0 leading zeros (canonical §8.1)
    check32("CLZ(x3=0x80000000) -> x4=0", dmem_word(10'h200), 32'h00000000);

    // ========================================================================
    // TEST 1c: CLZ basic — rs1=1, expect 31
    // Spec (canonical-reference.md §8.1):
    //   clz(0x00000001): only bit 0 set, bits 31..1 all zero -> 31.
    //   Expected: x6 = 31 = 0x0000001F
    // Sequence:
    //   imem[0] ADDI x5, x0, 1    -> x5 = 1
    //   imem[1] NOP
    //   imem[2] CLZ x6, x5        -> x6 = 31
    //   imem[3] NOP
    //   imem[4] SW x6, 0x200(x0)
    //   imem[5..8] NOPs
    // ========================================================================
    $display("\n--- TEST 1c: CLZ(1) = 31 ---");
    do_reset();
    imem[0] = enc_i(12'h001, 5'd0, 3'b000, 5'd5, OP_IALU); // ADDI x5,x0,1
    imem[1] = NOP;
    // CLZ x6, x5
    imem[2] = enc_r(F7_CLZ, 5'd0, 5'd5, 3'b000, 5'd6, OP_CUST0);
    imem[3] = NOP;
    imem[4] = enc_s(12'h200, 5'd6, 5'd0, 3'b010, OP_STOR);
    imem[5] = NOP; imem[6] = NOP; imem[7] = NOP; imem[8] = NOP;
    run_cycles(12);
    // ref: clz(1) = 31 = 0x0000001F (canonical §8.1)
    check32("CLZ(x5=1) -> x6=31", dmem_word(10'h200), 32'h0000001F);

    // ========================================================================
    // TEST 2a: MUL16S basic — positive x positive
    // Spec (canonical-reference.md §8.2):
    //   MUL16S: rd = sext(rs1[15:0]) x sext(rs2[15:0])
    //   x1=5, x2=3: sext(5)=5, sext(3)=3; 5 x 3 = 15 = 0x0000000F
    // Sequence:
    //   imem[0] ADDI x1, x0, 5    -> x1 = 5
    //   imem[1] ADDI x2, x0, 3    -> x2 = 3
    //   imem[2] NOP               (gap: both x1 and x2 WB before MUL16S EX)
    //   imem[3] MUL16S x3, x1, x2 -> x3 = 15
    //   imem[4] NOP
    //   imem[5] SW x3, 0x200(x0)
    //   imem[6..9] NOPs
    // ========================================================================
    $display("\n--- TEST 2a: MUL16S(5, 3) = 15 ---");
    do_reset();
    imem[0] = enc_i(12'h005, 5'd0, 3'b000, 5'd1, OP_IALU); // ADDI x1,x0,5
    imem[1] = enc_i(12'h003, 5'd0, 3'b000, 5'd2, OP_IALU); // ADDI x2,x0,3
    imem[2] = NOP;
    // MUL16S x3, x1, x2: funct7=0000100, rs2=x2, rs1=x1, funct3=000, rd=x3
    imem[3] = enc_r(F7_MUL16S, 5'd2, 5'd1, 3'b000, 5'd3, OP_CUST0);
    imem[4] = NOP;
    imem[5] = enc_s(12'h200, 5'd3, 5'd0, 3'b010, OP_STOR);
    imem[6] = NOP; imem[7] = NOP; imem[8] = NOP; imem[9] = NOP;
    run_cycles(13);
    // ref: sext(5) x sext(3) = 15 = 0x0000000F (canonical §8.2)
    check32("MUL16S(x1=5, x2=3) -> x3=15", dmem_word(10'h200), 32'h0000000F);

    // ========================================================================
    // TEST 2b: MUL16S basic — negative x positive
    // Spec (canonical-reference.md §8.2):
    //   x4 = -1 (ADDI x4, x0, -1 -> 0xFFFFFFFF)
    //   rs1[15:0] = 0xFFFF; sext(0xFFFF to 32-bit signed) = -1
    //   x5 = 7; sext(0x0007) = 7
    //   MUL16S x6, x4, x5: -1 x 7 = -7 = 0xFFFFFFF9
    // Sequence:
    //   imem[0] ADDI x4, x0, -1   -> x4 = 0xFFFFFFFF
    //   imem[1] ADDI x5, x0, 7    -> x5 = 7
    //   imem[2] NOP
    //   imem[3] MUL16S x6, x4, x5 -> x6 = -7 = 0xFFFFFFF9
    //   imem[4] NOP
    //   imem[5] SW x6, 0x200(x0)
    //   imem[6..9] NOPs
    // ========================================================================
    $display("\n--- TEST 2b: MUL16S(-1, 7) = -7 ---");
    do_reset();
    // ADDI x4, x0, -1: imm=12'hFFF (sign-ext = -1 = 0xFFFFFFFF)
    imem[0] = enc_i(12'hFFF, 5'd0, 3'b000, 5'd4, OP_IALU);
    imem[1] = enc_i(12'h007, 5'd0, 3'b000, 5'd5, OP_IALU); // ADDI x5,x0,7
    imem[2] = NOP;
    // MUL16S x6, x4, x5
    imem[3] = enc_r(F7_MUL16S, 5'd5, 5'd4, 3'b000, 5'd6, OP_CUST0);
    imem[4] = NOP;
    imem[5] = enc_s(12'h200, 5'd6, 5'd0, 3'b010, OP_STOR);
    imem[6] = NOP; imem[7] = NOP; imem[8] = NOP; imem[9] = NOP;
    run_cycles(13);
    // ref: sext(0xFFFF)=-1, sext(7)=7; -1 x 7 = -7 = 0xFFFFFFF9
    // (canonical §8.2: signed 16x16->32)
    check32("MUL16S(x4=-1, x5=7) -> x6=-7", dmem_word(10'h200), 32'hFFFFFFF9);

    // ========================================================================
    // TEST 3: WB->EX forwarding with CLZ
    // Spec (canonical-reference.md §7.3):
    //   WB->EX forward: instruction N+1 in EX uses result of instruction N
    //   when N is in WB simultaneously.
    //   forward_rs1 condition: wb_reg_write && wb_rd!=0 && wb_rd==ex_rs1
    //                          && alu_src_a==2'b00 (canonical §7.3)
    //   ADDI x1, x0, 1  (imem[0]) -> x1=1; WB at cycle 2
    //   CLZ x2, x1      (imem[1]) -> EX at cycle 2; rs1=x1, forwarded x1=1
    //   Expected: x2 = clz(1) = 31 = 0x0000001F
    // Sequence:
    //   imem[0] ADDI x1, x0, 1    -> x1 = 1
    //   imem[1] CLZ x2, x1        -> forwarded x1=1; x2=31
    //   imem[2] NOP
    //   imem[3] SW x2, 0x200(x0)
    //   imem[4..7] NOPs
    // ========================================================================
    $display("\n--- TEST 3: WB->EX forwarding with CLZ ---");
    do_reset();
    imem[0] = enc_i(12'h001, 5'd0, 3'b000, 5'd1, OP_IALU); // ADDI x1,x0,1
    // CLZ x2, x1 back-to-back: WB->EX forward rs1=x1
    imem[1] = enc_r(F7_CLZ, 5'd0, 5'd1, 3'b000, 5'd2, OP_CUST0);
    imem[2] = NOP;
    imem[3] = enc_s(12'h200, 5'd2, 5'd0, 3'b010, OP_STOR);
    imem[4] = NOP; imem[5] = NOP; imem[6] = NOP; imem[7] = NOP;
    run_cycles(11);
    // ref: clz(1) = 31 = 0x0000001F (canonical §8.1)
    check32("Fwd WB->EX: ADDI(1)->CLZ x2=31",
            dmem_word(10'h200), 32'h0000001F);

    // ========================================================================
    // TEST 4: WB->EX forwarding with MUL16S (both rs1 and rs2 forwarded)
    // Spec (canonical-reference.md §7.3):
    //   forward_rs1 and forward_rs2 both active for same source register.
    //   ADDI x1, x0, 6  (imem[0]) -> x1=6; WB at cycle 2
    //   MUL16S x2, x1, x1 (imem[1]) -> EX at cycle 2
    //     rs1=x1 forwarded: sext(6)=6
    //     rs2=x1 forwarded: sext(6)=6
    //     result: 6 x 6 = 36 = 0x00000024
    // Sequence:
    //   imem[0] ADDI x1, x0, 6    -> x1 = 6
    //   imem[1] MUL16S x2, x1, x1 -> forwarded x1 to both; x2=36
    //   imem[2] NOP
    //   imem[3] SW x2, 0x200(x0)
    //   imem[4..7] NOPs
    // ========================================================================
    $display("\n--- TEST 4: WB->EX forwarding with MUL16S (both rs) ---");
    do_reset();
    imem[0] = enc_i(12'h006, 5'd0, 3'b000, 5'd1, OP_IALU); // ADDI x1,x0,6
    // MUL16S x2, x1, x1 back-to-back: WB->EX forward for rs1 and rs2
    imem[1] = enc_r(F7_MUL16S, 5'd1, 5'd1, 3'b000, 5'd2, OP_CUST0);
    imem[2] = NOP;
    imem[3] = enc_s(12'h200, 5'd2, 5'd0, 3'b010, OP_STOR);
    imem[4] = NOP; imem[5] = NOP; imem[6] = NOP; imem[7] = NOP;
    run_cycles(11);
    // ref: sext(6) x sext(6) = 36 = 0x00000024 (canonical §8.2)
    check32("Fwd WB->EX: ADDI(6)->MUL16S(x1,x1) x2=36",
            dmem_word(10'h200), 32'h00000024);

    // ========================================================================
    // TEST 5: x0 suppression — CLZ to x0
    // Spec (canonical-reference.md §9.2, §7.3):
    //   Writes to x0 suppressed in register file; x0 always reads as 0.
    //   forward_rs1/rs2 gate: wb_rd!=0 prevents forwarding from x0 write.
    //   CLZ x0, x5 with x5=1: clz(1)=31, but write to x0 is suppressed.
    //   ADD x7, x0, x0 immediately after: if x0 were forwarded as 31,
    //   x7 would be 62. Expected: x7=0 (x0 is always 0).
    // Gotcha #8: x0 write/forward suppression.
    // Sequence:
    //   imem[0] ADDI x5, x0, 1    -> x5 = 1
    //   imem[1] NOP
    //   imem[2] CLZ x0, x5        -> rd=x0, write suppressed
    //   imem[3] ADD x7, x0, x0   -> x7 = 0 + 0 = 0
    //   imem[4] NOP
    //   imem[5] SW x7, 0x200(x0)
    //   imem[6..9] NOPs
    // ========================================================================
    $display("\n--- TEST 5: x0 suppression: CLZ rd=x0 ---");
    do_reset();
    imem[0] = enc_i(12'h001, 5'd0, 3'b000, 5'd5, OP_IALU); // ADDI x5,x0,1
    imem[1] = NOP;
    // CLZ x0, x5: rd=5'd0 (write suppressed by regfile, canonical §9.2)
    imem[2] = enc_r(F7_CLZ, 5'd0, 5'd5, 3'b000, 5'd0, OP_CUST0);
    // ADD x7, x0, x0: wb_rd==0 prevents forward; x0 read as 0
    imem[3] = enc_r(7'b0000000, 5'd0, 5'd0, 3'b000, 5'd7, OP_R);
    imem[4] = NOP;
    imem[5] = enc_s(12'h200, 5'd7, 5'd0, 3'b010, OP_STOR);
    imem[6] = NOP; imem[7] = NOP; imem[8] = NOP; imem[9] = NOP;
    run_cycles(13);
    // ref: x0 always 0; ADD(0,0)=0=0x00000000
    check32("CLZ rd=x0 suppressed: ADD(x0,x0)=0",
            dmem_word(10'h200), 32'h00000000);

    // ========================================================================
    // TEST 6: CLZ feeding MUL16S (instruction chaining with NOP bubble)
    // Spec (canonical-reference.md §8.1, §8.2):
    //   ADDI x1, x0, 4     -> x1 = 4
    //   CLZ x2, x1         -> x2 = clz(4) = 29 = 0x0000001D
    //     Derivation: 4 = 0b...0100; highest set bit = bit 2;
    //                 bits 31..3 = 29 zeros.
    //   ADDI x3, x0, 2     -> x3 = 2
    //   MUL16S x4, x2, x3  -> x4 = sext(29) x sext(2) = 58 = 0x0000003A
    //     Derivation: 29 x 2 = 58 (both positive; product = 58).
    //
    // NOP bubble at imem[3] ensures x2 is committed to regfile before
    // MUL16S enters EX (avoids need for forwarding from CLZ to MUL16S
    // across two instructions — tests normal regfile read path).
    //
    // Sequence:
    //   imem[0] ADDI x1, x0, 4    -> x1 = 4
    //   imem[1] NOP
    //   imem[2] CLZ x2, x1        -> x2 = 29
    //   imem[3] NOP               (bubble: x2 WB before MUL16S EX)
    //   imem[4] ADDI x3, x0, 2    -> x3 = 2
    //   imem[5] NOP
    //   imem[6] MUL16S x4, x2, x3 -> x4 = 58
    //   imem[7] NOP
    //   imem[8] SW x4, 0x200(x0)
    //   imem[9..12] NOPs
    // ========================================================================
    $display("\n--- TEST 6: CLZ(4)=29 chained into MUL16S(29,2)=58 ---");
    do_reset();
    imem[0] = enc_i(12'h004, 5'd0, 3'b000, 5'd1, OP_IALU); // ADDI x1,x0,4
    imem[1] = NOP;
    // CLZ x2, x1
    imem[2] = enc_r(F7_CLZ, 5'd0, 5'd1, 3'b000, 5'd2, OP_CUST0);
    imem[3] = NOP; // bubble: x2 committed before MUL16S EX
    imem[4] = enc_i(12'h002, 5'd0, 3'b000, 5'd3, OP_IALU); // ADDI x3,x0,2
    imem[5] = NOP;
    // MUL16S x4, x2, x3
    imem[6] = enc_r(F7_MUL16S, 5'd3, 5'd2, 3'b000, 5'd4, OP_CUST0);
    imem[7] = NOP;
    imem[8] = enc_s(12'h200, 5'd4, 5'd0, 3'b010, OP_STOR);
    imem[9]  = NOP; imem[10] = NOP; imem[11] = NOP; imem[12] = NOP;
    run_cycles(16);
    // ref: clz(4)=29; sext(29) x sext(2) = 58 = 0x0000003A
    check32("CLZ(4)=29; MUL16S(29,2)=58",
            dmem_word(10'h200), 32'h0000003A);

    // ========================================================================
    // Summary
    // ========================================================================
    $display("\n========================================");
    $display("RESULTS: %0d passed, %0d failed",
             pass_count, fail_count);
    $display("========================================");
    if (fail_count == 0)
      $display("ALL TESTS PASSED");
    else
      $display("FAILURES DETECTED -- see FAIL lines above");
    $finish;
  end

endmodule
