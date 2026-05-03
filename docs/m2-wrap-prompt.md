# M2-wrap: MMIO Wrapper Implementation Prompt

> Carry this prompt to a new Claude Code session. It is self-contained.

---

## Task

Implement the M2-wrap milestone: an MMIO wrapper (`chip_top`) around the
existing `pipeline_top` CPU core. The wrapper provides a host-facing
command interface to load programs into on-chip FF memories, run the CPU,
and read back results. `pipeline_top` is **not modified** — the wrapper
goes around it.

Read these files before starting:
- `CLAUDE.md` — project overview, constraints, agent workflow
- `docs/canonical-reference.md` §9 (chip-level I/O), §10 (interface contracts)
- `docs/mmio-wrapper-sketch.md` — full design sketch with FSM, command map,
  memory architecture, and integration notes. **This is the primary design
  reference for this task.** Follow it closely.
- `docs/conventions.md` — RTL naming, port suffixes, synthesizability rules
- `docs/gotchas.md` — implementation pitfalls

## What to build

A single new module `chip_top` appended to `flow/rtl/outputs/design.v`
(the project uses a single-file design — all modules in one file).

`chip_top` contains:
1. **Reset synchronizer** — 2-FF async-assert, sync-deassert (§9.2)
2. **MMIO controller FSM** — states: IDLE, LOADING, RUNNING, DONE
3. **Command register file** — CMD, ADDR, WDATA, RDATA, STATUS, PC, CYCLE_CNT
4. **FF instruction memory** — word-addressable, combinational read
5. **FF data memory** — word-addressable, byte-lane writes (data_we[3:0])
6. **Memory mux** — routes imem/dmem to wrapper (LOADING/DONE) or CPU (RUNNING)
7. **pipeline_top instantiation** — unchanged, wired through the mux

### External interface (chip_top ports)

```
input  logic        clk,
input  logic        rst_n,         // raw pad-level reset
input  logic [31:0] data_i,        // host write data bus
output logic [31:0] data_o,        // host read data bus
input  logic [2:0]  addr_cmd_i,    // register/command select (8 addresses)
input  logic        wr_en_i,       // write strobe
input  logic        rd_en_i,       // read strobe
output logic        busy_o,        // wrapper processing
output logic        done_o         // CPU halted
```

Use split data_i/data_o (not bidirectional) — simpler for simulation and
avoids tristate pad dependency. If pad count becomes an issue later we can
switch to bidir when ar provides the I/O library.

### Memory sizing

Use **64 words (256 bytes)** for both imem and dmem as the initial default.
Make depths parameterizable:
```
parameter IMEM_DEPTH = 64,
parameter DMEM_DEPTH = 64
```
This keeps FF count manageable (4096 FFs for both) while being large
enough for test programs. Can be increased later based on 180nm area budget.

### FSM behavior (from mmio-wrapper-sketch.md)

- **IDLE**: CPU rst_n held low. Memory mux selects wrapper. Waiting for commands.
- **LOADING**: CPU rst_n held low. Host writes instructions/data via LOAD_IMEM/LOAD_DMEM commands.
- **RUNNING**: CPU rst_n released. Memory mux selects CPU. Wrapper monitors halt_o. Cycle counter increments.
- **DONE**: CPU rst_n re-asserted. Memory mux selects wrapper. Host reads dmem via READ_DMEM.

### Command register map (addr_cmd encoding)

| addr_cmd | Register   | R/W | Description |
|----------|------------|-----|-------------|
| 3'h0     | CMD        | W   | Command code (see below) |
| 3'h1     | ADDR       | W   | Target memory address |
| 3'h2     | WDATA      | W   | Write data |
| 3'h3     | RDATA      | R   | Read data result |
| 3'h4     | STATUS     | R   | {28'b0, state[3:0]} |
| 3'h5     | PC         | R   | Current PC from pipeline_top |
| 3'h6     | CYCLE_CNT  | R   | 32-bit cycle counter |
| 3'h7     | (reserved) | —   | Returns 0 |

### CMD codes (written to addr_cmd=3'h0)

| data_i[3:0] | Name      | Action |
|-------------|-----------|--------|
| 4'h0        | NOP       | No operation |
| 4'h1        | LOAD_IMEM | Write WDATA to imem[ADDR] |
| 4'h2        | LOAD_DMEM | Write WDATA to dmem[ADDR] |
| 4'h3        | RUN       | Release CPU reset, begin execution |
| 4'h4        | HALT      | Force halt, return to IDLE |
| 4'h5        | READ_DMEM | Read dmem[ADDR] → RDATA |
| 4'h6        | READ_IMEM | Read imem[ADDR] → RDATA |

### pipeline_top port map (DO NOT modify pipeline_top)

```
pipeline_top u_core (
  .clk          (clk),
  .rst_n        (cpu_rst_n),        // controlled by FSM
  .instr_addr_o (cpu_instr_addr),   // [31:0] PC
  .instr_data_i (imem_rdata),       // [31:0] from muxed imem
  .data_addr_o  (cpu_data_addr),    // [31:0] ALU result
  .data_out_o   (cpu_data_out),     // [31:0] store data
  .data_we_o    (cpu_data_we),      // [3:0]  byte write enables
  .data_re_o    (cpu_data_re),      // read enable
  .data_in_i    (dmem_rdata),       // [31:0] from muxed dmem
  .halt_o       (cpu_halt)          // ECALL/EBREAK/illegal
);
```

## Agent workflow

Follow the standard 4-agent flow from CLAUDE.md:
1. **Spec-agent**: Review this prompt, confirm the interface contract, flag
   any ambiguities. Update `docs/canonical-reference.md` with a new §13
   (or appropriate section) documenting the chip_top interface.
2. **RTL-agent**: Implement `chip_top` in `flow/rtl/outputs/design.v`.
   Append it after the existing `pipeline_top` module.
3. **QC-agent**: Review in isolation. Key concerns: latch inference in FSM,
   memory mux correctness, reset synchronizer, byte-lane write logic,
   halt_o latching.
4. **Verification-agent**: Write `tb_chip_top.sv`. Test sequence:
   - Reset chip_top
   - LOAD_IMEM: load a small program (e.g., ADDI x1, x0, 42; ADDI x2, x0, 58; ADD x3, x1, x2; SW x3, 0(x0); EBREAK)
   - LOAD_DMEM: optionally pre-load data memory
   - RUN: release CPU, wait for done_o
   - READ_DMEM: read back results, verify x3=100 was stored to dmem[0]
   - Verify CYCLE_CNT > 0
   - Test with custom instructions too: load a CLZ or MUL16S program,
     verify results
   - Test HALT command (force-stop during execution)
   - Compile: `iverilog -g2012 -o chip_top_sim flow/rtl/outputs/design.v tb_chip_top.sv`

## Hard constraints

- No `*` operator in synthesizable RTL
- NDA: never persist 180nm PDK data
- `pipeline_top` is not modified — wrapper goes around it
- All signals must have defaults in always_comb (gotchas.md #1)
- Reset synchronizer: async assert, sync deassert (§9.2)
- Memory is word-addressed internally; CPU provides byte addresses
  (drop bottom 2 bits: `addr[AW+1:2]`)
- Match existing code style in design.v (2-space indent, comment headers,
  localparam naming conventions)

## Definition of done

- chip_top compiles with iverilog -g2012 (no errors)
- tb_chip_top passes: load program, run, read back correct results
- Full regression still passes (all existing testbenches unaffected)
- canonical-reference.md updated with chip_top interface spec
- CLAUDE.md milestones updated to mark M2-wrap complete
