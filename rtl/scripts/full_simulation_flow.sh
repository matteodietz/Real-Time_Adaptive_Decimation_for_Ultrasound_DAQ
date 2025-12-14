#!/bin/bash
# run_overnight.sh - Complete automated simulation flow with dataset selection

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Default dataset if not specified
DATASET_TYPE=${1:-experiments}
DATASET_NAME=${2:-contrast_speckle}
NUM_TESTS=${3:-100}

echo -e "${GREEN}=== Starting Automated Simulation Flow ===${NC}"
echo "Dataset: $DATASET_TYPE/$DATASET_NAME"
echo "Number of tests: $NUM_TESTS"

# Step 1: Generate test vectors
echo -e "${YELLOW}Step 1: Generating test vectors...${NC}"
cd /home/bsc25h10/mdietz/bachelors_thesis/simulator/scripts
python3 generate_vectors_top.py $DATASET_TYPE $DATASET_NAME -n $NUM_TESTS

if [ $? -ne 0 ]; then
    echo -e "${RED}ERROR: Test vector generation failed!${NC}"
    exit 1
fi
echo -e "${GREEN}Test vectors generated successfully${NC}"

# Step 2: Create sim_results directory if it doesn't exist
echo -e "${YELLOW}Step 2: Setting up results directory...${NC}"
mkdir -p /home/bsc25h10/mdietz/bachelors_thesis/rtl/sim_results

# Step 3: Run Vivado simulation
echo -e "${YELLOW}Step 3: Running Vivado simulation...${NC}"
cd /home/bsc25h10/mdietz/bachelors_thesis/rtl

# Run Vivado in batch mode with dataset parameters
vivado -mode batch -source run_sim.tcl -tclargs $DATASET_TYPE $DATASET_NAME \
    -log sim_results/vivado_sim_${DATASET_TYPE}_${DATASET_NAME}.log \
    -journal sim_results/vivado_sim_${DATASET_TYPE}_${DATASET_NAME}.jou

if [ $? -ne 0 ]; then
    echo -e "${RED}ERROR: Simulation failed!${NC}"
    exit 1
fi

echo -e "${GREEN}Simulation completed successfully${NC}"

# Step 4: Check results
echo -e "${YELLOW}Step 4: Checking results...${NC}"
CSV_FILE="sim_results/top_results_${DATASET_TYPE}_${DATASET_NAME}.csv"

if [ -f $CSV_FILE ]; then
    error_count=$(awk -F',' 'NR>1 {sum+=$NF} END {print sum}' $CSV_FILE)
    total_tests=$(wc -l < $CSV_FILE)
    total_tests=$((total_tests - 1))
    
    echo -e "${GREEN}Total test cases: ${total_tests}${NC}"
    echo -e "${GREEN}Failed test cases: ${error_count}${NC}"
    
    if [ $error_count -eq 0 ]; then
        echo -e "${GREEN}=== ALL TESTS PASSED ===${NC}"
    else
        echo -e "${RED}=== SOME TESTS FAILED ===${NC}"
    fi
else
    echo -e "${RED}ERROR: Results file not found: $CSV_FILE${NC}"
    exit 1
fi

echo -e "${GREEN}=== Simulation Flow Completed ===${NC}"
echo "Results saved to: $CSV_FILE"

exit 0