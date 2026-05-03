#=========================================================================
# constraints.tcl — datapath_m0, 50 MHz target
#=========================================================================
# Real clock on clk port (datapath_m0 has synchronous register file).
# Input/output delay budgets set to 10% of period as a reasonable
# starting point; tighten after seeing timing reports from DC.
#=========================================================================

create_clock -period 20.0 -name clk [get_ports clk]

# rst_n is async — no clock-relative delay needed
set_false_path -from [get_ports rst_n]

# Combinational inputs: rs setup budget = 2 ns (10% of 20 ns period)
set_input_delay 2.0 -clock clk \
  [remove_from_collection [all_inputs] [get_ports {clk rst_n}]]

# Combinational outputs: output hold budget = 2 ns
set_output_delay 2.0 -clock clk [all_outputs]
