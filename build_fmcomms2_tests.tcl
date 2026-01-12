###############################################################################
## FMCOMMS2/3 Testbench Builder for Vivado
##
## This script builds and runs the FMCOMMS2/3 testbenches from within Vivado
## without requiring the Make build system.
##
## Usage (from Vivado TCL console):
##   source <path_to_this_script>/build_fmcomms2_tests.tcl
##   build_fmcomms2_tests <adi_hdl_dir> [config_name] [test_name] [mode]
##
## Arguments:
##   adi_hdl_dir   - Path to the full ADI HDL repository root directory
##                   This must be the complete HDL repo (not just built IP)
##                   because testbenches require projects/ and library/ dirs.
##                   e.g., "C:/Work/Sandbox/QPSK_Triple_Comparison/deps/hdl"
##   config_name   - Optional: Configuration name from cfgs/ (default: "cfg1")
##   test_name     - Optional: Test name from tests/ (default: "test_program")
##   mode          - Optional: "batch" or "gui" (default: "batch")
##
## IMPORTANT: The ADI HDL libraries must be pre-built before running tests.
##            Use build_fmcomms2_ip.tcl to build the required IP first.
##
## Examples:
##   # Build and run default test:
##   source build_fmcomms2_tests.tcl
##   build_fmcomms2_tests "C:/Work/deps/hdl"
##
##   # Run specific config and test in GUI mode:
##   source build_fmcomms2_tests.tcl
##   build_fmcomms2_tests "C:/Work/deps/hdl" "cfg1" "test_program" "gui"
##
##   # Just build the environment (no test run):
##   source build_fmcomms2_tests.tcl
##   build_fmcomms2_env "C:/Work/deps/hdl" "cfg1"
##
## The script will:
##   1. Verify HDL libraries are built (component.xml exists)
##   2. Build simulation VIP components (io_vip, etc.)
##   3. Build the block design test environment
##   4. Run the specified test
###############################################################################

# Get the directory where this script is located
set script_dir [file dirname [file normalize [info script]]]

# Define the testbenches directory
set ad_tb_dir [file normalize $script_dir]

# Skip Vivado version checking
set IGNORE_VERSION_CHECK 1

# Set required_vivado_version to satisfy adi_ip_xilinx.tcl global variable reference
set required_vivado_version "any"

# Set VIVADO_IP_LIBRARY
if {[info exists ::env(ADI_VIVADO_IP_LIBRARY)]} {
    set VIVADO_IP_LIBRARY $::env(ADI_VIVADO_IP_LIBRARY)
} else {
    set VIVADO_IP_LIBRARY "user"
}

# Simulation VIP libraries required for fmcomms2 tests
set fmcomms2_sim_lib_deps {
    io_vip
}

# HDL libraries required for fmcomms2 tests (from Makefile LIB_DEPS)
set fmcomms2_hdl_lib_deps {
    axi_ad9361
    axi_dmac
    util_pack/util_cpack2
    util_pack/util_upack2
    util_rfifo
    util_tdd_sync
    util_wfifo
    xilinx/util_clkdiv
}

###############################################################################
# Procedure: build_sim_vip
# Builds a single simulation VIP library
###############################################################################
proc build_sim_vip {vip_name} {
    global ad_tb_dir
    global ad_hdl_dir
    global IGNORE_VERSION_CHECK
    global required_vivado_version
    global VIVADO_IP_LIBRARY

    set vip_path "$ad_tb_dir/library/vip/adi/$vip_name"
    set vip_tcl_file "$vip_path/${vip_name}_ip.tcl"

    if {![file exists $vip_tcl_file]} {
        puts "WARNING: VIP TCL file not found: $vip_tcl_file"
        return 0
    }

    # Check if already built
    if {[file exists "$vip_path/component.xml"]} {
        puts "VIP $vip_name already built, skipping"
        return 1
    }

    puts "=========================================="
    puts "Building VIP: $vip_name"
    puts "=========================================="

    set orig_dir [pwd]
    cd $vip_path

    if {[catch {source $vip_tcl_file} err]} {
        puts "ERROR building $vip_name: $err"
        catch {close_project}
        cd $orig_dir
        return 0
    }

    # Close project after build
    if {![catch {current_project}]} {
        puts "Closing project for $vip_name..."
        close_project
    }

    cd $orig_dir

    if {[file exists "$vip_path/component.xml"]} {
        puts "SUCCESS: $vip_name built successfully"
        return 1
    } else {
        puts "WARNING: component.xml not found after building $vip_name"
        return 0
    }
}

###############################################################################
# Procedure: check_hdl_libs
# Verifies HDL libraries are built (component.xml exists)
###############################################################################
proc check_hdl_libs {} {
    global ad_hdl_dir
    global fmcomms2_hdl_lib_deps

    puts "\n>>> Checking HDL library dependencies..."
    set missing_libs {}

    foreach lib $fmcomms2_hdl_lib_deps {
        set lib_path "$ad_hdl_dir/library/$lib"
        set lib_name [file tail $lib]

        if {![file exists "$lib_path/component.xml"]} {
            lappend missing_libs $lib
            puts "  MISSING: $lib"
        } else {
            puts "  OK: $lib"
        }
    }

    if {[llength $missing_libs] > 0} {
        puts ""
        puts "ERROR: The following HDL libraries are not built:"
        foreach lib $missing_libs {
            puts "  - $lib"
        }
        puts ""
        puts "Please build them first using build_fmcomms2_ip.tcl or make."
        return 0
    }

    puts "All HDL library dependencies are satisfied."
    return 1
}

###############################################################################
# Procedure: build_fmcomms2_env
# Builds the fmcomms2 test environment (block design)
###############################################################################
proc build_fmcomms2_env {adi_hdl_dir_arg {config_name "cfg1"}} {
    global ad_tb_dir
    global ad_hdl_dir
    global fmcomms2_sim_lib_deps
    global IGNORE_VERSION_CHECK
    global required_vivado_version
    global VIVADO_IP_LIBRARY

    # Normalize and set the HDL directory
    set adi_hdl_dir_arg [file normalize $adi_hdl_dir_arg]

    # The HDL directory must be the full repository root (containing library/ and projects/)
    # This is required because testbenches source files from projects/fmcomms2/common/
    if {![file exists "$adi_hdl_dir_arg/library"] || ![file exists "$adi_hdl_dir_arg/projects"]} {
        puts "ERROR: Invalid ADI HDL directory: $adi_hdl_dir_arg"
        puts "The directory must be the full HDL repository root containing:"
        puts "  - library/  (HDL IP cores)"
        puts "  - projects/ (project files including fmcomms2 block design)"
        puts ""
        puts "Example: C:/Work/Sandbox/QPSK_Triple_Comparison/deps/hdl"
        return ""
    }

    set ad_hdl_dir $adi_hdl_dir_arg

    # Also set environment variable for scripts that check it
    set ::env(ADI_HDL_DIR) $ad_hdl_dir

    set testbench_dir "$ad_tb_dir/testbenches/project/fmcomms2"

    puts "============================================================"
    puts "FMCOMMS2/3 Testbench Environment Builder"
    puts "============================================================"
    puts "ADI HDL Directory: $ad_hdl_dir"
    puts "Testbench Directory: $ad_tb_dir"
    puts "Configuration: $config_name"
    puts "============================================================"

    # Source the device info encoding script (in library/scripts/)
    set device_info_script "$ad_hdl_dir/library/scripts/adi_xilinx_device_info_enc.tcl"
    if {[file exists $device_info_script]} {
        source $device_info_script
    } else {
        puts "WARNING: Device info script not found: $device_info_script"
    }

    # Check HDL library dependencies
    if {![check_hdl_libs]} {
        return ""
    }

    # Build simulation VIP libraries
    puts "\n>>> Building simulation VIP libraries..."
    foreach vip $fmcomms2_sim_lib_deps {
        if {![build_sim_vip $vip]} {
            puts "ERROR: Failed to build VIP $vip"
            return ""
        }
    }

    # Change to testbench directory
    set orig_dir [pwd]
    cd $testbench_dir

    # Create runs directory
    file mkdir "runs"
    file mkdir "runs/$config_name"
    file mkdir "results"

    puts "\n>>> Building test environment for $config_name..."

    # Source the simulation script
    puts "DEBUG: Sourcing adi_sim.tcl from $ad_tb_dir/scripts/adi_sim.tcl"
    puts "DEBUG: Current working directory: [pwd]"
    puts "DEBUG: ad_hdl_dir = $ad_hdl_dir"
    puts "DEBUG: ADI_HDL_DIR env = $::env(ADI_HDL_DIR)"
    source "$ad_tb_dir/scripts/adi_sim.tcl"
    puts "DEBUG: adi_sim.tcl sourced successfully"

    # Ensure all required global variables from adi_board.tcl are set
    # These get set when adi_board.tcl is sourced but may not be in global scope
    # due to TCL scoping rules when sourced from within a procedure

    # Interconnect index variables
    if {![info exists ::sys_hpc0_interconnect_index]} { set ::sys_hpc0_interconnect_index -1 }
    if {![info exists ::sys_hpc1_interconnect_index]} { set ::sys_hpc1_interconnect_index -1 }
    if {![info exists ::sys_hp0_interconnect_index]}  { set ::sys_hp0_interconnect_index -1 }
    if {![info exists ::sys_hp1_interconnect_index]}  { set ::sys_hp1_interconnect_index -1 }
    if {![info exists ::sys_hp2_interconnect_index]}  { set ::sys_hp2_interconnect_index -1 }
    if {![info exists ::sys_hp3_interconnect_index]}  { set ::sys_hp3_interconnect_index -1 }
    if {![info exists ::sys_mem_interconnect_index]}  { set ::sys_mem_interconnect_index -1 }
    if {![info exists ::sys_mem_clk_index]}           { set ::sys_mem_clk_index 0 }

    # XCVR variables
    if {![info exists ::xcvr_index]}    { set ::xcvr_index -1 }
    if {![info exists ::xcvr_tx_index]} { set ::xcvr_tx_index 0 }
    if {![info exists ::xcvr_rx_index]} { set ::xcvr_rx_index 0 }
    if {![info exists ::xcvr_instance]} { set ::xcvr_instance NONE }

    # Smartconnect setting (default to 1 for Vivado 2023.2+)
    if {![info exists ::use_smartconnect]} {
        puts "DEBUG: use_smartconnect was not set globally, setting to 1"
        set ::use_smartconnect 1
    } else {
        puts "DEBUG: use_smartconnect = $::use_smartconnect"
    }

    if {[info exists ::sys_zynq]} {
        puts "DEBUG: sys_zynq = $::sys_zynq (before adi_sim_project_xilinx)"
    } else {
        puts "DEBUG: sys_zynq is NOT set yet (will be set in adi_sim_project_xilinx)"
    }

    puts "DEBUG: Global variables initialized for adi_board.tcl compatibility"

    # Source the configuration file
    set cfg_file "cfgs/${config_name}.tcl"
    if {![file exists $cfg_file]} {
        puts "ERROR: Configuration file not found: $cfg_file"
        cd $orig_dir
        return ""
    }
    puts "DEBUG: Sourcing configuration file: $cfg_file"
    source $cfg_file

    # Create the project
    set project_name $config_name
    puts "DEBUG: Calling adi_sim_project_xilinx with project=$project_name part=xczu9eg-ffvb1156-2-e"
    adi_sim_project_xilinx $project_name "xczu9eg-ffvb1156-2-e"

    # Verify key cells were created
    puts "DEBUG: After adi_sim_project_xilinx, checking if key cells exist..."
    if {[catch {set intc_cell [get_bd_cells axi_axi_interconnect]} err]} {
        puts "DEBUG: axi_axi_interconnect NOT found (catch error: $err)"
    } else {
        if {$intc_cell == ""} {
            puts "DEBUG: axi_axi_interconnect NOT found (empty result)"
        } else {
            puts "DEBUG: axi_axi_interconnect found: $intc_cell"
        }
    }
    if {[catch {set mem_intc [get_bd_cells axi_mem_interconnect]} err]} {
        puts "DEBUG: axi_mem_interconnect NOT found"
    } else {
        if {$mem_intc == ""} {
            puts "DEBUG: axi_mem_interconnect NOT found (empty result)"
        } else {
            puts "DEBUG: axi_mem_interconnect found: $mem_intc"
        }
    }

    # Source includes
    source $ad_tb_dir/library/includes/sp_include_dmac.tcl
    source $ad_tb_dir/library/includes/sp_include_converter.tcl

    # Add test files
    adi_sim_project_files [list \
        "tests/test_program.sv" \
    ]

    # Set default test program
    adi_sim_add_define "TEST_PROGRAM=test_program"

    # Generate the simulation
    adi_sim_generate $project_name

    # Close project
    if {![catch {current_project}]} {
        close_project
    }

    cd $orig_dir

    puts "\n============================================================"
    puts "Environment build complete!"
    puts "Project: $testbench_dir/runs/$config_name/$config_name.xpr"
    puts "============================================================"

    return "$testbench_dir/runs/$config_name/$config_name.xpr"
}

###############################################################################
# Procedure: run_fmcomms2_test
# Runs a specific test on a built environment
###############################################################################
proc run_fmcomms2_test {adi_hdl_dir_arg {config_name "cfg1"} {test_name "test_program"} {mode "batch"}} {
    global ad_tb_dir
    global ad_hdl_dir

    # Normalize and set the HDL directory (must be full repo root)
    set adi_hdl_dir_arg [file normalize $adi_hdl_dir_arg]
    set ad_hdl_dir $adi_hdl_dir_arg
    set ::env(ADI_HDL_DIR) $ad_hdl_dir

    set testbench_dir "$ad_tb_dir/testbenches/project/fmcomms2"
    set project_path "$testbench_dir/runs/$config_name/$config_name.xpr"

    if {![file exists $project_path]} {
        puts "ERROR: Project not found: $project_path"
        puts "Run build_fmcomms2_env first to create the test environment."
        return 0
    }

    puts "============================================================"
    puts "Running FMCOMMS2/3 Test"
    puts "============================================================"
    puts "Configuration: $config_name"
    puts "Test: $test_name"
    puts "Mode: $mode"
    puts "============================================================"

    set orig_dir [pwd]
    cd $testbench_dir

    # Source simulation scripts
    source "$ad_tb_dir/scripts/adi_sim.tcl"

    # Open the project
    adi_open_project $project_path

    # Update the test program define
    adi_update_define TEST_PROGRAM $test_name

    # Launch simulation
    launch_simulation

    if {$mode == "gui"} {
        log_wave -r {/system_tb/test_harness/DUT}

        set wave_file "waves/${config_name}.wcfg"
        if {[file exists $wave_file] == 0} {
            if {[file exists waves] == 0} {
                file mkdir waves
            }
            create_wave_config
            save_wave_config $wave_file
        } else {
            open_wave_config $wave_file
        }
        add_files -fileset sim_1 -norecurse $wave_file
        set_property xsim.view $wave_file [get_filesets sim_1]
    }

    # Run simulation
    run all

    cd $orig_dir

    puts "\n============================================================"
    puts "Test complete!"
    puts "============================================================"

    return 1
}

###############################################################################
# Main Procedure: build_fmcomms2_tests
# Builds environment and runs test in one step
###############################################################################
proc build_fmcomms2_tests {adi_hdl_dir_arg {config_name "cfg1"} {test_name "test_program"} {mode "batch"}} {
    # First build the environment
    set project_path [build_fmcomms2_env $adi_hdl_dir_arg $config_name]

    if {$project_path == ""} {
        puts "ERROR: Failed to build test environment"
        return 0
    }

    # Then run the test
    return [run_fmcomms2_test $adi_hdl_dir_arg $config_name $test_name $mode]
}

###############################################################################
# Procedure: list_fmcomms2_tests
# Lists available configurations and tests
###############################################################################
proc list_fmcomms2_tests {} {
    global ad_tb_dir

    set testbench_dir "$ad_tb_dir/testbenches/project/fmcomms2"

    puts "============================================================"
    puts "Available FMCOMMS2/3 Tests"
    puts "============================================================"

    puts "\nConfigurations (cfgs/):"
    foreach cfg_file [glob -nocomplain "$testbench_dir/cfgs/cfg*.tcl"] {
        set cfg_name [file rootname [file tail $cfg_file]]
        puts "  - $cfg_name"
    }

    puts "\nTests (tests/):"
    foreach test_file [glob -nocomplain "$testbench_dir/tests/*.sv"] {
        set test_name [file rootname [file tail $test_file]]
        puts "  - $test_name"
    }

    puts "============================================================"
}

###############################################################################
# Startup message
###############################################################################
puts "============================================================"
puts "FMCOMMS2/3 Testbench Builder loaded"
puts "============================================================"
puts "Available commands:"
puts ""
puts "  build_fmcomms2_tests <hdl_dir> \[cfg\] \[test\] \[mode\]"
puts "      Build environment and run test"
puts "      cfg  = configuration name (default: cfg1)"
puts "      test = test name (default: test_program)"
puts "      mode = batch or gui (default: batch)"
puts ""
puts "  build_fmcomms2_env <hdl_dir> \[cfg\]"
puts "      Build only the test environment"
puts ""
puts "  run_fmcomms2_test <hdl_dir> \[cfg\] \[test\] \[mode\]"
puts "      Run test on existing environment"
puts ""
puts "  list_fmcomms2_tests"
puts "      List available configurations and tests"
puts ""
puts "Examples:"
puts "  build_fmcomms2_tests \"C:/Work/deps/hdl\""
puts "  build_fmcomms2_env \"C:/Work/deps/hdl\" \"cfg1\""
puts "  run_fmcomms2_test \"C:/Work/deps/hdl\" \"cfg1\" \"test_program\" \"gui\""
puts ""
puts "NOTE: hdl_dir must be the full ADI HDL repository root"
puts "      (containing both library/ and projects/ directories)"
puts ""
puts "The script auto-detected testbenches at:"
puts "  $ad_tb_dir"
puts "============================================================"
