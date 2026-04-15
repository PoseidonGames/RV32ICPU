# Benchmarking Notes — When & What to Compare

## Current State (M0, FreePDK-45nm)
- No meaningful external benchmarks at this stage
- FreePDK-45nm is a surrogate PDK, not the real process
- M0 is a single-cycle datapath with no memory/pipeline — not a complete CPU
- 50 MHz on 45nm is extremely relaxed (12+ ns slack = 63% margin)

## Internal Health Check Numbers (M0)
- Timing: WNS = 12.735 ns setup, 0.125 ns hold at signoff
- Area: 8,963 μm² (3,870 cells), regfile = 84%
- 3870 cells is reasonable for M0-scope datapath
- Regfile area dominance expected for FF-based (no SRAM) designs

## When Benchmarks Become Relevant

### After TSMC 180nm run
- Real cell delays and parasitics
- 50 MHz target will be much tighter (slower process)
- Slack numbers become meaningful for timing closure confidence

### After M1 (pipeline, real PC, memory interface)
- Compare area vs. other RV32I cores:
  - PicoRV32: ~5k gates
  - SERV: ~200 FFs (serial, very small)
  - ibex (lowRISC): ~30k gates
- Compare Fmax at a given process node
- Area efficiency metric: gates/MHz

### After gate-level simulation with real SDF
- Cycle-accurate performance on standard benchmarks:
  - Dhrystone (DMIPS/MHz)
  - CoreMark (CoreMark/MHz)
- Requires M1+ with working instruction fetch and memory

## M1 Flow Status (FreePDK-45nm, April 13 2026)
- Steps 0–16 passed (through PT timing signoff)
- Step 17 (synopsys-ptpx-genlibdb) failed postconditions — 2 errors, 86 warnings
- `.lib` was generated (pipeline_top.lib, 15709 lines, 168 pins, 715 timing refs)
- Lib structure is valid but timing arcs may be incomplete/pessimistic

### Step 17 Root Cause

**Not PDK-related — this is a mflowgen default flow gap that will reproduce on any PDK (including TSMC 180nm).**

The SDC flow chain:

1. **User constraints** (`flow/constraints/constraints.tcl`) — clean. Only standard SDC
   commands: `create_clock`, `set_false_path`, `set_input_delay`, `set_output_delay`.
2. **Innovus signoff** (step 14) — runs `writeTimingCon` to export `design.pt.sdc` for
   downstream PT steps. Innovus injects 23 `append_to_collection` commands (lines 146-169+)
   to handle pin grouping when constraint lines exceed SDC command length limits.
3. **PT timing signoff** (step 16) — handles `append_to_collection` fine. It's valid
   Synopsys Tcl and PT's interactive parser supports it. Step 16 passes.
4. **PTPX genlibdb** (step 17) — uses a more restrictive Tcl parser that does NOT
   support `append_to_collection`. Throws CMD-005, aborts SDC read. False path and
   multicycle path constraints are not applied, so the generated `.lib` has
   conservative/pessimistic timing arcs.

Key files:
- Innovus SDC generation: `build/14-cadence-innovus-signoff/scripts/generate-results.tcl` (line 13)
- Problematic SDC output: `build/14-cadence-innovus-signoff/outputs/design.pt.sdc` (222 KB)
- SDC as received by genlibdb: `build/17-synopsys-ptpx-genlibdb/inputs/design.pt.sdc`

### TODO to fix
- Filter the 23 `append_to_collection` lines from the SDC before genlibdb reads it
- Options: (a) sed filter in genlibdb's `read_design.tcl`, or (b) override the signoff
  step to export PT-compatible SDC via `write_sdc -nosplit`
- Re-run step 17 after fix to get clean lib with accurate timing arcs
- Note: genlibdb is NOT on the critical path to DRC/LVS (that path is signoff → gdsmerge → drc/lvs)
- Steps 18–20 (DRC, LVS, debug-calibre) require Calibre — may need ChipsHub access

## What We Can Claim Now
- "Timing closed with 63% slack margin at 50 MHz on FreePDK-45nm" — good sign that 180nm target is achievable
- Hold timing positive throughout entire flow (0.125 ns at signoff)
- Zero DRV violations, zero connectivity/antenna issues
- Area is dominated by FF regfile — expected and will remain true through M1
