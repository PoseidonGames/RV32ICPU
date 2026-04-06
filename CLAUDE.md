# TSI RV32I Processor — TSMC 180nm Tapeout

## Project
- **Designer:** Beaux Cable | **Senior Lead:** ar
- **Target:** TSMC 180nm, 1mm × 1mm die, 50 MHz clock
- **Tapeout:** June 17, 2026 | **Hard gate:** May 15 — DRC/LVS clean or cut from shuttle
- **Architecture:** 3-stage pipeline (IF → EX → WB), FF register file, no SRAM, no caches

## Current State
- **Done:** alu.sv (QC PASS), regfile.sv
- **Next:** imm_gen.sv → control_decoder.sv → alu_control.sv → branch_comparator.sv → datapath_m0.sv
- **Milestones:** M0 (single-cycle, ~Apr 18) → M1 (pipeline, ~May 1) → M2a (bit-manip) → M2b (MAC stretch)

## Agent Workflow
4 subagents in `.claude/agents/`. Beaux routes work manually — no LLM coordinator.
1. **spec-agent** — ISA oracle. Answers encoding/architecture questions. Never writes code.
2. **rtl-agent** — Writes .sv modules. Reads `docs/` before coding. Flags uncertainty.
3. **qc-agent** — Adversarial reviewer. Receives ONLY .sv files, never RTL agent context. Information barrier is load-bearing.
4. **verification-agent** — Writes _tb.sv testbenches. Derives expected values from spec only.

Per-module flow: RTL agent writes → QC agent reviews (isolated) → fix loop → Verification agent tests → simulate.

## Reference Files (agents read on demand)
- `docs/canonical-reference.md` — SINGLE SOURCE OF TRUTH for all encodings and interfaces
- `docs/conventions.md` — RTL naming, port suffixes, synthesizability rules (from EE599)
- `docs/gotchas.md` — 10 RISC-V implementation pitfalls shared across all agents
- **Obsidian vault:** `/Users/bcable/Library/Mobile Documents/iCloud~md~obsidian/Documents/Starfall/TSI` — project notes, decisions, and design context (read on demand)

## Hard Constraints
- **NDA:** Never paste 180nm PDK data (.lib, .lef, .spf, .tf) into any AI tool
- **No `*` operator** in synthesizable RTL (MAC must use explicit shift-add)
- **No SRAM** — FF register file only, external memory via I/O pads
- **Backup plan:** If CPU too ambitious by end of Week 2, pivot to AES-128 or FIR filter

## Unresolved (need ar's input before committing)
- Custom instruction set: POPCOUNT + BREV confirmed, but CLZ vs BEXT vs BDEP TBD
- M1 scope: does M1 include custom extensions or just vanilla RV32I?
- Encoding sharing: shared package vs per-module localparams?
- Pipeline stage naming convention: _IF/_EX/_WB vs _S1/_S2/_S3
