# tech + cells
read_lef @TECH_LEF@
read_lef @CELL_LEF@
read_liberty @LIBERTY@

# synthesized gate netlist
read_verilog @NETLIST@
link_design @TOP_MODULE@

# timing constraints
create_clock -name core_clk -period @CLOCK_PERIOD@ [get_ports clock]
set_input_delay  1.0 -clock [get_clocks core_clk] [all_inputs]
set_output_delay 1.0 -clock [get_clocks core_clk] [all_outputs]

# rough wire model before routing
set_wire_rc -layer met2

# floorplan
initialize_floorplan \
  -utilization 70 \
  -aspect_ratio 1.0 \
  -core_space 10 \
  -site unithd

make_tracks
place_pins -hor_layers met3 -ver_layers met2

# placement
# Optimize critical path delay.
global_placement -timing_driven
detailed_placement

# parasitic estimation from placement
estimate_parasitics -placement

# STA Timing report
report_checks -path_delay max -fields {slew cap fanout input_pins nets} -digits 3

exit
