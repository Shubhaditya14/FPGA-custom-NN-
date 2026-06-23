#------------------------------------------------------------------------------
# vivado_setup.tcl
#
# Create a Vivado project for the Foundry PYNQ-Z2 systolic-array accelerator.
# Target: xc7z020clg400-1. The script adds RTL/testbench sources, packages the
# RTL wrapper as local IP, and creates a Zynq PS + two AXI DMA + systolic_top
# block design. Two DMA IPs are used because the accelerator has two input
# streams (A and B) and one output stream.
#------------------------------------------------------------------------------

set script_dir [file dirname [file normalize [info script]]]
set project_name foundry_pynq
set project_dir [file join $script_dir vivado_project]
set part_name xc7z020clg400-1

create_project $project_name $project_dir -part $part_name -force
set_property target_language Verilog [current_project]
set_property simulator_language Verilog [current_project]

add_files -fileset sources_1 [glob -nocomplain [file join $script_dir rtl *.v]]
add_files -fileset sim_1 [glob -nocomplain [file join $script_dir tb *.v]]
set_property top systolic_top [current_fileset]
set_property top tb_systolic_top [get_filesets sim_1]

if {[file exists [file join $script_dir constraints pynq_z2.xdc]]} {
    add_files -fileset constrs_1 [file join $script_dir constraints pynq_z2.xdc]
}

update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

set ip_repo_dir [file join $project_dir ip_repo]
file mkdir $ip_repo_dir

ipx::package_project \
    -root_dir [file join $ip_repo_dir foundry_systolic_top] \
    -vendor foundry.local \
    -library user \
    -taxonomy /UserIP \
    -import_files \
    -set_current false \
    -force

ipx::edit_ip_in_project \
    -upgrade true \
    -name foundry_systolic_top_packager \
    -directory [file join $project_dir ip_packager] \
    [file join $ip_repo_dir foundry_systolic_top component.xml]

set core [ipx::current_core]
set_property name foundry_systolic_top $core
set_property display_name {Foundry Systolic Top} $core
set_property description {16x16 INT8 systolic array with AXI-Lite control and AXI-Stream data interfaces} $core
ipx::infer_bus_interfaces foundry.local:user:foundry_systolic_top:1.0 $core
ipx::save_core $core
close_project

open_project [file join $project_dir ${project_name}.xpr]
set_property ip_repo_paths [list $ip_repo_dir] [current_project]
update_ip_catalog

create_bd_design foundry_system

create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7 processing_system7_0
apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 -config {make_external "FIXED_IO, DDR" apply_board_preset "1"} [get_bd_cells processing_system7_0]

create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma axi_dma_a_0
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma axi_dma_b_0
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect axi_interconnect_0
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset proc_sys_reset_0
create_bd_cell -type ip -vlnv foundry.local:user:foundry_systolic_top foundry_systolic_top_0

set_property -dict [list CONFIG.c_include_sg {0} CONFIG.c_sg_include_stscntrl_strm {0} CONFIG.c_include_mm2s {1} CONFIG.c_include_s2mm {1}] [get_bd_cells axi_dma_a_0]
set_property -dict [list CONFIG.c_include_sg {0} CONFIG.c_sg_include_stscntrl_strm {0} CONFIG.c_include_mm2s {1} CONFIG.c_include_s2mm {0}] [get_bd_cells axi_dma_b_0]
set_property -dict [list CONFIG.NUM_MI {3} CONFIG.NUM_SI {1}] [get_bd_cells axi_interconnect_0]

connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0] [get_bd_pins proc_sys_reset_0/slowest_sync_clk]
connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0] [get_bd_pins axi_interconnect_0/ACLK]
connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0] [get_bd_pins axi_interconnect_0/S00_ACLK]
connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0] [get_bd_pins axi_interconnect_0/M00_ACLK]
connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0] [get_bd_pins axi_interconnect_0/M01_ACLK]
connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0] [get_bd_pins axi_interconnect_0/M02_ACLK]
connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0] [get_bd_pins axi_dma_a_0/s_axi_lite_aclk]
connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0] [get_bd_pins axi_dma_a_0/m_axi_mm2s_aclk]
connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0] [get_bd_pins axi_dma_a_0/m_axi_s2mm_aclk]
connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0] [get_bd_pins axi_dma_b_0/s_axi_lite_aclk]
connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0] [get_bd_pins axi_dma_b_0/m_axi_mm2s_aclk]
connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0] [get_bd_pins foundry_systolic_top_0/s_axi_aclk]

connect_bd_net [get_bd_pins processing_system7_0/FCLK_RESET0_N] [get_bd_pins proc_sys_reset_0/ext_reset_in]
connect_bd_net [get_bd_pins proc_sys_reset_0/peripheral_aresetn] [get_bd_pins axi_interconnect_0/ARESETN]
connect_bd_net [get_bd_pins proc_sys_reset_0/peripheral_aresetn] [get_bd_pins axi_interconnect_0/S00_ARESETN]
connect_bd_net [get_bd_pins proc_sys_reset_0/peripheral_aresetn] [get_bd_pins axi_interconnect_0/M00_ARESETN]
connect_bd_net [get_bd_pins proc_sys_reset_0/peripheral_aresetn] [get_bd_pins axi_interconnect_0/M01_ARESETN]
connect_bd_net [get_bd_pins proc_sys_reset_0/peripheral_aresetn] [get_bd_pins axi_interconnect_0/M02_ARESETN]
connect_bd_net [get_bd_pins proc_sys_reset_0/peripheral_aresetn] [get_bd_pins axi_dma_a_0/axi_resetn]
connect_bd_net [get_bd_pins proc_sys_reset_0/peripheral_aresetn] [get_bd_pins axi_dma_b_0/axi_resetn]
connect_bd_net [get_bd_pins proc_sys_reset_0/peripheral_aresetn] [get_bd_pins foundry_systolic_top_0/s_axi_aresetn]

connect_bd_intf_net [get_bd_intf_pins processing_system7_0/M_AXI_GP0] [get_bd_intf_pins axi_interconnect_0/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_interconnect_0/M00_AXI] [get_bd_intf_pins foundry_systolic_top_0/S_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_interconnect_0/M01_AXI] [get_bd_intf_pins axi_dma_a_0/S_AXI_LITE]
connect_bd_intf_net [get_bd_intf_pins axi_interconnect_0/M02_AXI] [get_bd_intf_pins axi_dma_b_0/S_AXI_LITE]

connect_bd_intf_net [get_bd_intf_pins axi_dma_a_0/M_AXIS_MM2S] [get_bd_intf_pins foundry_systolic_top_0/s_axis_a]
connect_bd_intf_net [get_bd_intf_pins axi_dma_b_0/M_AXIS_MM2S] [get_bd_intf_pins foundry_systolic_top_0/s_axis_b]
connect_bd_intf_net [get_bd_intf_pins foundry_systolic_top_0/m_axis_result] [get_bd_intf_pins axi_dma_a_0/S_AXIS_S2MM]

apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config {Master "/processing_system7_0/M_AXI_GP0" Clk_master "/processing_system7_0/FCLK_CLK0" Clk_slave "/processing_system7_0/FCLK_CLK0" Clk_xbar "/processing_system7_0/FCLK_CLK0"} [get_bd_intf_pins axi_interconnect_0/S00_AXI]
assign_bd_address

validate_bd_design
save_bd_design
make_wrapper -files [get_files [file join $project_dir ${project_name}.srcs sources_1 bd foundry_system foundry_system.bd]] -top
add_files -norecurse [file join $project_dir ${project_name}.gen sources_1 bd foundry_system hdl foundry_system_wrapper.v]
set_property top foundry_system_wrapper [current_fileset]
update_compile_order -fileset sources_1

puts "Foundry Vivado project created at $project_dir"
puts "Run synthesis/implementation, then generate bitstream from foundry_system_wrapper."
