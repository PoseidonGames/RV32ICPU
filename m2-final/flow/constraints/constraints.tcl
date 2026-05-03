#=========================================================================
# constraints.tcl — chip_top (M2-wrap), 50 MHz target
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
set_input_delay 2.0 -clock clk \
  [remove_from_collection [all_inputs] [get_ports {clk rst_n}]]

# Output delays: 2 ns hold budget
set_output_delay 2.0 -clock clk [all_outputs]
