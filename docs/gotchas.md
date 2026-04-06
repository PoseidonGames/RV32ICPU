# RISC-V RV32I Implementation Gotchas

10 known pitfalls. RTL Agent guards against them. QC Agent probes for them. Verification Agent tests them.

1. **INFERRED LATCHES** — If always_comb doesn't assign a signal in every branch, synthesis infers a latch. Assign defaults at top of block.

2. **SIGN EXTENSION** — All RV32I immediates are sign-extended from inst[31]. Never zero-extend where sign-extend is required. SLTIU: immediate IS sign-extended first, THEN compared as unsigned.

3. **SHIFT AMOUNT MASKING** — Only low 5 bits of shift amount are used (rs2[4:0] or imm[4:0]). Full 32-bit value must NOT feed the shifter.

4. **S-TYPE IMMEDIATE SPLIT** — imm[11:5] = inst[31:25], imm[4:0] = inst[11:7]. Do NOT confuse inst[11:7] with rd — S-type has no rd field.

5. **B-TYPE/J-TYPE IMPLICIT ZERO** — Both have implicit 0 in bit position 0. Immediate generator must append 1'b0 at LSB.

6. **JALR LSB CLEAR** — target = (rs1 + sext(imm)) & ~1. The AND must be in the datapath.

7. **AUIPC USES CURRENT PC** — AUIPC adds upper immediate to current instruction's PC. Using PC+4 is WRONG.

8. **x0 WRITE/FORWARD SUPPRESSION** — Writes to x0 suppressed at register file AND in forwarding logic. Check: rd != 5'd0.

9. **PIPELINE FLUSH = NOP** — On taken branch/jump, insert NOP (32'h00000013 = ADDI x0,x0,0) by clearing valid bit or replacing instruction.

10. **SUB vs ADDI FUNCT7 DISTINCTION** — ADDI has no SUBI. funct7[5] only matters for R-type and I-type shifts. Do NOT check funct7 for non-shift I-type instructions.
