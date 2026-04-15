# MMIO Wrapper Design Sketch — `chip_top`

## Overview

The chip's external interface is a simple command-based MMIO wrapper. A host (test board MCU, FPGA, or lab equipment) writes commands and data over a 32-bit parallel bus to load programs, run the CPU, and read results. The CPU core (`pipeline_top`) is unchanged.

```
                         CHIP BOUNDARY
                        ┌──────────────────────────────────┐
  32-bit data bus ──────┤  chip_top                        │
  addr/cmd[2:0]  ──────┤    ┌────────────┐                │
  wr_en          ──────┤    │ mmio_ctrl  │                │
  rd_en          ──────┤    │ (FSM +     │                │
  data_out[31:0] ◄─────┤    │  cmd regs) │                │
  busy           ◄─────┤    └─────┬──────┘                │
  done           ◄─────┤          │                       │
  clk            ──────┤     ┌────┴─────┐                 │
  rst_n          ──────┤     │  2:1 mux │                 │
                        │     └──┬───┬──┘                 │
                        │        │   │                    │
                        │   ┌────┴┐ ┌┴────┐  ┌──────────┐│
                        │   │imem │ │dmem │  │pipeline   ││
                        │   │(FF) │ │(FF) │  │  _top     ││
                        │   └─────┘ └─────┘  └──────────┘│
                        └──────────────────────────────────┘
```

---

## External Pin Interface (~12-15 signal pads)

| Pin | Dir | Width | Description |
|-----|-----|-------|-------------|
| `clk` | in | 1 | System clock (50 MHz) |
| `rst_n` | in | 1 | Active-low reset (wrapper adds 2-FF synchronizer) |
| `data_io` | bidir | 32 | Shared data bus (or split into `data_i[31:0]` / `data_o[31:0]`) |
| `addr_cmd` | in | 3 | Register/command select (8 addresses) |
| `wr_en` | in | 1 | Write strobe |
| `rd_en` | in | 1 | Read strobe |
| `busy` | out | 1 | Wrapper is processing (host must wait) |
| `done` | out | 1 | CPU has halted (execution finished) |

If using a bidirectional data bus: **38 signal pads** (32 + 6 control).
If split in/out: **70 signal pads** — probably too many; bidir is the way to go.

**Alternative: SPI front-end** (if pad count is very tight): SCK, MOSI, MISO, CS_N = **4 pads**. Shift register deserializes into the same command registers. Slower but minimal pads.

Plus power/ground: ~8 pads (2x VDD, 2x VSS, 2x VDDIO, 2x VSSIO minimum).

---

## Command Register Map

| addr_cmd | Register | R/W | Description |
|----------|----------|-----|-------------|
| `3'h0` | CMD | W | Command code (triggers FSM transition) |
| `3'h1` | ADDR | W | Target memory address for load/read operations |
| `3'h2` | WDATA | W | Write data (instruction or data word) |
| `3'h3` | RDATA | R | Read data (result from dmem or status readback) |
| `3'h4` | STATUS | R | FSM state + halt reason |
| `3'h5` | PC | R | Current PC value (for debug) |
| `3'h6` | CYCLE_CNT | R | Cycle counter (for benchmarking custom instructions) |
| `3'h7` | (reserved) | — | Future use |

### CMD codes

| Code | Name | Action |
|------|------|--------|
| `4'h0` | NOP | No operation |
| `4'h1` | LOAD_IMEM | Write WDATA to imem[ADDR]. CPU held in reset. |
| `4'h2` | LOAD_DMEM | Write WDATA to dmem[ADDR]. CPU held in reset. |
| `4'h3` | RUN | Deassert CPU reset, begin execution |
| `4'h4` | HALT | Force halt (re-assert CPU reset) |
| `4'h5` | READ_DMEM | Read dmem[ADDR] → RDATA |
| `4'h6` | READ_IMEM | Read imem[ADDR] → RDATA |
| `4'h7` | (reserved) | Future use |

---

## FSM States

```
         ┌──────────┐
    ─────► RESET    │ (on rst_n assertion)
         └────┬─────┘
              │ rst_n deasserted
              ▼
         ┌──────────┐
    ┌────► IDLE     ◄────────────────────┐
    │    └────┬─────┘                    │
    │         │ CMD = LOAD_IMEM/DMEM     │ CMD = HALT
    │         ▼                          │   or
    │    ┌──────────┐                    │ CMD = RUN after DONE
    │    │ LOADING  │─── (more words) ──►│
    │    └────┬─────┘                    │
    │         │ CMD = RUN                │
    │         ▼                          │
    │    ┌──────────┐                    │
    │    │ RUNNING  │                    │
    │    └────┬─────┘                    │
    │         │ halt_o asserted          │
    │         ▼                          │
    │    ┌──────────┐                    │
    │    │ DONE     ├────────────────────┘
    │    └────┬─────┘
    │         │ CMD = READ_DMEM/IMEM/REG
    └─────────┘ (stays in DONE, serves reads)
```

### Key behaviors per state

- **IDLE/LOADING**: CPU `rst_n` held low. Memory mux selects wrapper (MMIO writes go directly to imem/dmem FF arrays).
- **RUNNING**: CPU `rst_n` released. Memory mux selects CPU (`pipeline_top` drives imem/dmem). Wrapper monitors `halt_o`.
- **DONE**: CPU `rst_n` re-asserted. Memory mux selects wrapper (host can read back dmem contents via READ_DMEM).

---

## Memory Architecture

### Instruction Memory (FF-based)

```systemverilog
// Word-addressable, read-only from CPU perspective
// Size TBD — 64 words (256B) to 256 words (1KB) depending on area budget
logic [31:0] imem [0:IMEM_DEPTH-1];

// CPU port (RUNNING state): combinational read
assign instr_data = imem[instr_addr[IMEM_AW+1:2]];  // word-aligned, drop bottom 2 bits

// Wrapper port (LOADING state): synchronous write
always_ff @(posedge clk)
  if (imem_we) imem[load_addr] <= load_data;
```

### Data Memory (FF-based)

```systemverilog
// Word-addressable, byte-lane write enables from CPU
// Size TBD — 64 words (256B) to 256 words (1KB)
logic [31:0] dmem [0:DMEM_DEPTH-1];

// CPU port (RUNNING state): combinational read, byte-lane write
assign data_in = dmem[data_addr[DMEM_AW+1:2]];

always_ff @(posedge clk)
  for (int i = 0; i < 4; i++)
    if (data_we[i]) dmem[data_addr[DMEM_AW+1:2]][i*8 +: 8] <= data_out[i*8 +: 8];

// Wrapper port (LOADING/DONE): full-word write or read
```

### Memory Mux (2:1)

```systemverilog
// In RUNNING state: pipeline_top drives memory
// In all other states: MMIO wrapper drives memory
assign mem_sel = (state == RUNNING);

assign imem_addr = mem_sel ? pipeline_instr_addr : wrapper_addr;
assign dmem_addr = mem_sel ? pipeline_data_addr  : wrapper_addr;
assign dmem_we   = mem_sel ? pipeline_data_we    : wrapper_we;
assign dmem_din  = mem_sel ? pipeline_data_out   : wrapper_wdata;
```

---

## pipeline_top Integration

`pipeline_top` is instantiated **unchanged**. The wrapper handles:

1. **Reset synchronizer**: 2-FF async-assert, sync-deassert before driving `rst_n` into `pipeline_top` (per canonical-reference.md §9.2)
2. **Memory mux**: Routes imem/dmem ports to either wrapper (LOADING/DONE) or CPU (RUNNING)
3. **halt_o latching**: `halt_o` from `pipeline_top` is combinational and transient — wrapper latches it to drive the DONE state transition

```systemverilog
pipeline_top u_core (
  .clk          (clk),
  .rst_n        (cpu_rst_n),        // controlled by FSM, not raw pin
  .instr_addr_o (cpu_instr_addr),
  .instr_data_i (imem_rdata),       // from muxed imem
  .data_addr_o  (cpu_data_addr),
  .data_out_o   (cpu_data_out),
  .data_we_o    (cpu_data_we),
  .data_re_o    (cpu_data_re),
  .data_in_i    (dmem_rdata),       // from muxed dmem
  .halt_o       (cpu_halt)
);
```

---

## RTL Hierarchy

```
chip_top.sv              — pad cells + pin-level I/O
  +-- rst_sync.sv        — 2-FF reset synchronizer
  +-- mmio_ctrl.sv       — FSM + command registers
  +-- imem.sv            — FF instruction memory array
  +-- dmem.sv            — FF data memory array (byte-lane writes)
  +-- pipeline_top.sv    — existing CPU core (unchanged)
```

---

## Open Questions (need ar or area analysis)

1. **Memory depth**: 64 words? 128? 256? Drives flip-flop count and area.
   - 64 words imem + 64 words dmem = 4096 FFs
   - 128+128 = 8192 FFs
   - 256+256 = 16384 FFs
2. **Bidirectional vs split bus**: Bidir saves pads but needs tristate pad cells from the I/O library.
3. **Cycle counter width**: 32-bit wraps at ~85s at 50 MHz. Sufficient?
4. **SPI vs parallel**: ar confirmed 32-bit bus, so parallel is the plan. SPI could be a fallback if pad count is very tight.
