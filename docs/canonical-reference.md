# Spec Agent — Canonical Reference

> **Purpose:** This is the single source of truth for the RV32I processor design. Every encoding, signal definition, and architectural decision lives here.
> **Last updated:** April 14, 2026

> **M0 SCOPE (confirmed by ar, April 2026):** instruction → decode → regfile read → ALU → regfile writeback. No PC, no instruction memory, no data memory, no branches, no loads/stores, no hazard logic. Modules: alu.sv, regfile.sv, imm_gen.sv, control_decoder.sv, alu_control.sv, datapath_m0.sv.
>
> **⚠ UNRESOLVED ITEMS** (do not treat as settled until confirmed with ar):
> - Custom instruction set: POPCOUNT, BREV, CLZ confirmed and implemented. BEXT and BDEP reserved but not yet implemented. MAC simplified to MUL16S (no accumulator).
> - Halt pin: single `halt` output = OR(halt_o, illegal_instr_o), or two separate pads? (not blocking M0)
> - 4-bit alu_ctrl space is fully exhausted (§8.3). Any future instruction requires expanding to 5 bits.

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
| SB          | 000    | mem[rs1+imm][7:0] = rs2[7:0]   | 4'b0000 | Store data placed in byte lane matching addr[1:0]. data_we = 4'b0001 << addr[1:0] |
| SH          | 001    | mem[rs1+imm][15:0] = rs2[15:0] | 4'b0000 | ⚠ S-type has NO rd — imm split across funct7+rd fields. data_we = addr[1] ? 4'b1100 : 4'b0011 |
| SW          | 010    | mem[rs1+imm][31:0] = rs2[31:0] | 4'b0000 | data_we = 4'b1111 |

**Memory interface decisions (confirmed by ar, April 2026):**
- `data_we[3:0]` is **active-high**, one bit per byte lane (AXI/AMBA convention)
- Store data is **byte-lane-aligned**: byte goes in the lane matching its address, not shifted to [7:0]
- Load extension (sign/zero) happens **inside the core**
- **Misaligned access is undefined behavior** — no trap logic required

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

Any opcode not in this table → `illegal_instr_o = 1`. ECALL/EBREAK → `halt_o = 1` (not `illegal_instr_o`).

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
| 4'b0000        | ADD       | R-type ADD, all loads, all stores, ADDI, LUI (0+U-imm), AUIPC (PC+U-imm), JAL target (PC+J-imm), JALR target (rs1+I-imm), FENCE/ECALL/EBREAK (safe default) |
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
| `alu_src_a`     | 2     | ALU operand A: 00=rs1, 01=PC (AUIPC/JAL), 10=zero (LUI) |
| `branch`        | 1     | Instruction is a conditional branch |
| `jump`          | 1     | Instruction is JAL or JALR |
| `alu_op`        | 2     | ALU operation category |
| `imm_type`      | 3     | Immediate format selector (see §4) |
| `jalr`          | 1     | Distinguishes JALR from JAL (for PC source mux) |
| `halt`          | 1     | ECALL/EBREAK — assert halt/trap pin |
| `illegal_instr` | 1     | Unrecognized opcode (not ECALL/EBREAK) |

### 6.2 ALU Operation Categories

| alu_op [1:0] | Meaning | ALU control derivation |
|--------------|---------|----------------------|
| 2'b00        | ADD (loads/stores/LUI/AUIPC/JAL/JALR/FENCE/ECALL/EBREAK) | alu_ctrl = 4'b0000 always |
| 2'b01        | BRANCH | alu_control must output alu_ctrl=4'b0000 (ADD) as safe default; ALU result discarded — branch comparator handles comparison |
| 2'b10        | R-type operation | alu_ctrl derived from funct3 + funct7 |
| 2'b11        | I-type operation | alu_ctrl derived from funct3 + imm[10] for shifts |

### 6.3 Control Signal Truth Table

| Opcode    | Instruction Class | reg_write | mem_read | mem_write | mem_to_reg | alu_src | branch | jump | alu_op | imm_type | alu_src_a | jalr | halt |
|-----------|-------------------|-----------|----------|-----------|------------|---------|--------|------|--------|----------|-----------|------|------|
| 0110011   | R-type ALU        | 1         | 0        | 0         | 0          | 0       | 0      | 0    | 10     | xxx      | 00        | 0    | 0    |
| 0010011   | I-type ALU        | 1         | 0        | 0         | 0          | 1       | 0      | 0    | 11     | 000 (I)  | 00        | 0    | 0    |
| 0000011   | Loads             | 1         | 1        | 0         | 1          | 1       | 0      | 0    | 00     | 000 (I)  | 00        | 0    | 0    |
| 0100011   | Stores            | 0         | 0        | 1         | x          | 1       | 0      | 0    | 00     | 001 (S)  | 00        | 0    | 0    |
| 1100011   | Branches          | 0         | 0        | 0         | x          | 0       | 1      | 0    | 01     | 010 (B)  | 00        | 0    | 0    |
| 1101111   | JAL               | 1         | 0        | 0         | 0          | 1       | 0      | 1    | 00     | 100 (J)  | 01 (PC)   | 0    | 0    |
| 1100111   | JALR              | 1         | 0        | 0         | 0          | 1       | 0      | 1    | 00     | 000 (I)  | 00        | 1    | 0    |
| 0110111   | LUI               | 1         | 0        | 0         | 0          | 1       | 0      | 0    | 00     | 011 (U)  | 10 (zero) | 0    | 0    |
| 0010111   | AUIPC             | 1         | 0        | 0         | 0          | 1       | 0      | 0    | 00     | 011 (U)  | 01 (PC)   | 0    | 0    |
| 0001111   | FENCE             | 0         | 0        | 0         | x          | x       | 0      | 0    | 00     | xxx      | 00        | 0    | 0    |
| 1110011   | ECALL/EBREAK      | 0         | 0        | 0         | x          | x       | 0      | 0    | 00     | xxx      | 00        | 0    | 1    |

`illegal_instr_o=1` for any opcode not in this table (driven by control_decoder default case).

**Notes on LUI:** The ALU computes `0 + U-imm`. `alu_src_a=10` (zero) selects zero for ALU-A; `alu_src=1` selects the U-immediate for ALU-B; `alu_op=00` forces ADD → result = U-imm, written to rd. The datapath ALU-A mux must implement the three-input structure: `00`=rs1, `01`=PC, `10`=zero (decided April 2026).

**Notes on JAL:** The ALU computes the jump target: `PC + sext(J-imm)` via `alu_src_a=01` (PC) and `alu_src=1` (J-imm). The link address (PC+4) written to rd comes from the dedicated PC+4 adder — the datapath writeback mux selects PC+4 when `jump=1` (see writeback note below).

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
forward_rs1 = (wb_reg_write && wb_rd != 0 && wb_rd == ex_rs1) && (alu_src_a == 2'b00)
forward_rs2 = (wb_reg_write && wb_rd != 0 && wb_rd == ex_rs2)
```
⚠ The `wb_rd != 0` check is MANDATORY — writes to x0 must never be forwarded.
⚠ The `alu_src_a == 2'b00` gate on `forward_rs1` is MANDATORY — when ALU-A is PC (AUIPC, JAL) or zero (LUI), forwarding must be suppressed or it will corrupt the result. `forward_rs2` has no equivalent gate since ALU-B is always rs2 or an immediate (never PC or zero).
⚠ **Store forwarding:** For store instructions, `rs2` is the store *data* (not an ALU operand) and routes directly to the memory write port — it does not pass through the `alu_src` mux. `forward_rs2` must therefore be routed to both (a) the ALU-B forwarding mux and (b) the store data path. A store that immediately follows a WB-stage write to the same register requires store data forwarding; failing to forward produces a silent write of stale data.

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
| CLZ         | 0000101   | 000    | rd = clz(rs1) | 4'b1111 | Count leading zeros (0-32; 32 when rs1=0) |

**Design note:** POPCOUNT, BREV, and CLZ are unary (use rs1 only; rs2 ignored). BEXT and BDEP are binary (use both rs1 and rs2). CLZ result is 32 when rs1=0 (all zeros), 0 when rs1[31]=1.

### 8.2 M2b — MUL16S (16×16 Signed Multiply)

| Instruction | funct7    | funct3 | Operation | alu_ctrl | Description |
|-------------|-----------|--------|-----------|----------|-------------|
| MUL16S      | 0000100   | 000    | rd = sext(rs1[15:0]) × sext(rs2[15:0]) | 4'b1110 | Signed 16×16→32 multiply |

**Scoped to 16×16 deliberately** — keeps it single-cycle at 50MHz on 180nm. A 32×32 multiplier would require multi-cycle or pipelining the accelerator itself.

**No accumulator.** Originally designed as MAC (multiply-accumulate), simplified to multiply-only to avoid a 3-read-port register file. Software handles accumulation: `MUL16S rd_temp, rs1, rs2` then `ADD rd, rd, rd_temp`. This is the same approach as the RISC-V M extension (MUL separate from ADD).

**Signed operands.** rs1[15:0] and rs2[15:0] are sign-extended to 32 bits before multiplication. Signed is more generally useful for DSP workloads (FIR filters, dot products).

**RTL constraint:** No `*` operator in synthesizable RTL. Must use a combinational partial-product tree (Wallace tree or balanced adder tree). A naive 16-serial-adder chain will NOT meet timing at 50 MHz / 180nm. The parallel tree structure compresses to ~4 adder levels (~6-8 ns), well within the 20 ns period.

### 8.3 Reserved alu_ctrl Codes

| alu_ctrl | Allocation |
|----------|-----------|
| 4'b0000–4'b1001 | RV32I base (defined in §5) |
| 4'b1010 | M2a: POPCOUNT |
| 4'b1011 | M2a: BREV |
| 4'b1100 | M2a: BEXT |
| 4'b1101 | M2a: BDEP |
| 4'b1110 | M2b: MUL16S |
| 4'b1111 | M2a: CLZ |

**Note:** The 4-bit alu_ctrl space is now fully exhausted. Any future custom instruction requires expanding alu_ctrl to 5 bits.

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
| `data_we` | Output | 4 | Byte write enables — **active-high, AXI/AMBA convention, one bit per byte lane** |
| `data_re` | Output | 1 | Read enable |
| `halt` | Output | 1 | Processor halted — driven by `halt_o \|\| illegal_instr_o` from decoder (⚠ pending ar confirmation: one pin or two?) |

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

## 12. RV32C — Compressed Instructions (M2c)

> **Status:** QC-passed and pipeline-integrated (April 2026). Verified with 220 decoder unit vectors + 41 pipeline integration vectors. This section is normative for `compressed_decoder` and the IF-stage alignment buffer.

### 12.1 Overview

RV32C instructions are **16-bit encodings** that expand to a canonical 32-bit RV32I instruction before entering the pipeline. The expansion is purely combinational and happens in the IF stage; the rest of the pipeline sees only 32-bit instructions.

**Quadrant identification:** bits [1:0] of every instruction word.

| inst[1:0] | Quadrant | Name |
|-----------|----------|------|
| `00`      | Q0       | C0   |
| `01`      | Q1       | C1   |
| `10`      | Q2       | C2   |
| `11`      | —        | 32-bit (not compressed) |

⚠ **A 16-bit word of `16'h0000` (all zeros) is always illegal**, regardless of quadrant. The decoder explicitly asserts `illegal_o=1` for this encoding.

**Primary decode key:** `{inst[15:13], inst[1:0]}` — a 5-bit value that selects the instruction within a quadrant.

**Instruction count supported:** 25 RV32C instructions (all architecturally defined RV32C encodings except floating-point, which are marked illegal in this implementation).

---

### 12.2 Compressed Instruction Formats — Bit Layouts

All widths are 16 bits. Fields that span non-contiguous bit positions are shown explicitly.

```
CR-format  (register):
  [15:12 funct4 | 11:7 rd/rs1 | 6:2 rs2 | 1:0 op]

CI-format  (immediate):
  [15:13 funct3 | 12 imm[part] | 11:7 rd/rs1 | 6:2 imm[part] | 1:0 op]

CSS-format (stack-relative store):
  [15:13 funct3 | 12:7 uimm | 6:2 rs2 | 1:0 op]

CIW-format (wide immediate):
  [15:13 funct3 | 12:5 nzuimm | 4:2 rd' | 1:0 op]

CL-format  (load):
  [15:13 funct3 | 12:10 uimm[part] | 9:7 rs1' | 6:5 uimm[part] | 4:2 rd' | 1:0 op]

CS-format  (store):
  [15:13 funct3 | 12:10 uimm[part] | 9:7 rs1' | 6:5 uimm[part] | 4:2 rs2' | 1:0 op]

CB-format  (branch / shift / ANDI):
  [15:13 funct3 | 12:10 offset/funct2+shamt | 9:7 rs1' | 6:2 offset/imm | 1:0 op]

CJ-format  (jump):
  [15:13 funct3 | 12:2 jump-target | 1:0 op]
```

**Compressed register notation:**
- `rd'`, `rs1'`, `rs2'` (primed) — 3-bit encoded, map to x8–x15 (see §12.6).
- `rd`, `rs1`, `rs2` (unprimed) — full 5-bit encoded, can address x0–x31.

---

### 12.3 Quadrant 0 (C0) — `inst[1:0] = 00`

Decode key: `inst[15:13]`

| inst[15:13] | Instruction    | Format | Expansion | Notes |
|-------------|----------------|--------|-----------|-------|
| `000`       | C.ADDI4SPN     | CIW    | `ADDI rd', x2, nzuimm` | nzuimm=0 → **illegal** |
| `001`       | _(C.FLD)_      | —      | **illegal** | F-extension; not implemented |
| `010`       | C.LW           | CL     | `LW rd', uimm(rs1')` | |
| `011`       | _(C.FLW)_      | —      | **illegal** | F-extension; not implemented |
| `100`       | _(reserved)_   | —      | **illegal** | Architecturally reserved in C0 |
| `101`       | _(C.FSD)_      | —      | **illegal** | F-extension; not implemented |
| `110`       | C.SW           | CS     | `SW rs2', uimm(rs1')` | |
| `111`       | _(C.FSW)_      | —      | **illegal** | F-extension; not implemented |

**C.ADDI4SPN immediate reconstruction** — produces a 10-bit non-zero unsigned immediate scaled by 1 (byte offset):

```
nzuimm[9:2] = { inst[10:7], inst[12:11], inst[5], inst[6] }
nzuimm[1:0] = 2'b00  (word-aligned; always zero)
12-bit zero-extended: { 2'b00, inst[10:7], inst[12:11], inst[5], inst[6], 2'b00 }
```

**C.LW / C.SW offset reconstruction** — 7-bit unsigned, word-aligned:

```
uimm[6:0] = { inst[5], inst[12:10], inst[6], 2'b00 }
```

Zero-extended to 12 bits for I-type (LW); split across imm[11:5]/imm[4:0] for S-type (SW).

---

### 12.4 Quadrant 1 (C1) — `inst[1:0] = 01`

Decode key: `inst[15:13]`

| inst[15:13] | Instruction      | Format | Expansion | Notes |
|-------------|------------------|--------|-----------|-------|
| `000`       | C.NOP / C.ADDI   | CI     | `ADDI rd, rd, sext(nzimm)` | rd=x0 or imm=0 → HINT (expands to valid ADDI; see Note A) |
| `001`       | C.JAL            | CJ     | `JAL x1, sext(offset)` | RV32 only; RV64 encodes C.ADDIW here |
| `010`       | C.LI             | CI     | `ADDI rd, x0, sext(imm)` | |
| `011`       | C.LUI / C.ADDI16SP | CI   | See Note B | rd=x2 → C.ADDI16SP; rd=x0 → HINT (NOP); else C.LUI |
| `100`       | C.SRLI / C.SRAI / C.ANDI / arithmetic | CB/CR | See §12.4.1 | Sub-decoded by inst[11:10] |
| `101`       | C.J              | CJ     | `JAL x0, sext(offset)` | Unconditional jump; discards link |
| `110`       | C.BEQZ           | CB     | `BEQ rs1', x0, sext(offset)` | |
| `111`       | C.BNEZ           | CB     | `BNE rs1', x0, sext(offset)` | |

**Note A — C.NOP / C.ADDI HINT behavior:** The decoder always produces `ADDI rd, rd, sext(nzimm)` regardless of HINT conditions. When rd=x0 (any imm) or imm=0 (any rd), this is architecturally a HINT; the expansion is correct because `ADDI x0, x0, 0` = NOP and `ADDI rd, rd, 0` is a no-op to any register.

**Note B — C.LUI / C.ADDI16SP disambiguation:**
- `rd = x2`: C.ADDI16SP → `ADDI x2, x2, sext(nzimm×16)`. nzimm=0 → **illegal**.
- `rd = x0`: HINT → expands to NOP (`32'h00000013`).
- `rd ≠ x0, x2`: C.LUI → `LUI rd, nzimm[17:12]`. nzimm=0 → **illegal**.

**C.ADDI / C.LI / C.ANDI shared immediate** — 6-bit signed, sign-extended to 12 bits:

```
imm[5:0] = { inst[12], inst[6:2] }
12-bit sign-extended: { {6{inst[12]}}, inst[12], inst[6:2] }
```

**C.ADDI16SP immediate** — 10-bit signed, word-aligned by 16:

```
nzimm[9:0] = { inst[12], inst[4:3], inst[5], inst[2], inst[6], 4'b0000 }
12-bit sign-extended: { {2{inst[12]}}, inst[12], inst[4:3], inst[5], inst[2], inst[6], 4'b0000 }
```

**C.LUI immediate** — 6-bit nzimm placed in bits [17:12] of U-type upper immediate:

```
nzimm[17:12] = { inst[12], inst[6:2] }
20-bit U-type: { {14{inst[12]}}, inst[12], inst[6:2] }   (sign-extended to fill bits [31:12])
```

**C.JAL / C.J jump offset** — 12-bit signed offset, reconstructed as a 21-bit J-type immediate:

```
offset raw bits (bit positions in the logical 12-bit value):
  bit[11] = inst[12]   (sign)
  bit[10] = inst[8]
  bit[9]  = inst[10]
  bit[8]  = inst[9]
  bit[7]  = inst[6]
  bit[6]  = inst[7]
  bit[5]  = inst[2]
  bit[4]  = inst[11]
  bit[3]  = inst[5]
  bit[2]  = inst[4]
  bit[1]  = inst[3]
  bit[0]  = 1'b0       (×2 alignment)

21-bit J-type immediate (direct wire mapping for RV32I JAL encoding):
  imm_jal_21 = { {9{inst[12]}}, inst[12], inst[8], inst[10:9],
                  inst[6], inst[7], inst[2], inst[11], inst[5:3], 1'b0 }
```

**C.BEQZ / C.BNEZ branch offset** — 9-bit signed offset, reconstructed as a 13-bit B-type immediate:

```
offset raw bits (bit positions in the logical 9-bit value):
  bit[8] = inst[12]   (sign)
  bit[7] = inst[6]
  bit[6] = inst[5]
  bit[5] = inst[2]
  bit[4] = inst[11]
  bit[3] = inst[10]
  bit[2] = inst[4]
  bit[1] = inst[3]
  bit[0] = 1'b0       (×2 alignment)

13-bit B-type immediate (direct wire mapping for RV32I BEQ/BNE encoding):
  imm_br_13 = { {4{inst[12]}}, inst[12], inst[6:5], inst[2],
                 inst[11:10], inst[4:3], 1'b0 }
```

#### 12.4.1 C1 funct3=100 Sub-decode (inst[11:10])

| inst[11:10] | Instruction | Expansion | Notes |
|-------------|-------------|-----------|-------|
| `00`        | C.SRLI      | `SRLI rd', rd', shamt` | shamt[5]=inst[12]=1 → **illegal** on RV32 |
| `01`        | C.SRAI      | `SRAI rd', rd', shamt` | shamt[5]=inst[12]=1 → **illegal** on RV32 |
| `10`        | C.ANDI      | `ANDI rd', rd', sext(imm)` | imm from shared 6-bit field |
| `11`        | C.SUB / C.XOR / C.OR / C.AND | See §12.4.2 | inst[12]=1 → **illegal** (RV64-only encodings) |

**SRLI / SRAI shamt field:**

```
shamt[5:0] = { inst[12], inst[6:2] }
```

⚠ shamt[5] (= inst[12]) **must be 0** on RV32. shamt[5]=1 is illegal for C.SRLI, C.SRAI, and C.SLLI (§12.7).

#### 12.4.2 C1 funct3=100, inst[11:10]=11 Sub-decode (inst[12]=0 required, inst[6:5])

| inst[12] | inst[6:5] | Instruction | Expansion |
|----------|-----------|-------------|-----------|
| `0`      | `00`      | C.SUB       | `SUB rd', rd', rs2'` |
| `0`      | `01`      | C.XOR       | `XOR rd', rd', rs2'` |
| `0`      | `10`      | C.OR        | `OR  rd', rd', rs2'` |
| `0`      | `11`      | C.AND       | `AND rd', rd', rs2'` |
| `1`      | any       | _(C.SUBW / C.ADDW)_ | **illegal** — RV64 encodings, not valid on RV32 |

---

### 12.5 Quadrant 2 (C2) — `inst[1:0] = 10`

Decode key: `inst[15:13]`

| inst[15:13] | Instruction     | Format | Expansion | Notes |
|-------------|-----------------|--------|-----------|-------|
| `000`       | C.SLLI          | CI     | `SLLI rd, rd, shamt` | shamt[5]=inst[12]=1 → **illegal** on RV32; rd=x0 is HINT |
| `001`       | _(C.FLDSP)_     | —      | **illegal** | F-extension; not implemented |
| `010`       | C.LWSP          | CI     | `LW rd, uimm(x2)` | rd=x0 → **illegal** |
| `011`       | _(C.FLWSP)_     | —      | **illegal** | F-extension; not implemented |
| `100`       | C.JR / C.MV / C.EBREAK / C.JALR / C.ADD | CR | See §12.5.1 | |
| `101`       | _(C.FSDSP)_     | —      | **illegal** | F-extension; not implemented |
| `110`       | C.SWSP          | CSS    | `SW rs2, uimm(x2)` | |
| `111`       | _(C.FSWSP)_     | —      | **illegal** | F-extension; not implemented |

**C.SLLI shamt** — same 6-bit field as SRLI/SRAI (see §12.4.1). shamt[5]=1 → **illegal**.

**C.LWSP offset** — 8-bit unsigned, word-aligned:

```
uimm[7:0] = { inst[3:2], inst[12], inst[6:4], 2'b00 }
12-bit zero-extended: { 4'b0000, inst[3:2], inst[12], inst[6:4], 2'b00 }
```

**C.SWSP offset** — 8-bit unsigned, word-aligned:

```
uimm[7:0] = { inst[8:7], inst[12:9], 2'b00 }
S-type split: imm[11:5] = { 4'b0000, uimm[7:5] }
              imm[4:0]  = uimm[4:0]
```

#### 12.5.1 C2 funct3=100 Sub-decode (inst[12], inst[6:2])

| inst[12] | inst[11:7] (rd) | inst[6:2] (rs2) | Instruction | Expansion |
|----------|-----------------|-----------------|-------------|-----------|
| `0`      | ≠ x0            | = 0             | C.JR        | `JALR x0, 0(rs1)` — indirect jump, no link |
| `0`      | x0              | = 0             | _(reserved)_ | **illegal** |
| `0`      | any             | ≠ 0             | C.MV        | `ADD rd, x0, rs2` — register copy |
| `1`      | = x0            | = 0             | C.EBREAK    | `EBREAK` (= `32'h00100073`) |
| `1`      | ≠ x0            | = 0             | C.JALR      | `JALR x1, 0(rs1)` — indirect call, link to x1 |
| `1`      | any             | ≠ 0             | C.ADD       | `ADD rd, rd, rs2` |

**Register fields for C2 funct3=100:** `rd` and `rs2` use the **full 5-bit** unprimed encoding:
- `rd` / `rs1` = inst[11:7]
- `rs2` = inst[6:2]

---

### 12.6 Compressed Register Mapping

Compressed instructions with primed register operands (`rd'`, `rs1'`, `rs2'`) encode a 3-bit register index that maps to the integer registers x8–x15.

| 3-bit encoding | Register | ABI name |
|----------------|----------|----------|
| `000`          | x8       | s0/fp    |
| `001`          | x9       | s1       |
| `010`          | x10      | a0       |
| `011`          | x11      | a1       |
| `100`          | x12      | a2       |
| `101`          | x13      | a3       |
| `110`          | x14      | a4       |
| `111`          | x15      | a5       |

**Bit positions per format:**
- `rd'`  = inst[4:2], expanded as `{2'b01, inst[4:2]}`
- `rs1'` = inst[9:7], expanded as `{2'b01, inst[9:7]}`
- `rs2'` = inst[4:2], expanded as `{2'b01, inst[4:2]}` (same bits as rd' in CS/CL formats)

---

### 12.7 Illegal / Reserved Instruction Conditions

All conditions below cause `illegal_o = 1` from `compressed_decoder`. The pipeline treats `illegal_o` identically to `illegal_instr_o` from the 32-bit control decoder — both assert `halt_o`.

| Rule | Encoding | Condition | Reason |
|------|----------|-----------|--------|
| 1    | Any quadrant | `instr_i == 16'h0000` | All-zeros is architecturally defined as illegal |
| 2    | C0: inst[15:13] = 001, 011, 101, 111 | Always | C.FLD, C.FLW, C.FSD, C.FSW — F-extension, not implemented |
| 2b   | C0: inst[15:13] = 100 | Always | Architecturally reserved in C0 |
| 3    | C2: inst[15:13] = 001, 011, 101, 111 | Always | C.FLDSP, C.FLWSP, C.FSDSP, C.FSWSP — F-extension, not implemented |
| 4    | C.ADDI4SPN (C0/000) | nzuimm = 0 | Spec requires non-zero immediate |
| 5    | C.ADDI16SP (C1/011, rd=x2) | nzimm = 0 | Spec requires non-zero immediate |
| 6    | C.LUI (C1/011, rd≠x0,x2) | nzimm = 0 | Spec requires non-zero immediate |
| 7    | C.LWSP (C2/010) | rd = x0 | Loading into x0 is architecturally reserved |
| 8    | C.JR (C2/100, inst[12]=0, rs2=0) | rd/rs1 = x0 | Jumping to address in x0 is reserved |
| 9    | **C.SLLI** (C2/000) | **shamt[5] = inst[12] = 1** | **RV32: shift amount > 31 is illegal** |
| 9    | **C.SRLI** (C1/100, inst[11:10]=00) | **shamt[5] = inst[12] = 1** | **RV32: shift amount > 31 is illegal** |
| 9    | **C.SRAI** (C1/100, inst[11:10]=01) | **shamt[5] = inst[12] = 1** | **RV32: shift amount > 31 is illegal** |
| 10   | C1/100, inst[11:10]=11 | inst[12] = 1 | Encodes C.SUBW/C.ADDW (RV64 only) — illegal on RV32 |

⚠ **Rule 9 applies to all three shift instructions.** All use the same shamt field `{inst[12], inst[6:2]}`. The shamt[5]=1 check is evaluated identically for C.SLLI, C.SRLI, and C.SRAI.

---

### 12.8 Pipeline Integration — IF-Stage Alignment Buffer

#### 12.8.1 Architecture

The alignment buffer allows zero-stall decode of any mix of 16-bit and 32-bit instructions. It consists of **17 flip-flops**:
- `upper_buf[15:0]` — 16-bit register holding the saved upper halfword of a previously fetched 32-bit word
- `upper_valid` — 1-bit flag indicating `upper_buf` holds a valid halfword

The instruction memory interface fetches **32-bit aligned words** at all times. The PC may point to a halfword-aligned address when executing compressed instructions.

#### 12.8.2 Instruction Memory Address Computation

```
instr_addr_o = upper_valid ? { pc_reg[31:2] + 30'd1, 2'b00 }
                            : { pc_reg[31:2], 2'b00 }
```

When `upper_valid=1`, the upper half of the previously fetched word is already buffered, so the memory must supply the **next** word (PC+4 aligned). When `upper_valid=0`, the fetch address is the word containing PC.

#### 12.8.3 Compression Detection and Halfword Selection

```
selected_hw   = upper_valid ? upper_buf : instr_data_i[15:0]
is_compressed = (selected_hw[1:0] != 2'b11)
```

The halfword being processed this cycle is always `selected_hw`. `is_compressed` is determined purely by bits [1:0] of that halfword.

#### 12.8.4 Raw Instruction Assembly (pre-expansion)

Three cases, evaluated combinationally:

| Case | Condition | raw_instr |
|------|-----------|-----------|
| Compressed | `is_compressed` | `{16'h0000, selected_hw}` — upper 16 bits unused; decoder sees [15:0] |
| Straddling 32-bit | `!is_compressed && upper_valid` | `{instr_data_i[15:0], upper_buf}` — upper buf is low half, new fetch is high half |
| Word-aligned 32-bit | `!is_compressed && !upper_valid` | `instr_data_i` — direct from memory |

The `compressed_decoder` receives `selected_hw` (not `raw_instr`) and produces `expanded_instr_c`. The final instruction sent to the IF/EX register is:

```
expanded_instr = is_compressed ? expanded_instr_c : raw_instr
```

#### 12.8.5 Alignment Buffer State Transitions

The buffer is updated on every cycle (synchronous, async reset). A flush (taken branch or jump) clears the buffer immediately.

| Condition | Next state |
|-----------|------------|
| Reset or flush | `upper_valid ← 0`, `upper_buf ← 0` |
| `is_compressed && !upper_valid` | Lower half was compressed; **save upper half**: `upper_buf ← instr_data_i[31:16]`, `upper_valid ← 1` |
| `is_compressed && upper_valid` | Consumed the buffered halfword; **clear**: `upper_valid ← 0` |
| `!is_compressed && upper_valid` | Straddling 32-bit consumed `upper_buf`; **save new upper half**: `upper_buf ← instr_data_i[31:16]`, `upper_valid ← 1` |
| `!is_compressed && !upper_valid` | Word-aligned 32-bit; **no buffering**: `upper_valid ← 0` |

#### 12.8.6 PC Increment

```
pc_plus_2   = pc_reg + 32'd2
pc_increment = is_compressed ? pc_plus_2 : pc_plus_4
```

The IF/EX pipeline register latches `pc_increment` as `if_ex_pc_plus_n`, which serves as the return address for compressed JAL/JALR (C.JAL, C.JALR) — they write `PC+2` to the link register, not `PC+4`.

#### 12.8.7 Zero-Stall Property

The alignment buffer delivers **one instruction per cycle** with no pipeline stalls for mixed 16-bit/32-bit streams. The only stall case that exists in the design is the pre-existing 1-cycle branch/jump flush (§7.3), which is unchanged. There is no fetch stall caused by compressed instructions.

#### 12.8.8 Flush Behavior

On `flush_if_ex`:
1. The IF/EX pipeline register is cleared to NOP (`32'h00000013`, valid=0).
2. The alignment buffer is reset (`upper_valid ← 0`).
3. The PC is updated to the branch/jump target.

This ensures that a stale buffered halfword from before the flush does not contaminate the instruction stream after the redirect.

---

## 13. Chip-Level MMIO Wrapper (chip_top)

> **Status:** Interface contract confirmed April 2026 (M2-wrap milestone).
> This section is normative for `chip_top` and all testbenches that
> exercise the MMIO interface.

### 13.1 External Port Table

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `clk` | in | 1 | External clock |
| `rst_n` | in | 1 | Pad-level active-low async reset (fed through reset synchronizer) |
| `data_i` | in | 32 | Host write data bus |
| `data_o` | out | 32 | Host read data bus |
| `addr_cmd_i` | in | 3 | Register/command select (8 addresses, see §13.2) |
| `wr_en_i` | in | 1 | Write strobe — captured on rising `clk` edge |
| `rd_en_i` | in | 1 | Read strobe — combinational read; `data_o` valid same cycle |
| `busy_o` | out | 1 | High while wrapper is processing (LOADING or RUNNING state) |
| `done_o` | out | 1 | High when CPU has halted (DONE state) |

Port naming follows `docs/conventions.md`: `_i`/`_o` suffixes on all ports except `clk` and `rst_n`.

---

### 13.2 Command Register Map

Addressed by `addr_cmd_i[2:0]`. All registers are 32 bits wide.

| addr_cmd | Register | R/W | Description |
|----------|----------|-----|-------------|
| `3'h0` | CMD | W | Command code (see §13.3); write triggers FSM action |
| `3'h1` | ADDR | W | Target memory word address |
| `3'h2` | WDATA | W | Write data for LOAD_IMEM / LOAD_DMEM commands |
| `3'h3` | RDATA | R | Read data result from READ_DMEM / READ_IMEM commands |
| `3'h4` | STATUS | R | `{28'b0, state[3:0]}` — current FSM state (see §13.5) |
| `3'h5` | PC | R | Current PC: sourced from `instr_addr_o` of pipeline_top |
| `3'h6` | CYCLE_CNT | R | 32-bit cycle counter; counts in RUNNING state only |
| `3'h7` | (reserved) | — | Returns `32'h0`; writes ignored |

Write-only registers (CMD, ADDR, WDATA) return `32'h0` on a read.
Read-only registers (RDATA, STATUS, PC, CYCLE_CNT) ignore writes.

---

### 13.3 CMD Codes (`data_i[3:0]` when writing to 3'h0)

| Code | Name | Action |
|------|------|--------|
| `4'h0` | NOP | No operation; FSM stays in current state |
| `4'h1` | LOAD_IMEM | Write `WDATA` to `imem[ADDR]` |
| `4'h2` | LOAD_DMEM | Write `WDATA` to `dmem[ADDR]` |
| `4'h3` | RUN | Release pipeline_top from reset; FSM enters RUNNING |
| `4'h4` | HALT | Force pipeline_top back into reset; FSM returns to IDLE |
| `4'h5` | READ_DMEM | Read `dmem[ADDR]` into RDATA register |
| `4'h6` | READ_IMEM | Read `imem[ADDR]` into RDATA register |

All other codes (`4'h7`–`4'hF`) are treated as NOP.

---

### 13.4 Memory Architecture

| Parameter | Default | Description |
|-----------|---------|-------------|
| `IMEM_DEPTH` | 64 | Number of 32-bit words in instruction memory |
| `DMEM_DEPTH` | 64 | Number of 32-bit words in data memory |

Both memories are **FF-based** (no SRAM until M3). Both are
**word-addressed**: `ADDR` register holds a word index, not a byte
address. Combinational read. Synchronous write on `clk` rising edge.

During RUNNING state, instruction memory read port is driven by
`instr_addr_o` from pipeline_top (word index = `instr_addr_o[AW+1:2]`).
Data memory is driven by `data_addr_o[AW+1:2]` for reads and writes
with `data_we_o[3:0]` byte-lane enables.

---

### 13.5 FSM States and Transitions

States encoded as `logic [3:0]` to match STATUS register layout.

| State | Encoding | Description |
|-------|----------|-------------|
| IDLE | `4'h0` | Reset state; pipeline_top held in reset; awaiting commands |
| LOADING | `4'h1` | Processing LOAD_IMEM or LOAD_DMEM; `busy_o = 1` |
| RUNNING | `4'h2` | pipeline_top executing; `busy_o = 1` |
| DONE | `4'h3` | pipeline_top halted; `done_o = 1`; `busy_o = 0` |

**Transition table:**

| From | Trigger | To |
|------|---------|----|
| IDLE | CMD = RUN | RUNNING |
| IDLE | CMD = LOAD_IMEM or LOAD_DMEM | LOADING |
| LOADING | write completes (single-cycle) | IDLE |
| RUNNING | `halt_o` asserted | DONE |
| RUNNING | CMD = HALT | IDLE |
| DONE | CMD = HALT | IDLE |
| Any | `rst_n_sync` deasserted | IDLE |

LOADING is a single-cycle transient state: the write to FF memory
completes in one clock, and the FSM returns to IDLE the next cycle.

---

### 13.6 pipeline_top Integration

**Reset control:** pipeline_top's `rst_n` is asserted (held low) in
IDLE, LOADING, and DONE states. It is deasserted (high) only in RUNNING.

**Reset synchronizer (§9.2):** Pad-level `rst_n` passes through a 2-FF
async-assert, sync-deassert synchronizer. All chip_top sequential logic
uses the synchronized output `rst_n_sync`.

**Memory mux:** Combinational mux selects address/data/write-enable
sources: pipeline_top in RUNNING, wrapper in all other states.

**Halt latching:** `halt_o` from pipeline_top is sampled on the rising
clock edge. The registered `halt_latched` signal drives the DONE
transition and `done_o` output.

**Cycle counter:** 32-bit counter increments every cycle in RUNNING
state. Cleared on reset. Does not increment in other states.

### 13.7 Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `IMEM_DEPTH` | integer | 64 | Words in instruction FF memory |
| `DMEM_DEPTH` | integer | 64 | Words in data FF memory |

Derived localparams:
- `IMEM_AW = $clog2(IMEM_DEPTH)` — address width for imem index
- `DMEM_AW = $clog2(DMEM_DEPTH)` — address width for dmem index

---

*End of canonical reference. If a question cannot be answered from this document, flag it as an open design decision.*
