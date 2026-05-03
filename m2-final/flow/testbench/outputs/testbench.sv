// =============================================================================
// Testbench: tb_chip_top.sv
// DUT: chip_top (MMIO wrapper for TSI RV32I core)
// Spec ref: docs/canonical-reference.md §13
// Timescale: 1ns/1ps, 50 MHz clock (period = 20 ns)
// Drive discipline: all stimulus driven at negedge (gotchas.md #11)
// =============================================================================
`timescale 1ns/1ps

module tb_chip_top;

  // ---------------------------------------------------------------------------
  // Clock and reset
  // ---------------------------------------------------------------------------
  logic        clk;
  logic        rst_n;
  logic [31:0] data_i;
  logic [31:0] data_o;
  logic [2:0]  addr_cmd_i;
  logic        wr_en_i;
  logic        rd_en_i;
  logic        busy_o;
  logic        done_o;

  // 50 MHz clock
  initial clk = 0;
  always #10 clk = ~clk;

  // ---------------------------------------------------------------------------
  // DUT instantiation (§13.1)
  // ---------------------------------------------------------------------------
  chip_top #(
    .IMEM_DEPTH(64),
    .DMEM_DEPTH(64)
  ) dut (
    .clk        (clk),
    .rst_n      (rst_n),
    .data_i     (data_i),
    .data_o     (data_o),
    .addr_cmd_i (addr_cmd_i),
    .wr_en_i    (wr_en_i),
    .rd_en_i    (rd_en_i),
    .busy_o     (busy_o),
    .done_o     (done_o)
  );

  // ---------------------------------------------------------------------------
  // Pass / fail tracking
  // ---------------------------------------------------------------------------
  integer pass_count;
  integer fail_count;

  task automatic check;
    input string  test_name;
    input logic [31:0] got;
    input logic [31:0] expected;
    input string  spec_ref;
    begin
      if (got !== expected) begin
        $display("FAIL [%s] got=%0h expected=%0h (%s)", test_name, got, expected, spec_ref);
        fail_count = fail_count + 1;
      end else begin
        $display("PASS [%s] got=%0h (%s)", test_name, got, spec_ref);
        pass_count = pass_count + 1;
      end
    end
  endtask

  task automatic check1;
    input string  test_name;
    input logic   got;
    input logic   expected;
    input string  spec_ref;
    begin
      if (got !== expected) begin
        $display("FAIL [%s] got=%0b expected=%0b (%s)", test_name, got, expected, spec_ref);
        fail_count = fail_count + 1;
      end else begin
        $display("PASS [%s] got=%0b (%s)", test_name, got, spec_ref);
        pass_count = pass_count + 1;
      end
    end
  endtask

  // ---------------------------------------------------------------------------
  // Helper tasks — all stimulus driven at negedge (gotchas.md #11)
  // ---------------------------------------------------------------------------

  // Write a register: set addr_cmd_i, data_i, assert wr_en_i for one cycle
  // §13.1: wr_en_i captured on rising clk edge
  task automatic write_reg;
    input [2:0]  addr;
    input [31:0] data;
    begin
      @(negedge clk);
      addr_cmd_i = addr;
      data_i     = data;
      wr_en_i    = 1'b1;
      @(negedge clk);
      wr_en_i    = 1'b0;
    end
  endtask

  // Read a register: combinational — data_o valid same cycle as rd_en_i (§13.1)
  task automatic read_reg;
    input  [2:0]  addr;
    output [31:0] data;
    begin
      @(negedge clk);
      addr_cmd_i = addr;
      rd_en_i    = 1'b1;
      #1;                   // combinational propagation
      data = data_o;
      @(negedge clk);
      rd_en_i = 1'b0;
    end
  endtask

  // Load one word into imem[word_addr]:
  //   1. Write ADDR register (3'h1) with word_addr
  //   2. Write WDATA register (3'h2) with word_data
  //   3. Write CMD register (3'h0) with CMD_LOAD_IMEM (4'h1)
  //      -> FSM enters LOADING (1 cycle) then returns to IDLE (§13.5)
  task automatic load_imem_word;
    input [31:0] word_addr;
    input [31:0] word_data;
    begin
      write_reg(3'h1, word_addr);
      write_reg(3'h2, word_data);
      write_reg(3'h0, 32'h1);   // CMD_LOAD_IMEM = 4'h1
      // LOADING is single-cycle transient; FSM auto-returns to IDLE next cycle (§13.5)
      // write_reg already consumed one negedge after the posedge captures CMD;
      // wait one additional cycle to let the write complete and state return to IDLE
      @(posedge clk); #1;
    end
  endtask

  // Load one word into dmem[word_addr]
  task automatic load_dmem_word;
    input [31:0] word_addr;
    input [31:0] word_data;
    begin
      write_reg(3'h1, word_addr);
      write_reg(3'h2, word_data);
      write_reg(3'h0, 32'h2);   // CMD_LOAD_DMEM = 4'h2
      @(posedge clk); #1;
    end
  endtask

  // Issue RUN command: CMD = 4'h3 (§13.3)
  task automatic issue_run;
    begin
      write_reg(3'h0, 32'h3);  // CMD_RUN
    end
  endtask

  // Issue HALT command: CMD = 4'h4 (§13.3)
  task automatic issue_halt;
    begin
      write_reg(3'h0, 32'h4);  // CMD_HALT
    end
  endtask

  // Wait for done_o with timeout
  task automatic wait_for_done;
    input integer max_cycles;
    output logic   timed_out;
    integer i;
    begin
      timed_out = 1'b0;
      for (i = 0; i < max_cycles; i = i + 1) begin
        if (done_o) begin
          timed_out = 1'b0;
          i = max_cycles; // exit loop
        end else begin
          @(posedge clk); #1;
        end
      end
      if (!done_o) timed_out = 1'b1;
    end
  endtask

  // ---------------------------------------------------------------------------
  // Main test sequence
  // ---------------------------------------------------------------------------
  logic [31:0] rd_data;
  logic        timed_out;

  initial begin
    // Initialize counters and signals
    pass_count = 0;
    fail_count = 0;
    rst_n      = 1'b0;
    data_i     = 32'h0;
    addr_cmd_i = 3'h0;
    wr_en_i    = 1'b0;
    rd_en_i    = 1'b0;

    // -------------------------------------------------------------------------
    // Reset sequence: assert for 2 cycles, deassert on posedge, wait 1 cycle
    // The 2-FF reset synchronizer (§13.6) requires rst_n_sync to propagate
    // through 2 FFs before internal logic is out of reset.
    // -------------------------------------------------------------------------
    repeat(2) @(posedge clk);
    @(negedge clk);
    rst_n = 1'b1;
    // Allow synchronizer 2 extra cycles to deassert rst_n_sync
    repeat(3) @(posedge clk);
    #1;

    // =========================================================================
    // TEST: Reset state — STATUS should read IDLE (4'h0) after reset
    // Spec §13.5: reset state is IDLE; STATUS = {28'h0, 4'h0}
    // =========================================================================
    $display("\n--- Reset State Check ---");
    read_reg(3'h4, rd_data);
    check("reset_status", rd_data, 32'h0, "§13.5 FSM IDLE=4'h0");

    // busy_o and done_o both low in IDLE (§13.5)
    check1("reset_busy_o", busy_o, 1'b0, "§13.5 busy_o=0 in IDLE");
    check1("reset_done_o", done_o, 1'b0, "§13.5 done_o=0 in IDLE");

    // Read CMD/ADDR/WDATA registers: write-only, return 32'h0 (§13.2)
    read_reg(3'h0, rd_data);
    check("read_CMD_reg",   rd_data, 32'h0, "§13.2 CMD is write-only returns 0");
    read_reg(3'h1, rd_data);
    check("read_ADDR_reg",  rd_data, 32'h0, "§13.2 ADDR is write-only returns 0");
    read_reg(3'h2, rd_data);
    check("read_WDATA_reg", rd_data, 32'h0, "§13.2 WDATA is write-only returns 0");

    // Reserved register 3'h7 returns 32'h0 (§13.2)
    read_reg(3'h7, rd_data);
    check("read_reserved_reg", rd_data, 32'h0, "§13.2 reserved 3'h7 returns 0");

    // =========================================================================
    // TEST 5 (simple): LOAD_DMEM / READ_DMEM
    // Load a known value into dmem[0], then read it back.
    // §13.3: CMD_LOAD_DMEM writes WDATA to dmem[ADDR]
    //        CMD_READ_DMEM reads dmem[ADDR] into RDATA
    // Expected: read back exactly what was written.
    // =========================================================================
    $display("\n--- Test 5: LOAD_DMEM / READ_DMEM ---");
    load_dmem_word(32'h0, 32'hDEADBEEF);

    // Now issue READ_DMEM for addr 0
    write_reg(3'h1, 32'h0);          // ADDR = 0
    write_reg(3'h0, 32'h5);          // CMD_READ_DMEM = 4'h5
    // rdata_reg latched on posedge; read it from RDATA register (§13.2 3'h3)
    @(posedge clk); #1;
    read_reg(3'h3, rd_data);
    check("dmem_load_readback", rd_data, 32'hDEADBEEF, "§13.3 READ_DMEM returns WDATA written by LOAD_DMEM");

    // Load a different addr
    load_dmem_word(32'h5, 32'hCAFEBABE);
    write_reg(3'h1, 32'h5);
    write_reg(3'h0, 32'h5);          // CMD_READ_DMEM
    @(posedge clk); #1;
    read_reg(3'h3, rd_data);
    check("dmem_load_readback_addr5", rd_data, 32'hCAFEBABE, "§13.3 READ_DMEM addr 5");

    // busy_o must be 0 in IDLE (not busy loading) (§13.5)
    check1("dmem_load_busy_after", busy_o, 1'b0, "§13.5 busy_o=0 after LOADING returns to IDLE");

    // =========================================================================
    // TEST 1: Basic ADD program
    // Program:
    //   imem[0]: ADDI x1, x0, 42    = 32'h02A00093
    //   imem[1]: ADDI x2, x0, 58    = 32'h03A00113
    //   imem[2]: ADD  x3, x1, x2    = 32'h002081B3
    //   imem[3]: SW   x3, 0(x0)     = 32'h00302023
    //   imem[4]: EBREAK              = 32'h00100073
    //
    // Spec derivation:
    //   ADDI x1, x0, 42: x1 = 0 + 42 = 42 (§1.2 ADDI)
    //   ADDI x2, x0, 58: x2 = 0 + 58 = 58
    //   ADD  x3, x1, x2: x3 = 42 + 58 = 100 (§1.1 ADD)
    //   SW   x3, 0(x0): dmem[0] = x3 = 100  (§1.4 SW, byte addr 0 = word index 0)
    //   EBREAK: triggers halt_o (§5 EBREAK)
    //
    // After RUN: done_o asserts, READ_DMEM[0] = 100 = 32'h64
    // CYCLE_CNT > 0 because CPU was RUNNING
    // =========================================================================
    $display("\n--- Test 1: Basic ADD program ---");

    // Load imem words (word-addressed, §13.4)
    load_imem_word(32'h0, 32'h02A00093); // ADDI x1, x0, 42
    load_imem_word(32'h1, 32'h03A00113); // ADDI x2, x0, 58
    load_imem_word(32'h2, 32'h002081B3); // ADD  x3, x1, x2
    load_imem_word(32'h3, 32'h00302023); // SW   x3, 0(x0)
    load_imem_word(32'h4, 32'h00100073); // EBREAK

    // Clear dmem[0] so we're not relying on stale value from Test 5
    load_dmem_word(32'h0, 32'h0);

    // Issue RUN (§13.3 CMD_RUN = 4'h3; FSM enters RUNNING, CPU released)
    issue_run();

    // busy_o should be high in RUNNING state (§13.5)
    @(posedge clk); #1;
    check1("add_prog_busy_running", busy_o, 1'b1, "§13.5 busy_o=1 in RUNNING");

    // Wait for done_o with 200-cycle timeout
    // Program is 5 instructions in a 3-stage pipeline: ~15 cycles is generous
    wait_for_done(200, timed_out);
    if (timed_out) begin
      $display("FAIL [add_prog_done] timed out waiting for done_o (§13.5 RUNNING->DONE on halt_o)");
      fail_count = fail_count + 1;
    end else begin
      $display("PASS [add_prog_done] done_o asserted (§13.5 RUNNING->DONE on halt_o)");
      pass_count = pass_count + 1;
    end

    // Verify output signals in DONE state (§13.5)
    check1("add_prog_done_o",  done_o,  1'b1, "§13.5 done_o=1 in DONE state");
    check1("add_prog_busy_o",  busy_o,  1'b0, "§13.5 busy_o=0 in DONE state");

    // Read STATUS: should be DONE = 4'h3 (§13.5, §13.2)
    read_reg(3'h4, rd_data);
    check("add_prog_status", rd_data, 32'h3, "§13.5 STATUS=DONE=4'h3");

    // READ_DMEM[0] to get the SW result
    // §13.3 CMD_READ_DMEM reads dmem[ADDR] into RDATA
    write_reg(3'h1, 32'h0);       // ADDR = 0
    write_reg(3'h0, 32'h5);       // CMD_READ_DMEM
    @(posedge clk); #1;
    read_reg(3'h3, rd_data);
    // Expected: 42 + 58 = 100 = 32'h64 (§1.1 ADD, §1.2 ADDI)
    check("add_result_dmem0", rd_data, 32'h00000064, "§1.1/§1.2 ADD: 42+58=100");

    // Verify CYCLE_CNT > 0 (§13.6 counter increments in RUNNING only)
    read_reg(3'h6, rd_data);
    if (rd_data === 32'h0) begin
      $display("FAIL [add_cycle_cnt] CYCLE_CNT=0 but should be >0 (§13.6)");
      fail_count = fail_count + 1;
    end else begin
      $display("PASS [add_cycle_cnt] CYCLE_CNT=%0d > 0 (§13.6)", rd_data);
      pass_count = pass_count + 1;
    end

    // Return to IDLE via HALT (§13.5 DONE->IDLE on CMD_HALT)
    issue_halt();
    @(posedge clk); #1;
    read_reg(3'h4, rd_data);
    check("add_halt_to_idle", rd_data, 32'h0, "§13.5 DONE->IDLE on CMD_HALT");
    check1("add_done_o_after_halt", done_o, 1'b0, "§13.5 done_o=0 in IDLE");

    // =========================================================================
    // TEST 4: READ_IMEM
    // After loading imem in Test 1, issue READ_IMEM and verify the word
    // matches what was written.
    // §13.3: CMD_READ_IMEM reads imem[ADDR] into RDATA
    // =========================================================================
    $display("\n--- Test 4: READ_IMEM ---");

    // Read back imem[0] = 32'h02A00093
    write_reg(3'h1, 32'h0);         // ADDR = 0
    write_reg(3'h0, 32'h6);         // CMD_READ_IMEM = 4'h6
    @(posedge clk); #1;
    read_reg(3'h3, rd_data);
    check("imem_readback_0", rd_data, 32'h02A00093, "§13.3 READ_IMEM[0] = ADDI x1,x0,42");

    // Read back imem[2] = 32'h002081B3
    write_reg(3'h1, 32'h2);         // ADDR = 2
    write_reg(3'h0, 32'h6);         // CMD_READ_IMEM
    @(posedge clk); #1;
    read_reg(3'h3, rd_data);
    check("imem_readback_2", rd_data, 32'h002081B3, "§13.3 READ_IMEM[2] = ADD x3,x1,x2");

    // Read back imem[4] = 32'h00100073 (EBREAK)
    write_reg(3'h1, 32'h4);         // ADDR = 4
    write_reg(3'h0, 32'h6);         // CMD_READ_IMEM
    @(posedge clk); #1;
    read_reg(3'h3, rd_data);
    check("imem_readback_4", rd_data, 32'h00100073, "§13.3 READ_IMEM[4] = EBREAK");

    // =========================================================================
    // TEST 2: CLZ custom instruction
    // Program (2 NOPs before and after CLZ to eliminate all pipeline hazards):
    //   imem[0]: ADDI x1, x0, 1  = 32'h00100093  (x1 = 1)
    //   imem[1]: NOP              = 32'h00000013  (pipeline drain)
    //   imem[2]: NOP              = 32'h00000013  (pipeline drain)
    //   imem[3]: CLZ x2, x1      = 32'h0A00810B
    //            Encoding: funct7=0000101, rs2=00000, rs1=x1(00001),
    //                      funct3=000, rd=x2(00010), opcode=0001011 (CUSTOM-0)
    //            Spec §8.1: CUSTOM-0 opcode = 7'b0001011
    //            = 0000101_00000_00001_000_00010_0001011 = 0x0A00810B
    //   imem[4]: NOP              = 32'h00000013
    //   imem[5]: NOP              = 32'h00000013
    //   imem[6]: SW x2, 0(x0)    = 32'h00202023
    //   imem[7]: EBREAK           = 32'h00100073
    //
    // Spec derivation (§8.1 CLZ):
    //   x1 = 1 = 0x00000001 = 0000_0000_0000_0000_0000_0000_0000_0001
    //   CLZ counts leading zeros: 31 zeros before the leading 1
    //   Expected: x2 = 31 = 32'h1F
    //   SW x2, 0(x0): dmem[0] = 31
    // =========================================================================
    $display("\n--- Test 2: CLZ custom instruction ---");

    // Overwrite imem with CLZ program (fully hazard-free: 2 NOPs before CLZ, 2 NOPs after CLZ)
    // x1 = 1; CLZ(x1)=31 written to x2; SW x2 to dmem[0]
    // CUSTOM-0 opcode = 7'b0001011 per canonical-reference.md §8.1
    load_imem_word(32'h0, 32'h00100093); // ADDI x1, x0, 1
    load_imem_word(32'h1, 32'h00000013); // NOP (ADDI x0,x0,0) — drain ADDI x1
    load_imem_word(32'h2, 32'h00000013); // NOP — drain
    load_imem_word(32'h3, 32'h0A00810B); // CLZ x2, x1  (CUSTOM-0, funct7=0000101, funct3=000)
    load_imem_word(32'h4, 32'h00000013); // NOP — drain CLZ before SW reads x2
    load_imem_word(32'h5, 32'h00000013); // NOP — drain
    load_imem_word(32'h6, 32'h00202023); // SW x2, 0(x0)
    load_imem_word(32'h7, 32'h00100073); // EBREAK

    // Clear dmem[0]
    load_dmem_word(32'h0, 32'h0);

    issue_run();

    wait_for_done(200, timed_out);
    if (timed_out) begin
      $display("FAIL [clz_prog_done] timed out waiting for done_o");
      fail_count = fail_count + 1;
    end else begin
      $display("PASS [clz_prog_done] done_o asserted");
      pass_count = pass_count + 1;
    end

    // READ_DMEM[0] — should contain CLZ(1) = 31
    write_reg(3'h1, 32'h0);
    write_reg(3'h0, 32'h5);       // CMD_READ_DMEM
    @(posedge clk); #1;
    read_reg(3'h3, rd_data);
    // §8.1: CLZ(1) = 31 leading zeros
    check("clz_result", rd_data, 32'h0000001F, "§8.1 CLZ(1)=31");

    issue_halt();
    @(posedge clk); #1;
    read_reg(3'h4, rd_data);
    check("clz_halt_to_idle", rd_data, 32'h0, "§13.5 DONE->IDLE on HALT");

    // =========================================================================
    // TEST 3: HALT command — force stop a running infinite loop
    // Program:
    //   imem[0]: JAL x0, 0  = 32'h0000006F  (jump to self, infinite loop)
    //            Encoding: imm=0 (J-type), rd=x0, opcode=1101111
    //            JAL: {imm[20|10:1|11|19:12], rd, 1101111}
    //            All imm bits 0 → 32'h0000006F
    //
    // Spec §13.3 CMD_HALT: force pipeline_top back into reset; FSM returns to IDLE
    // Expected: after HALT, done_o=0, busy_o=0, STATUS=IDLE=0
    // =========================================================================
    $display("\n--- Test 3: HALT force-stop ---");

    // Load infinite loop
    load_imem_word(32'h0, 32'h0000006F); // JAL x0, 0

    issue_run();

    // Wait a few cycles — done_o must NOT assert (infinite loop)
    repeat(20) @(posedge clk);
    #1;
    check1("halt_done_not_set", done_o, 1'b0, "§13.5 done_o=0 while infinite loop running");
    check1("halt_busy_running", busy_o, 1'b1, "§13.5 busy_o=1 in RUNNING state");

    // Issue HALT
    issue_halt();
    @(posedge clk); #1;

    // FSM must return to IDLE (§13.5 RUNNING->IDLE on CMD_HALT)
    read_reg(3'h4, rd_data);
    check("halt_status_idle", rd_data, 32'h0, "§13.5 RUNNING->IDLE on CMD_HALT");
    check1("halt_busy_o_idle",  busy_o, 1'b0, "§13.5 busy_o=0 after HALT");
    check1("halt_done_o_idle",  done_o, 1'b0, "§13.5 done_o=0 after HALT returns to IDLE");

    // =========================================================================
    // TEST: IDLE state FSM — NOP command does not change state
    // §13.3 NOP = 4'h0: FSM stays in current state
    // =========================================================================
    $display("\n--- Test: NOP command in IDLE ---");
    write_reg(3'h0, 32'h0); // CMD_NOP
    @(posedge clk); #1;
    read_reg(3'h4, rd_data);
    check("nop_state_stable", rd_data, 32'h0, "§13.3 NOP keeps FSM in IDLE");

    // =========================================================================
    // TEST: LOADING state busy_o
    // §13.5: busy_o = 1 in LOADING state
    // This is hard to observe directly (single-cycle transient), but we can
    // verify that loading completes and returns to IDLE without errors.
    // =========================================================================
    $display("\n--- Test: LOADING transient ---");
    load_imem_word(32'h3F, 32'hAAAA5555);  // load to last valid imem word (63)
    // verify FSM is back in IDLE after loading
    read_reg(3'h4, rd_data);
    check("loading_returns_idle", rd_data, 32'h0, "§13.5 LOADING->IDLE auto-return");

    // Verify the word loaded correctly via READ_IMEM
    write_reg(3'h1, 32'h3F);
    write_reg(3'h0, 32'h6);
    @(posedge clk); #1;
    read_reg(3'h3, rd_data);
    check("imem_boundary_readback", rd_data, 32'hAAAA5555, "§13.4 imem[63] boundary word");

    // =========================================================================
    // TEST: done_o is asserted in DONE, not in IDLE/RUNNING/LOADING
    // §13.5: done_o = (state == DONE)
    // =========================================================================
    $display("\n--- Test: done_o and busy_o output encoding ---");
    // Reload a terminating program
    load_imem_word(32'h0, 32'h00100073); // Just EBREAK at addr 0

    // Fill in any pipeline bubble instructions as NOPs
    load_imem_word(32'h1, 32'h00000013); // NOP
    load_imem_word(32'h2, 32'h00000013); // NOP

    issue_run();
    @(posedge clk); #1;
    // In RUNNING: busy_o=1, done_o=0
    check1("run_busy_high",  busy_o, 1'b1, "§13.5 busy_o=1 in RUNNING");
    check1("run_done_low",   done_o, 1'b0, "§13.5 done_o=0 in RUNNING");

    wait_for_done(200, timed_out);
    if (timed_out) begin
      $display("FAIL [ebreak_done] timed out waiting for done_o");
      fail_count = fail_count + 1;
    end else begin
      $display("PASS [ebreak_done] done_o asserted after EBREAK");
      pass_count = pass_count + 1;
    end

    check1("done_state_done_o", done_o,  1'b1, "§13.5 done_o=1 in DONE state");
    check1("done_state_busy_o", busy_o,  1'b0, "§13.5 busy_o=0 in DONE state");

    // Return to IDLE
    issue_halt();
    @(posedge clk); #1;

    // =========================================================================
    // TEST: CYCLE_CNT resets to 0 on rst_n assertion (§13.6)
    // Apply reset and verify counter clears
    // =========================================================================
    $display("\n--- Test: CYCLE_CNT cleared by reset ---");
    @(negedge clk);
    rst_n = 1'b0;
    repeat(2) @(posedge clk);
    @(negedge clk);
    rst_n = 1'b1;
    repeat(3) @(posedge clk);
    #1;
    read_reg(3'h6, rd_data);
    check("cycle_cnt_after_reset", rd_data, 32'h0, "§13.6 CYCLE_CNT cleared on reset");

    // Verify STATUS back to IDLE after reset
    read_reg(3'h4, rd_data);
    check("status_after_reset", rd_data, 32'h0, "§13.5 FSM resets to IDLE");

    // =========================================================================
    // TEST: CYCLE_CNT only increments in RUNNING (§13.6)
    // Load a short program, run it, observe counter
    // =========================================================================
    $display("\n--- Test: CYCLE_CNT increments only in RUNNING ---");
    // Read CYCLE_CNT before run — should still be 0 after reset
    read_reg(3'h6, rd_data);
    check("cycle_cnt_idle_zero", rd_data, 32'h0, "§13.6 CYCLE_CNT=0 while in IDLE");

    // Load a quick halting program
    load_imem_word(32'h0, 32'h00100073); // EBREAK
    load_imem_word(32'h1, 32'h00000013); // NOP (pipeline fill)
    load_imem_word(32'h2, 32'h00000013); // NOP

    // Verify counter still 0 after loading (not RUNNING)
    read_reg(3'h6, rd_data);
    check("cycle_cnt_after_load", rd_data, 32'h0, "§13.6 CYCLE_CNT does not increment in IDLE/LOADING");

    issue_run();
    wait_for_done(200, timed_out);
    if (timed_out) begin
      $display("FAIL [cycle_cnt_run] timed out waiting for done_o");
      fail_count = fail_count + 1;
    end else begin
      $display("PASS [cycle_cnt_run] program completed");
      pass_count = pass_count + 1;
    end

    read_reg(3'h6, rd_data);
    if (rd_data === 32'h0) begin
      $display("FAIL [cycle_cnt_nonzero] CYCLE_CNT=0 after RUNNING (§13.6)");
      fail_count = fail_count + 1;
    end else begin
      $display("PASS [cycle_cnt_nonzero] CYCLE_CNT=%0d after RUNNING (§13.6)", rd_data);
      pass_count = pass_count + 1;
    end

    issue_halt();
    @(posedge clk); #1;

    // =========================================================================
    // Summary
    // =========================================================================
    $display("\n==============================================");
    $display("  TESTBENCH COMPLETE: %0d passed, %0d failed", pass_count, fail_count);
    $display("==============================================\n");
    if (fail_count == 0)
      $display("ALL TESTS PASSED");
    else
      $display("FAILURES DETECTED — see FAIL lines above");

    $finish;
  end

  // ---------------------------------------------------------------------------
  // Simulation timeout watchdog: 100,000 cycles max
  // ---------------------------------------------------------------------------
  initial begin
    #2000000;
    $display("FATAL: simulation timeout (watchdog)");
    $finish;
  end

endmodule
