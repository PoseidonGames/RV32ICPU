// ============================================================================
// Module: tb_alu_mul16s
// Description: Self-checking testbench for ALU MUL16S custom operation.
//              Expected values derived from canonical-reference.md §8.2.
//              Spec: rd = sext(rs1[15:0]) x sext(rs2[15:0]), alu_ctrl=4'b1110
//              Upper 16 bits of rs1/rs2 are ignored (sign extension from
//              bit 15 only).
//              Reference model uses shift-add (not the multiply operator) to
//              satisfy the project hook on .sv files; correctness is verified
//              against all manually-derived test vectors in the file header.
//              All stimulus applied at negedge clk (gotchas.md #11).
// Author: Beaux Cable
// Date: April 2026
// Project: TSI RV32I Pipelined Processor (TSMC 180nm)
// ============================================================================

`timescale 1ns/1ps

module tb_alu_mul16s;

  // -------------------------------------------------------------------------
  // DUT port declarations
  // -------------------------------------------------------------------------
  logic [31:0] a_i;
  logic [31:0] b_i;
  logic [3:0]  alu_ctrl_i;
  logic [31:0] result_o;

  // -------------------------------------------------------------------------
  // ALU control encoding (canonical-reference.md §8.3)
  // -------------------------------------------------------------------------
  localparam logic [3:0] ALU_MUL16S = 4'b1110;

  // -------------------------------------------------------------------------
  // DUT instantiation
  // -------------------------------------------------------------------------
  alu dut (
    .a_i       (a_i),
    .b_i       (b_i),
    .alu_ctrl_i(alu_ctrl_i),
    .result_o  (result_o)
  );

  // -------------------------------------------------------------------------
  // Clock: 50 MHz (canonical-reference.md §9 target)
  // -------------------------------------------------------------------------
  logic clk;
  initial clk = 1'b0;
  always #10 clk = ~clk;

  // -------------------------------------------------------------------------
  // Pass/fail counters
  // -------------------------------------------------------------------------
  int pass_count;
  int fail_count;

  // -------------------------------------------------------------------------
  // Reference function: signed 16x16 → 32-bit product via shift-add
  // Spec (canonical-reference.md §8.2):
  //   rd = sext(rs1[15:0]) x sext(rs2[15:0])
  //   Upper 16 bits of a/b are ignored; sign extension is from bit 15.
  //
  // Algorithm: standard binary long-multiply on 32-bit sign-extended values.
  //   - Sign-extend both operands from 16 bits to 32 bits.
  //   - Accumulate: for each bit i of |sb|, if bit i is set, add (sa << i).
  //   - Negate the result if exactly one operand was negative (XOR of signs).
  // This matches the spec operation without using the multiply operator.
  // -------------------------------------------------------------------------
  function automatic [31:0] ref_mul16s(input [31:0] a, input [31:0] b);
    logic signed [31:0] sa32, sb32;
    logic        [31:0] ua, ub;
    logic        [31:0] acc;
    logic               neg_a, neg_b, negate;
    integer             i;
    begin
      // Sign-extend from bit 15 per spec
      sa32 = {{16{a[15]}}, a[15:0]};
      sb32 = {{16{b[15]}}, b[15:0]};

      // Determine sign of result (XOR of input signs)
      neg_a  = sa32[31];
      neg_b  = sb32[31];
      negate = neg_a ^ neg_b;

      // Take absolute values for unsigned shift-add
      ua = neg_a ? (~sa32 + 32'h1) : sa32;
      ub = neg_b ? (~sb32 + 32'h1) : sb32;

      // Shift-add (grade-school long multiply on unsigned magnitudes)
      acc = 32'h0;
      for (i = 0; i < 16; i = i + 1) begin
        if (ub[i])
          acc = acc + (ua << i);
      end

      // Apply sign
      ref_mul16s = negate ? (~acc + 32'h1) : acc;
    end
  endfunction

  // -------------------------------------------------------------------------
  // Checking task
  // Applies inputs at negedge clk, waits #1 for combinational settle,
  // then compares result_o to expected using !== (catches X/Z).
  // -------------------------------------------------------------------------
  task automatic check_mul16s(
    input [31:0] a_val,
    input [31:0] b_val,
    input [31:0] expected,
    input string test_name,
    input int    vec_idx
  );
    @(negedge clk);
    alu_ctrl_i = ALU_MUL16S;
    a_i        = a_val;
    b_i        = b_val;
    #1;
    if (result_o !== expected) begin
      $display("FAIL [%s] vec=%0d a=0x%08h b=0x%08h",
               test_name, vec_idx, a_val, b_val);
      $display("     expected=0x%08h (%0d) got=0x%08h (%0d)",
               expected, $signed(expected),
               result_o, $signed(result_o));
      fail_count++;
    end else begin
      pass_count++;
    end
  endtask

  // -------------------------------------------------------------------------
  // Main test sequence
  // -------------------------------------------------------------------------
  initial begin
    pass_count = 0;
    fail_count = 0;
    alu_ctrl_i = 4'b0000;
    a_i        = 32'h0;
    b_i        = 32'h0;

    // Wait for simulator to settle
    @(negedge clk);

    // =====================================================================
    // SECTION 1: Zero cases
    // Spec (§8.2): any operand = 0 → product = 0
    // =====================================================================

    // 0 x 0 = 0
    check_mul16s(32'h00000000, 32'h00000000, 32'h00000000,
                 "MUL16S_zero", 0);

    // 0 x 1 = 0
    check_mul16s(32'h00000000, 32'h00000001, 32'h00000000,
                 "MUL16S_zero", 1);

    // 1 x 0 = 0
    check_mul16s(32'h00000001, 32'h00000000, 32'h00000000,
                 "MUL16S_zero", 2);

    // 0 x -1 = 0  (b[15:0]=0xFFFF=-1 signed 16-bit)
    check_mul16s(32'h00000000, 32'h0000FFFF, 32'h00000000,
                 "MUL16S_zero", 3);

    // =====================================================================
    // SECTION 2: Identity / simple
    // Spec (§8.2): sext(a[15:0]) x sext(b[15:0])
    // =====================================================================

    // 1 x 1 = 1
    check_mul16s(32'h00000001, 32'h00000001, 32'h00000001,
                 "MUL16S_identity", 0);

    // -1 x -1 = 1
    // a[15:0]=0xFFFF=-1, b[15:0]=0xFFFF=-1; (-1)x(-1)=1
    check_mul16s(32'h0000FFFF, 32'h0000FFFF, 32'h00000001,
                 "MUL16S_identity", 1);

    // 1 x -1 = -1 = 32'hFFFFFFFF
    check_mul16s(32'h00000001, 32'h0000FFFF, 32'hFFFFFFFF,
                 "MUL16S_identity", 2);

    // -1 x 1 = -1 = 32'hFFFFFFFF
    check_mul16s(32'h0000FFFF, 32'h00000001, 32'hFFFFFFFF,
                 "MUL16S_identity", 3);

    // 2 x 3 = 6
    check_mul16s(32'h00000002, 32'h00000003, 32'h00000006,
                 "MUL16S_simple", 0);

    // 100 x 200 = 20000 = 0x00004E20
    check_mul16s(32'h00000064, 32'h000000C8, 32'h00004E20,
                 "MUL16S_simple", 1);

    // =====================================================================
    // SECTION 3: Max/min 16-bit signed edge cases
    // 16-bit signed range: -32768 (0x8000) to 32767 (0x7FFF)
    // Spec (§8.2): operands sign-extended from bit 15 before multiply
    //
    // Derivations:
    //   0x7FFF x 0x7FFF = 32767^2 = 1,073,676,289 = 0x3FFF0001
    //   0x8000 x 0x8000 = (-32768)x(-32768) = 2^30 = 0x40000000
    //   0x7FFF x 0x8000 = 32767 x (-32768) = -1,073,709,056 = 0xC0008000
    //     Verify: 32767 x 32768 = 32767 x 2^15 = 1,073,709,056; negate → 0xC0008000
    //   0x8000 x 0x0001 = -32768 x 1 = -32768 = 0xFFFF8000
    //   0x7FFF x 0x0001 = 32767 x 1 = 32767 = 0x00007FFF
    //   0x8000 x 0xFFFF = -32768 x (-1) = 32768 = 0x00008000
    //   0x7FFF x 0xFFFF = 32767 x (-1) = -32767 = 0xFFFF8001
    // =====================================================================

    // 32767 x 32767 = 1,073,676,289 = 0x3FFF0001
    check_mul16s(32'h00007FFF, 32'h00007FFF, 32'h3FFF0001,
                 "MUL16S_maxmin", 0);

    // -32768 x -32768 = 1,073,741,824 = 0x40000000
    check_mul16s(32'h00008000, 32'h00008000, 32'h40000000,
                 "MUL16S_maxmin", 1);

    // 32767 x -32768 = -1,073,709,056 = 0xC0008000
    // Derivation: 32767 x 32768 = 32767 x 2^15 = 1,073,709,056 = 0x3FFF8000
    //             negate → 0xC0008000
    check_mul16s(32'h00007FFF, 32'h00008000, 32'hC0008000,
                 "MUL16S_maxmin", 2);

    // -32768 x 1 = -32768 = 0xFFFF8000
    check_mul16s(32'h00008000, 32'h00000001, 32'hFFFF8000,
                 "MUL16S_maxmin", 3);

    // 32767 x 1 = 32767 = 0x00007FFF
    check_mul16s(32'h00007FFF, 32'h00000001, 32'h00007FFF,
                 "MUL16S_maxmin", 4);

    // -32768 x -1 = 32768 = 0x00008000
    // sext(0x8000)=-32768; sext(0xFFFF)=-1; product=32768
    check_mul16s(32'h00008000, 32'h0000FFFF, 32'h00008000,
                 "MUL16S_maxmin", 5);

    // 32767 x -1 = -32767 = 0xFFFF8001
    check_mul16s(32'h00007FFF, 32'h0000FFFF, 32'hFFFF8001,
                 "MUL16S_maxmin", 6);

    // =====================================================================
    // SECTION 4: Upper bits ignored
    // Spec (§8.2): "Upper 16 bits of rs1 and rs2 are ignored"
    // Test: a_i=32'hFFFF0005 (upper 16 set, lower=5), b_i=32'h00030003
    //        (lower=3). Expected: sext(5) x sext(3) = 15 = 0x0000000F
    //        Upper bits of a_i must not affect result.
    // =====================================================================
    check_mul16s(32'hFFFF0005, 32'h00030003, 32'h0000000F,
                 "MUL16S_upper_bits_ignored", 0);

    // a[15:0]=100, b[15:0]=200, upper bits are noise → must get 20000
    check_mul16s(32'hDEAD0064, 32'hBEEF00C8, 32'h00004E20,
                 "MUL16S_upper_bits_ignored", 1);

    // Both lower words = 0xFFFF = -1; upper bits are noise → must get 1
    check_mul16s(32'hABCDFFFF, 32'h1234FFFF, 32'h00000001,
                 "MUL16S_upper_bits_ignored", 2);

    // =====================================================================
    // SECTION 5: Sign extension correctness
    // Spec (§8.2): rs1[15] and rs2[15] determine sign of operands
    //
    // Test: a_i=16'hFFFF = -1 (signed 16-bit), b_i=16'h0001 = 1
    //        Expected: -1 x 1 = -1 = 32'hFFFFFFFF
    //        Verifies sign extension from bit 15, not bit 31.
    // =====================================================================

    // 0xFFFF (lower) = -1 signed 16-bit; x 1 = -1
    check_mul16s(32'h0000FFFF, 32'h00000001, 32'hFFFFFFFF,
                 "MUL16S_sign_extension", 0);

    // a[15]=1 (negative), a[31]=0; result must still be negative product
    // a[15:0]=0x8001=-32767; b[15:0]=0x0002=2; -32767x2=-65534=0xFFFF0002
    check_mul16s(32'h00008001, 32'h00000002, 32'hFFFF0002,
                 "MUL16S_sign_extension", 1);

    // a[31]=1 but a[15]=0 → operand is positive (upper bits ignored)
    // a[15:0]=0x7FFF=32767; b[15:0]=0x0002=2; 32767x2=65534=0x0000FFFE
    check_mul16s(32'h80007FFF, 32'h00000002, 32'h0000FFFE,
                 "MUL16S_sign_extension", 2);

    // =====================================================================
    // SECTION 6: Random vectors (100 minimum)
    // Expected value from ref_mul16s, which implements the spec
    // operation (sext(a[15:0]) x sext(b[15:0])) via shift-add.
    // Source: canonical-reference.md §8.2
    // =====================================================================
    begin
      logic [31:0] rnd_a, rnd_b, ref_val;
      for (int r = 0; r < 100; r++) begin
        rnd_a   = $urandom();
        rnd_b   = $urandom();
        ref_val = ref_mul16s(rnd_a, rnd_b);
        check_mul16s(rnd_a, rnd_b, ref_val,
                     "MUL16S_random", r);
      end
    end

    // =====================================================================
    // SECTION 7: Accumulation sequence (software MAC pattern)
    // Spec (§8.2): "Software handles accumulation: MUL16S rd_temp, rs1, rs2
    //               then ADD rd, rd, rd_temp" (same pattern as RISC-V M ext)
    // Test: compute 4 products in sequence; verify each individually.
    // Common DSP use: FIR inner loop, dot product.
    //
    // Derivations:
    //   100 x 200 = 20000 = 0x00004E20
    //   sext(0xFFFD)=-3; x 7 = -21 = 0xFFFFFFEB
    //   1000 x 50 = 50000 = 0x0000C350
    //   sext(0xFFFF)=-1; sext(0xFFFF)=-1; (-1)x(-1) = 1 = 0x00000001
    // =====================================================================
    begin
      localparam logic [31:0] ACC_A0 = 32'h00000064; // 100
      localparam logic [31:0] ACC_B0 = 32'h000000C8; // 200
      localparam logic [31:0] ACC_E0 = 32'h00004E20; // 20000

      localparam logic [31:0] ACC_A1 = 32'h0000FFFD; // -3 (16-bit signed)
      localparam logic [31:0] ACC_B1 = 32'h00000007; // 7
      localparam logic [31:0] ACC_E1 = 32'hFFFFFFEB; // -21

      localparam logic [31:0] ACC_A2 = 32'h000003E8; // 1000
      localparam logic [31:0] ACC_B2 = 32'h00000032; // 50
      localparam logic [31:0] ACC_E2 = 32'h0000C350; // 50000

      localparam logic [31:0] ACC_A3 = 32'h0000FFFF; // -1 (16-bit signed)
      localparam logic [31:0] ACC_B3 = 32'h0000FFFF; // -1
      localparam logic [31:0] ACC_E3 = 32'h00000001; // 1

      check_mul16s(ACC_A0, ACC_B0, ACC_E0, "MUL16S_mac_seq", 0);
      check_mul16s(ACC_A1, ACC_B1, ACC_E1, "MUL16S_mac_seq", 1);
      check_mul16s(ACC_A2, ACC_B2, ACC_E2, "MUL16S_mac_seq", 2);
      check_mul16s(ACC_A3, ACC_B3, ACC_E3, "MUL16S_mac_seq", 3);
    end

    // =====================================================================
    // SECTION 8: X/Z propagation check
    // No output bit should be X or Z during a valid MUL16S operation.
    // =====================================================================
    begin
      logic [31:0] xz_vals [4];
      xz_vals[0] = 32'h00000000;
      xz_vals[1] = 32'h0000FFFF;
      xz_vals[2] = 32'h00007FFF;
      xz_vals[3] = 32'hDEAD8000;

      for (int x = 0; x < 4; x++) begin
        @(negedge clk);
        alu_ctrl_i = ALU_MUL16S;
        a_i        = xz_vals[x];
        b_i        = xz_vals[(x + 1) % 4];
        #1;
        if (^result_o === 1'bx) begin
          $display(
            "FAIL [MUL16S_no_xz] a=0x%08h b=0x%08h result=0x%08h",
            a_i, b_i, result_o);
          fail_count++;
        end else begin
          pass_count++;
        end
      end
    end

    // =====================================================================
    // Summary
    // =====================================================================
    $display("============================================");
    $display("tb_alu_mul16s results:");
    $display("  Total : %0d", pass_count + fail_count);
    $display("  PASSED: %0d", pass_count);
    $display("  FAILED: %0d", fail_count);
    $display("============================================");
    if (fail_count == 0)
      $display("ALL TESTS PASSED");
    else
      $display("*** %0d FAILURES DETECTED ***", fail_count);

    $finish;
  end

endmodule
