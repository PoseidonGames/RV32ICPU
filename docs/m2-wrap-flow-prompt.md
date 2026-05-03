# M2-wrap Flow Packaging Prompt

> Carry this prompt to a new Claude Code session. It is self-contained.

---

## Task

Package the M2-wrap `chip_top` design for mflowgen synthesis. The RTL is
done and verified — this task updates the flow configuration to target
`chip_top` as the new top-level module and produces a `flow_m2wrap.zip`
ready for mflowgen on ChipsHub.

Read these files before starting:
- `CLAUDE.md` — project overview, constraints, hard rules
- `flow/construct.py` — current mflowgen flow graph (top = `pipeline_top`)
- `flow/rtl/configure.yml` — RTL concatenation step (stale — missing modules)
- `flow/constraints/constraints.tcl` — SDC constraints (targets `pipeline_top`)
- `docs/canonical-reference.md` §13 — chip_top interface spec
- `docs/conventions.md` — naming rules

## What to change

### 1. `flow/rtl/configure.yml` — fix the RTL step

The current `configure.yml` concatenates individual `.sv` files, but
`design.v` has been the single source of truth since M2a (modules were
added directly to it). The individual `.sv` files in `flow/rtl/` are
stale — they're missing `compressed_decoder` and `chip_top`.

**Replace the cat command with a simple copy:**

```yaml
name: rtl

outputs:
  - design.v

commands:
  - cp design.v outputs/design.v
```

`design.v` (2559 lines) already contains all 11 modules in dependency
order: alu, regfile, imm_gen, control_decoder, alu_control,
branch_comparator, load_store_unit, forwarding_unit, compressed_decoder,
pipeline_top, chip_top.

### 2. `flow/construct.py` — change top-level module

Update `design_name` from `'pipeline_top'` to `'chip_top'`:

```python
parameters = {
    'construct_path' : __file__,
    'design_name'    : 'chip_top',         # was pipeline_top
    'clock_period'   : 20.0,               # 50 MHz target
    'adk'            : adk_name,
    'adk_view'       : adk_view,
    'topographical'  : True,
}
```

Also update the header comment to reference M2-wrap.

### 3. `flow/constraints/constraints.tcl` — new SDC for chip_top

chip_top has a different port set than pipeline_top. Rewrite constraints.tcl
to target chip_top's ports (see canonical-reference.md §13.1):

```tcl
#=========================================================================
# constraints.tcl — chip_top (M2-wrap), TSMC 180nm, 50 MHz target
#=========================================================================
# chip_top wraps pipeline_top with an MMIO command-register interface.
# External ports: clk, rst_n, data_i[31:0], data_o[31:0],
#                 addr_cmd_i[2:0], wr_en_i, rd_en_i, busy_o, done_o
#=========================================================================

# 50 MHz clock
create_clock -period 20.0 -name clk [get_ports clk]

# rst_n is async — false path (synchronized internally by 2-FF sync)
set_false_path -from [get_ports rst_n]

# Input delays: 2 ns setup budget (10% of period)
# Host-facing inputs: data_i, addr_cmd_i, wr_en_i, rd_en_i
set_input_delay 2.0 -clock clk \
  [remove_from_collection [all_inputs] [get_ports {clk rst_n}]]

# Output delays: 2 ns hold budget
# Host-facing outputs: data_o, busy_o, done_o
set_output_delay 2.0 -clock clk [all_outputs]
```

The constraint structure is the same as before (10% I/O budget), but the
header and comments now correctly reference chip_top's ports. The
`remove_from_collection` / `all_outputs` wildcards handle the port set
automatically — no port-name changes needed in the SDC commands.

### 4. `flow/constraints/outputs/constraints.tcl` — copy the new SDC

The outputs/ directory has a stale copy. Overwrite it with the new
constraints.tcl (the configure.yml `cp` command does this at build time,
but having it pre-populated avoids confusion).

### 5. Package into zip

Create `flow_m2wrap.zip` containing the entire `flow/` directory:

```bash
cd /Users/bcable/tsi-rv32i
zip -r flow_m2wrap.zip flow/ \
  -x "flow/.mflowgen-build/*" \
  -x "flow/*/__pycache__/*" \
  -x "flow/*/outputs/.stamp"
```

Exclude mflowgen build artifacts, Python caches, and stamp files.

### 6. Verify the zip

```bash
unzip -l flow_m2wrap.zip | head -40
```

Confirm the zip contains:
- `flow/construct.py` (with `design_name = 'chip_top'`)
- `flow/rtl/configure.yml` (with `cp design.v outputs/design.v`)
- `flow/rtl/design.v` (2559 lines, chip_top at the end)
- `flow/rtl/outputs/design.v` (same content)
- `flow/constraints/constraints.tcl` (targeting chip_top)
- `flow/constraints/outputs/constraints.tcl` (same)
- `flow/.mflowgen.yml`

## What NOT to change

- **`design.v`** — already contains chip_top, verified with 44-vector
  testbench. Do not modify RTL.
- **`pipeline_top`** — remains inside design.v as a submodule of chip_top.
  Do not remove it.
- **Flow graph edges** — the mflowgen node connectivity is unchanged. Only
  the parameter `design_name` changes.
- **Hold slack tuning** — keep `hold_target_slack: 0.020` on postroute_hold.

## Hard constraints

- NDA: never persist 180nm PDK data
- Do not remove any existing modules from design.v
- The zip must be self-contained: someone with mflowgen + ADK should be
  able to `cd flow && mflowgen run --design .` and get through synthesis

## Definition of done

- construct.py has `design_name = 'chip_top'`
- constraints.tcl targets chip_top ports
- configure.yml uses `cp design.v outputs/design.v`
- `flow_m2wrap.zip` exists and contains the correct files
- Quick sanity: `grep design_name flow/construct.py` shows `chip_top`
