// ============================================================================
// Module: tb_forwarding_unit
// Description: Self-checking testbench for forwarding_unit.sv.
//              Expected values derived exclusively from:
//                - docs/canonical-reference.md §7.3 (forwarding equations)
//                - docs/gotchas.md #8 (x0 suppression)
//                - docs/gotchas.md #12 (alu_src_a gate on forward_rs1)
//
//              Spec equations under test (canonical-reference.md §7.3):
//                forward_rs1 = wb_reg_write && (wb_rd != 0)
//                              && (wb_rd == ex_rs1) && (alu_src_a == 2'b00)
//                forward_rs2 = wb_reg_write && (wb_rd != 0)
//                              && (wb_rd == ex_rs2)
//
// Author: Beaux Cable
// Date: April 2026
// Project: TSI RV32I Pipelined Processor (TSMC 180nm)
// ============================================================================

`timescale 1ns/1ps

module tb_forwarding_unit;

  // --------------------------------------------------------------------------
  // DUT port signals
  // --------------------------------------------------------------------------
  logic        wb_reg_write_i;
  logic [4:0]  wb_rd_i;
  logic [4:0]  ex_rs1_i;
  logic [4:0]  ex_rs2_i;
  logic [1:0]  alu_src_a_i;

  logic        forward_rs1_o;
  logic        forward_rs2_o;

  // --------------------------------------------------------------------------
  // DUT instantiation
  // --------------------------------------------------------------------------
  forwarding_unit dut (
    .wb_reg_write_i (wb_reg_write_i),
    .wb_rd_i        (wb_rd_i),
    .ex_rs1_i       (ex_rs1_i),
    .ex_rs2_i       (ex_rs2_i),
    .alu_src_a_i    (alu_src_a_i),
    .forward_rs1_o  (forward_rs1_o),
    .forward_rs2_o  (forward_rs2_o)
  );

  // --------------------------------------------------------------------------
  // Clock (50 MHz — required by conventions even for combinational DUT)
  // --------------------------------------------------------------------------
  logic clk;
  initial clk = 1'b0;
  always #10 clk = ~clk;

  // --------------------------------------------------------------------------
  // Test infrastructure
  // --------------------------------------------------------------------------
  int pass_count;
  int fail_count;

  // check_outputs: apply inputs, wait 1 ns for combinational settle, then
  // compare against expected values.  Prints PASS/FAIL with test name.
  task automatic check_outputs (
    input string  test_name,
    input logic   exp_rs1,
    input logic   exp_rs2
  );
    #1; // combinational settle (conventions: apply inputs, #1, check)
    if (forward_rs1_o !== exp_rs1) begin
      $display("FAIL  %-55s | forward_rs1_o got %b expected %b",
               test_name, forward_rs1_o, exp_rs1);
      fail_count++;
    end else begin
      $display("PASS  %-55s | forward_rs1_o = %b", test_name, forward_rs1_o);
      pass_count++;
    end
    if (forward_rs2_o !== exp_rs2) begin
      $display("FAIL  %-55s | forward_rs2_o got %b expected %b",
               test_name, forward_rs2_o, exp_rs2);
      fail_count++;
    end else begin
      $display("PASS  %-55s | forward_rs2_o = %b", test_name, forward_rs2_o);
      pass_count++;
    end
  endtask

  // --------------------------------------------------------------------------
  // Main test sequence
  // --------------------------------------------------------------------------
  initial begin
    pass_count = 0;
    fail_count = 0;

    $display("=================================================================");
    $display("  tb_forwarding_unit — self-checking testbench");
    $display("  Spec: canonical-reference.md §7.3, gotchas #8 and #12");
    $display("=================================================================");

    // -----------------------------------------------------------------------
    // GROUP 1: Idle / no-forward baseline
    // -----------------------------------------------------------------------
    // Spec §7.3: wb_reg_write=0 → both outputs 0 regardless of everything else.
    $display("");
    $display("--- GROUP 1: reg_write=0 (forward suppressed) ---");

    // Test 1.1: reg_write=0, matching rd/rs1, alu_src_a=00
    // Expected: forward_rs1=0 (wb_reg_write=0 disables AND chain)
    //           forward_rs2=0 (wb_reg_write=0 disables AND chain)
    wb_reg_write_i = 1'b0;
    wb_rd_i        = 5'd3;
    ex_rs1_i       = 5'd3;
    ex_rs2_i       = 5'd3;
    alu_src_a_i    = 2'b00;
    check_outputs("1.1 reg_write=0, rd==rs1==rs2, alu_src_a=00",
                  1'b0, 1'b0);

    // Test 1.2: reg_write=0, matching rd/rs1, alu_src_a=01 (PC)
    // Expected: both 0 — wb_reg_write=0 gate fires first
    wb_reg_write_i = 1'b0;
    wb_rd_i        = 5'd7;
    ex_rs1_i       = 5'd7;
    ex_rs2_i       = 5'd7;
    alu_src_a_i    = 2'b01;
    check_outputs("1.2 reg_write=0, rd==rs1==rs2, alu_src_a=01",
                  1'b0, 1'b0);

    // Test 1.3: reg_write=0, no match at all
    // Expected: both 0
    wb_reg_write_i = 1'b0;
    wb_rd_i        = 5'd1;
    ex_rs1_i       = 5'd2;
    ex_rs2_i       = 5'd3;
    alu_src_a_i    = 2'b00;
    check_outputs("1.3 reg_write=0, no rd match",
                  1'b0, 1'b0);

    // -----------------------------------------------------------------------
    // GROUP 2: Normal forwarding — both rs1 and rs2 forwarded
    // -----------------------------------------------------------------------
    // Spec §7.3:
    //   forward_rs1 = 1 when wb_reg_write=1 AND wb_rd!=0 AND wb_rd==ex_rs1
    //                        AND alu_src_a==2'b00
    //   forward_rs2 = 1 when wb_reg_write=1 AND wb_rd!=0 AND wb_rd==ex_rs2
    $display("");
    $display("--- GROUP 2: Normal forwarding (alu_src_a=00) ---");

    // Test 2.1: forward rs1 only (rs2 is different register)
    // wb_rd=1, ex_rs1=1 (match), ex_rs2=2 (no match), alu_src_a=00
    // Expected: forward_rs1=1, forward_rs2=0
    wb_reg_write_i = 1'b1;
    wb_rd_i        = 5'd1;
    ex_rs1_i       = 5'd1;
    ex_rs2_i       = 5'd2;
    alu_src_a_i    = 2'b00;
    check_outputs("2.1 rs1 match only, alu_src_a=00",
                  1'b1, 1'b0);

    // Test 2.2: forward rs2 only (rs1 is different register)
    // wb_rd=5, ex_rs1=3 (no match), ex_rs2=5 (match), alu_src_a=00
    // Expected: forward_rs1=0, forward_rs2=1
    wb_reg_write_i = 1'b1;
    wb_rd_i        = 5'd5;
    ex_rs1_i       = 5'd3;
    ex_rs2_i       = 5'd5;
    alu_src_a_i    = 2'b00;
    check_outputs("2.2 rs2 match only, alu_src_a=00",
                  1'b0, 1'b1);

    // Test 2.3: forward both rs1 and rs2 simultaneously
    // wb_rd=10, ex_rs1=10 (match), ex_rs2=10 (match), alu_src_a=00
    // Expected: forward_rs1=1, forward_rs2=1
    // Spec §7.3: both AND chains evaluate true independently
    wb_reg_write_i = 1'b1;
    wb_rd_i        = 5'd10;
    ex_rs1_i       = 5'd10;
    ex_rs2_i       = 5'd10;
    alu_src_a_i    = 2'b00;
    check_outputs("2.3 both rs1 and rs2 match, alu_src_a=00",
                  1'b1, 1'b1);

    // Test 2.4: high register numbers (boundary) — wb_rd=31
    // wb_rd=31, ex_rs1=31 (match), ex_rs2=31 (match), alu_src_a=00
    // Expected: forward_rs1=1, forward_rs2=1
    wb_reg_write_i = 1'b1;
    wb_rd_i        = 5'd31;
    ex_rs1_i       = 5'd31;
    ex_rs2_i       = 5'd31;
    alu_src_a_i    = 2'b00;
    check_outputs("2.4 boundary rd=31, both match, alu_src_a=00",
                  1'b1, 1'b1);

    // Test 2.5: no match — rd differs from both rs1 and rs2
    // wb_rd=8, ex_rs1=9, ex_rs2=10, alu_src_a=00
    // Expected: forward_rs1=0, forward_rs2=0
    wb_reg_write_i = 1'b1;
    wb_rd_i        = 5'd8;
    ex_rs1_i       = 5'd9;
    ex_rs2_i       = 5'd10;
    alu_src_a_i    = 2'b00;
    check_outputs("2.5 no rd match at all",
                  1'b0, 1'b0);

    // -----------------------------------------------------------------------
    // GROUP 3: x0 suppression (gotcha #8)
    // -----------------------------------------------------------------------
    // Spec §7.3: "(wb_rd != 0)" is MANDATORY in both forward equations.
    // Writes to x0 must never forward — x0 always reads as zero; forwarding
    // a WB write to x0 would corrupt operands with whatever was "written."
    $display("");
    $display("--- GROUP 3: x0 suppression (gotcha #8) ---");

    // Test 3.1: wb_rd=0 with matching rs1=0, alu_src_a=00
    // Expected: forward_rs1=0 (wb_rd==0 kills the AND chain)
    //           forward_rs2=0 (wb_rd==0 kills the AND chain)
    wb_reg_write_i = 1'b1;
    wb_rd_i        = 5'd0;
    ex_rs1_i       = 5'd0;
    ex_rs2_i       = 5'd0;
    alu_src_a_i    = 2'b00;
    check_outputs("3.1 wb_rd=x0, rs1=x0, rs2=x0 — no forward",
                  1'b0, 1'b0);

    // Test 3.2: wb_rd=0 with matching rs1=0 but rs2 non-zero, alu_src_a=00
    // Expected: forward_rs1=0, forward_rs2=0
    wb_reg_write_i = 1'b1;
    wb_rd_i        = 5'd0;
    ex_rs1_i       = 5'd0;
    ex_rs2_i       = 5'd4;
    alu_src_a_i    = 2'b00;
    check_outputs("3.2 wb_rd=x0, rs1=x0, rs2 different — no forward",
                  1'b0, 1'b0);

    // Test 3.3: wb_rd=0 with non-zero rs1/rs2 that don't match — still 0
    // Expected: both 0 (wb_rd==0 kills the chain before the == check)
    wb_reg_write_i = 1'b1;
    wb_rd_i        = 5'd0;
    ex_rs1_i       = 5'd5;
    ex_rs2_i       = 5'd6;
    alu_src_a_i    = 2'b00;
    check_outputs("3.3 wb_rd=x0, rs1/rs2 non-zero non-match — no forward",
                  1'b0, 1'b0);

    // -----------------------------------------------------------------------
    // GROUP 4: alu_src_a gate on forward_rs1 (gotcha #12)
    // -----------------------------------------------------------------------
    // Spec §7.3: forward_rs1 is gated by (alu_src_a == 2'b00).
    // When alu_src_a=01 (PC, used by AUIPC/JAL) or alu_src_a=10 (zero,
    // used by LUI), ALU-A is NOT rs1.  Forwarding here would silently
    // overwrite PC or zero with stale register data.
    // Critically: forward_rs2 has NO such gate — it must assert regardless
    // of alu_src_a (stores need rs2 forwarding even when alu_src_a != 00).
    $display("");
    $display("--- GROUP 4: alu_src_a gate (gotcha #12) ---");

    // Test 4.1: wb_rd matches ex_rs1, alu_src_a=01 (AUIPC/JAL uses PC)
    // forward_rs1 must be 0; forward_rs2 unaffected (rs2 also matches).
    // Expected: forward_rs1=0, forward_rs2=1
    wb_reg_write_i = 1'b1;
    wb_rd_i        = 5'd4;
    ex_rs1_i       = 5'd4;
    ex_rs2_i       = 5'd4;
    alu_src_a_i    = 2'b01;  // PC path (AUIPC / JAL)
    check_outputs("4.1 rs1 match, alu_src_a=01 (PC) — rs1 NOT fwd, rs2 fwd",
                  1'b0, 1'b1);

    // Test 4.2: wb_rd matches ex_rs1, alu_src_a=10 (LUI uses zero)
    // Expected: forward_rs1=0, forward_rs2=1
    wb_reg_write_i = 1'b1;
    wb_rd_i        = 5'd6;
    ex_rs1_i       = 5'd6;
    ex_rs2_i       = 5'd6;
    alu_src_a_i    = 2'b10;  // zero path (LUI)
    check_outputs("4.2 rs1 match, alu_src_a=10 (zero/LUI) — rs1 NOT fwd, rs2 fwd",
                  1'b0, 1'b1);

    // Test 4.3: wb_rd matches ex_rs1 but not ex_rs2, alu_src_a=01
    // Expected: forward_rs1=0 (alu_src_a gate), forward_rs2=0 (no match)
    wb_reg_write_i = 1'b1;
    wb_rd_i        = 5'd12;
    ex_rs1_i       = 5'd12;
    ex_rs2_i       = 5'd15;
    alu_src_a_i    = 2'b01;
    check_outputs("4.3 rs1 match, rs2 no match, alu_src_a=01",
                  1'b0, 1'b0);

    // Test 4.4: wb_rd matches ex_rs1 but not ex_rs2, alu_src_a=10
    // Expected: forward_rs1=0, forward_rs2=0
    wb_reg_write_i = 1'b1;
    wb_rd_i        = 5'd20;
    ex_rs1_i       = 5'd20;
    ex_rs2_i       = 5'd21;
    alu_src_a_i    = 2'b10;
    check_outputs("4.4 rs1 match, rs2 no match, alu_src_a=10",
                  1'b0, 1'b0);

    // Test 4.5: JALR corner — alu_src_a=00 (JALR uses rs1 directly,
    // canonical-reference.md §6.3 shows alu_src_a=00 for JALR).
    // Forwarding MUST occur for JALR since it needs the actual rs1 value
    // to compute the jump target.
    // Expected: forward_rs1=1, forward_rs2=1
    wb_reg_write_i = 1'b1;
    wb_rd_i        = 5'd9;
    ex_rs1_i       = 5'd9;
    ex_rs2_i       = 5'd9;
    alu_src_a_i    = 2'b00;  // JALR: alu_src_a=00, forwarding enabled
    check_outputs("4.5 JALR (alu_src_a=00) — rs1 IS forwarded",
                  1'b1, 1'b1);

    // -----------------------------------------------------------------------
    // GROUP 5: rs2 forwarding ungated by alu_src_a
    // -----------------------------------------------------------------------
    // Spec §7.3: "forward_rs2 has no equivalent gate since ALU-B is always
    // rs2 or an immediate (never PC or zero)."
    // Additionally: store instructions route rs2 directly to the memory
    // write port, bypassing the alu_src mux. forward_rs2 must fire even
    // when alu_src_a != 00 so store data is forwarded correctly.
    $display("");
    $display("--- GROUP 5: rs2 ungated by alu_src_a ---");

    // Test 5.1: rs2 match, alu_src_a=01 — rs2 should still forward
    // (e.g., a store instruction whose WB producer used alu_src_a=01)
    wb_reg_write_i = 1'b1;
    wb_rd_i        = 5'd14;
    ex_rs1_i       = 5'd25;  // different — rs1 won't match
    ex_rs2_i       = 5'd14;  // match
    alu_src_a_i    = 2'b01;
    check_outputs("5.1 rs2 match, alu_src_a=01 — rs2 forwarded, rs1 not",
                  1'b0, 1'b1);

    // Test 5.2: rs2 match, alu_src_a=10 — rs2 should still forward
    wb_reg_write_i = 1'b1;
    wb_rd_i        = 5'd17;
    ex_rs1_i       = 5'd25;
    ex_rs2_i       = 5'd17;
    alu_src_a_i    = 2'b10;
    check_outputs("5.2 rs2 match, alu_src_a=10 — rs2 forwarded, rs1 not",
                  1'b0, 1'b1);

    // Test 5.3: rs2 match, alu_src_a=11 (reserved — still not 00)
    // Spec defines 00/01/10 only; 11 is not assigned but the gate condition
    // is (alu_src_a == 2'b00), so 11 still suppresses rs1 forwarding.
    // rs2 has no gate, so it still forwards.
    // Expected: forward_rs1=0 (alu_src_a != 00), forward_rs2=1
    wb_reg_write_i = 1'b1;
    wb_rd_i        = 5'd19;
    ex_rs1_i       = 5'd19;
    ex_rs2_i       = 5'd19;
    alu_src_a_i    = 2'b11;  // reserved, treated as not-rs1-path
    check_outputs("5.3 alu_src_a=11 (reserved) — rs1 gated, rs2 not",
                  1'b0, 1'b1);

    // -----------------------------------------------------------------------
    // GROUP 6: Boundary register values
    // -----------------------------------------------------------------------
    $display("");
    $display("--- GROUP 6: Boundary register values ---");

    // Test 6.1: wb_rd=1 (lowest non-x0), rs1=1, rs2=1, alu_src_a=00
    // Expected: forward_rs1=1, forward_rs2=1
    wb_reg_write_i = 1'b1;
    wb_rd_i        = 5'd1;
    ex_rs1_i       = 5'd1;
    ex_rs2_i       = 5'd1;
    alu_src_a_i    = 2'b00;
    check_outputs("6.1 wb_rd=1 (lowest non-x0), both match",
                  1'b1, 1'b1);

    // Test 6.2: wb_rd=16, rs1=16, rs2=15 (off-by-one on rs2), alu_src_a=00
    // Expected: forward_rs1=1, forward_rs2=0
    wb_reg_write_i = 1'b1;
    wb_rd_i        = 5'd16;
    ex_rs1_i       = 5'd16;
    ex_rs2_i       = 5'd15;
    alu_src_a_i    = 2'b00;
    check_outputs("6.2 rs1 match, rs2 off-by-one (15 vs 16)",
                  1'b1, 1'b0);

    // Test 6.3: wb_rd=16, rs1=17 (off-by-one on rs1), rs2=16, alu_src_a=00
    // Expected: forward_rs1=0, forward_rs2=1
    wb_reg_write_i = 1'b1;
    wb_rd_i        = 5'd16;
    ex_rs1_i       = 5'd17;
    ex_rs2_i       = 5'd16;
    alu_src_a_i    = 2'b00;
    check_outputs("6.3 rs1 off-by-one (17 vs 16), rs2 match",
                  1'b0, 1'b1);

    // Test 6.4: wb_rd=30, rs1=31 (adjacent, no match), rs2=29, alu_src_a=00
    // Expected: forward_rs1=0, forward_rs2=0
    wb_reg_write_i = 1'b1;
    wb_rd_i        = 5'd30;
    ex_rs1_i       = 5'd31;
    ex_rs2_i       = 5'd29;
    alu_src_a_i    = 2'b00;
    check_outputs("6.4 wb_rd=30, no match on either side",
                  1'b0, 1'b0);

    // -----------------------------------------------------------------------
    // GROUP 7: All-zeros and all-ones corner states
    // -----------------------------------------------------------------------
    $display("");
    $display("--- GROUP 7: All-zeros / all-ones corners ---");

    // Test 7.1: All inputs zero — wb_rd=0 suppresses everything
    // Expected: forward_rs1=0, forward_rs2=0
    wb_reg_write_i = 1'b0;
    wb_rd_i        = 5'd0;
    ex_rs1_i       = 5'd0;
    ex_rs2_i       = 5'd0;
    alu_src_a_i    = 2'b00;
    check_outputs("7.1 all zeros — both suppressed",
                  1'b0, 1'b0);

    // Test 7.2: reg_write=1, wb_rd=0, all other registers=0
    // wb_rd=0 suppresses regardless of other conditions (gotcha #8)
    // Expected: forward_rs1=0, forward_rs2=0
    wb_reg_write_i = 1'b1;
    wb_rd_i        = 5'd0;
    ex_rs1_i       = 5'd0;
    ex_rs2_i       = 5'd0;
    alu_src_a_i    = 2'b00;
    check_outputs("7.2 reg_write=1 wb_rd=x0 all match — x0 gate wins",
                  1'b0, 1'b0);

    // Test 7.3: reg_write=1, wb_rd=31, rs1=31, rs2=31, alu_src_a=00
    // All non-zero, all matching — both should forward
    // Expected: forward_rs1=1, forward_rs2=1
    wb_reg_write_i = 1'b1;
    wb_rd_i        = 5'd31;
    ex_rs1_i       = 5'd31;
    ex_rs2_i       = 5'd31;
    alu_src_a_i    = 2'b00;
    check_outputs("7.3 wb_rd=31, rs1=31, rs2=31, alu_src_a=00 — both fwd",
                  1'b1, 1'b1);

    // -----------------------------------------------------------------------
    // Summary
    // -----------------------------------------------------------------------
    $display("");
    $display("=================================================================");
    $display("  RESULTS: %0d PASS  /  %0d FAIL  /  %0d total checks",
             pass_count, fail_count, pass_count + fail_count);
    if (fail_count == 0)
      $display("  ALL TESTS PASSED");
    else
      $display("  *** FAILURES DETECTED — see FAIL lines above ***");
    $display("=================================================================");

    $finish;
  end

endmodule
