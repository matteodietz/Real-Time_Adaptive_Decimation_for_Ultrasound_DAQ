#!/usr/bin/env python3
"""
Stimulus Generation for complex_to_log_power module

Generates test vectors with edge cases and random inputs.
"""

import sys
from pathlib import Path
import random
import math

# Add the parent directory to path to import fixed_float_conversions
SIMULATOR_ROOT = Path(__file__).resolve().parent.parent
sys.path.append(str(SIMULATOR_ROOT))

from fixed_float_conversions import float_to_fixed_point, fixed_point_to_float

# Configuration parameters
INPUT_WIDTH = 16   # Width of I and Q inputs
OUTPUT_WIDTH = 32  # Width of output
OUTPUT_FRAC = 16   # Fractional bits in output

def calculate_expected_log_power(i_val, q_val, input_width, output_width, output_frac):
    """
    Calculate the expected log power output (integer log2 only).
    
    Args:
        i_val: I component (as fixed-point integer)
        q_val: Q component (as fixed-point integer)
        input_width: bit width of inputs
        output_width: bit width of output
        output_frac: fractional bits in output
    
    Returns:
        Expected output value (as fixed-point integer)
    """
    # Convert to signed integers
    if i_val >= (1 << (input_width - 1)):
        i_signed = i_val - (1 << input_width)
    else:
        i_signed = i_val
    
    if q_val >= (1 << (input_width - 1)):
        q_signed = q_val - (1 << input_width)
    else:
        q_signed = q_val
    
    # Calculate magnitude squared
    mag_sq = i_signed * i_signed + q_signed * q_signed
    
    # Handle zero case
    if mag_sq == 0:
        return 0
    
    # Find MSB position (integer log2)
    msb_pos = mag_sq.bit_length() - 1
    
    # Place integer log2 in fixed-point format (shift left by OUTPUT_FRAC)
    log2_val = msb_pos << output_frac
    
    # Scale by 3: x * 3 = (x << 1) + x
    result = (log2_val << 1) + log2_val
    
    # Mask to output width
    result &= (1 << output_width) - 1
    
    return result

def generate_edge_cases(input_width):
    """
    Generate edge case test vectors.
    
    Returns:
        List of tuples (i_val, q_val, description)
    """
    max_pos = (1 << (input_width - 1)) - 1  # 0111...1
    min_neg = (1 << (input_width - 1))      # 1000...0
    zero = 0
    
    edge_cases = [
        # Both zero
        (zero, zero, "Both zero"),
        
        # Single component max/min
        (max_pos, zero, "I max positive, Q zero"),
        (min_neg, zero, "I max negative, Q zero"),
        (zero, max_pos, "I zero, Q max positive"),
        (zero, min_neg, "I zero, Q max negative"),
        
        # Both same sign
        (max_pos, max_pos, "Both max positive"),
        (min_neg, min_neg, "Both max negative"),
        
        # Opposite signs
        (max_pos, min_neg, "I max pos, Q max neg"),
        (min_neg, max_pos, "I max neg, Q max pos"),
        
        # Small values
        (1, 1, "Both minimum positive"),
        (1, 0, "I minimum positive, Q zero"),
        (0, 1, "I zero, Q minimum positive"),
        
        # Mid-range values
        (1 << (input_width - 2), 0, "I quarter scale, Q zero"),
        (0, 1 << (input_width - 2), "I zero, Q quarter scale"),
        (1 << (input_width - 2), 1 << (input_width - 2), "Both quarter scale"),
    ]
    
    return edge_cases

def generate_random_cases(input_width, num_cases=50):
    """
    Generate random test cases.
    
    Returns:
        List of tuples (i_val, q_val, description)
    """
    random_cases = []
    max_val = (1 << input_width) - 1
    
    for i in range(num_cases):
        i_val = random.randint(0, max_val)
        q_val = random.randint(0, max_val)
        random_cases.append((i_val, q_val, f"Random case {i+1}"))
    
    return random_cases

def write_vector_file(test_cases, output_path, input_width, output_width, output_frac):
    """
    Write test vectors to file.
    
    Format:
        Line 1-3: Header comments describing format
        Then pairs of lines:
        Line N:   I_value Q_value
        Line N+1: Expected_output
    """
    with open(output_path, 'w') as f:
        # Write header
        f.write("# Test vectors for complex_to_log_power module\n")
        f.write(f"# Format: Each test case consists of 2 lines:\n")
        f.write(f"# Line 1: I_value Q_value (both {input_width}-bit fixed-point integers)\n")
        f.write(f"# Line 2: Expected_output ({output_width}-bit fixed-point integer with {output_frac} fractional bits)\n")
        f.write(f"# Lines starting with '#' are comments and should be skipped\n")
        f.write("#\n")
        
        # Write test cases
        for i_val, q_val, description in test_cases:
            expected = calculate_expected_log_power(i_val, q_val, input_width, 
                                                   output_width, output_frac)
            
            # Write comment with description
            f.write(f"# Test case: {description}\n")
            
            # Write input values (I and Q on same line)
            f.write(f"{i_val} {q_val}\n")
            
            # Write expected output
            f.write(f"{expected}\n")

def main():
    """Generate all test vectors."""
    
    print("=== Generating test vectors for complex_to_log_power ===")
    print(f"INPUT_WIDTH  = {INPUT_WIDTH}")
    print(f"OUTPUT_WIDTH = {OUTPUT_WIDTH}")
    print(f"OUTPUT_FRAC  = {OUTPUT_FRAC}")
    print()
    
    # Generate edge cases
    edge_cases = generate_edge_cases(INPUT_WIDTH)
    print(f"Generated {len(edge_cases)} edge cases")
    
    # Generate random cases
    random_cases = generate_random_cases(INPUT_WIDTH, num_cases=50)
    print(f"Generated {len(random_cases)} random cases")
    
    # Combine all test cases
    test_cases = edge_cases + random_cases
    
    # Write to file
    output_dir = SIMULATOR_ROOT.parent / "rtl" / "simvectors"
    output_dir.mkdir(parents=True, exist_ok=True)
    output_path = output_dir / "log_power_vectors.txt"
    
    write_vector_file(test_cases, output_path, INPUT_WIDTH, OUTPUT_WIDTH, OUTPUT_FRAC)
    
    print(f"\n=== Successfully generated {len(test_cases)} test cases ===")
    print(f"Output file: {output_path}")
    print("\nTest cases generated:")
    print(f"  - Edge cases: {len(edge_cases)}")
    print(f"  - Random cases: {len(random_cases)}")
    print(f"  - Total: {len(test_cases)}")
    
    # Show a few example calculations
    print("\n=== Example test cases ===")
    for i, (i_val, q_val, desc) in enumerate(test_cases[:3]):
        expected = calculate_expected_log_power(i_val, q_val, INPUT_WIDTH, 
                                               OUTPUT_WIDTH, OUTPUT_FRAC)
        print(f"\nCase {i+1}: {desc}")
        print(f"  I = {i_val:6d} (0x{i_val:04x})")
        print(f"  Q = {q_val:6d} (0x{q_val:04x})")
        print(f"  Expected = {expected:10d} (0x{expected:08x})")

if __name__ == "__main__":
    main()