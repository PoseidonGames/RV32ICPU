# RISC-V RV32I Implementation Gotchas

13 known pitfalls. RTL Agent guards against them. QC Agent probes for them. Verification Agent tests them.

1. **INFERRED LATCHES** — If always_comb doesn't assign a signal in every branch, synthesis infers a latch. Assign defaults at top of block.

2. **SIGN EXTENSION** — All RV32I immediates are sign-extended from inst[31]. Never zero-extend where sign-extend is required. SLTIU: immediate IS sign-extended first, THEN compared as unsigned.

3. **SHIFT AMOUNT MASKING** — Only low 5 bits of shift amount are used (rs2[4:0] or imm[4:0]). Full 32-bit value must NOT feed the shifter.

4. **S-TYPE IMMEDIATE SPLIT** — imm[11:5] = inst[31:25], imm[4:0] = inst[11:7]. Do NOT confuse inst[11:7] with rd — S-type has no rd field.

5. **B-TYPE/J-TYPE IMPLICIT ZERO** — Both have implicit 0 in bit position 0. Immediate generator must append 1'b0 at LSB.

6. **JALR LSB CLEAR** — target = (rs1 + sext(imm)) & ~1. The AND belongs in `datapath_m0.sv` as a one-liner after the ALU output, before the PC mux: `assign jalr_target = {alu_result[31:1], 1'b0};`. It does NOT belong inside the branch comparator (which only produces taken/not-taken) or inside the ALU. `jalr_target` feeds a dedicated input on the PC-next mux, selected when `jalr_o=1`.

7. **AUIPC USES CURRENT PC** — AUIPC adds upper immediate to current instruction's PC. Using PC+4 is WRONG.

8. **x0 WRITE/FORWARD SUPPRESSION** — Writes to x0 suppressed at register file AND in forwarding logic. Check: rd != 5'd0.

9. **PIPELINE FLUSH = NOP** — On taken branch/jump, insert NOP (32'h00000013 = ADDI x0,x0,0) by clearing valid bit or replacing instruction.

10. **SUB vs ADDI FUNCT7 DISTINCTION** — ADDI has no SUBI. funct7[5] only matters for R-type and I-type shifts. Do NOT check funct7 for non-shift I-type instructions.

11. **TESTBENCH STIMULUS RACE** — Driving DUT inputs immediately after `@(posedge clk)` in a testbench `initial` block races with `always_ff @(posedge clk)` in the DUT. Both wake in the same active-event region; IEEE 1800 does not define which runs first, so the DUT may capture the newly driven values on the same edge the testbench intended as setup. Fix: drive all stimulus at `@(negedge clk)` so inputs are settled before the next capturing posedge. Never use `@(posedge clk)` as the trigger to apply new stimulus to a synchronous DUT.

12. **AUIPC/JAL/LUI FORWARDING CORRUPTION** — When `alu_src_a == 2'b01` (PC, used by AUIPC and JAL) or `alu_src_a == 2'b10` (zero, used by LUI), ALU-A is not rs1. The forwarding enable must be gated: `fwd_a_en = wb_reg_write && (wb_rd != 0) && (wb_rd == ex_rs1) && (alu_src_a == 2'b00)`. Forwarding when `alu_src_a != 00` would overwrite PC or zero with stale register data, silently corrupting AUIPC and JAL results. Note: JALR has `alu_src_a=00` and is NOT affected by this gotcha.

13. **BRANCH ALU_OP SAFE DEFAULT** — `alu_op=2'b01` (BRANCH) is driven to `alu_control` for branch instructions, but the ALU result is discarded — the branch comparator handles comparison. `alu_control` must output `alu_ctrl=4'b0000` (ADD) as a safe default for `alu_op=01`. Leaving it as don't-care risks synthesis inferring unintended logic on the ALU inputs during branches.
