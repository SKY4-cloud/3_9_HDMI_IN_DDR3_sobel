# ModelSim run script for simple sobel test
# usage (ModelSim GUI): do run_models.do
# usage (command line): vsim -c -do run_models.do

vlib work
vmap work work

# compile DUT and testbench
vlog "HDMI_IN_DDR3_sobel/HDMI_IN_DDR3_sobel/source/img_process/sobel.v"
vlog "HDMI_IN_DDR3_sobel/HDMI_IN_DDR3_sobel/source/img_process/tb_sobel.v"

# run simulation for 400 ns and exit
vsim -c tb_sobel -do "run 400ns; quit -f"
