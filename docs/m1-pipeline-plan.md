# M1 Pipeline Implementation Plan

> **Status:** Approved for implementation
> **Date:** April 12, 2026
> **Author:** Beaux Cable
> **Target:** ~May 1, 2026

## Context

M0 (single-cycle datapath) is complete: 6 modules, all QC PASS, all testbenches green (881 total tests). M1 upgrades this to a 3-stage pipeline (IF/EX/WB) targeting the same TSMC 180nm / 50 MHz / tapeout June 17 constraints.

The M0 modules are **unchanged** -- they become leaf instances inside a new pipeline top-level. `datapath_m0.sv` is retired (kept for regression).

---

## Architecture: 3-Stage Pipeline

```
IF                          EX ("fat" stage)                    WB
-----------    IF/EX reg    ---------------------------    EX/WB reg    --------
PC reg    -->  {instr,  --> decode + regfile read +    --> {write_data, --> regfile
PC+4 adder     pc,          imm_gen + ALU +                 rd,             write
instr mem      pc+4,        branch_comp + mem I/O +         reg_write}
interface      valid}        PC-next mux + fwd muxes
```

**Key design facts:**
- EX resolves branches/jumps; flush IF/EX on taken branch or any jump (1-cycle bubble)
- WB-to-EX forwarding only (no EX-to-EX, no load-use stall)
- Separate branch target adder (PC + B-imm) in EX, independent of ALU
- WB mux selects: ALU result / load data / PC+4 (link address for JAL/JALR)

---

## New Modules (4)

### Phase 1: Leaf Modules (parallel, no inter-dependencies)

#### 1a. `branch_comparator.sv`
- **Type:** Combinational, ~40 lines
- **Ports:** `rs1_data_i[31:0]`, `rs2_data_i[31:0]`, `funct3_i[2:0]` -> `branch_taken_o`
- **Logic:** Case on funct3: BEQ(000), BNE(001), BLT(100), BGE(101), BLTU(110), BGEU(111)
- **Default:** `branch_taken_o = 1'b0`
- **Spec:** canonical-reference.md S1.5, S10.4

#### 1b. `load_store_unit.sv`
- **Type:** Combinational, ~100 lines
- **Store path:** Byte-lane alignment of rs2 data + data_we[3:0] generation
  - SB: `4'b0001 << addr[1:0]`
  - SH: `addr[1] ? 4'b1100 : 4'b0011`
  - SW: `4'b1111`
- **Load path:** Sign/zero extension based on funct3 + addr[1:0]
  - LB/LBU, LH/LHU, LW -- extract correct byte/halfword, extend
- **Spec:** canonical-reference.md S1.3, S1.4

#### 1c. `forwarding_unit.sv`
- **Type:** Combinational, ~20 lines
- **Logic:**
  - `forward_rs1_o = wb_reg_write && (wb_rd != 0) && (wb_rd == ex_rs1) && (alu_src_a == 2'b00)`
  - `forward_rs2_o = wb_reg_write && (wb_rd != 0) && (wb_rd == ex_rs2)`
- **Gotchas:** #8 (x0 suppression) + #12 (alu_src_a gate on rs1 only)
- **Note:** forward_rs2 feeds BOTH ALU-B mux and store data path

### Phase 2: Integration

#### 2. `pipeline_top.sv`
- **Type:** Sequential + combinational, ~250 lines
- **Instantiates:** All 6 M0 modules + 3 new leaf modules
- **Contains:**
  - PC register (resets to 0), PC+4 adder
  - IF/EX pipeline register with valid/flush control
  - EX/WB pipeline register
  - Forwarding muxes, ALU-A/B muxes, WB mux, PC-next mux
  - Flush logic, branch target adder, JALR LSB clear
- **Memory interfaces:**
  - Instruction: `instr_addr_o[31:0]` out, `instr_data_i[31:0]` in
  - Data: `data_addr_o[31:0]` out, `data_out_o[31:0]` out, `data_we_o[3:0]` out, `data_re_o` out, `data_in_i[31:0]` in
- **Halt:** `halt_o = (ex_halt || ex_illegal_instr) && if_ex_valid`

---

## PC-Next Mux Logic (resolved in EX)

```
if      (branch && branch_taken && valid)  -> branch_target  (PC + B-imm, separate adder)
else if (jump && !jalr && valid)           -> alu_result     (PC + J-imm, from ALU)
else if (jump && jalr && valid)            -> jalr_target    ({alu_result[31:1], 1'b0})
else                                       -> pc_plus_4
```

**Flush:** `flush_if_ex = ((branch && branch_taken) || jump) && if_ex_valid`

---

## IF/EX Pipeline Register

```systemverilog
always_ff @(posedge clk or negedge rst_n) begin
  if (!rst_n) begin
    if_ex_instr     <= 32'h00000013;  // NOP
    if_ex_pc        <= 32'h0;
    if_ex_pc_plus_4 <= 32'd4;
    if_ex_valid     <= 1'b0;
  end else if (flush_if_ex) begin
    if_ex_instr     <= 32'h00000013;  // NOP (gotcha #9)
    if_ex_pc        <= 32'h0;
    if_ex_pc_plus_4 <= 32'd4;
    if_ex_valid     <= 1'b0;
  end else begin
    if_ex_instr     <= instr_data_i;
    if_ex_pc        <= pc_reg;
    if_ex_pc_plus_4 <= pc_plus_4;
    if_ex_valid     <= 1'b1;
  end
end
```

## EX/WB Pipeline Register

```systemverilog
always_ff @(posedge clk or negedge rst_n) begin
  if (!rst_n) begin
    wb_write_data <= 32'h0;
    wb_rd         <= 5'b0;
    wb_reg_write  <= 1'b0;
  end else begin
    wb_write_data <= ex_write_data;
    wb_rd         <= ex_rd_addr;
    wb_reg_write  <= ex_reg_write && if_ex_valid;
  end
end
```

## WB Mux (computed in EX, latched into EX/WB register)

```systemverilog
always_comb begin
  if (ex_jump)
    ex_write_data = if_ex_pc_plus_4;   // JAL/JALR link address (PC+4)
  else if (ex_mem_to_reg)
    ex_write_data = load_data;         // from load_store_unit
  else
    ex_write_data = alu_result;        // ALU result
end
```

---

## Forwarding Muxes (in pipeline_top.sv)

```systemverilog
// Forwarded register data
logic [31:0] rs1_fwd = forward_rs1 ? wb_write_data : rs1_data;
logic [31:0] rs2_fwd = forward_rs2 ? wb_write_data : rs2_data;

// ALU-A mux (uses forwarded rs1)
always_comb begin
  alu_a = 32'h0;
  case (ex_alu_src_a)
    2'b00:   alu_a = rs1_fwd;     // rs1 (with forwarding)
    2'b01:   alu_a = if_ex_pc;    // AUIPC/JAL: current PC (gotcha #7)
    2'b10:   alu_a = 32'h0;       // LUI: zero
    default: alu_a = 32'h0;
  endcase
end

// ALU-B mux (uses forwarded rs2)
assign alu_b = ex_alu_src ? ex_imm : rs2_fwd;
```

---

## Gotcha Compliance

| # | Risk | Where Handled |
|---|------|---------------|
| 1 | Inferred latches | All new `always_comb` blocks have defaults at top |
| 6 | JALR LSB clear | `pipeline_top.sv`: `jalr_target = {alu_result[31:1], 1'b0}` |
| 7 | AUIPC uses current PC | ALU-A mux fed `if_ex_pc` (not pc_plus_4) when alu_src_a=01 |
| 8 | x0 forward suppression | `forwarding_unit.sv`: `wb_rd != 5'd0` |
| 9 | Pipeline flush = NOP | IF/EX reg: `if_ex_instr <= 32'h00000013` on flush |
| 11 | TB stimulus race | All new testbenches drive at `@(negedge clk)` |
| 12 | AUIPC/JAL/LUI fwd corruption | `forwarding_unit.sv`: `alu_src_a == 2'b00` gate on rs1 |
| 13 | Branch alu_op safe default | Already handled in alu_control.sv (M0) |

---

## Existing Module Disposition

| Module | M1 Role | Modified? |
|--------|---------|-----------|
| `alu.sv` | Instantiated in EX | No |
| `regfile.sv` | Read in EX, write from WB | No (write port driven by WB signals) |
| `imm_gen.sv` | Instantiated in EX | No |
| `control_decoder.sv` | Instantiated in EX | No (all _nc signals now connected) |
| `alu_control.sv` | Instantiated in EX | No |
| `datapath_m0.sv` | Retired, kept for regression | No |

---

## Critical Path (50 MHz = 20 ns period)

EX stage is the bottleneck:
```
IF/EX reg -> ctrl_dec -> alu_ctrl -> ALU -> data memory -> load ext -> WB mux
              ~1.5ns      ~0.5ns    ~3ns     ~5-8ns        ~1ns       ~0.5ns
```
**Estimated total:** ~14-17 ns. **Margin:** 3-6 ns.
**Risk:** External memory timing is the biggest unknown.

---

## 4-Agent Workflow Sequence

| Step | Module | Agent Flow |
|------|--------|------------|
| 1a | `branch_comparator.sv` | RTL -> QC -> fix -> verif -> sim |
| 1b | `load_store_unit.sv` | RTL -> QC -> fix -> verif -> sim |
| 1c | `forwarding_unit.sv` | RTL -> QC -> fix -> verif -> sim |
| 2 | `pipeline_top.sv` | RTL -> QC -> fix -> verif -> sim |
| 3 | Flow integration | Update flow/rtl/, construct.py |

Steps 1a/1b/1c are parallelizable. Step 2 depends on all of Phase 1.

---

## Testbench Plan

| TB | Coverage |
|----|----------|
| `tb_branch_comparator.sv` | All 6 conditions, boundary values, signed/unsigned edges |
| `tb_load_store_unit.sv` | All 5 load + 3 store types at each valid byte offset |
| `tb_forwarding_unit.sv` | Forward-needed, forward-suppressed, x0, alu_src_a gate |
| `tb_pipeline_top.sv` | NOP stream, single-instruction, branches, jumps, forwarding, flush correctness, program sequences (fibonacci, call/return) |

---

## Unresolved (need ar input, non-blocking for RTL start)

1. **Stage suffix naming:** `_IF/_EX/_WB` vs `_S1/_S2/_S3` -- plan uses `if_ex_`, `ex_`, `wb_`
2. **Halt pin:** Single `halt_o = halt || illegal` vs two pads -- plan assumes single
3. **M1 scope:** Vanilla RV32I only vs include CUSTOM-0 -- plan assumes vanilla (CUSTOM-0 already in decoder, just no ALU extension ops yet)

---

## Verification Sequence

After all modules pass individual QC + testbenches:
1. Compile full pipeline:
   ```
   iverilog -g2012 -o pipeline_sim \
     alu.sv regfile.sv imm_gen.sv control_decoder.sv alu_control.sv \
     branch_comparator.sv load_store_unit.sv forwarding_unit.sv \
     pipeline_top.sv tb_pipeline_top.sv
   ```
2. Run: `vvp pipeline_sim` -- all self-checking tests must PASS
3. Update `flow/rtl/` with new modules, run mflowgen synthesis flow
4. Check timing closure at 50 MHz on FreePDK-45nm surrogate
