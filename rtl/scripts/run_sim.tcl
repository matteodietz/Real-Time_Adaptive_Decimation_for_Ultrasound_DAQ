# # run_sim.tcl - Automated simulation script for Vivado with dataset parameters
# # Usage: vivado -mode batch -source run_sim.tcl -tclargs <dataset_type> <dataset_name>

# # Get command line arguments
# if { $argc >= 2 } {
#     set dataset_type [lindex $argv 0]
#     set dataset_name [lindex $argv 1]
#     puts "Running simulation with dataset: ${dataset_type}/${dataset_name}"
# } else {
#     set dataset_type "experiments"
#     set dataset_name "contrast_speckle"
#     puts "Using default dataset: ${dataset_type}/${dataset_name}"
# }

# # Set your project path
# set project_dir "/home/bsc25h10/mdietz/bachelors_thesis/rtl/vivado"
# set project_name "bw_estim"

# # Open project (if it exists)
# # 3. Open Project
# if {[file exists ${project_dir}/${project_name}.xpr]} {
#     # Only open if not already open to prevent errors
#     if {[current_project -quiet] eq ""} {
#         open_project ${project_dir}/${project_name}.xpr
#     } else {
#         # Check if the opened project matches the one we want
#         set curr_proj [current_project]
#         if {$curr_proj ne $project_name} {
#             puts "WARNING: Closing current project $curr_proj to open $project_name"
#             close_project
#             open_project ${project_dir}/${project_name}.xpr
#         }
#     }
# } else {
#     puts "ERROR: Project file not found at ${project_dir}/${project_name}.xpr"
#     # Check one level up just in case the project was created flat in 'rtl'
#     set flat_dir [file normalize "${script_dir}/.."]
#     if {[file exists ${flat_dir}/${project_name}.xpr]} {
#         puts "FOUND in flat directory. Opening..."
#         open_project ${flat_dir}/${project_name}.xpr
#     } else {
#         return -code error "Project not found in ${project_dir} or ${flat_dir}"
#     }
# }

# # if {[file exists ${project_dir}/${project_name}.xpr]} {
# #     open_project ${project_dir}/${project_name}.xpr
# # } else {
# #     puts "ERROR: Project file not found at ${project_dir}/${project_name}.xpr"
# #     exit 1
# # }

# # 4. Simulation Setup
# set_property top top_tb [get_filesets sim_1]
# set_property top_lib xil_defaultlib [get_filesets sim_1]
# update_compile_order -fileset sim_1

# # 5. Pass Arguments to Verilog via Testplusargs
# #    We clear previous options first to avoid accumulating args if run multiple times
# set_property -name {xsim.simulate.xsim.more_options} -value "" -objects [get_filesets sim_1]
# set_property -name {xsim.simulate.xsim.more_options} -value "-testplusarg DATASET_TYPE=${dataset_type} -testplusarg DATASET_NAME=${dataset_name}" -objects [get_filesets sim_1]

# # 6. Launch and Run
# # FIX: Check if simulation is already running and close it to prevent [Vivado 12-1501] error
# if {[current_sim -quiet] ne ""} {
#     puts "Closing active simulation..."
#     close_sim
# }

# launch_simulation
# run all

# # 7. Cleanup
# # In GUI mode (tcl_interactive=1), leave open for inspection.
# # In Batch mode (tcl_interactive=0), close to exit cleanly.
# if {[info exists ::tcl_interactive] && $::tcl_interactive == 0} {
#     close_sim
#     close_project
# } else {
#     puts "Simulation done. Project left open for waveform inspection."
# }

# # run_sim.tcl - Robust simulation launch script for Vivado
# # Usage (Tcl Console):
# #   set argv [list <dataset_type> <dataset_name>]
# #   set argc 2
# #   source scripts/run_sim.tcl

# # # 1. Handle Arguments (Works for batch mode or if argv is set in console)
# # if { [info exists ::argv] && [llength $::argv] >= 2 } {
# #     set dataset_type [lindex $::argv 0]
# #     set dataset_name [lindex $::argv 1]
# #     puts "Running simulation with dataset: ${dataset_type}/${dataset_name}"
# # } else {
# #     set dataset_type "experiments"
# #     set dataset_name "contrast_speckle"
# #     puts "Using default/fallback dataset: ${dataset_type}/${dataset_name}"
# # }

# # # 2. Robust Path Detection (Relative to this script file)
# # #    This allows the script to work regardless of where you launch Vivado from.
# # set script_path [file normalize [info script]]
# # set script_dir  [file dirname $script_path]

# # set project_name "bw_estim"

# # # FIX: Point to the subdirectory containing the project file
# # # Structure: rtl/scripts/run_sim.tcl -> go up to 'rtl' -> go down to 'bw_estim'
# # # Result: .../rtl/bw_estim/
# # set project_dir [file normalize "${script_dir}/../${project_name}"]

# # puts "Project Directory: $project_dir"
# # puts "Project File: ${project_dir}/${project_name}.xpr"

# # # 3. Open Project
# # if {[file exists ${project_dir}/${project_name}.xpr]} {
# #     # Only open if not already open to prevent errors
# #     if {[current_project -quiet] eq ""} {
# #         open_project ${project_dir}/${project_name}.xpr
# #     } else {
# #         # Check if the opened project matches the one we want
# #         set curr_proj [current_project]
# #         if {$curr_proj ne $project_name} {
# #             puts "WARNING: Closing current project $curr_proj to open $project_name"
# #             close_project
# #             open_project ${project_dir}/${project_name}.xpr
# #         }
# #     }
# # } else {
# #     puts "ERROR: Project file not found at ${project_dir}/${project_name}.xpr"
# #     # Check one level up just in case the project was created flat in 'rtl'
# #     set flat_dir [file normalize "${script_dir}/.."]
# #     if {[file exists ${flat_dir}/${project_name}.xpr]} {
# #         puts "FOUND in flat directory. Opening..."
# #         open_project ${flat_dir}/${project_name}.xpr
# #     } else {
# #         return -code error "Project not found in ${project_dir} or ${flat_dir}"
# #     }
# # }

# # # 4. Simulation Setup
# # set_property top top_tb [get_filesets sim_1]
# # set_property top_lib xil_defaultlib [get_filesets sim_1]
# # update_compile_order -fileset sim_1

# # # 5. Pass Arguments to Verilog via Testplusargs
# # #    We clear previous options first to avoid accumulating args if run multiple times
# # set_property -name {xsim.simulate.xsim.more_options} -value "" -objects [get_filesets sim_1]
# # set_property -name {xsim.simulate.xsim.more_options} -value "-testplusarg DATASET_TYPE=${dataset_type} -testplusarg DATASET_NAME=${dataset_name}" -objects [get_filesets sim_1]

# # # 6. Launch and Run
# # launch_simulation
# # run all

# # # 7. Cleanup
# # # In GUI mode (tcl_interactive=1), leave open for inspection.
# # # In Batch mode (tcl_interactive=0), close to exit cleanly.
# # if {[info exists ::tcl_interactive] && $::tcl_interactive == 0} {
# #     close_sim
# #     close_project
# # } else {
# #     puts "Simulation done. Project left open for waveform inspection."
# # }

# run_sim.tcl - Robust simulation launch script for Vivado
# Usage (Tcl Console):
#   set argv [list <dataset_type> <dataset_name>]
#   set argc 2
#   source scripts/run_sim.tcl

# 1. Handle Arguments
if { [info exists ::argv] && [llength $::argv] >= 2 } {
    set dataset_type [lindex $::argv 0]
    set dataset_name [lindex $::argv 1]
    puts "Running simulation with dataset: ${dataset_type}/${dataset_name}"
} else {
    set dataset_type "experiments"
    set dataset_name "contrast_speckle"
    puts "Using default/fallback dataset: ${dataset_type}/${dataset_name}"
}

# 2. Robust Path Detection
set script_path [file normalize [info script]]
set script_dir  [file dirname $script_path]

set project_name "bw_estim"

# Project is located in 'rtl/vivado' (based on your previous query)
# Script is in 'rtl/scripts'
# So we go up one level from scripts to 'rtl', then down to 'vivado'
set project_dir [file normalize "${script_dir}/../vivado"]

puts "Project Directory: $project_dir"
puts "Project File: ${project_dir}/${project_name}.xpr"

# 3. Open Project
if {[file exists ${project_dir}/${project_name}.xpr]} {
    if {[current_project -quiet] eq ""} {
        open_project ${project_dir}/${project_name}.xpr
    } else {
        set curr_proj [current_project]
        if {$curr_proj ne $project_name} {
            puts "WARNING: Closing current project $curr_proj to open $project_name"
            close_project
            open_project ${project_dir}/${project_name}.xpr
        }
    }
} else {
    puts "ERROR: Project file not found at ${project_dir}/${project_name}.xpr"
    return -code error "Project file missing"
}

# 4. Simulation Setup
set_property top top_tb [get_filesets sim_1]
set_property top_lib xil_defaultlib [get_filesets sim_1]
update_compile_order -fileset sim_1

# 5. Pass Arguments via Testplusargs ONLY
#    We must explicitly CLEAR the elaborate options to remove any stale '+define+' flags
#    from previous runs that are causing the "Cannot find design unit" error.

set_property -name {xsim.elaborate.xelab.more_options} -value "" -objects [get_filesets sim_1]
set_property -name {xsim.simulate.xsim.more_options} -value "" -objects [get_filesets sim_1]

# Set new runtime options
# NOTE: Ensure your testbench uses $value$plusargs("DATASET_TYPE=%s", ...) to read these.
set_property -name {xsim.simulate.xsim.more_options} -value "-testplusarg DATASET_TYPE=${dataset_type} -testplusarg DATASET_NAME=${dataset_name}" -objects [get_filesets sim_1]

# 6. Launch and Run
# Check if simulation is already running and close it
if {[current_sim -quiet] ne ""} {
    puts "Closing active simulation..."
    close_sim -force
}

launch_simulation
run all

# 7. Cleanup
if {[info exists ::tcl_interactive] && $::tcl_interactive == 0} {
    close_sim
    close_project
} else {
    puts "Simulation done. Project left open for waveform inspection."
}