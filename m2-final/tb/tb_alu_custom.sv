// ============================================================================
// Module: tb_alu_custom
// Description: Self-checking testbench for ALU POPCOUNT and BREV custom
//              operations. Expected values derived from
//              canonical-reference.md §8.1 and m2a-verification-plan.md §2.
//              All stimulus applied at negedge clk (gotchas.md #11).
// Author: Beaux Cable
// Date: April 2026
// Project: RV32I Pipelined Processor
// ============================================================================

`timescale 1ns/1ps

module tb_alu_custom;

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
  localparam logic [3:0] ALU_POPCOUNT = 4'b1010;
  localparam logic [3:0] ALU_BREV     = 4'b1011;
  localparam logic [3:0] ALU_CLZ      = 4'b1111;

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
  // Clock: 50 MHz (canonical-reference.md 50 MHz target)
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
  // Reference functions (m2a-verification-plan.md §6.3)
  // No `*` operator used (conventions.md synthesizability rules)
  // -------------------------------------------------------------------------

  // POPCOUNT reference: count 1-bits in val, result 0-32 (6-bit range)
  // Source: m2a-verification-plan.md §6.3
  function automatic [5:0] ref_popcount(input [31:0] val);
    ref_popcount = '0;
    for (int i = 0; i < 32; i++)
      ref_popcount = ref_popcount + {5'b0, val[i]};
  endfunction

  // BREV reference: result[i] = val[31-i] for i=0..31
  // Source: canonical-reference.md §8.1, m2a-verification-plan.md §6.3
  function automatic [31:0] ref_brev(input [31:0] val);
    for (int i = 0; i < 32; i++)
      ref_brev[i] = val[31-i];
  endfunction

  // CLZ reference: scan from bit 31 down to 0; return position of first 1-bit
  // expressed as (31 - i). Default 32 when no bit is set.
  // Source: canonical-reference.md §8.1 — "Scans from bit 31 down.
  //   Result 0-32. Result = 32 when rs1=0. Result = 0 when rs1[31]=1."
  // Note: uses found flag instead of disable (iverilog does not support
  //   disable inside functions).
  function automatic [5:0] ref_clz(input [31:0] val);
    integer i;
    reg     found;
    begin
      ref_clz = 6'd32; // default: all zeros → 32 leading zeros
      found   = 1'b0;
      for (i = 31; i >= 0; i = i - 1) begin
        if (!found && val[i]) begin
          ref_clz = 6'(31 - i);
          found   = 1'b1;
        end
      end
    end
  endfunction

  // -------------------------------------------------------------------------
  // Checking tasks
  // -------------------------------------------------------------------------

  // Check POPCOUNT result (expected is 6-bit count, zero-extended to 32)
  // canonical-reference.md §8.1: result 0-32, zero-extended to 32 bits
  task automatic check_popcount(
    input [31:0] a_val,
    input [31:0] b_val,
    input [5:0]  expected_count,
    input string test_name,
    input int    vec_idx
  );
    logic [31:0] expected;
    expected = {26'h0, expected_count};
    @(negedge clk);
    alu_ctrl_i = ALU_POPCOUNT;
    a_i        = a_val;
    b_i        = b_val;
    #1;
    if (result_o !== expected) begin
      $display("FAIL [%s] vec=%0d a=0x%08h b=0x%08h",
               test_name, vec_idx, a_val, b_val);
      $display("     expected=0x%08h (count=%0d) got=0x%08h",
               expected, expected_count, result_o);
      fail_count++;
    end else begin
      pass_count++;
    end
  endtask

  // Check CLZ result (expected is 6-bit count 0-32, zero-extended to 32 bits)
  // canonical-reference.md §8.1: result 0-32, zero-extended to 32 bits
  task automatic check_clz(
    input [31:0] a_val,
    input [5:0]  expected_count,
    input string test_name,
    input int    vec_idx
  );
    logic [31:0] expected;
    expected = {26'h0, expected_count};
    @(negedge clk);
    alu_ctrl_i = ALU_CLZ;
    a_i        = a_val;
    b_i        = 32'h0; // rs2 ignored per spec
    #1;
    if (result_o !== expected) begin
      $display("FAIL [%s] vec=%0d a=0x%08h",
               test_name, vec_idx, a_val);
      $display("     expected=0x%08h (count=%0d) got=0x%08h",
               expected, expected_count, result_o);
      fail_count++;
    end else begin
      pass_count++;
    end
  endtask

  // Check BREV result
  task automatic check_brev(
    input [31:0] a_val,
    input [31:0] b_val,
    input [31:0] expected,
    input string test_name,
    input int    vec_idx
  );
    @(negedge clk);
    alu_ctrl_i = ALU_BREV;
    a_i        = a_val;
    b_i        = b_val;
    #1;
    if (result_o !== expected) begin
      $display("FAIL [%s] vec=%0d a=0x%08h b=0x%08h",
               test_name, vec_idx, a_val, b_val);
      $display("     expected=0x%08h got=0x%08h",
               expected, result_o);
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
    // SECTION 1: POPCOUNT tests
    // Expected values from m2a-verification-plan.md §2.1
    // Spec: popcount(a_i) = count of 1-bits, result zero-extended to 32
    // canonical-reference.md §8.1
    // =====================================================================

    // --- 1.1 Zero ---
    // Input: 0x00000000, no bits set → count = 0
    check_popcount(32'h00000000, 32'h0, 6'd0,
                   "POPCOUNT_zero", 0);

    // --- 1.2 All ones ---
    // Input: 0xFFFFFFFF, all 32 bits set → count = 32
    check_popcount(32'hFFFFFFFF, 32'h0, 6'd32,
                   "POPCOUNT_all_ones", 0);

    // --- 1.3 Single bit set: (1 << i) → count = 1 for i = 0..31 ---
    // Each input has exactly one 1-bit → count = 1
    for (int i = 0; i < 32; i++) begin
      check_popcount(32'h1 << i, 32'h0, 6'd1,
                     "POPCOUNT_single_bit_set", i);
    end

    // --- 1.4 Single bit clear: ~(1 << i) → count = 31 for i = 0..31 ---
    // Each input has 31 bits set → count = 31
    for (int i = 0; i < 32; i++) begin
      check_popcount(~(32'h1 << i), 32'h0, 6'd31,
                     "POPCOUNT_single_bit_clear", i);
    end

    // --- 1.5 Alternating patterns ---
    // 0x55555555 = 0101...0101 → 16 ones
    check_popcount(32'h55555555, 32'h0, 6'd16,
                   "POPCOUNT_alternating", 0);
    // 0xAAAAAAAA = 1010...1010 → 16 ones
    check_popcount(32'hAAAAAAAA, 32'h0, 6'd16,
                   "POPCOUNT_alternating", 1);

    // --- 1.6 Byte patterns: each has 8 ones ---
    check_popcount(32'h000000FF, 32'h0, 6'd8,
                   "POPCOUNT_byte_pattern", 0);
    check_popcount(32'h0000FF00, 32'h0, 6'd8,
                   "POPCOUNT_byte_pattern", 1);
    check_popcount(32'h00FF0000, 32'h0, 6'd8,
                   "POPCOUNT_byte_pattern", 2);
    check_popcount(32'hFF000000, 32'h0, 6'd8,
                   "POPCOUNT_byte_pattern", 3);

    // --- 1.7 Ascending count: (1 << n) - 1 for n = 1..32 → n ones ---
    // (1<<n)-1 has exactly n bits set in positions [n-1:0]
    // n=32: (1<<32)-1 overflows 32-bit → 0xFFFFFFFF = 32 ones
    for (int n = 1; n <= 31; n++) begin
      check_popcount((32'h1 << n) - 32'h1, 32'h0, n[5:0],
                     "POPCOUNT_ascending", n);
    end
    // n=32: all 32 bits set
    check_popcount(32'hFFFFFFFF, 32'h0, 6'd32,
                   "POPCOUNT_ascending", 32);

    // --- 1.8 Sparse values ---
    // 0x80000001: bits 31 and 0 set → count = 2
    check_popcount(32'h80000001, 32'h0, 6'd2,
                   "POPCOUNT_sparse", 0);
    // 0x00010001: bits 16 and 0 set → count = 2
    check_popcount(32'h00010001, 32'h0, 6'd2,
                   "POPCOUNT_sparse", 1);

    // --- 1.9 Random: 1000 random 32-bit values vs ref_popcount ---
    // ref_popcount is the spec model per m2a-verification-plan.md §6.3
    begin
      logic [31:0] rnd_val;
      logic [5:0]  ref_cnt;
      for (int r = 0; r < 1000; r++) begin
        rnd_val = $urandom();
        ref_cnt = ref_popcount(rnd_val);
        check_popcount(rnd_val, 32'h0, ref_cnt,
                       "POPCOUNT_random", r);
      end
    end

    // =====================================================================
    // SECTION 2: BREV tests
    // Expected values from m2a-verification-plan.md §2.2
    // Spec: result[i] = a_i[31-i] for i = 0..31
    // canonical-reference.md §8.1
    // =====================================================================

    // --- 2.1 Zero → zero ---
    check_brev(32'h00000000, 32'h0, 32'h00000000,
               "BREV_zero", 0);

    // --- 2.2 All ones → all ones ---
    check_brev(32'hFFFFFFFF, 32'h0, 32'hFFFFFFFF,
               "BREV_all_ones", 0);

    // --- 2.3 Single bit: (1 << i) → (1 << (31-i)) for i = 0..31 ---
    // Bit i moves to position 31-i after reversal
    for (int i = 0; i < 32; i++) begin
      check_brev(32'h1 << i, 32'h0, 32'h1 << (31-i),
                 "BREV_single_bit", i);
    end

    // --- 2.4 Palindromes (self-reversal) ---
    // 0x81818181 reversed is itself (verified manually: each nibble-pair
    // is symmetric, and the full 32-bit pattern is bit-symmetric)
    // ref: m2a-verification-plan.md §2.2 palindromes row
    check_brev(32'h81818181, 32'h0, 32'h81818181,
               "BREV_palindrome", 0);
    check_brev(32'hFF0000FF, 32'h0, 32'hFF0000FF,
               "BREV_palindrome", 1);

    // --- 2.5 Non-palindrome ---
    // 0x0000000F = 0000...00001111 reversed = 1111000...0000 = 0xF0000000
    // ref: m2a-verification-plan.md §2.2
    check_brev(32'h0000000F, 32'h0, 32'hF0000000,
               "BREV_non_palindrome", 0);

    // --- 2.6 Byte reversal check ---
    // 0x12345678 reversed = 0x1E6A2C48
    // Derivation from spec (result[i] = input[31-i]):
    //   0x12345678 = 0001_0010_0011_0100_0101_0110_0111_1000
    //   reversed  = 0001_1110_0110_1010_0010_1100_0100_1000
    //             = 0x1E6A2C48
    // ref: m2a-verification-plan.md §2.2
    check_brev(32'h12345678, 32'h0, 32'h1E6A2C48,
               "BREV_byte_reversal", 0);

    // --- 2.7 MSB/LSB swap ---
    // 0x80000000 = 1 followed by 31 zeros; reversed = 31 zeros + 1
    //           = 0x00000001
    // ref: m2a-verification-plan.md §2.2
    check_brev(32'h80000000, 32'h0, 32'h00000001,
               "BREV_msb_lsb_swap", 0);

    // --- 2.8 Self-inverse property: brev(brev(x)) == x ---
    // 500 random values; apply BREV twice and verify result equals input
    // This tests the involution property explicitly per §2.2 and §5.1
    begin
      logic [31:0] rnd_val;
      logic [31:0] brev1;
      logic [31:0] brev2;
      for (int r = 0; r < 500; r++) begin
        rnd_val = $urandom();
        // First application
        @(negedge clk);
        alu_ctrl_i = ALU_BREV;
        a_i        = rnd_val;
        b_i        = 32'h0;
        #1;
        brev1 = result_o;
        // Second application
        @(negedge clk);
        alu_ctrl_i = ALU_BREV;
        a_i        = brev1;
        b_i        = 32'h0;
        #1;
        brev2 = result_o;
        if (brev2 !== rnd_val) begin
          $display(
            "FAIL [BREV_self_inverse] vec=%0d x=0x%08h",
            r, rnd_val);
          $display(
            "     brev(brev(x))=0x%08h expected=0x%08h",
            brev2, rnd_val);
          fail_count++;
        end else begin
          pass_count++;
        end
      end
    end

    // --- 2.9 Random: 500 random values vs ref_brev ---
    begin
      logic [31:0] rnd_val;
      logic [31:0] ref_val;
      for (int r = 0; r < 500; r++) begin
        rnd_val = $urandom();
        ref_val = ref_brev(rnd_val);
        check_brev(rnd_val, 32'h0, ref_val,
                   "BREV_random", r);
      end
    end

    // =====================================================================
    // SECTION 3: Operand B independence
    // Spec: POPCOUNT and BREV are unary — b_i must not affect result
    // canonical-reference.md §8.1, m2a-verification-plan.md §2.3
    // =====================================================================
    // For 10 random rs1 values, test each with 5 different rs2 values.
    // Verify all 5 results are identical.
    begin
      logic [31:0] rs1_vals [10];
      logic [31:0] rs2_vals [5];
      logic [31:0] baseline_pc;
      logic [31:0] baseline_br;
      logic [31:0] cur_result;

      // Populate rs1 test values (mix of interesting patterns)
      rs1_vals[0] = 32'h00000000;
      rs1_vals[1] = 32'hFFFFFFFF;
      rs1_vals[2] = 32'h55555555;
      rs1_vals[3] = 32'hAAAAAAAA;
      rs1_vals[4] = 32'h12345678;
      rs1_vals[5] = 32'hDEADBEEF;
      rs1_vals[6] = 32'h80000001;
      rs1_vals[7] = 32'h00FF00FF;
      rs1_vals[8] = $urandom();
      rs1_vals[9] = $urandom();

      // Populate rs2 test values (variety of patterns)
      rs2_vals[0] = 32'h00000000;
      rs2_vals[1] = 32'hFFFFFFFF;
      rs2_vals[2] = 32'hA5A5A5A5;
      rs2_vals[3] = 32'h12345678;
      rs2_vals[4] = $urandom();

      for (int s = 0; s < 10; s++) begin
        // --- POPCOUNT: get baseline with rs2=0 ---
        @(negedge clk);
        alu_ctrl_i = ALU_POPCOUNT;
        a_i        = rs1_vals[s];
        b_i        = 32'h0;
        #1;
        baseline_pc = result_o;

        for (int t = 0; t < 5; t++) begin
          @(negedge clk);
          alu_ctrl_i = ALU_POPCOUNT;
          a_i        = rs1_vals[s];
          b_i        = rs2_vals[t];
          #1;
          cur_result = result_o;
          if (cur_result !== baseline_pc) begin
            $display(
              "FAIL [POPCOUNT_b_ignored] rs1=0x%08h rs2=0x%08h",
              rs1_vals[s], rs2_vals[t]);
            $display(
              "     result=0x%08h baseline=0x%08h",
              cur_result, baseline_pc);
            fail_count++;
          end else begin
            pass_count++;
          end
        end

        // --- BREV: get baseline with rs2=0 ---
        @(negedge clk);
        alu_ctrl_i = ALU_BREV;
        a_i        = rs1_vals[s];
        b_i        = 32'h0;
        #1;
        baseline_br = result_o;

        for (int t = 0; t < 5; t++) begin
          @(negedge clk);
          alu_ctrl_i = ALU_BREV;
          a_i        = rs1_vals[s];
          b_i        = rs2_vals[t];
          #1;
          cur_result = result_o;
          if (cur_result !== baseline_br) begin
            $display(
              "FAIL [BREV_b_ignored] rs1=0x%08h rs2=0x%08h",
              rs1_vals[s], rs2_vals[t]);
            $display(
              "     result=0x%08h baseline=0x%08h",
              cur_result, baseline_br);
            fail_count++;
          end else begin
            pass_count++;
          end
        end
      end
    end

    // =====================================================================
    // SECTION 4: X/Z propagation check
    // No output should be X or Z during valid custom operations
    // m2a-verification-plan.md §5.2 criterion 3
    // =====================================================================
    begin
      logic [31:0] xz_vals [4];
      xz_vals[0] = 32'h00000000;
      xz_vals[1] = 32'hFFFFFFFF;
      xz_vals[2] = 32'h55555555;
      xz_vals[3] = 32'hDEADBEEF;

      for (int x = 0; x < 4; x++) begin
        @(negedge clk);
        alu_ctrl_i = ALU_POPCOUNT;
        a_i        = xz_vals[x];
        b_i        = 32'h0;
        #1;
        if (^result_o === 1'bx) begin
          $display(
            "FAIL [POPCOUNT_no_xz] a=0x%08h result=0x%08h",
            xz_vals[x], result_o);
          fail_count++;
        end else begin
          pass_count++;
        end

        @(negedge clk);
        alu_ctrl_i = ALU_BREV;
        a_i        = xz_vals[x];
        b_i        = 32'h0;
        #1;
        if (^result_o === 1'bx) begin
          $display(
            "FAIL [BREV_no_xz] a=0x%08h result=0x%08h",
            xz_vals[x], result_o);
          fail_count++;
        end else begin
          pass_count++;
        end
      end
    end

    // =====================================================================
    // SECTION 5: CLZ tests
    // canonical-reference.md §8.1: alu_ctrl=4'b1111, unary (rs2 ignored).
    // Operation: count zeros from bit 31 down to first 1-bit.
    // Result range: 0-32. Result=32 when rs1=0. Result=0 when rs1[31]=1.
    // =====================================================================

    // --- 5.1 Boundary values (canonical-reference.md §8.1) ---
    // rs1=0x00000000: no bits set → 32 leading zeros
    check_clz(32'h00000000, 6'd32, "CLZ_boundary", 0);
    // rs1=0x00000001: only bit 0 set → 31 leading zeros (bits 31..1 are 0)
    check_clz(32'h00000001, 6'd31, "CLZ_boundary", 1);
    // rs1=0x80000000: bit 31 set → 0 leading zeros
    check_clz(32'h80000000, 6'd0,  "CLZ_boundary", 2);
    // rs1=0xFFFFFFFF: bit 31 set → 0 leading zeros
    check_clz(32'hFFFFFFFF, 6'd0,  "CLZ_boundary", 3);
    // rs1=0x7FFFFFFF: bit 31=0, bit 30=1 → 1 leading zero
    check_clz(32'h7FFFFFFF, 6'd1,  "CLZ_boundary", 4);

    // --- 5.2 Powers of 2: (1 << N) for N=0..31 → expected = (31-N) ---
    // Derivation from spec: only bit N is set, so there are 31-N zeros
    // above it (bits 31 down to N+1), giving CLZ = 31-N.
    // Special case N=31: bit 31 set → CLZ = 0.
    for (int n = 0; n < 32; n++) begin
      check_clz(32'h1 << n, 6'(31 - n), "CLZ_power_of_2", n);
    end

    // --- 5.3 All-ones prefix patterns: 0xFFFF...F shifted right ---
    // Tests that CLZ finds the FIRST leading zero for descending masks.
    // Pattern: 32'hFFFFFFFF >> k has bits [31-k:0] set and bits [31:32-k]=0
    // For k=0: all 32 bits set → CLZ=0
    // For k=1: 0x7FFFFFFF → bit31=0, bit30=1 → CLZ=1
    // For k=31: 0x00000001 → only bit0 set → CLZ=31
    // For k=32: 0x00000000 → no bits → CLZ=32 (use explicit 0 case)
    for (int k = 0; k <= 31; k++) begin
      check_clz(32'hFFFFFFFF >> k, 6'(k), "CLZ_ones_prefix", k);
    end
    check_clz(32'h00000000, 6'd32, "CLZ_ones_prefix_zero", 32);

    // --- 5.4 Spot-check non-trivial patterns ---
    // 0x00010000: bit 16 set → CLZ = 31 - 16 = 15
    check_clz(32'h00010000, 6'd15, "CLZ_spot", 0);
    // 0x00008000: bit 15 set → CLZ = 31 - 15 = 16
    check_clz(32'h00008000, 6'd16, "CLZ_spot", 1);
    // 0x40000000: bit 30 set → CLZ = 31 - 30 = 1
    check_clz(32'h40000000, 6'd1,  "CLZ_spot", 2);
    // 0x20000000: bit 29 set → CLZ = 31 - 29 = 2
    check_clz(32'h20000000, 6'd2,  "CLZ_spot", 3);
    // 0x00000002: bit 1 set → CLZ = 31 - 1 = 30
    check_clz(32'h00000002, 6'd30, "CLZ_spot", 4);
    // 0x00000100: bit 8 set → CLZ = 31 - 8 = 23
    check_clz(32'h00000100, 6'd23, "CLZ_spot", 5);

    // --- 5.5 Random patterns: 50 values vs ref_clz ---
    // ref_clz is the spec-derived model per canonical-reference.md §8.1
    begin
      logic [31:0] rnd_val;
      logic [5:0]  ref_cnt;
      for (int r = 0; r < 50; r++) begin
        rnd_val = $urandom();
        ref_cnt = ref_clz(rnd_val);
        check_clz(rnd_val, ref_cnt, "CLZ_random", r);
      end
    end

    // --- 5.6 CLZ b_i independence ---
    // Spec: CLZ is unary — b_i must not affect result
    // canonical-reference.md §8.1 design note
    begin
      logic [31:0] clz_rs1_vals [5];
      logic [31:0] clz_rs2_vals [4];
      logic [31:0] baseline_clz;
      logic [31:0] cur_clz_result;

      clz_rs1_vals[0] = 32'h00000000;
      clz_rs1_vals[1] = 32'hFFFFFFFF;
      clz_rs1_vals[2] = 32'h00010000;
      clz_rs1_vals[3] = 32'h80000001;
      clz_rs1_vals[4] = $urandom();

      clz_rs2_vals[0] = 32'hFFFFFFFF;
      clz_rs2_vals[1] = 32'hA5A5A5A5;
      clz_rs2_vals[2] = 32'h12345678;
      clz_rs2_vals[3] = $urandom();

      for (int s = 0; s < 5; s++) begin
        @(negedge clk);
        alu_ctrl_i = ALU_CLZ;
        a_i        = clz_rs1_vals[s];
        b_i        = 32'h0;
        #1;
        baseline_clz = result_o;

        for (int t = 0; t < 4; t++) begin
          @(negedge clk);
          alu_ctrl_i = ALU_CLZ;
          a_i        = clz_rs1_vals[s];
          b_i        = clz_rs2_vals[t];
          #1;
          cur_clz_result = result_o;
          if (cur_clz_result !== baseline_clz) begin
            $display(
              "FAIL [CLZ_b_ignored] rs1=0x%08h rs2=0x%08h",
              clz_rs1_vals[s], clz_rs2_vals[t]);
            $display(
              "     result=0x%08h baseline=0x%08h",
              cur_clz_result, baseline_clz);
            fail_count++;
          end else begin
            pass_count++;
          end
        end
      end
    end

    // --- 5.7 X/Z propagation check for CLZ ---
    // No output should be X or Z during valid CLZ operations
    begin
      logic [31:0] xz_vals [4];
      xz_vals[0] = 32'h00000000;
      xz_vals[1] = 32'hFFFFFFFF;
      xz_vals[2] = 32'h80000000;
      xz_vals[3] = 32'hDEADBEEF;

      for (int x = 0; x < 4; x++) begin
        @(negedge clk);
        alu_ctrl_i = ALU_CLZ;
        a_i        = xz_vals[x];
        b_i        = 32'h0;
        #1;
        if (^result_o === 1'bx) begin
          $display(
            "FAIL [CLZ_no_xz] a=0x%08h result=0x%08h",
            xz_vals[x], result_o);
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
    $display("tb_alu_custom results:");
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
