"""
generate_vectors_find_max.py

Generates test vectors for the find_max_power module testbench.
Uses shared fixed-point conversion logic for consistency.
"""

import numpy as np
import sys
from pathlib import Path

# Add parent directory to path to import shared modules
SIMULATOR_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SIMULATOR_ROOT / "src"))

# Import your shared conversion function
from fixed_float_conversions import float_to_fixed_point

def generate_test_vectors(output_file):
    """Generate test vectors for find_max_power testbench"""
    
    # Test configuration
    NUM_BINS_OPTIONS = [24] 
    POWER_WIDTH = 8
    POWER_FRAC = 0  # Q16.16 format
    POWER_INT  = POWER_WIDTH - POWER_FRAC
    IS_SIGNED  = False # The log_power output is Unsigned
    
    test_cases = []
    
    # =========================================================================
    # Test Case 1: All values the same
    # =========================================================================
    for num_bins in NUM_BINS_OPTIONS:
        power_values = [42.5] * num_bins
        expected_max = 42.5
        test_cases.append({
            'name': f'All_Same_{num_bins}_bins',
            'num_bins': num_bins,
            'values': power_values,
            'expected': expected_max
        })
    
    # =========================================================================
    # Test Case 2: Maximum at the first position
    # =========================================================================
    for num_bins in NUM_BINS_OPTIONS:
        power_values = [100.0] + [i * 2.5 for i in range(num_bins - 1)]
        expected_max = 100.0
        test_cases.append({
            'name': f'Max_at_Start_{num_bins}_bins',
            'num_bins': num_bins,
            'values': power_values,
            'expected': expected_max
        })
    
    # =========================================================================
    # Test Case 3: Maximum at the last position
    # =========================================================================
    for num_bins in NUM_BINS_OPTIONS:
        power_values = [i * 2.5 for i in range(num_bins - 1)] + [100.0]
        expected_max = 100.0
        test_cases.append({
            'name': f'Max_at_End_{num_bins}_bins',
            'num_bins': num_bins,
            'values': power_values,
            'expected': expected_max
        })
    
    # =========================================================================
    # Test Case 4: Maximum in the middle
    # =========================================================================
    for num_bins in NUM_BINS_OPTIONS:
        power_values = [i * 2.0 for i in range(num_bins)]
        power_values[num_bins // 2] = 100.0
        expected_max = 100.0
        test_cases.append({
            'name': f'Max_in_Middle_{num_bins}_bins',
            'num_bins': num_bins,
            'values': power_values,
            'expected': expected_max
        })
    
    # =========================================================================
    # Test Case 5: Random values (50 Iterations, Full 16-bit Range)
    # =========================================================================
    np.random.seed(42)
    # 50 Random Iterations
    for k in range(50):
        for num_bins in NUM_BINS_OPTIONS:
            # Generate random values between 0 and 255 (2^8 - 1)
            # This fills the Integer part of the Q8.0 format
            power_values = np.random.uniform(0, 255, num_bins).tolist()
            expected_max = max(power_values)
            
            test_cases.append({
                'name': f'Random_FullRange_{num_bins}bins_iter{k}',
                'num_bins': num_bins,
                'values': power_values,
                'expected': expected_max
            })
    
    # =========================================================================
    # Write test vectors to file
    # =========================================================================
    with open(output_file, 'w') as f:
        # Write header
        f.write("=" * 80 + "\n")
        f.write("Test Vectors for find_max_power Module\n")
        f.write("=" * 80 + "\n")
        f.write(f"Generated test cases: {len(test_cases)}\n")
        f.write(f"Power width: {POWER_WIDTH} bits\n")
        f.write(f"Fractional bits: {POWER_FRAC}\n")
        f.write(f"Signed: {IS_SIGNED}\n")
        f.write("\n")
        f.write("Format:\n")
        f.write("  TEST_NAME\n")
        f.write("  NUM_BINS\n")
        f.write("  POWER_VALUES (hex, unsigned fixed-point Q{}.{})\n".format(
            POWER_INT, POWER_FRAC))
        f.write("  EXPECTED_MAX (hex)\n")
        f.write("=" * 80 + "\n\n")
        
        # Write each test case
        for test in test_cases:
            f.write(f"{test['name']}\n")
            f.write(f"{test['num_bins']}\n")
            
            # Convert inputs using shared function
            for val in test['values']:
                fixed_val = float_to_fixed_point(val, POWER_INT, POWER_FRAC, signed=IS_SIGNED)
                f.write(f"{fixed_val:02x}\n")
            
            # Convert expected output using shared function
            expected_fixed = float_to_fixed_point(test['expected'], POWER_INT, POWER_FRAC, signed=IS_SIGNED)
            f.write(f"{expected_fixed:02x}\n")
            
            f.write("\n")
    
    print(f"Generated {len(test_cases)} test cases")
    print(f"Output written to: {output_file}")

if __name__ == '__main__':
    output_dir = SIMULATOR_ROOT.parent / "rtl" / "simvectors"
    output_dir.mkdir(parents=True, exist_ok=True)
    output_path = output_dir / "find_max_power_vectors.txt"
    
    generate_test_vectors(output_path)
    print("\nVector generation complete!")