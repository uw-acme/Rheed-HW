



####################################################################################
# Constraints from file : 'xpm_cdc_gray.tcl'
####################################################################################


set_false_path -from [list iCoaxlinkCore/*/C [get_pins {iCoaxlinkCore/user_rst_reg_replica/C iCoaxlinkCore/user_rst_reg_replica_1/C iCoaxlinkCore/user_rst_reg_replica_2/C iCoaxlinkCore/user_rst_reg_replica_3/C iCoaxlinkCore/user_rst_reg_replica_4/C iCoaxlinkCore/user_rst_reg_replica_5/C iCoaxlinkCore/user_rst_reg_replica_6/C iCoaxlinkCore/user_rst_reg_replica_7/C iCoaxlinkCore/user_rst_reg_replica_8/C iCoaxlinkCore/user_rst_reg_replica_9/C iCoaxlinkCore/user_rst_reg_replica_10/C iCoaxlinkCore/user_rst_reg_replica_11/C iCoaxlinkCore/user_rst_reg_replica_12/C iCoaxlinkCore/user_rst_reg_replica_13/C iCoaxlinkCore/user_rst_reg_replica_14/C iCoaxlinkCore/user_rst_reg_replica_15/C}]] -to [list iCoaxlinkCore/*/CE [get_pins {iCoaxlinkCore/user_rst_reg_replica/CE iCoaxlinkCore/user_rst_reg_replica_1/CE iCoaxlinkCore/user_rst_reg_replica_2/CE iCoaxlinkCore/user_rst_reg_replica_3/CE iCoaxlinkCore/user_rst_reg_replica_4/CE iCoaxlinkCore/user_rst_reg_replica_5/CE iCoaxlinkCore/user_rst_reg_replica_6/CE iCoaxlinkCore/user_rst_reg_replica_7/CE iCoaxlinkCore/user_rst_reg_replica_8/CE iCoaxlinkCore/user_rst_reg_replica_9/CE iCoaxlinkCore/user_rst_reg_replica_10/CE iCoaxlinkCore/user_rst_reg_replica_11/CE iCoaxlinkCore/user_rst_reg_replica_12/CE iCoaxlinkCore/user_rst_reg_replica_13/CE iCoaxlinkCore/user_rst_reg_replica_14/CE iCoaxlinkCore/user_rst_reg_replica_15/CE}]]

####################################################################################
# Constraints from file : 'xpm_cdc_gray.tcl'
####################################################################################

set_property C_CLK_INPUT_FREQ_HZ 300000000 [get_debug_cores dbg_hub]
set_property C_ENABLE_CLK_DIVIDER false [get_debug_cores dbg_hub]
set_property C_USER_SCAN_CHAIN 1 [get_debug_cores dbg_hub]
connect_debug_port dbg_hub/clk [get_nets clk]
