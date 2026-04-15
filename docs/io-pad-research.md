# I/O Pad Integration Research — Small ASIC Tapeouts

## The Problem

`pipeline_top` has ~168 signal pins (two 32-bit memory buses, controls, clock, reset). On a 1mm x 1mm die at 180nm, pads are ~100-120 um wide. With corner cells, that's roughly **8-9 pads per side = 32-36 total pad sites**. Subtract ~8 for power/ground, 4 for corners, and you're left with **~20 usable signal pads**. Every university tapeout hits this wall.

---

## 1. Pin Reduction Strategies (What People Actually Do)

### Narrowed/Serialized Memory Bus (most common)
Instead of full 32-bit instruction and data buses, narrow each to 8 bits with a 4-cycle transfer protocol and `valid`/`ready` handshake. Cuts 128 signal pins down to 16 data pins plus a few control signals. At 50 MHz, even 4:1 serialization keeps external SRAM timing comfortable. Some designs go further with SPI (4 pins per memory) but that adds significant latency.

### Bus Multiplexing (shared instruction/data port)
A Harvard-to-Von Neumann bridge at the chip boundary multiplexes instruction and data buses onto a single external port with a phase/select signal. Halves external data pins at the cost of one wasted cycle per instruction fetch. At 50 MHz this is acceptable if instruction and data accesses don't collide heavily. With a 3-stage pipeline that fetches every cycle, you'd need stalls or double-pumping.

### Scan Chain / JTAG Debug Port
Instead of bringing out every internal signal for debug, insert a scan chain or JTAG TAP. Full observability through 4-5 pins (TCK, TMS, TDI, TDO, TRST). PULPino and NEORV32 both use this. A minimal scan wrapper around the register file and pipeline registers gives post-silicon debug without burning pad sites.

### Dedicated Test/Debug Mux
A top-level `mode` pin selects between normal operation and a test mode where internal signals (PC, register contents, pipeline state) are time-multiplexed onto a narrow output bus. Tiny Tapeout uses a combinational mux to share 8 output pins among multiple designs.

---

## 2. Chip-Top Wrapper Patterns

Standard RTL hierarchy for tapeout:

```
chip_top (pad instantiation, pin muxing, clock/reset buffering)
  +-- core (pipeline_top — purely synthesizable, no pad cells)
```

### Chipyard (Berkeley)
Formalizes this as `ChipTop` vs `DigitalTop`. `ChipTop` instantiates IO cells, clock receivers, reset synchronizers, and analog IP. `DigitalTop` is purely digital and portable across technologies. IOBinders map each logical port to a physical pad cell. HarnessBinders connect the test harness for simulation. `DigitalTop` never changes between FPGA and ASIC targets.
- [Chipyard IO Docs](https://chipyard.readthedocs.io/en/stable/Customization/IOBinders.html)

### PULPino (ETH Zurich)
Uses `pulpino_top.sv` as the chip-level wrapper. Instantiates pad cells for every I/O, clock gating cells (ICGs), and clock muxes. The core (`soc_domain`) sits inside. Taped out on UMC 65nm.
- [Source: pulpino_top.sv](https://github.com/pulp-platform/pulpino/blob/master/rtl/pulpino_top.sv)

### For Our Design
Create `chip_top.sv` that wraps `pipeline_top`, instantiates pad cells from the TSMC 180nm I/O library, adds bus-narrowing/mux logic, and provides clock/reset pad cells. Keep `pipeline_top` unchanged — it remains the portable, simulatable core.

---

## 3. I/O Pad Cells in Innovus / mflowgen

### Pad Ring in Innovus
The floorplan TCL script (`floorplan.tcl` in mflowgen's `cadence-innovus-init` step) defines pad placement:

- `loadIoFile <file>.io` — specifies pad placement order around the die perimeter (N/S/E/W sides), including corner cells
- `addIoFiller -cell <filler_name> -prefix FILLER -side n` (repeat for e/s/w) — fills gaps between pads with IO filler cells
- Corner cells at each die corner (mandatory for DRC-clean pad rings)
- Power rings (`addRing`) connect pad-level VDD/VSS to core power mesh

### IO Filler Cells
**Mandatory.** They maintain ESD guard ring continuity and n-well/p-well connections between pad cells. Every university tapeout that skips IO fillers fails DRC.

### mflowgen Integration
Add a custom `init` step or modify `cadence-innovus-init` to source the IO placement file before core floorplanning.
- [mflowgen Floorplan Docs](https://mflowgen.readthedocs.io/en/latest/stdlib-innovus-floorplan.html)

---

## 4. Pin Assignment Best Practices

### Clock and Reset
Place clock and reset pads adjacent to each other, ideally on the bottom (south) side near the clock tree root. Minimizes clock skew from pad to first buffer. Use a dedicated clock pad cell (not a general-purpose input pad) if the library provides one.

### Power/Ground Distribution
Rule of thumb: 20-30% of all pad sites should be VDD/VSS pairs. For 40-60 total pads = 8-16 power/ground pads (4-8 pairs), distributed evenly around all four sides. At least one VDD/VSS pair per side. Separate core VDD/VSS from I/O VDD/VSS if the pad library supports it.

### Signal Grouping
Group related signals on the same die side. Instruction memory interface on one side, data memory on the adjacent side. Simplifies PCB routing on the test board and reduces internal routing congestion. Place output pads away from clock pads to reduce switching noise coupling.

### ESD
Every signal pad includes ESD protection (clamp diodes) in the pad cell itself. The ESD power bus must be continuous — this is what IO filler cells guarantee.

---

## 5. TSMC 180nm Specifics

- I/O library often designated `tpz973g` or similar
- Pad cells typically **100-120 um** wide
- 1mm die edge fits roughly **8-9 pads per side** (with corners)
- Supports **1.8V core / 3.3V I/O** voltage domains
- Library includes: input pads (Schmitt trigger option), output pads (drive strength selection), bidirectional pads, analog pads, power/ground pads
- Third-party libraries (e.g., Certus Semiconductor) offer enhanced options including 5V-tolerant I/O
- [Certus 180nm Brochure](https://certus-semi.com/wp-content/uploads/2019/01/CertusBrochure_TSMC180nm-Library.V2p4.pdf)
- [CMC Microsystems TSMC 180nm](https://www.cmc.ca/tsmc-180-nm-cmos/)

---

## 6. Recommended Pad Budget for Our Design (~20 signal pads)

| Pins | Function |
|------|----------|
| 8 | Shared 8-bit data bus (instruction + data, time-multiplexed) |
| 4 | Address output (upper bits, or serialized) |
| 3 | Control (read/write/select, or SPI-style CS/SCLK/MOSI) |
| 2 | Clock, reset |
| 4 | JTAG (TCK, TMS, TDI, TDO) |
| 1 | Halt output |
| **22** | **Total signal pads** |

Leaves room for a couple spare/test pins.

---

## Sources

- [Chipyard: IOBinders and HarnessBinders](https://chipyard.readthedocs.io/en/stable/Customization/IOBinders.html)
- [Chipyard: Tapeout Tools](https://chipyard.readthedocs.io/en/main/Tools/Tapeout-Tools.html)
- [PULPino Top-Level RTL](https://github.com/pulp-platform/pulpino/blob/master/rtl/pulpino_top.sv)
- [WPI ECE574: Full-Chip Layout](https://schaumont.dyn.wpi.edu/ece574f24/10fclayout.html)
- [Cornell ECE5745: ASIC Flow Back-End](https://cornell-ece5745.github.io/ece5745-S02-back-end/)
- [mflowgen Floorplan Docs](https://mflowgen.readthedocs.io/en/latest/stdlib-innovus-floorplan.html)
- [Certus 180nm Library Brochure](https://certus-semi.com/wp-content/uploads/2019/01/CertusBrochure_TSMC180nm-Library.V2p4.pdf)
- [CMC Microsystems: TSMC 180nm CMOS](https://www.cmc.ca/tsmc-180-nm-cmos/)
- [NEORV32 RISC-V Processor](https://stnolting.github.io/neorv32/)
- [StanfordAHA Garnet IO Filler Discussion](https://github.com/StanfordAHA/garnet/issues/356)
