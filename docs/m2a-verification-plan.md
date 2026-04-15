# M2a Verification Plan — POPCOUNT + BREV Custom Instructions

> **Purpose:** Define coverage goals and test strategy BEFORE writing RTL. All expected values derived from the ISA spec (canonical-reference.md §8.1), never from the implementation.
>
> **Last updated:** April 14, 2026

---

## 1. Instructions Under Test

| Instruction | Encoding | Operation | Inputs | alu_ctrl |
|-------------|----------|-----------|--------|----------|
| POPCOUNT | opcode=0001011, funct7=0000000, funct3=000 | rd = popcount(rs1) | Unary (rs2 ignored) | 4'b1010 |
| BREV | opcode=0001011, funct7=0000001, funct3=000 | rd = bitreverse(rs1) | Unary (rs2 ignored) | 4'b1011 |

Both use CUSTOM-0 opcode (R-type format). The control decoder already handles CUSTOM-0 (design.v:553-572). Changes are in alu_control (funct7 decode) and ALU (new operations).

---

## 2. Unit-Level Tests — ALU Standalone

Test the ALU module in isolation with direct alu_ctrl drive. No pipeline, no decoder.

### 2.1 POPCOUNT (alu_ctrl = 4'b1010)

**Definition:** Count the number of 1-bits in a 32-bit value.

| Category | Test Vectors | Expected Result | Count |
|----------|-------------|-----------------|-------|
| **Zero** | `32'h00000000` | 0 | 1 |
| **All ones** | `32'hFFFFFFFF` | 32 | 1 |
| **Single bit set** | `1 << i` for i = 0..31 | 1 | 32 |
| **Single bit clear** | `~(1 << i)` for i = 0..31 | 31 | 32 |
| **Alternating** | `32'h55555555`, `32'hAAAAAAAA` | 16, 16 | 2 |
| **Byte patterns** | `32'h000000FF`, `32'h0000FF00`, `32'h00FF0000`, `32'hFF000000` | 8, 8, 8, 8 | 4 |
| **Ascending count** | `(1 << n) - 1` for n = 1..32 | n | 32 |
| **Sparse** | `32'h80000001`, `32'h00010001` | 2, 2 | 2 |
| **Random** | 1000 random 32-bit values | `$countones(val)` reference | 1000 |

**Total: ~1106 vectors**

**Coverage bins for result value:** 0, 1, 2..15, 16, 17..30, 31, 32 (all 33 possible output values should be hit)

### 2.2 BREV (alu_ctrl = 4'b1011)

**Definition:** Reverse the bit order of a 32-bit value. `result[i] = input[31-i]` for i = 0..31.

| Category | Test Vectors | Expected Result | Count |
|----------|-------------|-----------------|-------|
| **Zero** | `32'h00000000` | `32'h00000000` | 1 |
| **All ones** | `32'hFFFFFFFF` | `32'hFFFFFFFF` | 1 |
| **Single bit** | `1 << i` for i = 0..31 | `1 << (31-i)` | 32 |
| **Palindromes** | `32'h81818181`, `32'hFF0000FF` | self (brev == input) | 2 |
| **Non-palindromes** | `32'h0000000F` | `32'hF0000000` | 1 |
| **Byte reversal check** | `32'h12345678` | `32'h1E6A2C48` | 1 |
| **MSB/LSB swap** | `32'h80000000` | `32'h00000001` | 1 |
| **Self-inverse property** | 500 random values: verify `brev(brev(x)) == x` | input | 500 |
| **Random** | 500 random 32-bit values | bitwise reversal reference | 500 |

**Total: ~1039 vectors**

**Critical property:** BREV is a self-inverse (involution). `brev(brev(x)) == x` MUST hold for all inputs. The testbench must verify this explicitly, not just check individual results.

### 2.3 Operand B Ignored

Both POPCOUNT and BREV are unary — rs2 is present in the encoding but must not affect the result.

| Test | Method |
|------|--------|
| rs2 variation | For 10 random rs1 values, run each with 5 different rs2 values. Verify result depends only on rs1. |

---

## 3. Unit-Level Tests — ALU Control

Test alu_control module to verify CUSTOM-0 funct7 decode.

| Test | Input | Expected alu_ctrl | Expected illegal |
|------|-------|-------------------|------------------|
| POPCOUNT decode | alu_op=RTYPE, funct7=0000000, funct3=000, opcode=CUSTOM-0 | 4'b1010 | 0 |
| BREV decode | alu_op=RTYPE, funct7=0000001, funct3=000, opcode=CUSTOM-0 | 4'b1011 | 0 |
| Invalid funct7 | alu_op=RTYPE, funct7=1111111, funct3=000, opcode=CUSTOM-0 | don't care | 1 |
| Invalid funct3 | alu_op=RTYPE, funct7=0000000, funct3=001, opcode=CUSTOM-0 | don't care | 1 |
| R-type ADD unaffected | alu_op=RTYPE, funct7=0000000, funct3=000, opcode=0110011 | 4'b0000 (ADD) | 0 |
| R-type SUB unaffected | alu_op=RTYPE, funct7=0100000, funct3=000, opcode=0110011 | 4'b0001 (SUB) | 0 |

**Key regression:** Ensure adding CUSTOM-0 decode does not break any existing R-type instruction decode. Run full R-type decode sweep (all 10 base instructions).

---

## 4. Integration Tests — Pipeline Level

Full pipeline_top simulation with instruction sequences. Expected values derived from spec.

### 4.1 Basic Execution

| Test | Instruction Sequence | Verify |
|------|---------------------|--------|
| POPCOUNT basic | `POPCOUNT x1, x2` (x2 preloaded with 0xFF00FF00) | x1 == 16 |
| BREV basic | `BREV x1, x2` (x2 preloaded with 0x00000001) | x1 == 0x80000000 |
| POPCOUNT then ADD | `POPCOUNT x1, x2; ADD x3, x1, x1` | x3 == 2 * popcount(x2) |
| BREV then BREV | `BREV x1, x2; BREV x3, x1` | x3 == x2 (self-inverse) |

### 4.2 Forwarding (Gotcha #12 aware)

Custom instructions use `alu_src_a == 2'b00` (RS1), so forwarding IS active.

| Test | Sequence | Hazard Type | Verify |
|------|----------|-------------|--------|
| Custom → base dependency | `POPCOUNT x1, x2; ADD x3, x1, x4` | EX→EX forward | x3 == popcount(x2) + x4 |
| Base → custom dependency | `ADD x1, x2, x3; POPCOUNT x4, x1` | EX→EX forward | x4 == popcount(x2 + x3) |
| Custom → custom dependency | `POPCOUNT x1, x2; BREV x3, x1` | EX→EX forward | x3 == brev(popcount(x2)) |
| WB → custom dependency | `ADD x1, x2, x3; NOP; POPCOUNT x4, x1` | WB→EX forward | x4 == popcount(x2 + x3) |

### 4.3 Branch Interaction

| Test | Sequence | Verify |
|------|----------|--------|
| Custom after taken branch | `BEQ x0, x0, +8; POPCOUNT x1, x2; target: ADD x3, x4, x5` | POPCOUNT flushed, x1 unchanged |
| Custom before branch | `POPCOUNT x1, x2; BEQ x1, x3, target` | Branch condition uses POPCOUNT result |
| Custom in branch shadow | `BNE x1, x2, skip; POPCOUNT x3, x4; skip: ...` | POPCOUNT executes only if branch not taken |

### 4.4 x0 Suppression (Gotcha #8)

| Test | Sequence | Verify |
|------|----------|--------|
| POPCOUNT to x0 | `POPCOUNT x0, x2` (x2 = 0xFFFFFFFF) | x0 remains 0 |
| BREV to x0 | `BREV x0, x2` (x2 = 0x12345678) | x0 remains 0 |
| Forward after x0 write | `POPCOUNT x0, x2; ADD x1, x0, x3` | x1 == x3 (x0 not forwarded) |

### 4.5 Halt/Illegal Interaction

| Test | Sequence | Verify |
|------|----------|--------|
| Custom then ECALL | `POPCOUNT x1, x2; ECALL` | x1 written, then halt_o asserts |
| Illegal custom funct7 | Instruction with opcode=0001011, funct7=1111111 | halt_o asserts (illegal) |

---

## 5. Functional Coverage Goals

### 5.1 Coverage Points

| Coverage Item | Goal | Method |
|---------------|------|--------|
| All alu_ctrl codes 4'b1010, 4'b1011 exercised | 100% | Covergroup on alu_ctrl_i |
| All funct7 values for CUSTOM-0 (valid + invalid) | 100% valid, ≥5 invalid | Covergroup on funct7 |
| POPCOUNT result range 0..32 | All 33 values hit | Covergroup on result when alu_ctrl==POPCOUNT |
| BREV self-inverse property | ≥500 random vectors | Assertion: `brev(brev(x)) == x` |
| rs2 independence for unary ops | ≥50 pairs | Cross-coverage: same rs1, varying rs2 |
| Forwarding: custom→base | ≥5 cases | Covergroup on forwarding + custom alu_ctrl |
| Forwarding: base→custom | ≥5 cases | Covergroup on forwarding + custom alu_ctrl |
| x0 destination suppression | ≥2 cases (one per instruction) | Explicit check |

### 5.2 Pass Criteria

1. **Zero failures** across all directed test vectors
2. **All coverage bins hit** as defined above
3. **No X/Z propagation** on any output during valid instruction execution
4. **Base RV32I regression:** Full M1 testbench must still pass with zero changes to expected behavior

---

## 6. Test Infrastructure

### 6.1 ALU Standalone Testbench (`tb_alu_custom.sv`)
- Direct drive of `alu_ctrl_i`, `a_i`, `b_i`
- Reference model: SystemVerilog function computing expected POPCOUNT/BREV
- Self-checking: compare `result_o` against reference, report pass/fail with vector index

### 6.2 Pipeline Integration Testbench (`tb_pipeline_custom.sv`)
- Preload instruction memory with test sequences
- Preload register file initial values
- Run N cycles, then read register file and compare against expected values
- Uses `@(negedge clk)` for stimulus per gotcha #11

### 6.3 Reference Functions

```systemverilog
// POPCOUNT reference
function automatic [5:0] ref_popcount(input [31:0] val);
  ref_popcount = '0;
  for (int i = 0; i < 32; i++)
    ref_popcount = ref_popcount + {5'b0, val[i]};
endfunction

// BREV reference
function automatic [31:0] ref_brev(input [31:0] val);
  for (int i = 0; i < 32; i++)
    ref_brev[i] = val[31-i];
endfunction
```

---

## 7. Encoding Reference (for testbench instruction generation)

### POPCOUNT rd, rs1
```
[31:25]  [24:20]  [19:15]  [14:12]  [11:7]  [6:0]
0000000  rs2(xx)  rs1      000      rd      0001011
```
rs2 field is don't-care (unary op). Testbench should vary rs2 to verify independence.

### BREV rd, rs1
```
[31:25]  [24:20]  [19:15]  [14:12]  [11:7]  [6:0]
0000001  rs2(xx)  rs1      000      rd      0001011
```
rs2 field is don't-care (unary op).

### Instruction builder helper
```systemverilog
function automatic [31:0] encode_custom0(
  input [6:0] funct7, input [4:0] rs2, input [4:0] rs1,
  input [2:0] funct3, input [4:0] rd
);
  encode_custom0 = {funct7, rs2, rs1, funct3, rd, 7'b0001011};
endfunction
```
