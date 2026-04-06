# Spec Agent — Canonical Reference

> **Purpose:** This is the single source of truth for the RV32I processor design. Every encoding, signal definition, and architectural decision lives here.
> **Last updated:** April 1, 2026

> **⚠ UNRESOLVED ITEMS** (do not treat as settled until confirmed with ar):
> - Custom instruction set beyond POPCOUNT + BREV is TBD (CLZ vs BEXT vs BDEP)
> - M1 scope: vanilla RV32I only, or includes custom extensions?
> - ALU encoding table is authoritative for base RV32I; extension encodings (1010+) may change

---

## 1. Instruction Set — Complete Encoding Table

### 1.1 R-Type Instructions (opcode = 0110011)

| Instruction | funct7    | funct3 | Operation           | alu_ctrl | Notes |
|-------------|-----------|--------|---------------------|----------|-------|
| ADD         | 0000000   | 000    | rd = rs1 + rs2      | 4'b0000  | Overflow ignored |
| SUB         | 0100000   | 000    | rd = rs1 - rs2      | 4'b0001  | Same funct3 as ADD; funct7 distinguishes |
| SLL         | 0000000   | 001    | rd = rs1 << rs2[4:0]| 4'b0111  | Shift left logical |
| SLT         | 0000000   | 010    | rd = (rs1 <s rs2)?1:0 | 4'b0101 | Signed compare |
| SLTU        | 0000000   | 011    | rd = (rs1 <u rs2)?1:0 | 4'b0110 | Unsigned compare |
| XOR         | 0000000   | 100    | rd = rs1 ^ rs2      | 4'b0100  | |
| SRL         | 0000000   | 101    | rd = rs1 >> rs2[4:0]| 4'b1000  | Zero-fill |
| SRA         | 0100000   | 101    | rd = rs1 >>> rs2[4:0]| 4'b1001 | Sign-extend fill |
| OR          | 0000000   | 110    | rd = rs1 | rs2      | 4'b0011  | |
| AND         | 0000000   | 111    | rd = rs1 & rs2      | 4'b0010  | |

### 1.2 I-Type Arithmetic (opcode = 0010011)

| Instruction | imm[11:0] / funct7+shamt | funct3 | Operation              | alu_ctrl | Notes |
|-------------|--------------------------|--------|------------------------|----------|-------|
| ADDI        | imm[11:0]                | 000    | rd = rs1 + sext(imm)   | 4'b0000  | NOP = ADDI x0,x0,0. NO SUBI exists. |
| SLTI        | imm[11:0]                | 010    | rd = (rs1 <s sext(imm))?1:0 | 4'b0101 | Signed |
| SLTIU       | imm[11:0]                | 011    | rd = (rs1 <u sext(imm))?1:0 | 4'b0110 | ⚠ imm IS sign-extended, then compared unsigned |
| XORI        | imm[11:0]                | 100    | rd = rs1 ^ sext(imm)   | 4'b0100  | XORI rd,rs1,-1 = NOT |
| ORI         | imm[11:0]                | 110    | rd = rs1 | sext(imm)   | 4'b0011  | |
| ANDI        | imm[11:0]                | 111    | rd = rs1 & sext(imm)   | 4'b0010  | |
| SLLI        | 0000000 + shamt[4:0]     | 001    | rd = rs1 << shamt      | 4'b0111  | imm[11:5] must be 0000000 |
| SRLI        | 0000000 + shamt[4:0]     | 101    | rd = rs1 >> shamt      | 4'b1000  | imm[11:5] must be 0000000 |
| SRAI        | 0100000 + shamt[4:0]     | 101    | rd = rs1 >>> shamt     | 4'b1001  | imm[11:5] must be 0100000 |

### 1.3 Load Instructions (opcode = 0000011)

| Instruction | funct3 | Operation | alu_ctrl | Notes |
|-------------|--------|-----------|----------|-------|
| LB          | 000    | rd = sext(mem[rs1+imm][7:0])   | 4'b0000 | ALU computes address (ADD) |
| LH          | 001    | rd = sext(mem[rs1+imm][15:0])  | 4'b0000 | |
| LW          | 010    | rd = mem[rs1+imm][31:0]        | 4'b0000 | |
| LBU         | 100    | rd = zext(mem[rs1+imm][7:0])   | 4'b0000 | |
| LHU         | 101    | rd = zext(mem[rs1+imm][15:0])  | 4'b0000 | |

### 1.4 Store Instructions (opcode = 0100011)

| Instruction | funct3 | Operation | alu_ctrl | Notes |
|-------------|--------|-----------|----------|-------|
| SB          | 000    | mem[rs1+imm][7:0] = rs2[7:0]   | 4'b0000 | ALU computes address. Store data = rs2. |
| SH          | 001    | mem[rs1+imm][15:0] = rs2[15:0] | 4'b0000 | ⚠ S-type has NO rd — imm split across funct7+rd fields |
| SW          | 010    | mem[rs1+imm][31:0] = rs2[31:0] | 4'b0000 | |

### 1.5 Branch Instructions (opcode = 1100011)

| Instruction | funct3 | Condition | Notes |
|-------------|--------|-----------|-------|
| BEQ         | 000    | rs1 == rs2 | |
| BNE         | 001    | rs1 != rs2 | |
| BLT         | 100    | signed(rs1) < signed(rs2) | |
| BGE         | 101    | signed(rs1) >= signed(rs2) | |
| BLTU        | 110    | unsigned(rs1) < unsigned(rs2) | |
| BGEU        | 111    | unsigned(rs1) >= unsigned(rs2) | |

Branch target = PC + sext(B-imm). Offset is in multiples of 2 bytes (±4 KiB range). ALU is NOT used for branch comparison — a separate branch comparator handles this.

### 1.6 Jump Instructions

| Instruction | Opcode  | Type | imm encoding | Operation | Notes |
|-------------|---------|------|--------------|-----------|-------|
| JAL         | 1101111 | J    | J_imm        | rd=PC+4; PC+=sext(J-imm) | ±1 MiB range. JAL x0,offset = unconditional jump |
| JALR        | 1100111 | I    | I_imm        | rd=PC+4; PC=(rs1+sext(imm))&~1 | ⚠ Clears LSB of target address |

### 1.7 Upper Immediate Instructions

| Instruction | Opcode  | Type | Operation | Notes |
|-------------|---------|------|-----------|-------|
| LUI         | 0110111 | U    | rd = imm[31:12] << 12 | Lower 12 bits zeroed |
| AUIPC       | 0010111 | U    | rd = PC + (imm[31:12] << 12) | ⚠ Uses THIS instruction's PC, not PC+4 |

### 1.8 System / Synchronization

| Instruction | Opcode  | funct3 | imm[11:0] | Implementation |
|-------------|---------|--------|-----------|----------------|
| FENCE       | 0001111 | 000    | varies    | NOP (single-hart system) |
| ECALL       | 1110011 | 000    | 000000000000 | Assert halt/trap output pin |
| EBREAK      | 1110011 | 000    | 000000000001 | Assert halt/trap output pin |

---

## 2. Opcode Map

| Opcode [6:0] | Type | Instructions |
|--------------|------|--------------|
| 0110011      | R    | ADD, SUB, SLL, SLT, SLTU, XOR, SRL, SRA, OR, AND |
| 0010011      | I    | ADDI, SLTI, SLTIU, XORI, ORI, ANDI, SLLI, SRLI, SRAI |
| 0000011      | I    | LB, LH, LW, LBU, LHU |
| 0100011      | S    | SB, SH, SW |
| 1100011      | B    | BEQ, BNE, BLT, BGE, BLTU, BGEU |
| 1101111      | J    | JAL |
| 1100111      | I    | JALR |
| 0110111      | U    | LUI |
| 0010111      | U    | AUIPC |
| 0001111      | I    | FENCE |
| 1110011      | I    | ECALL, EBREAK |
| **0001011**  | **R** | **CUSTOM-0 (reserved for M2a/M2b extensions)** |

Any opcode not in this table → `illegal_instr = 1`.

---

## 3. Instruction Formats — Bit-Level Encoding

```
R-type:  [31:25 funct7 | 24:20 rs2 | 19:15 rs1 | 14:12 funct3 | 11:7 rd | 6:0 opcode]
I-type:  [31:20 imm[11:0]          | 19:15 rs1 | 14:12 funct3 | 11:7 rd | 6:0 opcode]
S-type:  [31:25 imm[11:5] | 24:20 rs2 | 19:15 rs1 | 14:12 funct3 | 11:7 imm[4:0] | 6:0 opcode]
B-type:  [31 imm[12] | 30:25 imm[10:5] | 24:20 rs2 | 19:15 rs1 | 14:12 funct3 | 11:8 imm[4:1] | 7 imm[11] | 6:0 opcode]
U-type:  [31:12 imm[31:12]                                      | 11:7 rd | 6:0 opcode]
J-type:  [31 imm[20] | 30:21 imm[10:1] | 20 imm[11] | 19:12 imm[19:12] | 11:7 rd | 6:0 opcode]
```

**Critical:** The sign bit for ALL immediates is always instruction bit 31. This allows sign-extension to happen in parallel with decode.

---

## 4. Immediate Extraction (for imm_gen.sv)

| Format | imm_type | Extraction (MSB to LSB) |
|--------|----------|------------------------|
| I-type | 3'b000   | `{ {20{inst[31]}}, inst[31:20] }` |
| S-type | 3'b001   | `{ {20{inst[31]}}, inst[31:25], inst[11:7] }` |
| B-type | 3'b010   | `{ {19{inst[31]}}, inst[31], inst[7], inst[30:25], inst[11:8], 1'b0 }` |
| U-type | 3'b011   | `{ inst[31:12], 12'b0 }` |
| J-type | 3'b100   | `{ {11{inst[31]}}, inst[31], inst[19:12], inst[20], inst[30:21], 1'b0 }` |

---

## 5. ALU Control Encoding (established in alu.sv)

| alu_ctrl [3:0] | Operation | Used by |
|----------------|-----------|---------|
| 4'b0000        | ADD       | R-type ADD, all loads, all stores, ADDI, AUIPC addr calc |
| 4'b0001        | SUB       | R-type SUB |
| 4'b0010        | AND       | R-type AND, ANDI |
| 4'b0011        | OR        | R-type OR, ORI |
| 4'b0100        | XOR       | R-type XOR, XORI |
| 4'b0101        | SLT       | R-type SLT, SLTI |
| 4'b0110        | SLTU      | R-type SLTU, SLTIU |
| 4'b0111        | SLL       | R-type SLL, SLLI |
| 4'b1000        | SRL       | R-type SRL, SRLI |
| 4'b1001        | SRA       | R-type SRA, SRAI |

Codes 4'b1010 through 4'b1111 are **reserved for M2a/M2b custom extensions**.

---

## 6. Control Decoder Signal Definitions

### 6.1 Signal Table

| Signal          | Width | Purpose |
|-----------------|-------|---------|
| `reg_write`     | 1     | Enable write to register file (rd) |
| `mem_read`      | 1     | Enable memory read (loads) |
| `mem_write`     | 1     | Enable memory write (stores) |
| `mem_to_reg`    | 1     | Writeback source: 0=ALU result, 1=memory data |
| `alu_src`       | 1     | ALU operand B: 0=rs2, 1=immediate |
| `branch`        | 1     | Instruction is a conditional branch |
| `jump`          | 1     | Instruction is JAL or JALR |
| `alu_op`        | 2     | ALU operation category |
| `imm_type`      | 3     | Immediate format selector (see §4) |
| `pc_to_alu`     | 1     | ALU operand A: 0=rs1, 1=PC (for AUIPC) |
| `jalr`          | 1     | Distinguishes JALR from JAL (for PC source mux) |
| `illegal_instr` | 1     | Unrecognized opcode → halt/trap |

### 6.2 ALU Operation Categories

| alu_op [1:0] | Meaning | ALU control derivation |
|--------------|---------|----------------------|
| 2'b00        | ADD (for loads/stores/AUIPC/LUI) | alu_ctrl = 4'b0000 always |
| 2'b01        | BRANCH (comparison) | Not used — branch comparator is separate |
| 2'b10        | R-type operation | alu_ctrl derived from funct3 + funct7 |
| 2'b11        | I-type operation | alu_ctrl derived from funct3 + imm[10] for shifts |

### 6.3 Control Signal Truth Table

| Opcode    | Instruction Class | reg_write | mem_read | mem_write | mem_to_reg | alu_src | branch | jump | alu_op | imm_type | pc_to_alu | jalr |
|-----------|-------------------|-----------|----------|-----------|------------|---------|--------|------|--------|----------|-----------|------|
| 0110011   | R-type ALU        | 1         | 0        | 0         | 0          | 0       | 0      | 0    | 10     | xxx      | 0         | 0    |
| 0010011   | I-type ALU        | 1         | 0        | 0         | 0          | 1       | 0      | 0    | 11     | 000 (I)  | 0         | 0    |
| 0000011   | Loads             | 1         | 1        | 0         | 1          | 1       | 0      | 0    | 00     | 000 (I)  | 0         | 0    |
| 0100011   | Stores            | 0         | 0        | 1         | x          | 1       | 0      | 0    | 00     | 001 (S)  | 0         | 0    |
| 1100011   | Branches          | 0         | 0        | 0         | x          | 0       | 1      | 0    | 01     | 010 (B)  | 0         | 0    |
| 1101111   | JAL               | 1         | 0        | 0         | 0          | x       | 0      | 1    | xx     | 100 (J)  | 0         | 0    |
| 1100111   | JALR              | 1         | 0        | 0         | 0          | 1       | 0      | 1    | 00     | 000 (I)  | 0         | 1    |
| 0110111   | LUI               | 1         | 0        | 0         | 0          | 1       | 0      | 0    | 00     | 011 (U)  | 0         | 0    |
| 0010111   | AUIPC             | 1         | 0        | 0         | 0          | 1       | 0      | 0    | 00     | 011 (U)  | 1         | 0    |
| 0001111   | FENCE             | 0         | 0        | 0         | x          | x       | 0      | 0    | xx     | xxx      | 0         | 0    |
| 1110011   | ECALL/EBREAK      | 0         | 0        | 0         | x          | x       | 0      | 0    | xx     | xxx      | 0         | 0    |

**Notes on LUI:** The ALU computes `0 + U-imm` (effectively a pass-through of the upper immediate). The `alu_src=1` selects the immediate, and since `alu_op=00` forces ADD with `alu_ctrl=4'b0000`, the ALU input A should be zero. Implementation options: (a) feed the immediate through the ALU with rs1 forced to 0 via alu_src_a mux, or (b) add a dedicated `lui` signal. Option (a) is simpler — just ensure the ALU's A-input mux can select 0 or PC in addition to rs1.

**Notes on writeback for JAL/JALR:** The value written to rd is PC+4 (the return address), NOT the ALU result. This requires an additional mux in the writeback path: `wb_data = jump ? pc_plus_4 : (mem_to_reg ? mem_data : alu_result)`.

---

## 7. Pipeline Architecture (3-Stage)

### 7.1 Stage Definitions

```
IF (Instruction Fetch)
├── Read instruction from memory using PC
├── Compute PC+4
└── Pipeline register captures: {instruction, PC, PC+4}

EX (Execute — the "fat" stage)
├── Decode instruction (control decoder)
├── Read register file (rs1, rs2)
├── Generate immediate
├── Compute ALU result OR memory address
├── Perform memory read/write
├── Evaluate branch condition (branch comparator)
├── Compute branch/jump target
└── Select next PC

WB (Write Back)
├── Write ALU result, memory data, or PC+4 to register file
└── Pipeline register captures: {write_data, rd, reg_write, [debug signals]}
```

### 7.2 Pipeline Registers

**IF→EX Register:**
| Signal | Width | Description |
|--------|-------|-------------|
| `instruction` | 32 | Fetched instruction word |
| `pc` | 32 | PC of this instruction |
| `pc_plus_4` | 32 | PC + 4 |
| `valid` | 1 | 0 on flush (NOP bubble) |

**EX→WB Register:**
| Signal | Width | Description |
|--------|-------|-------------|
| `write_data` | 32 | Data to write to rd (ALU result, mem data, or PC+4) |
| `rd` | 5 | Destination register address |
| `reg_write` | 1 | Write enable for register file |

### 7.3 Hazard Handling

**Data Hazards — WB→EX Forwarding Only:**
```
forward_rs1 = (wb_reg_write && wb_rd != 0 && wb_rd == ex_rs1)
forward_rs2 = (wb_reg_write && wb_rd != 0 && wb_rd == ex_rs2)
```
⚠ The `wb_rd != 0` check is MANDATORY — writes to x0 must never be forwarded.

No load-use stall is needed because memory access occurs in EX — loaded data is available at WB and forwarded to the next EX.

**Control Hazards — 1-Cycle Branch Penalty:**
- Branch/jump decision is resolved in EX
- On taken branch/jump: flush the IF→EX pipeline register (insert NOP = 0x00000013)
- This is always a 1-cycle bubble

**NOP Encoding:** `ADDI x0, x0, 0` = `32'h00000013`

---

## 8. Custom ISA Extensions

### 8.1 M2a — Bit-Manipulation (Reach Goal)

**Opcode:** CUSTOM-0 = `0001011` (R-type format)

| Instruction | funct7    | funct3 | Operation | alu_ctrl | Description |
|-------------|-----------|--------|-----------|----------|-------------|
| POPCOUNT    | 0000000   | 000    | rd = popcount(rs1) | 4'b1010 | Population count (number of 1-bits) |
| BREV        | 0000001   | 000    | rd = bitreverse(rs1) | 4'b1011 | Bit reversal |
| BEXT        | 0000010   | 000    | rd = bext(rs1, rs2) | 4'b1100 | Bit extract (scatter/gather) |
| BDEP        | 0000011   | 000    | rd = bdep(rs1, rs2) | 4'b1101 | Bit deposit (scatter/gather inverse) |

**Design note:** POPCOUNT and BREV are unary (use rs1 only; rs2 ignored). BEXT and BDEP are binary (use both rs1 and rs2).

### 8.2 M2b — MAC (Stretch Goal)

| Instruction | funct7    | funct3 | Operation | alu_ctrl | Description |
|-------------|-----------|--------|-----------|----------|-------------|
| MAC         | 0000100   | 000    | rd = rs1[15:0] × rs2[15:0] + rd_old | 4'b1110 | 16×16→32 multiply-accumulate |

**Scoped to 16×16 deliberately** — keeps it single-cycle at 50MHz on 180nm. A 32×32 multiplier would require multi-cycle or pipelining the accelerator itself.

**MAC reads rd as an accumulator input.** This is a 3-read-port operation (rs1, rs2, rd_old). The register file has 2 read ports. Options: (a) add a third read port, (b) read rd in a prior cycle and latch it, (c) use a dedicated accumulator register. **This is an open design decision.**

### 8.3 Reserved alu_ctrl Codes

| alu_ctrl | Allocation |
|----------|-----------|
| 4'b0000–4'b1001 | RV32I base (defined in §5) |
| 4'b1010 | M2a: POPCOUNT |
| 4'b1011 | M2a: BREV |
| 4'b1100 | M2a: BEXT |
| 4'b1101 | M2a: BDEP |
| 4'b1110 | M2b: MAC |
| 4'b1111 | **Unallocated — reserved for future use** |

---

## 9. Chip-Level I/O

### 9.1 Minimum Pin Allocation

| Signal | Direction | Width | Notes |
|--------|-----------|-------|-------|
| `clk` | Input | 1 | External clock |
| `rst_n` | Input | 1 | Active-low async reset (synchronized internally) |
| `instr_data` | Input | 32 | Instruction from external memory |
| `instr_addr` | Output | 32 | Instruction address |
| `data_in` | Input | 32 | Read data from external data memory |
| `data_out` | Output | 32 | Write data to external data memory |
| `data_addr` | Output | 32 | Data memory address |
| `data_we` | Output | 4 | Byte write enables |
| `data_re` | Output | 1 | Read enable |
| `halt` | Output | 1 | Processor halted (ECALL/EBREAK/illegal) |

**⚠ Pin budget problem:** ~100+ signals but only ~40-60 I/O pads available on 1mm×1mm die at 180nm. Bus multiplexing or serialization required. **This is an open design decision — discuss with senior lead ar.**

### 9.2 Reset Strategy

Async assert, sync deassert — industry standard 2-FF synchronizer. Reset convention: **active-low** (`rst_n`). All pipeline registers and the PC clear to 0 on reset. Register file clears all 32 registers to 0 on reset.

---

## 10. Module Interface Contracts

### 10.1 ALU ↔ Control Decoder
- Decoder produces `alu_op[1:0]`
- ALU Control module takes `alu_op` + `funct3` + `funct7[5]` → produces `alu_ctrl[3:0]`
- `alu_ctrl` feeds directly into alu.sv's `alu_ctrl` input

### 10.2 Immediate Generator ↔ Control Decoder
- Decoder produces `imm_type[2:0]`
- Imm gen takes `imm_type` + `instruction[31:0]` → produces `imm_out[31:0]`

### 10.3 Register File ↔ Datapath
- Read ports: `rs1_addr = instruction[19:15]`, `rs2_addr = instruction[24:20]`
- Write port: `rd_addr = instruction[11:7]` (from WB stage), `wr_en = reg_write` (from WB stage)
- Forwarding muxes sit BETWEEN regfile read outputs and ALU inputs

### 10.4 Branch Comparator ↔ Datapath
- Inputs: `rs1_data`, `rs2_data`, `funct3[2:0]`
- Output: `branch_taken` (1 bit)
- PC logic: `next_pc = (branch && branch_taken) || jump ? branch_target : pc_plus_4`

---

## 11. Verification Anchors

These are the golden reference values that testbenches should check against:

**NOP:** `32'h00000013` = ADDI x0, x0, 0
**Max positive I-imm:** `32'h7FF` = 2047
**Max negative I-imm:** `32'h800` sign-extended = `32'hFFFFF800` = -2048
**LUI 0xDEADB:** `32'hDEADB137` → rd = `32'hDEADB000`
**AUIPC at PC=0x100, imm=0x12345:** rd = `0x100 + 0x12345000` = `0x12345100`

---

*End of canonical reference. If a question cannot be answered from this document, flag it as an open design decision.*
