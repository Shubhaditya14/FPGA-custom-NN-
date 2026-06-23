##------------------------------------------------------------------------------
## pynq_z2.xdc
##
## Basic PYNQ-Z2 timing/clock constraints for Foundry. In the Vivado block
## design flow the accelerator clock normally comes from the Zynq PS FCLK_CLK0,
## so these constraints are mainly useful when simulating or synthesizing the
## RTL wrapper as a standalone top with an external 125 MHz board clock.
##------------------------------------------------------------------------------

## PYNQ-Z2 125 MHz system clock. Verify against your board revision's master
## XDC before using this as a standalone top-level clock port.
set sys_clk_ports [get_ports -quiet {sys_clk}]
if {[llength $sys_clk_ports] > 0} {
    set_property PACKAGE_PIN H16 $sys_clk_ports
    set_property IOSTANDARD LVCMOS33 $sys_clk_ports
    create_clock -name sys_clk_125mhz -period 8.000 $sys_clk_ports
}

## The accelerator target frequency is 100 MHz. In the PS block design this
## clock is normally internal FCLK_CLK0, so this standalone port constraint is
## guarded to avoid failing a block-design wrapper that has no s_axi_aclk port.
set axi_clk_ports [get_ports -quiet {s_axi_aclk}]
if {[llength $axi_clk_ports] > 0} {
    create_clock -name foundry_target_100mhz -period 10.000 $axi_clk_ports

    ## Conservative input/output delays for standalone timing analysis. The PYNQ
    ## deployment uses AXI interfaces inside the PL/PS fabric, so physical IO
    ## delay constraints are not required for the AXI buses in the block design.
    set_input_delay  2.000 -clock foundry_target_100mhz [all_inputs]
    set_output_delay 2.000 -clock foundry_target_100mhz [all_outputs]
}
