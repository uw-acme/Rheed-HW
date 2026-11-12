############### TEMPORARY OVER-CONSTRAINT ###############
#260 MHz	3.846 ns	0.154
#270 MHz	3.704 ns	0.296
#280 MHz	3.571 ns	0.429
#290 MHz	3.448 ns	0.552
#300 MHz	3.333 ns	0.667
#########################################################

#set_clock_uncertainty -setup 0.429 [get_clocks clk250]


#set_clock_uncertainty -setup -from [get_clocks clk250] -to [get_clocks clk250] 0.429

####################################################################################
# Constraints from file : 'xpm_cdc_async_rst.tcl'
####################################################################################


