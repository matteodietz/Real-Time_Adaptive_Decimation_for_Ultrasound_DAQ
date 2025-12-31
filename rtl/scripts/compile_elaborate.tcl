# compile_elaborate.tcl - Compile and elaborate design once (no simulation run)
# This script only compiles and elaborates, leaving the design ready for multiple runs

puts "========================================"
puts "  Compile and Elaborate Design"
puts "========================================"

# 1. Robust Path Detection
set script_path [file normalize [info script]]
set script_dir  [file dirname $script_path]
set project_name "bw_estim"

# Project is located in 'rtl/vivado'
# Script is in 'rtl/scripts'
set project_dir [file normalize "${script_dir}/../vivado"]

puts "Project Directory: $project_dir"
puts "Project File: ${project_dir}/${project_name}.xpr"

# 2. Open Project
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


# 2.5. Generate IP Simulation Files & Clean Up Sources
puts "Generating IP simulation files..."

# Upgrade IP if needed
upgrade_ip -quiet [get_ips]

# Generate simulation products
generate_target simulation [get_ips]

# CRITICAL FOR BATCH MODE: Export IP files to the correct lib directories
export_ip_user_files -of_objects [get_ips] -no_script -sync -force -quiet

puts "IP simulation files generated and exported."

# --- Disable IP Demo Testbenches ---
# Vivado adds 'tb_cordic_0.vhd' to sim_1. We must disable it 
# because it conflicts with the compilation flow of the actual design.
set garbage_tbs [get_files -quiet -all -filter {NAME =~ *demo_tb* || NAME =~ *tb_cordic_0*}]
if {$garbage_tbs ne ""} {
    puts "Removing Xilinx IP demo testbenches from simulation context: $garbage_tbs"
    set_property used_in_simulation false $garbage_tbs
}


# 3. Simulation Setup
set_property top top_tb [get_filesets sim_1]
set_property top_lib xil_defaultlib [get_filesets sim_1]

# Re-scan the compilation order after disabling the garbage files
update_compile_order -fileset sim_1


# 4. Clear any existing simulation options
set_property -name {xsim.elaborate.xelab.more_options} -value "" -objects [get_filesets sim_1]
set_property -name {xsim.simulate.xsim.more_options} -value "" -objects [get_filesets sim_1]

puts "Compiling and elaborating design..."

# 5. Launch elaboration only (don't run simulation)
# Close any existing simulation first
if {[current_sim -quiet] ne ""} {
    puts "Closing active simulation..."
    close_sim -force
}

# Launch simulation but don't run it
launch_simulation -mode behavioral

# Close the simulation immediately (we only wanted to compile/elaborate)
close_sim

puts "========================================"
puts "  Compilation and Elaboration Complete"
puts "========================================"
puts "Design is ready for multiple simulation runs"

# Close project in batch mode
if {[info exists ::tcl_interactive] && $::tcl_interactive == 0} {
    close_project
}

exit 0