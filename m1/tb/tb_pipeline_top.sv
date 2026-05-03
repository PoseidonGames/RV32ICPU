// ============================================================================
// Module: tb_pipeline_top
// Description: Self-checking testbench for pipeline_top.sv (M1 3-stage
//              RV32I pipeline). Derives ALL expected values from
//              docs/canonical-reference.md. Tests: NOP stream, R-type,
//              I-type ALU, LUI, AUIPC, Load/Store, branches (taken/not-taken),
//              JAL, JALR, WB-to-EX forwarding, Fibonacci program, ECALL halt.
// Author: Beaux Cable (Verification Agent)
// Date: April 2026
// Project: TSI RV32I Pipelined Processor (TSMC 180nm)
//
// Instruction encoding reference: canonical-reference.md §3
//   R-type: {funct7[6:0], rs2[4:0], rs1[4:0], funct3[2:0], rd[4:0], opcode[6:0]}
//   I-type: {imm[11:0], rs1[4:0], funct3[2:0], rd[4:0], opcode[6:0]}
//   S-type: {imm[11:5], rs2[4:0], rs1[4:0], funct3[2:0], imm[4:0], opcode[6:0]}
//   B-type: {imm[12], imm[10:5], rs2[4:0], rs1[4:0], funct3[2:0],
//            imm[4:1], imm[11], opcode[6:0]}
//   U-type: {imm[31:12], rd[4:0], opcode[6:0]}
//   J-type: {imm[20], imm[10:1], imm[11], imm[19:12], rd[4:0], opcode[6:0]}
//
// Pipeline timing (canonical-reference.md §7.1):
//   Cycle N  : PC=addr, instruction word available on instr_data_i
//   Cycle N+1: Instruction in IF/EX register (EX stage), PC advances
//   Cycle N+2: Result written to regfile (WB stage, via EX/WB register)
//   So an instruction fetched in cycle N is visible in regfile after cycle N+2.
//
// Forwarding (canonical-reference.md §7.3):
//   WB-to-EX forwarding: instruction in EX can see result that is simultaneously
//   being written back by the prior instruction in WB (same cycle).
//   This means: inst@N writes result at end of cycle N+2;
//               inst@N+1 (in EX at cycle N+2) can use that result via forwarding.
// ============================================================================

`timescale 1ns/1ps

module tb_pipeline_top;

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
  logic [31:0] imem [0:255];  // instruction memory
  logic [7:0]  dmem [0:1023]; // data memory (byte array, 1 KiB)

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
  // Clock: 10 ns period = 100 MHz (matches conventions.md requirement of
  // `always #10 clk = ~clk`)
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
      $display("FAIL  %s: got=0x%08X expected=0x%08X", test_name, got, expected);
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

  // Reset pipeline and memories, flush imem/dmem, wait for clean state.
  // Conventions (conventions.md + m1-pipeline-plan.md §gotcha #11):
  //   - Drive stimulus at negedge clk to avoid races
  //   - Assert rst_n=0 for 2 cycles, deassert on posedge, wait 1 more cycle
  task automatic do_reset();
    integer i;
    // Clear instruction memory to NOP so pipeline idles cleanly
    for (i = 0; i < 256; i++) imem[i] = 32'h00000013; // NOP
    // Clear data memory
    for (i = 0; i < 1024; i++) dmem[i] = 8'h00;
    // Assert reset
    @(negedge clk);
    rst_n = 1'b0;
    @(negedge clk);
    @(negedge clk);
    // Deassert on negedge so rst_n is stable before next posedge
    @(negedge clk);
    rst_n = 1'b1;
    #1;
  endtask

  // Run N clock cycles (used to drain pipeline after loading a program)
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

  // B-type: {imm[12], imm[10:5], rs2, rs1, funct3, imm[4:1], imm[11], opcode}
  // imm is a signed byte offset (multiples of 2); bit 0 always 0.
  function automatic [31:0] enc_b(
    input [12:0] imm, // imm[12:0]; bit 0 is 0
    input [4:0]  rs2, rs1,
    input [2:0]  funct3,
    input [6:0]  opcode
  );
    enc_b = {imm[12], imm[10:5], rs2, rs1, funct3, imm[4:1], imm[11], opcode};
  endfunction

  // U-type: {imm[31:12], rd, opcode}
  // imm_upper is the 20-bit upper immediate (placed at [31:12])
  function automatic [31:0] enc_u(
    input [19:0] imm_upper,
    input [4:0]  rd,
    input [6:0]  opcode
  );
    enc_u = {imm_upper, rd, opcode};
  endfunction

  // J-type: {imm[20], imm[10:1], imm[11], imm[19:12], rd, opcode}
  // imm is the 21-bit signed byte offset (bit 0 always 0)
  function automatic [31:0] enc_j(
    input [20:0] imm, // imm[20:0]; bit 0 is 0
    input [4:0]  rd,
    input [6:0]  opcode
  );
    enc_j = {imm[20], imm[10:1], imm[11], imm[19:12], rd, opcode};
  endfunction

  // Opcode constants (canonical-reference.md §2)
  localparam [6:0] OP_R    = 7'b0110011; // R-type ALU
  localparam [6:0] OP_IALU = 7'b0010011; // I-type ALU (ADDI etc.)
  localparam [6:0] OP_LOAD = 7'b0000011; // Loads
  localparam [6:0] OP_STOR = 7'b0100011; // Stores
  localparam [6:0] OP_BRNC = 7'b1100011; // Branches
  localparam [6:0] OP_JAL  = 7'b1101111; // JAL
  localparam [6:0] OP_JALR = 7'b1100111; // JALR
  localparam [6:0] OP_LUI  = 7'b0110111; // LUI
  localparam [6:0] OP_AUIPC= 7'b0010111; // AUIPC
  localparam [6:0] OP_SYS  = 7'b1110011; // ECALL/EBREAK

  // NOP = ADDI x0, x0, 0 (canonical-reference.md §7.3)
  localparam [31:0] NOP = 32'h00000013;

  // ==========================================================================
  // Register file readback helper
  // To observe a register value, we issue a SW from that register to a known
  // dmem address (0x100), then read dmem after enough pipeline cycles.
  // This avoids any need to peek inside the DUT.
  //
  // Sequence: SW rx, 0(x0) stores rx to addr 0x100
  //   then NOP * 4 to drain pipeline
  //   then read dmem[0x100].
  //
  // We use address 0x100 (256) for all readbacks; it is beyond the imem window
  // (imem is word-indexed so PC goes 0, 4, 8... but dmem is separate).
  // ==========================================================================

  // Load a small program into imem starting at word index `start_word`,
  // padded with NOPs up to `total_slots` slots.
  // Caller provides the program as a fixed-size array via separate assignments.
  // (Programs are loaded directly by the test bodies below.)

  // Readback: store rx to dmem[0x100] via SW rx, 0x100(x0), drain 4 cycles,
  // return dmem word at byte address 0x100.
  // NOTE: All read-back stores are appended to the program by the test itself.
  function automatic [31:0] dmem_word(input [9:0] byte_addr);
    dmem_word = {dmem[byte_addr+3], dmem[byte_addr+2],
                 dmem[byte_addr+1], dmem[byte_addr]};
  endfunction

  // ==========================================================================
  // TEST SUITE
  // ==========================================================================
  initial begin
    pass_count = 0;
    fail_count = 0;

    // ========================================================================
    // TEST 1: NOP STREAM
    // Spec: NOP = ADDI x0, x0, 0 = 32'h00000013 (canonical-reference.md §7.3)
    // Expected: no register writes (x0 is always 0), no memory activity,
    //           no halt, PC advances by 4 each cycle.
    // ========================================================================
    $display("\n--- TEST 1: NOP stream ---");
    do_reset();
    // imem is already all NOPs from do_reset
    // Run 10 cycles, checking no halt and no dmem write
    run_cycles(5);
    check1("NOP: halt_o stays 0", halt_o, 1'b0);
    check32("NOP: no dmem write (data_we_o==0)", {28'h0, data_we_o}, 32'h0);
    // PC should be 5*4=20 = 0x14 after 5 posedges post-reset (reset clears PC
    // to 0; each cycle advances by 4). We observe instr_addr_o = current PC.
    // After do_reset we have clocked 2 extra cycles inside do_reset; let's just
    // verify PC is word-aligned and not X/Z.
    if (instr_addr_o[1:0] !== 2'b00)
      $display("FAIL  NOP: PC not word-aligned: 0x%08X", instr_addr_o);
    else begin
      $display("PASS  NOP: PC word-aligned: 0x%08X", instr_addr_o);
      pass_count++;
    end
    run_cycles(3);
    check1("NOP: halt_o still 0 after 8 cycles", halt_o, 1'b0);

    // ========================================================================
    // TEST 2: SINGLE R-TYPE — ADD x1, x0, x0
    // Spec (canonical-reference.md §1.1):
    //   ADD: funct7=0000000, funct3=000, opcode=0110011
    //   rd = rs1 + rs2 = x0 + x0 = 0
    //   x1 should be 0x00000000
    // Encoding: {7'b0000000, 5'd0, 5'd0, 3'b000, 5'd1, 7'b0110011}
    //         = 32'h00000033
    // Pipeline latency: fetched cycle 0, written back end of cycle 2.
    // We read back by storing x1 to dmem[0x100] after 4 NOPs.
    // ========================================================================
    $display("\n--- TEST 2: Single R-type ADD x1,x0,x0 ---");
    do_reset();
    imem[0] = enc_r(7'b0000000, 5'd0, 5'd0, 3'b000, 5'd1, OP_R); // ADD x1,x0,x0
    // SW x1, 0x100(x0): S-type, funct3=010, rs1=x0, rs2=x1, imm=0x100
    // imm=0x100=256: imm[11:5]=0000010, imm[4:0]=00000
    imem[1] = NOP;
    imem[2] = NOP;
    imem[3] = enc_s(12'h100, 5'd1, 5'd0, 3'b010, OP_STOR); // SW x1,0x100(x0)
    // 4 drain NOPs
    imem[4] = NOP; imem[5] = NOP; imem[6] = NOP; imem[7] = NOP;
    run_cycles(10);
    // Spec: ADD x0+x0 = 0 -> x1=0
    check32("ADD x1,x0,x0 -> x1=0x00000000",
            dmem_word(10'h100), 32'h00000000);

    // ========================================================================
    // TEST 3: ALU INSTRUCTIONS
    // All encodings derived from canonical-reference.md §1.1 (R-type) and
    // §1.2 (I-type). Expected values derived from the specified operation.
    //
    // Strategy: load immediate values with ADDI, then test R/I ops,
    // store results to dmem at incrementing 4-byte addresses starting 0x200.
    // ========================================================================
    $display("\n--- TEST 3: ALU instructions ---");
    do_reset();

    // --- 3a: ADDI x1, x0, 15 -> x1 = 15 = 0x0000000F
    // Spec §1.2: rd = rs1 + sext(imm) = 0 + 15 = 15
    // Encoding: I-type {12'd15, 5'd0, 3'b000, 5'd1, 7'b0010011}
    imem[0] = enc_i(12'd15, 5'd0, 3'b000, 5'd1, OP_IALU);  // ADDI x1,x0,15
    imem[1] = enc_s(12'h200, 5'd1, 5'd0, 3'b010, OP_STOR); // SW x1,0x200(x0)
    imem[2] = NOP; imem[3] = NOP; imem[4] = NOP; imem[5] = NOP;
    run_cycles(8);
    check32("ADDI x1,x0,15 -> x1=0x0000000F",
            dmem_word(10'h200), 32'h0000000F);

    // --- 3b: ADD x3, x1, x2 (x1=5, x2=3 -> x3=8)
    // Spec §1.1: rd = rs1 + rs2 = 5 + 3 = 8
    do_reset();
    imem[0] = enc_i(12'd5,  5'd0, 3'b000, 5'd1, OP_IALU); // ADDI x1,x0,5
    imem[1] = enc_i(12'd3,  5'd0, 3'b000, 5'd2, OP_IALU); // ADDI x2,x0,3
    imem[2] = NOP;
    imem[3] = enc_r(7'b0000000, 5'd2, 5'd1, 3'b000, 5'd3, OP_R); // ADD x3,x1,x2
    imem[4] = NOP; imem[5] = NOP;
    imem[6] = enc_s(12'h200, 5'd3, 5'd0, 3'b010, OP_STOR); // SW x3,0x200(x0)
    imem[7] = NOP; imem[8] = NOP; imem[9] = NOP; imem[10] = NOP;
    run_cycles(13);
    check32("ADD x3,x1,x2 (5+3) -> x3=0x00000008",
            dmem_word(10'h200), 32'h00000008);

    // --- 3c: SUB x3, x1, x2 (x1=10, x2=3 -> x3=7)
    // Spec §1.1: SUB funct7=0100000, funct3=000, rd = rs1 - rs2 = 10-3 = 7
    do_reset();
    imem[0] = enc_i(12'd10, 5'd0, 3'b000, 5'd1, OP_IALU); // ADDI x1,x0,10
    imem[1] = enc_i(12'd3,  5'd0, 3'b000, 5'd2, OP_IALU); // ADDI x2,x0,3
    imem[2] = NOP;
    imem[3] = enc_r(7'b0100000, 5'd2, 5'd1, 3'b000, 5'd3, OP_R); // SUB x3,x1,x2
    imem[4] = NOP; imem[5] = NOP;
    imem[6] = enc_s(12'h200, 5'd3, 5'd0, 3'b010, OP_STOR);
    imem[7] = NOP; imem[8] = NOP; imem[9] = NOP; imem[10] = NOP;
    run_cycles(13);
    check32("SUB x3,x1,x2 (10-3) -> x3=0x00000007",
            dmem_word(10'h200), 32'h00000007);

    // --- 3d: AND x3, x1, x2 (x1=0xFF, x2=0x0F -> x3=0x0F)
    // Spec §1.1: AND funct7=0000000, funct3=111, rd = rs1 & rs2
    // 0xFF & 0x0F = 0x0F
    do_reset();
    imem[0] = enc_i(12'hFF,  5'd0, 3'b000, 5'd1, OP_IALU); // ADDI x1,x0,255
    imem[1] = enc_i(12'h00F, 5'd0, 3'b000, 5'd2, OP_IALU); // ADDI x2,x0,15
    imem[2] = NOP;
    imem[3] = enc_r(7'b0000000, 5'd2, 5'd1, 3'b111, 5'd3, OP_R); // AND x3,x1,x2
    imem[4] = NOP; imem[5] = NOP;
    imem[6] = enc_s(12'h200, 5'd3, 5'd0, 3'b010, OP_STOR);
    imem[7] = NOP; imem[8] = NOP; imem[9] = NOP; imem[10] = NOP;
    run_cycles(13);
    check32("AND x3,x1,x2 (0xFF & 0x0F) -> x3=0x0000000F",
            dmem_word(10'h200), 32'h0000000F);

    // --- 3e: OR x3, x1, x2 (x1=0xF0, x2=0x0F -> x3=0xFF)
    // Spec §1.1: OR funct7=0000000, funct3=110, rd = rs1 | rs2
    // 0xF0 | 0x0F = 0xFF
    do_reset();
    imem[0] = enc_i(12'hF0,  5'd0, 3'b000, 5'd1, OP_IALU); // ADDI x1,x0,0xF0
    imem[1] = enc_i(12'h00F, 5'd0, 3'b000, 5'd2, OP_IALU); // ADDI x2,x0,0x0F
    imem[2] = NOP;
    imem[3] = enc_r(7'b0000000, 5'd2, 5'd1, 3'b110, 5'd3, OP_R); // OR x3,x1,x2
    imem[4] = NOP; imem[5] = NOP;
    imem[6] = enc_s(12'h200, 5'd3, 5'd0, 3'b010, OP_STOR);
    imem[7] = NOP; imem[8] = NOP; imem[9] = NOP; imem[10] = NOP;
    run_cycles(13);
    check32("OR x3,x1,x2 (0xF0|0x0F) -> x3=0x000000FF",
            dmem_word(10'h200), 32'h000000FF);

    // --- 3f: XOR x3, x1, x2 (x1=0xFF, x2=0x0F -> x3=0xF0)
    // Spec §1.1: XOR funct7=0000000, funct3=100, rd = rs1 ^ rs2
    // 0xFF ^ 0x0F = 0xF0
    do_reset();
    imem[0] = enc_i(12'hFF,  5'd0, 3'b000, 5'd1, OP_IALU); // ADDI x1,x0,255
    imem[1] = enc_i(12'h00F, 5'd0, 3'b000, 5'd2, OP_IALU); // ADDI x2,x0,15
    imem[2] = NOP;
    imem[3] = enc_r(7'b0000000, 5'd2, 5'd1, 3'b100, 5'd3, OP_R); // XOR x3,x1,x2
    imem[4] = NOP; imem[5] = NOP;
    imem[6] = enc_s(12'h200, 5'd3, 5'd0, 3'b010, OP_STOR);
    imem[7] = NOP; imem[8] = NOP; imem[9] = NOP; imem[10] = NOP;
    run_cycles(13);
    check32("XOR x3,x1,x2 (0xFF^0x0F) -> x3=0x000000F0",
            dmem_word(10'h200), 32'h000000F0);

    // --- 3g: SLT x3, x1, x2 (x1=-1 signed, x2=1 -> x3=1; -1 <s 1)
    // Spec §1.1: SLT funct7=0000000, funct3=010, rd=(rs1 <s rs2)?1:0
    // ADDI x1,x0,-1: imm=-1=0xFFF (12-bit two's complement)
    // -1 <s 1 -> x3=1
    do_reset();
    imem[0] = enc_i(12'hFFF, 5'd0, 3'b000, 5'd1, OP_IALU); // ADDI x1,x0,-1
    imem[1] = enc_i(12'd1,   5'd0, 3'b000, 5'd2, OP_IALU); // ADDI x2,x0,1
    imem[2] = NOP;
    imem[3] = enc_r(7'b0000000, 5'd2, 5'd1, 3'b010, 5'd3, OP_R); // SLT x3,x1,x2
    imem[4] = NOP; imem[5] = NOP;
    imem[6] = enc_s(12'h200, 5'd3, 5'd0, 3'b010, OP_STOR);
    imem[7] = NOP; imem[8] = NOP; imem[9] = NOP; imem[10] = NOP;
    run_cycles(13);
    check32("SLT x3,x1,x2 (-1 <s 1) -> x3=0x00000001",
            dmem_word(10'h200), 32'h00000001);

    // --- 3h: SLTU x3, x1, x2 (x1=0xFFFFFFFF unsigned, x2=1 -> x3=0;
    //         0xFFFFFFFF >u 1)
    // Spec §1.1: SLTU funct7=0000000, funct3=011, rd=(rs1 <u rs2)?1:0
    // x1 = sext(-1) = 0xFFFFFFFF; 0xFFFFFFFF >u 1 -> x3=0
    do_reset();
    imem[0] = enc_i(12'hFFF, 5'd0, 3'b000, 5'd1, OP_IALU); // ADDI x1,x0,-1 -> 0xFFFFFFFF
    imem[1] = enc_i(12'd1,   5'd0, 3'b000, 5'd2, OP_IALU); // ADDI x2,x0,1
    imem[2] = NOP;
    imem[3] = enc_r(7'b0000000, 5'd2, 5'd1, 3'b011, 5'd3, OP_R); // SLTU x3,x1,x2
    imem[4] = NOP; imem[5] = NOP;
    imem[6] = enc_s(12'h200, 5'd3, 5'd0, 3'b010, OP_STOR);
    imem[7] = NOP; imem[8] = NOP; imem[9] = NOP; imem[10] = NOP;
    run_cycles(13);
    check32("SLTU x3,x1,x2 (0xFFFFFFFF <u 1 = 0) -> x3=0x00000000",
            dmem_word(10'h200), 32'h00000000);

    // --- 3i: SLL x3, x1, x2 (x1=1, x2=4 -> x3=16=0x10)
    // Spec §1.1: SLL funct7=0000000, funct3=001, rd = rs1 << rs2[4:0]
    // 1 << 4 = 16
    do_reset();
    imem[0] = enc_i(12'd1, 5'd0, 3'b000, 5'd1, OP_IALU); // ADDI x1,x0,1
    imem[1] = enc_i(12'd4, 5'd0, 3'b000, 5'd2, OP_IALU); // ADDI x2,x0,4
    imem[2] = NOP;
    imem[3] = enc_r(7'b0000000, 5'd2, 5'd1, 3'b001, 5'd3, OP_R); // SLL x3,x1,x2
    imem[4] = NOP; imem[5] = NOP;
    imem[6] = enc_s(12'h200, 5'd3, 5'd0, 3'b010, OP_STOR);
    imem[7] = NOP; imem[8] = NOP; imem[9] = NOP; imem[10] = NOP;
    run_cycles(13);
    check32("SLL x3,x1,x2 (1<<4) -> x3=0x00000010",
            dmem_word(10'h200), 32'h00000010);

    // --- 3j: SRL x3, x1, x2 (x1=0x80, x2=3 -> x3=0x10)
    // Spec §1.1: SRL funct7=0000000, funct3=101, rd = rs1 >> rs2[4:0] (zero-fill)
    // 0x80 >> 3 = 0x10
    do_reset();
    imem[0] = enc_i(12'h080, 5'd0, 3'b000, 5'd1, OP_IALU); // ADDI x1,x0,0x80=128
    imem[1] = enc_i(12'd3,   5'd0, 3'b000, 5'd2, OP_IALU); // ADDI x2,x0,3
    imem[2] = NOP;
    imem[3] = enc_r(7'b0000000, 5'd2, 5'd1, 3'b101, 5'd3, OP_R); // SRL x3,x1,x2
    imem[4] = NOP; imem[5] = NOP;
    imem[6] = enc_s(12'h200, 5'd3, 5'd0, 3'b010, OP_STOR);
    imem[7] = NOP; imem[8] = NOP; imem[9] = NOP; imem[10] = NOP;
    run_cycles(13);
    check32("SRL x3,x1,x2 (0x80>>3 logical) -> x3=0x00000010",
            dmem_word(10'h200), 32'h00000010);

    // --- 3k: SRA x3, x1, x2 (x1=0xFFFFFF80=-128, x2=3 -> x3=0xFFFFFFF0=-16)
    // Spec §1.1: SRA funct7=0100000, funct3=101, rd=rs1>>>rs2[4:0] (sign-extend)
    // 0xFFFFFF80 >>> 3 = 0xFFFFFFF0  (arithmetic right shift preserves sign)
    do_reset();
    // ADDI x1,x0,-128: imm = -128 = 0xF80 (12-bit two's complement)
    imem[0] = enc_i(12'hF80, 5'd0, 3'b000, 5'd1, OP_IALU); // ADDI x1,x0,-128
    imem[1] = enc_i(12'd3,   5'd0, 3'b000, 5'd2, OP_IALU); // ADDI x2,x0,3
    imem[2] = NOP;
    imem[3] = enc_r(7'b0100000, 5'd2, 5'd1, 3'b101, 5'd3, OP_R); // SRA x3,x1,x2
    imem[4] = NOP; imem[5] = NOP;
    imem[6] = enc_s(12'h200, 5'd3, 5'd0, 3'b010, OP_STOR);
    imem[7] = NOP; imem[8] = NOP; imem[9] = NOP; imem[10] = NOP;
    run_cycles(13);
    check32("SRA x3,x1,x2 (0xFFFFFF80>>>3) -> x3=0xFFFFFFF0",
            dmem_word(10'h200), 32'hFFFFFFF0);

    // ========================================================================
    // TEST 4: LUI and AUIPC
    // Spec canonical-reference.md §1.7 and §11 verification anchors.
    //
    // 4a: LUI x1, 0x12345
    //   rd = imm[31:12] << 12 = 0x12345000
    //   Encoding: U-type {20'h12345, 5'd1, 7'b0110111}
    //
    // 4b: AUIPC x2, 0x00001
    //   rd = PC + (imm[31:12] << 12) = PC + 0x1000
    //   Spec §1.7 note: uses THIS instruction's PC (not PC+4).
    //   AUIPC is at word index 0 => PC=0x0000_0000
    //   rd = 0x0000_0000 + 0x0000_1000 = 0x0000_1000
    // ========================================================================
    $display("\n--- TEST 4: LUI and AUIPC ---");

    // 4a: LUI x1, 0x12345
    do_reset();
    imem[0] = enc_u(20'h12345, 5'd1, OP_LUI);               // LUI x1,0x12345
    imem[1] = NOP; imem[2] = NOP;
    imem[3] = enc_s(12'h200, 5'd1, 5'd0, 3'b010, OP_STOR);  // SW x1,0x200(x0)
    imem[4] = NOP; imem[5] = NOP; imem[6] = NOP; imem[7] = NOP;
    run_cycles(10);
    // Spec §1.7: LUI rd = imm[31:12] << 12; imm_upper=0x12345 -> rd=0x12345000
    check32("LUI x1,0x12345 -> x1=0x12345000",
            dmem_word(10'h200), 32'h12345000);

    // 4b: AUIPC x2, 0x00001 at PC=0x0 -> x2=0x00001000
    // Spec §1.7 + §11: AUIPC rd = PC + (imm << 12)
    // PC of AUIPC instruction = 0x0 (first instruction after reset)
    // rd = 0x0 + 0x1000 = 0x1000
    do_reset();
    imem[0] = enc_u(20'h00001, 5'd2, OP_AUIPC);              // AUIPC x2,0x1
    imem[1] = NOP; imem[2] = NOP;
    imem[3] = enc_s(12'h200, 5'd2, 5'd0, 3'b010, OP_STOR);  // SW x2,0x200(x0)
    imem[4] = NOP; imem[5] = NOP; imem[6] = NOP; imem[7] = NOP;
    run_cycles(10);
    // Spec: PC=0x0, imm<<12=0x1000 -> rd=0x1000
    check32("AUIPC x2,0x1 at PC=0 -> x2=0x00001000",
            dmem_word(10'h200), 32'h00001000);

    // 4c: AUIPC x2, 0x12345 at PC=0x4 (second instruction)
    // PC of AUIPC at word index 1 = 4
    // rd = 0x4 + 0x12345000 = 0x12345004
    do_reset();
    imem[0] = NOP;                                            // at PC=0
    imem[1] = enc_u(20'h12345, 5'd2, OP_AUIPC);             // AUIPC at PC=4
    imem[2] = NOP; imem[3] = NOP;
    imem[4] = enc_s(12'h200, 5'd2, 5'd0, 3'b010, OP_STOR);
    imem[5] = NOP; imem[6] = NOP; imem[7] = NOP; imem[8] = NOP;
    run_cycles(11);
    check32("AUIPC x2,0x12345 at PC=4 -> x2=0x12345004",
            dmem_word(10'h200), 32'h12345004);

    // ========================================================================
    // TEST 5: LOAD/STORE
    // Spec §1.3, §1.4.
    //
    // 5a: SW then LW — store 0xDEADBEEF to dmem[0x300], load back to x5
    //     SW: funct3=010, data_we=4'b1111 (full word)
    //     LW: funct3=010, rd = mem[rs1+imm][31:0]
    //
    // 5b: SB then LB — sign extension
    //     Store 0xFF as byte to dmem[0x304], load back with LB -> -1 (0xFFFFFFFF)
    //
    // 5c: SH then LH — store 0x8000 (halfword), load with LH -> sign extended 0xFFFF8000
    //
    // 5d: LBU — store 0xFF byte, load with LBU -> zero-extended 0x000000FF
    //
    // 5e: LHU — store 0x8000 halfword, load with LHU -> zero-extended 0x00008000
    // ========================================================================
    $display("\n--- TEST 5: Load/Store ---");

    // 5a: SW x1, 0x300(x0) then LW x5, 0x300(x0)
    // ADDI x1,x0,-1 sets x1=0xFFFFFFFF as a known non-zero pattern.
    // imm for 0x300: 12'h300=768
    do_reset();
    // Load x1 = 0x12345678 using LUI + ADDI
    // LUI x1, 0x12345 -> x1=0x12345000; ADDI x1,x1,0x678 -> x1=0x12345678
    // Note: 0x678 is positive, no sign issue.
    imem[0] = enc_u(20'h12345, 5'd1, OP_LUI);               // LUI x1,0x12345
    imem[1] = enc_i(12'h678, 5'd1, 3'b000, 5'd1, OP_IALU); // ADDI x1,x1,0x678
    imem[2] = NOP;
    imem[3] = enc_s(12'h300, 5'd1, 5'd0, 3'b010, OP_STOR); // SW x1,0x300(x0)
    imem[4] = NOP; imem[5] = NOP;
    // LW x5, 0x300(x0): I-type funct3=010 opcode=LOAD
    imem[6] = enc_i(12'h300, 5'd0, 3'b010, 5'd5, OP_LOAD); // LW x5,0x300(x0)
    imem[7] = NOP; imem[8] = NOP;
    imem[9] = enc_s(12'h200, 5'd5, 5'd0, 3'b010, OP_STOR); // SW x5,0x200(x0)
    imem[10] = NOP; imem[11] = NOP; imem[12] = NOP; imem[13] = NOP;
    run_cycles(16);
    check32("SW/LW roundtrip -> x5=0x12345678",
            dmem_word(10'h200), 32'h12345678);

    // 5b: SB then LB sign extension
    // Store byte 0xFF to dmem[0x304]; LB loads sign-extended -> 0xFFFFFFFF
    // SB: funct3=000, data_we = 4'b0001 << addr[1:0] = 4'b0001 (addr[1:0]=00)
    do_reset();
    imem[0] = enc_i(12'hFFF, 5'd0, 3'b000, 5'd1, OP_IALU); // ADDI x1,x0,-1 (=0xFF in byte)
    imem[1] = NOP;
    // SB x1, 0x304(x0): imm=0x304, rs1=x0, rs2=x1, funct3=000
    imem[2] = enc_s(12'h304, 5'd1, 5'd0, 3'b000, OP_STOR); // SB x1,0x304(x0)
    imem[3] = NOP; imem[4] = NOP;
    // LB x5, 0x304(x0): funct3=000
    imem[5] = enc_i(12'h304, 5'd0, 3'b000, 5'd5, OP_LOAD); // LB x5,0x304(x0)
    imem[6] = NOP; imem[7] = NOP;
    imem[8] = enc_s(12'h200, 5'd5, 5'd0, 3'b010, OP_STOR);
    imem[9] = NOP; imem[10] = NOP; imem[11] = NOP; imem[12] = NOP;
    run_cycles(15);
    // Spec §1.3: LB rd = sext(mem[addr][7:0]); 0xFF sign-extended = 0xFFFFFFFF
    check32("SB/LB 0xFF sign-extend -> x5=0xFFFFFFFF",
            dmem_word(10'h200), 32'hFFFFFFFF);

    // 5c: SH then LH sign extension
    // Store 0x8000 halfword to dmem[0x308]; LH sign-extends -> 0xFFFF8000
    // SH: funct3=001, addr[1:0]=00 -> data_we = 4'b0011
    do_reset();
    // ADDI x1,x0,-32768 is not representable as 12-bit imm directly.
    // Use LUI x1,0xFFFF8 then ADDI x1,x1,0 -> 0xFFFF8000
    // Better: LUI x1,0x80000 is not valid 20-bit. Use ORI approach:
    // LUI x1, 1 -> x1=0x00001000; SLLI x1,x1,3 -> x1=0x00008000
    // But we want 0x8000 in the halfword. Let's use ADDI with the I-type
    // negative value to set upper bits via sign extension:
    // We can't get 0x8000 directly from ADDI (12-bit signed range is -2048..2047).
    // Use LUI: LUI x1, 0x00001 -> x1=0x1000; not 0x8000.
    // Best approach: LUI x1, 0x80000 is invalid (20-bit max 0xFFFFF).
    // Use: ADDI x1,x0,-1 sets all bits; then SLLI x1,x1,15 -> 0xFFFF8000
    // But we want to store only the low halfword. Actually let's store using:
    // ORI x1,x0,0x800 -> x1=sext(0x800)=0xFFFFF800 — wrong.
    // Simplest: use literal 0x8000 cannot come from 12-bit imm.
    // Use LUI x1,0x00001 (x1=0x1000) then SLLI x1,x1,3 (x1=0x8000).
    // SLLI shamt=3: I-type {0000000,00011, rs1=1, 001, rd=1, 0010011}
    imem[0] = enc_u(20'h00001, 5'd1, OP_LUI);               // LUI x1,1 -> 0x1000
    // SLLI x1,x1,3: imm[11:5]=0000000, shamt=3, funct3=001
    imem[1] = enc_i({7'b0000000, 5'd3}, 5'd1, 3'b001, 5'd1, OP_IALU); // SLLI x1,x1,3
    imem[2] = NOP;
    // SH x1,0x308(x0): funct3=001
    imem[3] = enc_s(12'h308, 5'd1, 5'd0, 3'b001, OP_STOR); // SH x1,0x308(x0)
    imem[4] = NOP; imem[5] = NOP;
    // LH x5,0x308(x0): funct3=001
    imem[6] = enc_i(12'h308, 5'd0, 3'b001, 5'd5, OP_LOAD); // LH x5,0x308(x0)
    imem[7] = NOP; imem[8] = NOP;
    imem[9] = enc_s(12'h200, 5'd5, 5'd0, 3'b010, OP_STOR);
    imem[10] = NOP; imem[11] = NOP; imem[12] = NOP; imem[13] = NOP;
    run_cycles(16);
    // Spec §1.3: LH rd = sext(mem[addr][15:0]); 0x8000 sext = 0xFFFF8000
    check32("SH/LH 0x8000 sign-extend -> x5=0xFFFF8000",
            dmem_word(10'h200), 32'hFFFF8000);

    // 5d: LBU zero extension
    // Store 0xFF to dmem[0x30C], load with LBU -> 0x000000FF
    do_reset();
    imem[0] = enc_i(12'hFFF, 5'd0, 3'b000, 5'd1, OP_IALU); // ADDI x1,x0,-1
    imem[1] = NOP;
    imem[2] = enc_s(12'h30C, 5'd1, 5'd0, 3'b000, OP_STOR); // SB x1,0x30C(x0)
    imem[3] = NOP; imem[4] = NOP;
    // LBU x5,0x30C(x0): funct3=100
    imem[5] = enc_i(12'h30C, 5'd0, 3'b100, 5'd5, OP_LOAD); // LBU x5,0x30C(x0)
    imem[6] = NOP; imem[7] = NOP;
    imem[8] = enc_s(12'h200, 5'd5, 5'd0, 3'b010, OP_STOR);
    imem[9] = NOP; imem[10] = NOP; imem[11] = NOP; imem[12] = NOP;
    run_cycles(15);
    // Spec §1.3: LBU rd = zext(mem[addr][7:0]); 0xFF -> 0x000000FF
    check32("SB/LBU 0xFF zero-extend -> x5=0x000000FF",
            dmem_word(10'h200), 32'h000000FF);

    // 5e: LHU zero extension
    // Store 0x8000 halfword, load with LHU -> 0x00008000
    do_reset();
    imem[0] = enc_u(20'h00001, 5'd1, OP_LUI);               // LUI x1,1 -> 0x1000
    imem[1] = enc_i({7'b0000000, 5'd3}, 5'd1, 3'b001, 5'd1, OP_IALU); // SLLI x1,x1,3 -> 0x8000
    imem[2] = NOP;
    imem[3] = enc_s(12'h310, 5'd1, 5'd0, 3'b001, OP_STOR); // SH x1,0x310(x0)
    imem[4] = NOP; imem[5] = NOP;
    // LHU x5,0x310(x0): funct3=101
    imem[6] = enc_i(12'h310, 5'd0, 3'b101, 5'd5, OP_LOAD); // LHU x5,0x310(x0)
    imem[7] = NOP; imem[8] = NOP;
    imem[9] = enc_s(12'h200, 5'd5, 5'd0, 3'b010, OP_STOR);
    imem[10] = NOP; imem[11] = NOP; imem[12] = NOP; imem[13] = NOP;
    run_cycles(16);
    // Spec §1.3: LHU rd = zext(mem[addr][15:0]); 0x8000 -> 0x00008000
    check32("SH/LHU 0x8000 zero-extend -> x5=0x00008000",
            dmem_word(10'h200), 32'h00008000);

    // ========================================================================
    // TEST 6: BRANCHES — taken and not-taken
    // Spec §1.5: branch target = PC + sext(B-imm); 1-cycle bubble on taken.
    // Spec §7.3: flush IF/EX on taken branch or jump.
    //
    // 6a: BEQ not-taken (x1 != x2)
    //   x1=5, x2=3; BEQ x1,x2,+8 -> branch NOT taken -> fall-through
    //   Instruction at fall-through executes normally.
    //
    // 6b: BEQ taken (x1 == x2)
    //   x1=7, x2=7; BEQ x1,x2,+8 -> branch taken, PC jumps to PC+8
    //   The instruction in the slot after BEQ is flushed (bubble).
    //   Instruction at branch target executes.
    // ========================================================================
    $display("\n--- TEST 6: Branches taken/not-taken ---");

    // 6a: BEQ not-taken
    // Program layout (word indices):
    //   0: ADDI x1,x0,5
    //   1: ADDI x2,x0,3
    //   2: NOP  (drain so x1/x2 are in regfile before BEQ reaches EX)
    //   3: BEQ x1,x2,+12  (B-imm=12 means PC+12; PC=12=0xC -> target=0x18=word 6)
    //   4: ADDI x3,x0,1   (fall-through; should execute when not-taken)
    //   5: NOP
    //   6: ADDI x3,x0,99  (branch target; should NOT execute when not-taken)
    //   7: NOP
    //   8: SW x3,0x200(x0)
    //   9..12: NOP drain
    //
    // Not-taken: x3 = 1 (fall-through executes)
    // B-imm=12: offset from BEQ's PC (=12) to target (=24): 24-12=12
    // B-type imm encoding: imm[12:1] = {0,0,0,0,0,0,1,1,0,0,0,0}
    //                      offset=12=0b0000_0000_1100
    //                      imm[12]=0, imm[11]=0, imm[10:5]=000001, imm[4:1]=1000
    // Wait -- let me re-derive. B-imm is the signed offset in bytes.
    // For offset=12 (decimal): binary 0000_0000_1100
    //   bit positions in the offset: [12]=0 [11]=0 [10:5]=000001 [4:1]=1000 [0]=0
    //   Hmm: 12 = 0b00000001100
    //   imm[12]=0, imm[11]=0, imm[10:5]=0b000011, imm[4:1]=0b0000
    //   Wait: 12 in binary = 0b00001100
    //   bit 12=0, bit 11=0, bit 10=0, bits[9:5]=00000, bits[4:1]=0110, bit 0=0
    //   Actually: 12 = 8+4 = bit3 + bit2
    //   imm[4:1] = 4'b0110, imm[10:5]=6'b000000, imm[11]=0, imm[12]=0
    do_reset();
    imem[0] = enc_i(12'd5, 5'd0, 3'b000, 5'd1, OP_IALU);    // ADDI x1,x0,5
    imem[1] = enc_i(12'd3, 5'd0, 3'b000, 5'd2, OP_IALU);    // ADDI x2,x0,3
    imem[2] = NOP;
    // BEQ x1,x2 offset=+20: target = PC(12)+20 = 32 = word8 (NOP, never reached)
    imem[3] = enc_b(13'd20, 5'd2, 5'd1, 3'b000, OP_BRNC);   // BEQ x1,x2,+20
    imem[4] = enc_i(12'd1,  5'd0, 3'b000, 5'd3, OP_IALU);   // ADDI x3,x0,1 (fall-thru)
    imem[5] = NOP;
    imem[6] = enc_s(12'h200, 5'd3, 5'd0, 3'b010, OP_STOR);  // SW x3 before target
    imem[7] = NOP; imem[8] = NOP; imem[9] = NOP; imem[10] = NOP;
    run_cycles(15);
    // Not-taken: x3 should be 1 (from fall-through at imem[4])
    check32("BEQ not-taken (5!=3): fall-through x3=1",
            dmem_word(10'h200), 32'h00000001);

    // 6b: BEQ taken
    // Layout:
    //   0: ADDI x1,x0,7
    //   1: ADDI x2,x0,7
    //   2: NOP
    //   3: BEQ x1,x2,+12   (PC=12, target=24=word6; taken)
    //   4: ADDI x3,x0,55   (this gets flushed by taken branch; x3 must NOT be 55)
    //   5: NOP
    //   6: ADDI x3,x0,42   (branch target; should execute)
    //   7: NOP
    //   8: SW x3,0x200(x0)
    //   9..12: NOP drain
    do_reset();
    imem[0] = enc_i(12'd7, 5'd0, 3'b000, 5'd1, OP_IALU);    // ADDI x1,x0,7
    imem[1] = enc_i(12'd7, 5'd0, 3'b000, 5'd2, OP_IALU);    // ADDI x2,x0,7
    imem[2] = NOP;
    imem[3] = enc_b(13'd12, 5'd2, 5'd1, 3'b000, OP_BRNC);   // BEQ x1,x2,+12 (taken)
    imem[4] = enc_i(12'd55, 5'd0, 3'b000, 5'd3, OP_IALU);   // ADDI x3,x0,55 (FLUSHED)
    imem[5] = NOP;
    imem[6] = enc_i(12'd42, 5'd0, 3'b000, 5'd3, OP_IALU);   // ADDI x3,x0,42 (target)
    imem[7] = NOP; imem[8] = NOP;
    imem[9] = enc_s(12'h200, 5'd3, 5'd0, 3'b010, OP_STOR);
    imem[10] = NOP; imem[11] = NOP; imem[12] = NOP; imem[13] = NOP;
    run_cycles(16);
    // Taken: x3=42 (branch target executed, slot after branch was flushed)
    check32("BEQ taken (7==7): target executes x3=42",
            dmem_word(10'h200), 32'h0000002A);

    // 6c: BNE taken (x1 != x2)
    // x1=5, x2=3; BNE x1,x2,+12 -> taken
    // Spec §1.5: BNE funct3=001, condition: rs1 != rs2
    do_reset();
    imem[0] = enc_i(12'd5, 5'd0, 3'b000, 5'd1, OP_IALU);
    imem[1] = enc_i(12'd3, 5'd0, 3'b000, 5'd2, OP_IALU);
    imem[2] = NOP;
    imem[3] = enc_b(13'd12, 5'd2, 5'd1, 3'b001, OP_BRNC);   // BNE x1,x2,+12
    imem[4] = enc_i(12'd11, 5'd0, 3'b000, 5'd3, OP_IALU);   // ADDI x3,x0,11 (FLUSHED)
    imem[5] = NOP;
    imem[6] = enc_i(12'd77, 5'd0, 3'b000, 5'd3, OP_IALU);   // ADDI x3,x0,77 (target)
    imem[7] = NOP; imem[8] = NOP;
    imem[9] = enc_s(12'h200, 5'd3, 5'd0, 3'b010, OP_STOR);
    imem[10] = NOP; imem[11] = NOP; imem[12] = NOP; imem[13] = NOP;
    run_cycles(16);
    check32("BNE taken (5!=3): target x3=77",
            dmem_word(10'h200), 32'h0000004D);

    // 6d: BLT taken (signed: x1=-1 < x2=1)
    // Spec §1.5: BLT funct3=100, signed comparison
    do_reset();
    imem[0] = enc_i(12'hFFF, 5'd0, 3'b000, 5'd1, OP_IALU); // ADDI x1,x0,-1
    imem[1] = enc_i(12'd1,   5'd0, 3'b000, 5'd2, OP_IALU); // ADDI x2,x0,1
    imem[2] = NOP;
    imem[3] = enc_b(13'd12, 5'd2, 5'd1, 3'b100, OP_BRNC);  // BLT x1,x2,+12
    imem[4] = enc_i(12'd0,  5'd0, 3'b000, 5'd3, OP_IALU);  // (FLUSHED)
    imem[5] = NOP;
    imem[6] = enc_i(12'd33, 5'd0, 3'b000, 5'd3, OP_IALU);  // ADDI x3,x0,33 (target)
    imem[7] = NOP; imem[8] = NOP;
    imem[9] = enc_s(12'h200, 5'd3, 5'd0, 3'b010, OP_STOR);
    imem[10] = NOP; imem[11] = NOP; imem[12] = NOP; imem[13] = NOP;
    run_cycles(16);
    check32("BLT taken (-1 <s 1): x3=33", dmem_word(10'h200), 32'h00000021);

    // 6e: BGE not-taken (x1=5 >= x2=10 is false)
    // Spec §1.5: BGE funct3=101, condition signed rs1 >= rs2
    // x1=5, x2=10; 5 >= 10 is false -> not taken -> fall-through
    do_reset();
    imem[0] = enc_i(12'd5,  5'd0, 3'b000, 5'd1, OP_IALU);
    imem[1] = enc_i(12'd10, 5'd0, 3'b000, 5'd2, OP_IALU);
    imem[2] = NOP;
    // BGE x1,x2 offset=+20: target = PC(12)+20 = 32 = word8 (NOP, never reached)
    imem[3] = enc_b(13'd20, 5'd2, 5'd1, 3'b101, OP_BRNC);  // BGE x1,x2,+20
    imem[4] = enc_i(12'd88, 5'd0, 3'b000, 5'd3, OP_IALU);  // fall-through
    imem[5] = NOP;
    imem[6] = enc_s(12'h200, 5'd3, 5'd0, 3'b010, OP_STOR); // SW x3 before target
    imem[7] = NOP; imem[8] = NOP; imem[9] = NOP; imem[10] = NOP;
    run_cycles(15);
    check32("BGE not-taken (5 >= 10 false): fall-through x3=88",
            dmem_word(10'h200), 32'h00000058);

    // ========================================================================
    // TEST 7: JAL
    // Spec §1.6: JAL rd=PC+4; PC+=sext(J-imm). ±1 MiB range.
    // rd gets PC+4 (link/return address).
    // 1-cycle bubble after JAL (flush IF/EX).
    //
    // Layout:
    //   Word 0 (PC=0x0): JAL x1, +12 -> x1=0x4 (PC+4); PC jumps to 0x0+12=0xC=word3
    //   Word 1 (PC=0x4): ADDI x2,x0,55  <- FLUSHED (should not execute)
    //   Word 2 (PC=0x8): NOP
    //   Word 3 (PC=0xC): ADDI x3,x0,42  <- jump target
    //   Word 4 (PC=0x10): NOP
    //   Word 5 (PC=0x14): SW x1,0x200(x0)  <- store link register
    //   Word 6 (PC=0x18): SW x3,0x204(x0)  <- store target result
    //   Word 7..11: NOP drain
    // ========================================================================
    $display("\n--- TEST 7: JAL ---");
    do_reset();
    // JAL x1,+12: J-imm=12 decimal
    // J-type encoding: {imm[20], imm[10:1], imm[11], imm[19:12], rd, opcode}
    // imm=12=0b00000001100 -> imm[20]=0 imm[19:12]=0 imm[11]=0 imm[10:1]=6(0b0000000110) imm[0]=0
    // wait: imm=12, binary: bit1=0,bit2=1,bit3=1,bits4-20=0
    // imm[10:1] = 10'b0000000110, imm[11]=0, imm[19:12]=0, imm[20]=0
    // enc_j takes 21-bit imm[20:0]: 21'd12
    imem[0] = enc_j(21'd12, 5'd1, OP_JAL);                  // JAL x1,+12
    imem[1] = enc_i(12'd55, 5'd0, 3'b000, 5'd2, OP_IALU);  // ADDI x2,x0,55 (FLUSHED)
    imem[2] = NOP;
    imem[3] = enc_i(12'd42, 5'd0, 3'b000, 5'd3, OP_IALU);  // ADDI x3,x0,42 (target)
    imem[4] = NOP; imem[5] = NOP;
    imem[6] = enc_s(12'h200, 5'd1, 5'd0, 3'b010, OP_STOR); // SW x1,0x200(x0) (link)
    imem[7] = enc_s(12'h204, 5'd3, 5'd0, 3'b010, OP_STOR); // SW x3,0x204(x0)
    imem[8] = NOP; imem[9] = NOP; imem[10] = NOP; imem[11] = NOP;
    run_cycles(14);
    // Spec: x1 = PC_JAL + 4 = 0x0 + 4 = 4
    check32("JAL x1,+12: link register x1=4 (PC+4)",
            dmem_word(10'h200), 32'h00000004);
    // Spec: x3 = 42 (jump target executed)
    check32("JAL x1,+12: target x3=42",
            dmem_word(10'h204), 32'h0000002A);

    // ========================================================================
    // TEST 8: JALR
    // Spec §1.6: JALR rd=PC+4; PC=(rs1+sext(imm))&~1 (LSB cleared).
    // Gotcha #6: JALR clears LSB of computed target.
    //
    // Layout:
    //   0: ADDI x1,x0,8    -> x1=8 (base register for JALR)
    //   1: NOP
    //   2: JALR x2,x1,4    -> x2=PC+4=12; target=(8+4)&~1=12; PC->word3
    //   3: ADDI x4,x0,11   (slot after JALR — FLUSHED)
    //   4: NOP
    //   5: ADDI x5,x0,99   (JALR target at PC=12=word3... wait)
    //
    // Actually: JALR at word2 => PC=8. x1=8, imm=4. target=(8+4)&~1=12=word3.
    // x2 = PC+4 = 8+4 = 12.
    //   0: ADDI x1,x0,8
    //   1: NOP
    //   2: JALR x2,4(x1)   PC=8, target=12, x2=12
    //   3: ADDI x4,x0,11   FLUSHED
    //   4: NOP             (this is at PC=16, not the target)
    //   ... wait, target is word3=PC12? No: word3 is byte address 12.
    //   word3 = imem[3] at PC=12 -> that's the target!
    //   But we put the flushed slot at word3... let me re-layout:
    //
    //   0: ADDI x1,x0,16   -> x1=16 (will jump to PC=20=word5)
    //   1: NOP
    //   2: JALR x2,4(x1)   -> PC=8, target=(16+4)&~1=20=word5, x2=12
    //   3: ADDI x4,x0,11   (FLUSHED — 1-cycle bubble)
    //   4: NOP
    //   5: ADDI x5,x0,88   (target, PC=20)
    //   6: NOP; 7: NOP
    //   8: SW x2,0x200(x0)
    //   9: SW x5,0x204(x0)
    //   10..13: NOP drain
    // ========================================================================
    $display("\n--- TEST 8: JALR ---");
    do_reset();
    imem[0] = enc_i(12'd16, 5'd0, 3'b000, 5'd1, OP_IALU);  // ADDI x1,x0,16
    imem[1] = NOP;
    // JALR x2, 4(x1): I-type {imm=4, rs1=x1, funct3=000, rd=x2, opcode=JALR}
    imem[2] = enc_i(12'd4, 5'd1, 3'b000, 5'd2, OP_JALR);   // JALR x2,4(x1)
    imem[3] = enc_i(12'd11, 5'd0, 3'b000, 5'd4, OP_IALU);  // ADDI x4,x0,11 (FLUSHED)
    imem[4] = NOP;
    imem[5] = enc_i(12'd88, 5'd0, 3'b000, 5'd5, OP_IALU);  // ADDI x5,x0,88 (target)
    imem[6] = NOP; imem[7] = NOP;
    imem[8] = enc_s(12'h200, 5'd2, 5'd0, 3'b010, OP_STOR); // SW x2,0x200(x0)
    imem[9] = enc_s(12'h204, 5'd5, 5'd0, 3'b010, OP_STOR); // SW x5,0x204(x0)
    imem[10] = NOP; imem[11] = NOP; imem[12] = NOP; imem[13] = NOP;
    run_cycles(16);
    // Spec: x2 = PC_JALR + 4 = 8 + 4 = 12
    check32("JALR x2,4(x1): link x2=12", dmem_word(10'h200), 32'h0000000C);
    // Spec: x5 = 88 (target executed)
    check32("JALR x2,4(x1): target x5=88", dmem_word(10'h204), 32'h00000058);

    // 8b: JALR LSB-clear test
    // x1=0x11 (odd), imm=0 -> target=(0x11+0)&~1=0x10=word4
    // Spec §1.6: LSB of target is always cleared (gotcha #6)
    do_reset();
    imem[0] = enc_i(12'd17, 5'd0, 3'b000, 5'd1, OP_IALU);  // ADDI x1,x0,17 (0x11, odd)
    imem[1] = NOP;
    // JALR x2,0(x1): target=(17+0)&~1=16=word4
    imem[2] = enc_i(12'd0, 5'd1, 3'b000, 5'd2, OP_JALR);   // JALR x2,0(x1)
    imem[3] = enc_i(12'd99, 5'd0, 3'b000, 5'd3, OP_IALU);  // FLUSHED
    imem[4] = enc_i(12'd66, 5'd0, 3'b000, 5'd5, OP_IALU);  // ADDI x5,x0,66 (target)
    imem[5] = NOP; imem[6] = NOP;
    imem[7] = enc_s(12'h200, 5'd5, 5'd0, 3'b010, OP_STOR);
    imem[8] = NOP; imem[9] = NOP; imem[10] = NOP; imem[11] = NOP;
    run_cycles(14);
    // Spec §1.6: LSB cleared -> target=16=word4, x5=66
    check32("JALR LSB clear: odd target -> x5=66", dmem_word(10'h200), 32'h00000042);

    // ========================================================================
    // TEST 9: WB-TO-EX FORWARDING
    // Spec §7.3: forward_rs1 / forward_rs2 when WB-stage is writing the same
    // register that EX-stage needs.
    //
    // Without forwarding, back-to-back instructions would see stale regfile data.
    //
    // 9a: ADDI x1,x0,5 then immediately ADDI x2,x1,3 -> x2=8
    //   Cycle 0: ADDI x1 fetched
    //   Cycle 1: ADDI x1 in EX; ADDI x2 fetched
    //   Cycle 2: ADDI x1 in WB (x1=5 being written); ADDI x2 in EX
    //            -> forwarding: WB write_data(5) forwarded to EX rs1 operand
    //   Cycle 3: ADDI x2 in WB (x2=8 written)
    //   Without forwarding: x2 would read stale x1=0 -> x2=3 (WRONG)
    // ========================================================================
    $display("\n--- TEST 9: WB-to-EX Forwarding ---");
    do_reset();
    imem[0] = enc_i(12'd5, 5'd0, 3'b000, 5'd1, OP_IALU);   // ADDI x1,x0,5
    imem[1] = enc_i(12'd3, 5'd1, 3'b000, 5'd2, OP_IALU);   // ADDI x2,x1,3 (needs x1)
    imem[2] = NOP; imem[3] = NOP;
    imem[4] = enc_s(12'h200, 5'd2, 5'd0, 3'b010, OP_STOR);
    imem[5] = NOP; imem[6] = NOP; imem[7] = NOP; imem[8] = NOP;
    run_cycles(11);
    // Spec + forwarding: x2 = x1 + 3 = 5 + 3 = 8
    // Without forwarding: x2 = 0 + 3 = 3 (wrong)
    check32("WB-to-EX fwd: ADDI x1,5 then ADDI x2,x1,3 -> x2=8",
            dmem_word(10'h200), 32'h00000008);

    // 9b: Chain forwarding — rs2 forwarding for R-type
    // ADDI x1,x0,10; ADD x2,x0,x1 (x2 = 0 + x1 = 10, needs forwarded x1)
    do_reset();
    imem[0] = enc_i(12'd10, 5'd0, 3'b000, 5'd1, OP_IALU);  // ADDI x1,x0,10
    imem[1] = enc_r(7'b0000000, 5'd1, 5'd0, 3'b000, 5'd2, OP_R); // ADD x2,x0,x1
    imem[2] = NOP; imem[3] = NOP;
    imem[4] = enc_s(12'h200, 5'd2, 5'd0, 3'b010, OP_STOR);
    imem[5] = NOP; imem[6] = NOP; imem[7] = NOP; imem[8] = NOP;
    run_cycles(11);
    // Spec: x2 = x0 + x1_forwarded = 0 + 10 = 10
    check32("WB-to-EX fwd rs2: ADD x2,x0,x1 (x1=10) -> x2=10",
            dmem_word(10'h200), 32'h0000000A);

    // 9c: x0 forwarding suppression
    // Writing to x0 must never be forwarded (canonical-reference.md §7.3)
    // ADDI x0,x0,5 (writes to x0=5, but x0 always reads 0)
    // ADDI x3,x0,7  -> x3 must be 7, not 12
    do_reset();
    imem[0] = enc_i(12'd5, 5'd0, 3'b000, 5'd0, OP_IALU);   // ADDI x0,x0,5 (x0 is always 0)
    imem[1] = enc_i(12'd7, 5'd0, 3'b000, 5'd3, OP_IALU);   // ADDI x3,x0,7
    imem[2] = NOP; imem[3] = NOP;
    imem[4] = enc_s(12'h200, 5'd3, 5'd0, 3'b010, OP_STOR);
    imem[5] = NOP; imem[6] = NOP; imem[7] = NOP; imem[8] = NOP;
    run_cycles(11);
    // x0 always 0; no forward from x0 write; x3=0+7=7
    check32("x0 fwd suppression: ADDI x0,5; ADDI x3,x0,7 -> x3=7",
            dmem_word(10'h200), 32'h00000007);

    // 9d: Store forwarding — SW immediately after instruction that writes rs2
    // Spec §7.3: forward_rs2 routes to store data path as well as ALU-B
    // ADDI x1,x0,0xAB; SW x1,0x400(x0) — x1 must be forwarded to store data
    do_reset();
    imem[0] = enc_i(12'hAB, 5'd0, 3'b000, 5'd1, OP_IALU);  // ADDI x1,x0,0xAB=171
    imem[1] = enc_s(12'h3F8, 5'd1, 5'd0, 3'b010, OP_STOR); // SW x1,0x3F8(x0)
    imem[2] = NOP; imem[3] = NOP; imem[4] = NOP; imem[5] = NOP;
    run_cycles(9);
    // x1 forwarded to SW store data; dmem[0x3F8] = 0xAB
    check32("Store forwarding: ADDI x1,0xAB; SW x1 -> dmem[0x3F8]=0xAB",
            dmem_word(10'h3F8), 32'h000000AB);

    // ========================================================================
    // TEST 10: FIBONACCI SEQUENCE
    // Compute fib(1..8) = 1,1,2,3,5,8,13,21.
    // Store final result (fib(8)=21) to dmem for verification.
    //
    // Algorithm (no branch needed for fixed iterations; use straight-line code):
    // x1=1 (fib(1)), x2=1 (fib(2))
    // x3=x1+x2=2    (fib(3))
    // x4=x2+x3=3    (fib(4))
    // x5=x3+x4=5    (fib(5))
    // x6=x4+x5=8    (fib(6))
    // x7=x5+x6=13   (fib(7))
    // x8=x6+x7=21   (fib(8))
    //
    // Each ADD depends on two prior results. With WB-to-EX forwarding, a result
    // is available to the NEXT instruction in EX. But for the instruction
    // immediately after the producing instruction, only the WB-stage result is
    // forwarded. Instructions two steps after the producer read from regfile.
    //
    // Safe sequencing: place a NOP between each dependent pair to ensure the
    // producer reaches WB before the consumer enters EX. Actually, with the
    // 1-cycle WB-to-EX forwarding, no NOP is needed for back-to-back — but the
    // ADD producing x3 reads x1 and x2 which may still be in-flight.
    //
    // To keep this test simple and unambiguous, we use NOPs between each step.
    // ========================================================================
    $display("\n--- TEST 10: Fibonacci fib(8)=21 ---");
    do_reset();
    // Straight-line, NOP-separated (no forwarding reliance for clarity)
    imem[0]  = enc_i(12'd1, 5'd0, 3'b000, 5'd1, OP_IALU); // ADDI x1,x0,1 (fib1)
    imem[1]  = enc_i(12'd1, 5'd0, 3'b000, 5'd2, OP_IALU); // ADDI x2,x0,1 (fib2)
    imem[2]  = NOP;
    imem[3]  = enc_r(7'b0000000,5'd2,5'd1,3'b000,5'd3,OP_R); // ADD x3,x1,x2 (fib3=2)
    imem[4]  = NOP;
    imem[5]  = enc_r(7'b0000000,5'd3,5'd2,3'b000,5'd4,OP_R); // ADD x4,x2,x3 (fib4=3)
    imem[6]  = NOP;
    imem[7]  = enc_r(7'b0000000,5'd4,5'd3,3'b000,5'd5,OP_R); // ADD x5,x3,x4 (fib5=5)
    imem[8]  = NOP;
    imem[9]  = enc_r(7'b0000000,5'd5,5'd4,3'b000,5'd6,OP_R); // ADD x6,x4,x5 (fib6=8)
    imem[10] = NOP;
    imem[11] = enc_r(7'b0000000,5'd6,5'd5,3'b000,5'd7,OP_R); // ADD x7,x5,x6 (fib7=13)
    imem[12] = NOP;
    imem[13] = enc_r(7'b0000000,5'd7,5'd6,3'b000,5'd8,OP_R); // ADD x8,x6,x7 (fib8=21)
    imem[14] = NOP; imem[15] = NOP;
    imem[16] = enc_s(12'h200, 5'd8, 5'd0, 3'b010, OP_STOR); // SW x8,0x200(x0)
    imem[17] = NOP; imem[18] = NOP; imem[19] = NOP; imem[20] = NOP;
    run_cycles(23);
    // Spec: fib(8) = 21 = 0x15
    check32("Fibonacci fib(8): x8=21=0x00000015",
            dmem_word(10'h200), 32'h00000015);

    // Also verify intermediate fib values via additional stores
    do_reset();
    imem[0]  = enc_i(12'd1, 5'd0, 3'b000, 5'd1, OP_IALU);
    imem[1]  = enc_i(12'd1, 5'd0, 3'b000, 5'd2, OP_IALU);
    imem[2]  = NOP;
    imem[3]  = enc_r(7'b0000000,5'd2,5'd1,3'b000,5'd3,OP_R);
    imem[4]  = NOP;
    imem[5]  = enc_r(7'b0000000,5'd3,5'd2,3'b000,5'd4,OP_R);
    imem[6]  = NOP;
    imem[7]  = enc_r(7'b0000000,5'd4,5'd3,3'b000,5'd5,OP_R);
    imem[8]  = NOP;
    imem[9]  = enc_r(7'b0000000,5'd5,5'd4,3'b000,5'd6,OP_R);
    imem[10] = NOP;
    imem[11] = enc_r(7'b0000000,5'd6,5'd5,3'b000,5'd7,OP_R);
    imem[12] = NOP;
    imem[13] = enc_r(7'b0000000,5'd7,5'd6,3'b000,5'd8,OP_R);
    imem[14] = NOP; imem[15] = NOP;
    imem[16] = enc_s(12'h200, 5'd3, 5'd0, 3'b010, OP_STOR); // fib3
    imem[17] = enc_s(12'h204, 5'd5, 5'd0, 3'b010, OP_STOR); // fib5
    imem[18] = enc_s(12'h208, 5'd7, 5'd0, 3'b010, OP_STOR); // fib7
    imem[19] = NOP; imem[20] = NOP; imem[21] = NOP; imem[22] = NOP;
    run_cycles(25);
    check32("Fibonacci fib(3)=2", dmem_word(10'h200), 32'h00000002);
    check32("Fibonacci fib(5)=5", dmem_word(10'h204), 32'h00000005);
    check32("Fibonacci fib(7)=13=0xD", dmem_word(10'h208), 32'h0000000D);

    // ========================================================================
    // TEST 11: ECALL HALT
    // Spec §1.8: ECALL asserts halt_o.
    // Encoding: I-type {12'b0, 5'b0, 3'b000, 5'b0, 7'b1110011} = 32'h00000073
    // Spec §7.3: halt_o = (ex_halt || ex_illegal_instr) && if_ex_valid
    // ECALL must assert halt_o when it reaches EX stage (2 cycles after fetch,
    // accounting for the 1 cycle IF/EX latch delay).
    // ========================================================================
    $display("\n--- TEST 11: ECALL halt ---");
    do_reset();
    imem[0] = 32'h00000073;  // ECALL = {12'b0, 5'b0, 3'b000, 5'b0, 7'b1110011}
    // ECALL at imem[0]: fetched at posedge 1, enters IF/EX at posedge 1,
    // halt_o asserted combinationally after posedge 1 until posedge 2.
    // halt_o is transient (1 cycle) — pipeline does not stall on halt.
    run_cycles(1);
    check1("ECALL: halt_o asserted", halt_o, 1'b1);
    // After one more cycle, ECALL leaves EX, halt_o drops (no pipeline stall)
    run_cycles(1);
    check1("ECALL: halt_o clears next cycle (no stall)", halt_o, 1'b0);

    // 11b: EBREAK also halts
    // Spec §1.8: EBREAK = {12'b000000000001, 5'b0, 3'b000, 5'b0, 7'b1110011}
    //          = 32'h00100073
    $display("\n--- TEST 11b: EBREAK halt ---");
    do_reset();
    imem[0] = 32'h00100073;  // EBREAK
    run_cycles(1);
    check1("EBREAK: halt_o asserted", halt_o, 1'b1);

    // 11c: Illegal opcode triggers halt
    // Spec §2: Any opcode not in the table -> illegal_instr_o=1 -> halt_o=1
    // Use opcode 7'b0000000 (not a valid RV32I opcode)
    $display("\n--- TEST 11c: Illegal opcode halt ---");
    do_reset();
    imem[0] = 32'h00000000;  // all-zero instruction (opcode=0000000, illegal)
    run_cycles(1);
    check1("Illegal opcode 0x00000000: halt_o asserted", halt_o, 1'b1);

    // 11d: NOP does NOT assert halt
    do_reset();
    // All NOPs already loaded; run and verify no halt
    run_cycles(6);
    check1("NOP does not assert halt_o", halt_o, 1'b0);

    // ========================================================================
    // TEST 12: ADDITIONAL ALU IMMEDIATE OPERATIONS
    // Spec §1.2.
    //
    // 12a: SLTI — signed immediate comparison
    //   x1=-1; SLTI x2,x1,0 -> x2=1 (-1 <s 0)
    //
    // 12b: SLTIU — unsigned immediate comparison
    //   x1=0xFFFFFFFF; SLTIU x2,x1,1 -> x2=0 (0xFFFFFFFF >u 1)
    //   Note: spec §1.2 warns imm IS sign-extended, then compared unsigned.
    //   imm=1, sext(1)=1; 0xFFFFFFFF <u 1 is false -> x2=0
    //
    // 12c: XORI — exclusive or with immediate
    //   x1=0xFF; XORI x2,x1,-1 -> x2=~x1=0xFFFFFF00
    //   Spec §1.2: XORI rd,rs1,-1 = bitwise NOT
    //
    // 12d: ORI — or with immediate
    //   x1=0xF0; ORI x2,x1,0x0F -> x2=0xFF
    //
    // 12e: ANDI — and with immediate
    //   x1=0xFF; ANDI x2,x1,0x0F -> x2=0x0F
    //
    // 12f: SRAI — arithmetic right shift immediate
    //   x1=-128=0xFFFFFF80; SRAI x2,x1,3 -> x2=0xFFFFFFF0
    // ========================================================================
    $display("\n--- TEST 12: I-type ALU operations ---");

    // 12a: SLTI
    do_reset();
    imem[0] = enc_i(12'hFFF, 5'd0, 3'b000, 5'd1, OP_IALU); // ADDI x1,x0,-1
    imem[1] = NOP;
    // SLTI x2,x1,0: imm=0, funct3=010
    imem[2] = enc_i(12'd0, 5'd1, 3'b010, 5'd2, OP_IALU);   // SLTI x2,x1,0
    imem[3] = NOP; imem[4] = NOP;
    imem[5] = enc_s(12'h200, 5'd2, 5'd0, 3'b010, OP_STOR);
    imem[6] = NOP; imem[7] = NOP; imem[8] = NOP; imem[9] = NOP;
    run_cycles(12);
    check32("SLTI x2,x1,0 (-1 <s 0) -> x2=1", dmem_word(10'h200), 32'h00000001);

    // 12b: SLTIU
    do_reset();
    imem[0] = enc_i(12'hFFF, 5'd0, 3'b000, 5'd1, OP_IALU); // ADDI x1,x0,-1 (=0xFFFFFFFF)
    imem[1] = NOP;
    // SLTIU x2,x1,1: funct3=011, imm=1 (sext=1); 0xFFFFFFFF <u 1 -> 0
    imem[2] = enc_i(12'd1, 5'd1, 3'b011, 5'd2, OP_IALU);   // SLTIU x2,x1,1
    imem[3] = NOP; imem[4] = NOP;
    imem[5] = enc_s(12'h200, 5'd2, 5'd0, 3'b010, OP_STOR);
    imem[6] = NOP; imem[7] = NOP; imem[8] = NOP; imem[9] = NOP;
    run_cycles(12);
    check32("SLTIU x2,x1,1 (0xFFFFFFFF <u 1 = 0) -> x2=0",
            dmem_word(10'h200), 32'h00000000);

    // 12c: XORI with -1 (bitwise NOT)
    do_reset();
    imem[0] = enc_i(12'hFF,  5'd0, 3'b000, 5'd1, OP_IALU); // ADDI x1,x0,0xFF
    imem[1] = NOP;
    // XORI x2,x1,-1: funct3=100, imm=0xFFF (-1 sign-extended)
    imem[2] = enc_i(12'hFFF, 5'd1, 3'b100, 5'd2, OP_IALU); // XORI x2,x1,-1
    imem[3] = NOP; imem[4] = NOP;
    imem[5] = enc_s(12'h200, 5'd2, 5'd0, 3'b010, OP_STOR);
    imem[6] = NOP; imem[7] = NOP; imem[8] = NOP; imem[9] = NOP;
    run_cycles(12);
    // Spec: 0x000000FF ^ 0xFFFFFFFF = 0xFFFFFF00
    check32("XORI x2,x1,-1 (NOT 0xFF) -> x2=0xFFFFFF00",
            dmem_word(10'h200), 32'hFFFFFF00);

    // 12d: ORI
    do_reset();
    imem[0] = enc_i(12'hF0,  5'd0, 3'b000, 5'd1, OP_IALU); // ADDI x1,x0,0xF0
    imem[1] = NOP;
    // ORI x2,x1,0x0F: funct3=110
    imem[2] = enc_i(12'h00F, 5'd1, 3'b110, 5'd2, OP_IALU); // ORI x2,x1,0xF
    imem[3] = NOP; imem[4] = NOP;
    imem[5] = enc_s(12'h200, 5'd2, 5'd0, 3'b010, OP_STOR);
    imem[6] = NOP; imem[7] = NOP; imem[8] = NOP; imem[9] = NOP;
    run_cycles(12);
    check32("ORI x2,x1,0xF (0xF0|0xF) -> x2=0xFF", dmem_word(10'h200), 32'h000000FF);

    // 12e: ANDI
    do_reset();
    imem[0] = enc_i(12'hFF,  5'd0, 3'b000, 5'd1, OP_IALU); // ADDI x1,x0,0xFF
    imem[1] = NOP;
    // ANDI x2,x1,0x0F: funct3=111
    imem[2] = enc_i(12'h00F, 5'd1, 3'b111, 5'd2, OP_IALU); // ANDI x2,x1,0xF
    imem[3] = NOP; imem[4] = NOP;
    imem[5] = enc_s(12'h200, 5'd2, 5'd0, 3'b010, OP_STOR);
    imem[6] = NOP; imem[7] = NOP; imem[8] = NOP; imem[9] = NOP;
    run_cycles(12);
    check32("ANDI x2,x1,0xF (0xFF&0xF) -> x2=0xF", dmem_word(10'h200), 32'h0000000F);

    // 12f: SRAI (arithmetic right shift immediate)
    // Spec §1.2: funct7=0100000, funct3=101 (same funct3 as SRLI, funct7[5] distinguishes)
    // imm[11:5]=0100000, shamt=3: full imm field = {7'b0100000, 5'd3} = 12'h403? No:
    // SRAI encoding: imm[11:5] = 0100000 (7 bits), shamt = imm[4:0]
    // So for shamt=3: imm[11:0] = {7'b0100000, 5'b00011} = 12'b010000000011 = 12'h403
    do_reset();
    imem[0] = enc_i(12'hF80, 5'd0, 3'b000, 5'd1, OP_IALU); // ADDI x1,x0,-128 (0xFFFFFF80)
    imem[1] = NOP;
    // SRAI x2,x1,3: funct3=101, imm={0100000,00011}=0x403
    imem[2] = enc_i(12'h403, 5'd1, 3'b101, 5'd2, OP_IALU); // SRAI x2,x1,3
    imem[3] = NOP; imem[4] = NOP;
    imem[5] = enc_s(12'h200, 5'd2, 5'd0, 3'b010, OP_STOR);
    imem[6] = NOP; imem[7] = NOP; imem[8] = NOP; imem[9] = NOP;
    run_cycles(12);
    // Spec: 0xFFFFFF80 >>> 3 = 0xFFFFFFF0 (arithmetic, sign extended)
    check32("SRAI x2,x1,3 (0xFFFFFF80>>>3) -> x2=0xFFFFFFF0",
            dmem_word(10'h200), 32'hFFFFFFF0);

    // ========================================================================
    // TEST 13: I-IMMEDIATE SIGN EXTENSION CORNERS
    // Spec §4: sign bit is always instruction bit 31 (canonical-reference.md §3)
    // Spec §11: Max positive I-imm=2047=0x7FF, max negative=-2048=0xFFFFF800
    //
    // 13a: ADDI x1,x0,2047 (max positive 12-bit) -> x1=2047
    // 13b: ADDI x1,x0,-2048 (min negative 12-bit) -> x1=0xFFFFF800
    // ========================================================================
    $display("\n--- TEST 13: Immediate sign extension corners ---");

    // 13a: max positive
    do_reset();
    imem[0] = enc_i(12'h7FF, 5'd0, 3'b000, 5'd1, OP_IALU); // ADDI x1,x0,2047
    imem[1] = NOP; imem[2] = NOP;
    imem[3] = enc_s(12'h200, 5'd1, 5'd0, 3'b010, OP_STOR);
    imem[4] = NOP; imem[5] = NOP; imem[6] = NOP; imem[7] = NOP;
    run_cycles(10);
    // Spec §11: Max positive I-imm = 2047 = 0x7FF
    check32("ADDI x1,x0,2047 -> x1=0x000007FF",
            dmem_word(10'h200), 32'h000007FF);

    // 13b: max negative (min value)
    do_reset();
    imem[0] = enc_i(12'h800, 5'd0, 3'b000, 5'd1, OP_IALU); // ADDI x1,x0,-2048
    imem[1] = NOP; imem[2] = NOP;
    imem[3] = enc_s(12'h200, 5'd1, 5'd0, 3'b010, OP_STOR);
    imem[4] = NOP; imem[5] = NOP; imem[6] = NOP; imem[7] = NOP;
    run_cycles(10);
    // Spec §11: Max negative I-imm = 0x800 sign-extended = 0xFFFFF800 = -2048
    check32("ADDI x1,x0,-2048 -> x1=0xFFFFF800",
            dmem_word(10'h200), 32'hFFFFF800);

    // ========================================================================
    // TEST 14: x0 SPECIAL CASES
    // Spec: x0 is hardwired to 0. Writes to x0 have no effect.
    // (canonical-reference.md §7.3, forwarding note: wb_rd != 0 mandatory)
    //
    // 14a: Write to x0 — result must always read as 0
    // 14b: Read x0 — always 0 regardless of any prior writes
    // ========================================================================
    $display("\n--- TEST 14: x0 special cases ---");

    // 14a: ADDI x0,x0,99 -> x0 must still be 0
    do_reset();
    imem[0] = enc_i(12'd99, 5'd0, 3'b000, 5'd0, OP_IALU);  // ADDI x0,x0,99
    imem[1] = NOP; imem[2] = NOP;
    imem[3] = enc_s(12'h200, 5'd0, 5'd0, 3'b010, OP_STOR); // SW x0,0x200(x0)
    imem[4] = NOP; imem[5] = NOP; imem[6] = NOP; imem[7] = NOP;
    run_cycles(10);
    // x0 hardwired to 0 (canonical-reference.md §10.3, regfile convention)
    check32("x0 write: ADDI x0,99 then SW x0 -> dmem=0",
            dmem_word(10'h200), 32'h00000000);

    // 14b: ADD x3,x0,x0 = 0+0 = 0
    do_reset();
    imem[0] = enc_r(7'b0000000, 5'd0, 5'd0, 3'b000, 5'd3, OP_R); // ADD x3,x0,x0
    imem[1] = NOP; imem[2] = NOP;
    imem[3] = enc_s(12'h200, 5'd3, 5'd0, 3'b010, OP_STOR);
    imem[4] = NOP; imem[5] = NOP; imem[6] = NOP; imem[7] = NOP;
    run_cycles(10);
    check32("ADD x3,x0,x0 -> x3=0", dmem_word(10'h200), 32'h00000000);

    // ========================================================================
    // TEST 15: PIPELINE FLUSH VERIFICATION (branch bubble)
    // Verify that exactly 1 cycle is flushed (bubble inserted) on taken branch.
    // The instruction immediately after the branch MUST NOT execute.
    // The instruction 2 slots after the branch also MUST NOT execute if branch
    // target is beyond it (we verified this in TEST 6b; this test makes the
    // bubble effect explicit using a store to a sentinel address).
    //
    // Layout:
    //   0: ADDI x1,x0,5
    //   1: ADDI x2,x0,5
    //   2: NOP
    //   3: BEQ x1,x2,+8 (taken: target=word5=PC20)
    //   4: SW x0,0x500(x0)   <- this is the BUBBLE slot (FLUSHED); must NOT write 0x500
    //   5: NOP
    //   6: SW x0,0x504(x0)   <- this is 2 slots after branch; also not executed
    //                             (PC went to word5=20, not here)
    //   Wait - branch target offset=8 from PC=12 -> target=20=word5
    //   word4=16: bubble slot (flushed)
    //   word5=20: target
    //   So: imem[5] = target instruction
    //       imem[4] = flushed slot
    // Actually let me redo: BEQ at word3 (PC=12), offset=8, target=20=word5.
    //   imem[4] (PC=16): flushed (SW sentinel should not execute)
    //   imem[5] (PC=20): target (ADDI x3,x0,77)
    //   imem[6..]: normal drain + final SW
    // ========================================================================
    $display("\n--- TEST 15: Branch flush (bubble verification) ---");
    do_reset();
    // Initialize sentinel location (0x3E0) to 0xFFFFFFFF to detect spurious writes
    dmem[10'h3E0] = 8'hFF;
    dmem[10'h3E1] = 8'hFF;
    dmem[10'h3E2] = 8'hFF;
    dmem[10'h3E3] = 8'hFF;
    imem[0] = enc_i(12'd5, 5'd0, 3'b000, 5'd1, OP_IALU);
    imem[1] = enc_i(12'd5, 5'd0, 3'b000, 5'd2, OP_IALU);
    imem[2] = NOP;
    // BEQ x1,x2,+8 (offset=8, B-imm=8): target = 12+8=20 = word5
    imem[3] = enc_b(13'd8, 5'd2, 5'd1, 3'b000, OP_BRNC);   // BEQ x1,x2,+8
    // Bubble slot (flushed): SW x0,0x3E0(x0) FLUSHED — must NOT write dmem[0x3E0]
    imem[4] = enc_s(12'h3E0, 5'd0, 5'd0, 3'b010, OP_STOR); // SW x0,0x3E0(x0) FLUSHED
    imem[5] = enc_i(12'd77, 5'd0, 3'b000, 5'd3, OP_IALU);  // target: ADDI x3,x0,77
    imem[6] = NOP; imem[7] = NOP;
    imem[8] = enc_s(12'h200, 5'd3, 5'd0, 3'b010, OP_STOR);
    imem[9] = NOP; imem[10] = NOP; imem[11] = NOP; imem[12] = NOP;
    run_cycles(15);
    // x3 must be 77 (target executed)
    check32("Branch flush: target x3=77", dmem_word(10'h200), 32'h0000004D);
    // dmem[0x3E0] must remain 0xFFFFFFFF (flushed store did NOT execute)
    check32("Branch flush: bubble slot SW did NOT write sentinel 0xFFFFFFFF",
            dmem_word(10'h3E0), 32'hFFFFFFFF);

    // ========================================================================
    // TEST 16: PC RESET VALUE
    // Spec §9.2: PC clears to 0 on reset.
    // After reset, instr_addr_o must be 0x0 on the first active cycle.
    // ========================================================================
    $display("\n--- TEST 16: PC reset to 0 ---");
    // Assert reset and verify PC clears to 0
    @(negedge clk);
    rst_n = 1'b0;
    @(posedge clk); #1;
    check32("PC resets to 0x0: instr_addr_o=0 during reset",
            instr_addr_o, 32'h00000000);
    // Deassert reset at negedge; on next posedge, pc_reg advances from 0 to 4
    // (the instruction at PC=0 was fetched while pc_reg was 0)
    @(negedge clk);
    rst_n = 1'b1;
    @(posedge clk); #1;
    // After first post-reset posedge: pc_reg has advanced to 4
    check32("PC=4 after first post-reset cycle",
            instr_addr_o, 32'h00000004);
    @(posedge clk); #1;
    check32("PC=8 after second cycle",
            instr_addr_o, 32'h00000008);

    // ========================================================================
    // SUMMARY
    // ========================================================================
    $display("\n========================================");
    $display("TESTBENCH COMPLETE");
    $display("  PASS: %0d", pass_count);
    $display("  FAIL: %0d", fail_count);
    $display("========================================");
    if (fail_count == 0)
      $display("ALL TESTS PASSED");
    else
      $display("SOME TESTS FAILED — review RTL against canonical-reference.md");
    $finish;
  end

  // ==========================================================================
  // Timeout watchdog — abort if simulation hangs (e.g., halt_o stuck high
  // preventing PC advance or TB logic error)
  // ==========================================================================
  initial begin
    #500000; // 500 us simulation limit
    $display("TIMEOUT: simulation exceeded 500us. TB or DUT hung.");
    $finish;
  end

endmodule
