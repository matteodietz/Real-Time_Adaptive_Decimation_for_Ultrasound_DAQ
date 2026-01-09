# run_sim.tcl - Run simulation ONLY (assumes design already compiled/elaborated)
# Usage in shell: vivado -mode batch -source run_sim.tcl -tclargs <dataset_type> <dataset_name>

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

# 2. Path Detection
set script_path [file normalize [info script]]
set script_dir  [file dirname $script_path]
set project_name "bw_estim"

# Project is located in 'rtl/vivado'
# Script is in 'rtl/scripts'
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

# 4. Simulation Setup (no recompilation needed)
set_property top top_tb [get_filesets sim_1]
set_property top_lib xil_defaultlib [get_filesets sim_1]

# 5. Pass Arguments via Testplusargs ONLY
set_property -name {xsim.simulate.xsim.more_options} -value "-testplusarg DATASET_TYPE=${dataset_type} -testplusarg DATASET_NAME=${dataset_name}" -objects [get_filesets sim_1]

# 6. Launch and Run (reuses already compiled design)
if {[current_sim -quiet] ne ""} {
    puts "Closing active simulation..."
    close_sim -force
}

puts "Launching simulation for ${dataset_type}/${dataset_name}..."
launch_simulation -mode behavioral

puts "Running simulation..."
run all

# 7. Cleanup
close_sim

if {[info exists ::tcl_interactive] && $::tcl_interactive == 0} {
    close_project
}

puts "Simulation complete for ${dataset_type}/${dataset_name}"
exit 0