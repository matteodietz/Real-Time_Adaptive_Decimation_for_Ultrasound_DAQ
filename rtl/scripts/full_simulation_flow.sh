#!/bin/bash
# full_simulation_flow.sh - Optimized portable simulation flow
#
# Usage: ./full_simulation_flow.sh [NUM_TESTS]

# --- 1. Robust Path Detection ---
# Get the directory where this script is physically located
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

# Define project roots relative to the script location
# Structure:
#   repo_root/
#     rtl/
#       scripts/ (Where this script is)
#     simulator/
#       generate_stimuli/ (Where python generation scripts are)

RTL_DIR="${SCRIPT_DIR}/.."
SIM_SCRIPTS_DIR="${SCRIPT_DIR}/../../simulator/generate_stimuli"

# Configuration
NUM_TESTS=${1:-5}

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Automated Overnight Simulation Flow  ${NC}"
echo -e "${GREEN}========================================${NC}"
echo "Script location: $SCRIPT_DIR"
echo "RTL directory:   $RTL_DIR"
echo "Sim directory:   $SIM_SCRIPTS_DIR"
echo "Test cases/set:  $NUM_TESTS"
echo ""

declare -a DATASETS=(
    "experiments contrast_speckle"
    "experiments resolution_distorsion"
    "in_vivo carotid_cross"
    "in_vivo carotid_long"
    # "simulation contrast_speckle"
    # "simulation resolution_distorsion"
)

#==============================================================================
# STEP 1: Generate Test Vectors
#==============================================================================
echo -e "${BLUE}STEP 1: Generating Test Vectors${NC}"

# Move to python script directory to ensure relative imports inside python work
cd "$SIM_SCRIPTS_DIR" || { echo "Error: Could not find sim scripts dir: $SIM_SCRIPTS_DIR"; exit 1; }

for dataset in "${DATASETS[@]}"; do
    read -r dataset_type dataset_name <<< "$dataset"
    echo -e "${YELLOW}Generating: ${dataset_type}/${dataset_name}${NC}"
    
    python generate_vectors_top.py -t "$dataset_type" -d "$dataset_name" -n "$NUM_TESTS"
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}ERROR: Vector generation failed.${NC}"
        exit 1
    fi
done

#==============================================================================
# STEP 2: Compile and Elaborate
#==============================================================================
echo -e "${BLUE}STEP 2: Compile and Elaborate${NC}"

# Move to RTL directory for Vivado execution
cd "$RTL_DIR" || { echo "Error: Could not find RTL dir: $RTL_DIR"; exit 1; }
mkdir -p sim_results

# We use relative path 'scripts/' because we are now inside 'rtl/'
vitis-2024.2 vivado -mode batch -source scripts/compile_elaborate.tcl \
    -log sim_results/vivado_compile.log \
    -journal sim_results/vivado_compile.jou

if [ $? -ne 0 ]; then
    echo -e "${RED}ERROR: Compilation failed. Check log.${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Compilation successful${NC}"

#==============================================================================
# STEP 3: Run Simulations
#==============================================================================
echo -e "${BLUE}STEP 3: Running Simulations${NC}"

TOTAL_DATASETS=${#DATASETS[@]}
CURRENT=0
FAILED_SIMS=()

for dataset in "${DATASETS[@]}"; do
    read -r dataset_type dataset_name <<< "$dataset"
    CURRENT=$((CURRENT + 1))
    
    echo -e "${YELLOW}[${CURRENT}/${TOTAL_DATASETS}] Simulating: ${dataset_type}/${dataset_name}${NC}"
    
    # Run simulation using relative path to script
    vitis-2024.2 vivado -mode batch -source scripts/run_sim.tcl -tclargs "$dataset_type" "$dataset_name" \
        -log sim_results/vivado_sim_${dataset_type}_${dataset_name}.log \
        -journal sim_results/vivado_sim_${dataset_type}_${dataset_name}.jou
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}✗ Failed${NC}"
        FAILED_SIMS+=("${dataset_type}/${dataset_name}")
    else
        echo -e "${GREEN}✓ Completed${NC}"
    fi
done

#==============================================================================
# STEP 4: Results Analysis
#==============================================================================
echo -e "${BLUE}STEP 4: Analysis${NC}"

TOTAL_TESTS=0
TOTAL_ERRORS=0

for dataset in "${DATASETS[@]}"; do
    read -r dataset_type dataset_name <<< "$dataset"
    CSV_FILE="sim_results/top_results_${dataset_type}_${dataset_name}.csv"
    
    if [ -f "$CSV_FILE" ]; then
        num_tests=$(tail -n +2 "$CSV_FILE" | wc -l)
        num_errors=$(awk -F',' 'NR>1 && $NF==1 {count++} END {print count+0}' "$CSV_FILE")
        
        TOTAL_TESTS=$((TOTAL_TESTS + num_tests))
        TOTAL_ERRORS=$((TOTAL_ERRORS + num_errors))
        
        if [ "$num_errors" -eq 0 ]; then
            echo -e "${GREEN}✓ ${dataset_name}:${NC} $num_tests tests, ${GREEN}0 errors${NC}"
        else
            echo -e "${RED}✗ ${dataset_name}:${NC} $num_tests tests, ${RED}$num_errors errors${NC}"
        fi
    else
        echo -e "${RED}✗ ${dataset_name}: No results file found${NC}"
    fi
done

echo ""
if [ $TOTAL_ERRORS -eq 0 ]; then
    echo -e "${GREEN}ALL PASSED ($TOTAL_TESTS tests)${NC}"
else
    echo -e "${RED}FAILURES DETECTED ($TOTAL_ERRORS errors)${NC}"
fi

exit 0