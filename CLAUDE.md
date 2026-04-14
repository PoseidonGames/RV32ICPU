# TSI RV32I Processor — TSMC 180nm Tapeout

## Project
- **Designer:** Beaux Cable | **Senior Lead:** ar
- **Target:** TSMC 180nm, 1mm × 1mm die, 50 MHz clock
- **Tapeout:** June 17, 2026 | **Hard gate:** May 15 — DRC/LVS clean or cut from shuttle
- **Architecture:** 3-stage pipeline (IF → EX → WB), FF register file, no SRAM, no caches

## Current State
- **Done:** M0 (single-cycle, Apr 9) → M1 (3-stage pipeline, Apr 13 — P&R + PT signoff on FreePDK-45nm)
- **Next:** I/O pads → M2a (custom instructions) → M2b (MAC accelerator) → TSMC 180nm flow → DRC/LVS signoff
- **180nm PDK:** Expected week of Apr 13, 2026

## Milestones
- **M0** — Single-cycle datapath (DONE Apr 9)
- **M1** — 3-stage pipeline, vanilla RV32I (DONE Apr 13, FreePDK-45nm through step 16)
- **M1-pads** — I/O pad ring for 1mm×1mm die, pin assignment
- **M2a** — Custom instructions: POPCOUNT + BREV confirmed; CLZ vs BEXT vs BDEP TBD (need ar)
- **M2b** — MAC accelerator (shift-add, no `*` operator) — stretch goal
- **M1-180nm** — Re-run M1 flow on TSMC 180nm PDK (when available)
- **Signoff** — DRC/LVS clean on 180nm (hard gate: May 15)

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

## Agent Behavior Guidelines
- **Think before coding:** State assumptions explicitly before implementing. If multiple interpretations exist, present all of them — don't pick silently. Stop when confused; name what is unclear and ask. Push back when a simpler approach exists.
- **Goal-driven execution:** Transform tasks into verifiable goals. "Fix the bug" → write a test that reproduces it, then make it pass. "Add a module" → define the interface contract first, then implement to satisfy it. For multi-step work, state a plan with explicit verify steps before starting.
- **Surgical changes only:** Every changed line must trace directly to the request. Don't improve adjacent code, comments, or formatting as side effects. Match existing style. If you notice unrelated issues, mention them — don't fix them silently.
- **Simplicity first:** No abstractions for single-use code. No speculative flexibility. No error handling for impossible scenarios. If 200 lines could be 50, rewrite it.
- **Structured observations:** When recording decisions, findings, or facts — each fact must be one self-contained statement. No pronouns, no "it" or "this" references. Each must stand alone months later without surrounding context.
- **Skip noise:** Don't record routine actions (file listings, status checks, dependency installs, git log reads). Only record things that were *learned, decided, built, fixed, or discovered*. If it can be re-derived from the code or git history, it doesn't need to be saved.
- **NDA-aware capture:** Never persist 180nm PDK data (.lib, .lef, .spf, .tf contents) in any notes, memory, logs, or external tools. When in doubt, omit — the NDA constraint applies to all forms of persistence, not just AI chat.

## Hard Constraints
- **NDA:** Never paste 180nm PDK data (.lib, .lef, .spf, .tf) into any AI tool
- **No `*` operator** in synthesizable RTL (MAC must use explicit shift-add)
- **No SRAM** — FF register file only, external memory via I/O pads
- **Backup plan:** If CPU too ambitious by end of Week 2, pivot to AES-128 or FIR filter

## Unresolved (need ar's input before committing)
- Custom instruction set: POPCOUNT + BREV confirmed, but CLZ vs BEXT vs BDEP TBD
- Encoding sharing: shared package vs per-module localparams?
- MAC accelerator interface: memory-mapped vs dedicated instruction vs coprocessor port
- Pad ring: power/ground pad count, ESD strategy, pin assignment constraints
