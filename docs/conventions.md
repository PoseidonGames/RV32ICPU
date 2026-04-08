# RTL Conventions — TSI RV32I Project

Source: Prof. Torng's EE 599 Tutorial 3 (Fall 2025), adapted for TSI.

## Naming
- Module names: `snake_case` (e.g., `imm_gen`, `control_decoder`)
- Ports: `snake_case` with `_i` (input) / `_o` (output) suffixes. Exceptions: `clk`, `rst_n`
- Internal signals: `snake_case`, no suffix
- Parameters: `localparam UPPER_SNAKE_CASE` (e.g., `ALU_ADD = 4'b0000`)
- Pipeline stage suffixes: `_IF`, `_EX`, `_WB` (or `_S1`, `_S2`, `_S3`) — TBD with ar
- Instance names: `snake_case` (e.g., `alu_unit`, `reg_file`)
- Prefer descriptive names (`write_en` not `wen`)

## Module Structure (this order)
1. Header comment: module name, description, author, date, project
2. Module declaration with ANSI-style port list
3. Localparams for encoding constants
4. Internal signal declarations
5. Combinational logic (`always_comb` or `assign`)
6. Sequential logic (`always_ff`) — only if module has state
7. `endmodule`

## Formatting
- ≤74 chars per line, 2-space indent, never tabs (exception: fixed-width banner separator lines `// ====...====` may be 78 chars)
- One port per line, vertically aligned
- Named port bindings (`.port(signal)`), one per line

## Synthesizability Rules
- `always_ff @(posedge clk or negedge rst_n)` for sequential — `<=` only
- `always_comb` for combinational — `=` only
- Active-low async reset: `if (!rst_n) ... else ...`
- All flip-flops must have reset values
- No `initial` blocks, no `#delay`, no `casex`/`casez` (use `case...inside` if needed)
- No `*` operator (multiply) — use shift-add or instantiated multiplier
- No `tri`, `wand`, `wor` — `logic` everywhere
- All case statements need `default` branch
- Every signal in always_comb assigned in every branch (prevent latch inference)
- Explicit widths, sized literals: `32'h0` not `0`
- No combinational feedback loops
- Wrap debug code in `ifndef SYNTHESIS` / `endif`

## Header Template
```systemverilog
// ============================================================================
// Module: [name]
// Description: [brief]
// Author: Beaux Cable
// Date: [month] 2026
// Project: TSI RV32I Pipelined Processor (TSMC 180nm)
// ============================================================================
```
