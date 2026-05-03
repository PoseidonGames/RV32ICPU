// ============================================================
// Register File Testbench — Directed Tests
// ============================================================
// Tests:
//   1. Reset clears all registers
//   2. x0 always reads zero (even after attempted write)
//   3. Basic write then read
//   4. Both read ports simultaneously
//   5. Write-enable gating (no write when wr_en=0)
//   6. Read-during-write returns old value
//   7. Write to all 31 registers, read them all back
//
// Usage (VCS):
//   vcs -sverilog regfile.sv regfile_tb.sv -o regfile_sim
//   ./regfile_sim
//
// Usage (Icarus):
//   iverilog -g2012 -o regfile_sim regfile.sv regfile_tb.sv
//   ./regfile_sim
// ============================================================

module regfile_tb;

    logic        clk;
    logic        rst_n;
    logic        wr_en;
    logic [4:0]  wr_addr;
    logic [31:0] wr_data;
    logic [4:0]  rd_addr_a;
    logic [31:0] rd_data_a;
    logic [4:0]  rd_addr_b;
    logic [31:0] rd_data_b;

    regfile dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .wr_en_i     (wr_en),
        .wr_addr_i   (wr_addr),
        .wr_data_i   (wr_data),
        .rd_addr_a_i (rd_addr_a),
        .rd_data_a_o (rd_data_a),
        .rd_addr_b_i (rd_addr_b),
        .rd_data_b_o (rd_data_b)
    );

    // --------------------------------------------------------
    // Clock generation — 10ns period (100MHz)
    // --------------------------------------------------------
    initial clk = 0;
    always #5 clk = ~clk;

    // --------------------------------------------------------
    // Test infrastructure
    // --------------------------------------------------------
    integer pass_count = 0;
    integer fail_count = 0;

    task check_port_a(
        input string    test_name,
        input [31:0]    expected
    );
        if (rd_data_a === expected) begin
            $display("  PASS  %-40s  rd_data_a=%08h", test_name, rd_data_a);
            pass_count++;
        end else begin
            $display("  FAIL  %-40s  rd_data_a=%08h (expected %08h)",
                     test_name, rd_data_a, expected);
            fail_count++;
        end
    endtask

    task check_port_b(
        input string    test_name,
        input [31:0]    expected
    );
        if (rd_data_b === expected) begin
            $display("  PASS  %-40s  rd_data_b=%08h", test_name, rd_data_b);
            pass_count++;
        end else begin
            $display("  FAIL  %-40s  rd_data_b=%08h (expected %08h)",
                     test_name, rd_data_b, expected);
            fail_count++;
        end
    endtask

    task write_reg(
        input [4:0]  addr,
        input [31:0] data
    );
        @(negedge clk);   // drive at negedge — settled before next posedge captures
        wr_en   = 1'b1;
        wr_addr = addr;
        wr_data = data;
        @(negedge clk);   // wait one full cycle, then deassert
        wr_en   = 1'b0;
    endtask

    // --------------------------------------------------------
    // Test sequence
    // --------------------------------------------------------
    initial begin
        $display("============================================");
        $display(" RV32I Register File — Directed Test Suite");
        $display("============================================");

        // Initialize inputs
        wr_en     = 1'b0;
        wr_addr   = 5'b0;
        wr_data   = 32'b0;
        rd_addr_a = 5'b0;
        rd_addr_b = 5'b0;

        // ---- Test 1: Reset clears all registers ----
        $display("\n--- Test 1: Reset ---");
        rst_n = 1'b0;
        @(posedge clk);
        @(posedge clk);
        rst_n = 1'b1;
        @(negedge clk); // sample after reset deasserts

        rd_addr_a = 5'd0;  #1; check_port_a("x0 after reset",  32'b0);
        rd_addr_a = 5'd1;  #1; check_port_a("x1 after reset",  32'b0);
        rd_addr_a = 5'd31; #1; check_port_a("x31 after reset", 32'b0);

        // ---- Test 2: x0 always reads zero ----
        $display("\n--- Test 2: x0 hardwired to zero ---");
        write_reg(5'd0, 32'hDEADBEEF);
        rd_addr_a = 5'd0; #1;
        check_port_a("x0 after write attempt", 32'b0);

        // ---- Test 3: Basic write then read ----
        $display("\n--- Test 3: Basic write/read ---");
        write_reg(5'd1, 32'hCAFEBABE);
        rd_addr_a = 5'd1; #1;
        check_port_a("x1 = 0xCAFEBABE", 32'hCAFEBABE);

        write_reg(5'd2, 32'h12345678);
        rd_addr_a = 5'd2; #1;
        check_port_a("x2 = 0x12345678", 32'h12345678);

        // ---- Test 4: Both read ports simultaneously ----
        $display("\n--- Test 4: Dual read ports ---");
        rd_addr_a = 5'd1;
        rd_addr_b = 5'd2;
        #1;
        check_port_a("port A reads x1", 32'hCAFEBABE);
        check_port_b("port B reads x2", 32'h12345678);

        // Same register on both ports
        rd_addr_a = 5'd1;
        rd_addr_b = 5'd1;
        #1;
        check_port_a("port A reads x1 (dup)", 32'hCAFEBABE);
        check_port_b("port B reads x1 (dup)", 32'hCAFEBABE);

        // ---- Test 5: Write-enable gating ----
        $display("\n--- Test 5: Write-enable gating ---");
        // Attempt write with wr_en=0 — drive at negedge so posedge sees settled inputs
        @(negedge clk);
        wr_en   = 1'b0;
        wr_addr = 5'd1;
        wr_data = 32'hFFFFFFFF;
        @(negedge clk);
        rd_addr_a = 5'd1; #1;
        check_port_a("x1 unchanged (wr_en=0)", 32'hCAFEBABE);

        // ---- Test 6: Read-during-write returns old value ----
        $display("\n--- Test 6: Read-during-write ---");
        // Set up: give x3 a known value first
        write_reg(5'd3, 32'hAAAAAAAA);

        // Drive write stimulus at negedge — inputs settled before posedge captures.
        // The combinational read sees the old FF value (0xAAAAAAAA) until the
        // posedge actually clocks in 0xBBBBBBBB.
        @(negedge clk);
        wr_en     = 1'b1;
        wr_addr   = 5'd3;
        wr_data   = 32'hBBBBBBBB;
        rd_addr_a = 5'd3;
        #1;
        check_port_a("x3 old value during write", 32'hAAAAAAAA);
        // Now let the posedge capture the write, then deassert
        @(negedge clk);
        wr_en = 1'b0;
        #1;
        check_port_a("x3 new value after write", 32'hBBBBBBBB);

        // ---- Test 7: Write all registers, read back ----
        $display("\n--- Test 7: All 31 registers ---");
        for (int i = 1; i < 32; i++) begin
            write_reg(i[4:0], {16'hA500, 11'b0, i[4:0]});
        end

        for (int i = 1; i < 32; i++) begin
            rd_addr_a = i[4:0]; #1;
            check_port_a($sformatf("x%0d readback", i),
                         {16'hA500, 11'b0, i[4:0]});
        end

        // Confirm x0 still zero after all that
        rd_addr_a = 5'd0; #1;
        check_port_a("x0 still zero", 32'b0);

        // --------------------------------------------------------
        // Summary
        // --------------------------------------------------------
        $display("\n============================================");
        $display(" Results: %0d passed, %0d failed", pass_count, fail_count);
        $display("============================================");

        if (fail_count == 0)
            $display(" ALL TESTS PASSED");
        else
            $display(" SOME TESTS FAILED — review above");

        $finish;
    end

endmodule
