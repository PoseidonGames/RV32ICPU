// ============================================================
// ALU Testbench — Directed Tests
// ============================================================
// Tests each ALU operation with known inputs/outputs.
// Run this to verify correctness before pushing through
// synthesis and P&R.
//
// Usage (with Synopsys VCS):
//   vcs -sverilog alu.sv alu_tb.sv -o alu_sim
//   ./alu_sim
//
// Usage (with Icarus Verilog, if available):
//   iverilog -g2012 -o alu_sim alu.sv alu_tb.sv
//   ./alu_sim
// ============================================================

module alu_tb;

    logic [31:0] a_i, b_i, result_o;
    logic [3:0]  alu_ctrl_i;

    // Instantiate the ALU
    alu dut (
        .a_i        (a_i),
        .b_i        (b_i),
        .alu_ctrl_i (alu_ctrl_i),
        .result_o   (result_o)
    );

    // --------------------------------------------------------
    // Test helper: check result against expected value
    // --------------------------------------------------------
    integer pass_count = 0;
    integer fail_count = 0;

    task check(
        input string    op_name,
        input [31:0]    expected
    );
        #1; // let combinational logic settle
        if (result_o === expected) begin
            $display("  PASS  %-5s  a=%08h  b=%08h  result=%08h",
                     op_name, a_i, b_i, result_o);
            pass_count++;
        end else begin
            $display("  FAIL  %-5s  a=%08h  b=%08h  result=%08h (expected %08h)",
                     op_name, a_i, b_i, result_o, expected);
            fail_count++;
        end
    endtask

    // --------------------------------------------------------
    // Test sequence
    // --------------------------------------------------------
    initial begin
        $display("============================================");
        $display(" RV32I ALU — Directed Test Suite");
        $display("============================================");

        // --- ADD (4'b0000) ---
        $display("\n--- ADD ---");
        alu_ctrl_i = 4'b0000;

        a_i = 32'd10;       b_i = 32'd20;       check("ADD", 32'd30);
        a_i = 32'd0;        b_i = 32'd0;        check("ADD", 32'd0);        // zero flag test
        a_i = 32'hFFFFFFFF; b_i = 32'd1;        check("ADD", 32'd0);        // overflow wraps
        a_i = 32'h7FFFFFFF; b_i = 32'd1;        check("ADD", 32'h80000000); // positive overflow

        // --- SUB (4'b0001) ---
        $display("\n--- SUB ---");
        alu_ctrl_i = 4'b0001;

        a_i = 32'd30;       b_i = 32'd10;       check("SUB", 32'd20);
        a_i = 32'd10;       b_i = 32'd10;       check("SUB", 32'd0);        // zero flag test
        a_i = 32'd0;        b_i = 32'd1;        check("SUB", 32'hFFFFFFFF); // underflow wraps

        // --- AND (4'b0010) ---
        $display("\n--- AND ---");
        alu_ctrl_i = 4'b0010;

        a_i = 32'hFF00FF00; b_i = 32'h0F0F0F0F; check("AND", 32'h0F000F00);
        a_i = 32'hFFFFFFFF; b_i = 32'h00000000; check("AND", 32'h00000000);

        // --- OR (4'b0011) ---
        $display("\n--- OR ---");
        alu_ctrl_i = 4'b0011;

        a_i = 32'hFF00FF00; b_i = 32'h0F0F0F0F; check("OR", 32'hFF0FFF0F);
        a_i = 32'h00000000; b_i = 32'h00000000; check("OR", 32'h00000000); // zero flag

        // --- XOR (4'b0100) ---
        $display("\n--- XOR ---");
        alu_ctrl_i = 4'b0100;

        a_i = 32'hFF00FF00; b_i = 32'hFF00FF00; check("XOR", 32'h00000000); // same = zero
        a_i = 32'hAAAAAAAA; b_i = 32'h55555555; check("XOR", 32'hFFFFFFFF);

        // --- SLT signed (4'b0101) ---
        $display("\n--- SLT ---");
        alu_ctrl_i = 4'b0101;

        a_i = 32'd5;              b_i = 32'd10;             check("SLT", 32'd1);  // 5 < 10
        a_i = 32'd10;             b_i = 32'd5;              check("SLT", 32'd0);  // 10 >= 5
        a_i = 32'hFFFFFFFF;       b_i = 32'd1;              check("SLT", 32'd1);  // -1 < 1 (signed)
        a_i = 32'd1;              b_i = 32'hFFFFFFFF;       check("SLT", 32'd0);  // 1 >= -1 (signed)

        // --- SLTU unsigned (4'b0110) ---
        $display("\n--- SLTU ---");
        alu_ctrl_i = 4'b0110;

        a_i = 32'd5;              b_i = 32'd10;             check("SLTU", 32'd1); // 5 < 10
        a_i = 32'hFFFFFFFF;       b_i = 32'd1;              check("SLTU", 32'd0); // 0xFFFFFFFF > 1 unsigned
        a_i = 32'd1;              b_i = 32'hFFFFFFFF;       check("SLTU", 32'd1); // 1 < 0xFFFFFFFF unsigned

        // --- SLL (4'b0111) ---
        $display("\n--- SLL ---");
        alu_ctrl_i = 4'b0111;

        a_i = 32'd1;              b_i = 32'd4;              check("SLL", 32'd16);       // 1 << 4
        a_i = 32'h80000001;       b_i = 32'd1;              check("SLL", 32'h00000002); // high bit shifts out

        // --- SRL (4'b1000) ---
        $display("\n--- SRL ---");
        alu_ctrl_i = 4'b1000;

        a_i = 32'd16;             b_i = 32'd4;              check("SRL", 32'd1);        // 16 >> 4
        a_i = 32'h80000000;       b_i = 32'd1;              check("SRL", 32'h40000000); // logical: zero-fills

        // --- SRA (4'b1001) ---
        $display("\n--- SRA ---");
        alu_ctrl_i = 4'b1001;

        a_i = 32'h80000000;       b_i = 32'd1;              check("SRA", 32'hC0000000); // arithmetic: sign-extends
        a_i = 32'h40000000;       b_i = 32'd1;              check("SRA", 32'h20000000); // positive: same as SRL
        a_i = 32'hFFFFFF00;       b_i = 32'd4;              check("SRA", 32'hFFFFFFF0); // negative, shift 4

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
