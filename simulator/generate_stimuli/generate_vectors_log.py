"""
Stimulus Generation for complex_to_log_power module

Generates test vectors using simplified logic: 3 * floor(log2(I^2 + Q^2))
"""

import sys
from pathlib import Path
import random

# --- Configuration ---
INPUT_WIDTH = 18   # Width of I and Q inputs
OUTPUT_WIDTH = 8   # Width of output
OUTPUT_FRAC = 0    # Fractional bits (kept for compatibility, though unused in logic)

def to_signed(val, width):
    """
    Interpret an unsigned integer (raw bits) as a 2's complement signed integer.
    """
    if val >= (1 << (width - 1)):
        return val - (1 << width)
    return val

def calculate_expected_log_power(i_val_raw, q_val_raw, input_width, output_width, output_frac):
    """
    Calculate simple log power: 3 * floor(log2(I^2 + Q^2))
    """
    # 1. Convert raw bits to signed integers for correct math
    i_signed = to_signed(i_val_raw, input_width)
    q_signed = to_signed(q_val_raw, input_width)
    
    # 2. Calculate Magnitude Squared (Integer Math)
    mag_sq = (i_signed * i_signed) + (q_signed * q_signed)
    
    # 3. Handle Zero Case
    if mag_sq == 0:
        return 0
        
    # 4. Find MSB Index (Equivalent to floor(log2(x)))
    msb_index = mag_sq.bit_length() - 1
    
    # 5. Calculate dB Power (3 * MSB)
    result = msb_index * 3
    
    # 6. Clip to Output Width
    return result & ((1 << output_width) - 1)

def generate_edge_cases(input_width):
    """Generate edge case test vectors."""
    max_pos = (1 << (input_width - 1)) - 1
    min_neg = (1 << (input_width - 1))
    zero = 0
    
    edge_cases = [
        (zero, zero, "Both zero"),
        (max_pos, zero, "I max positive, Q zero"),
        (min_neg, zero, "I max negative, Q zero"),
        (zero, max_pos, "I zero, Q max positive"),
        (zero, min_neg, "I zero, Q max negative"),
        (max_pos, max_pos, "Both max positive"),
        (min_neg, min_neg, "Both max negative"),
        (max_pos, min_neg, "I max pos, Q max neg"),
        (1, 1, "Both minimum positive"),
        (1 << (input_width - 2), 1 << (input_width - 2), "Both quarter scale"),
    ]
    return edge_cases

def generate_random_cases(input_width, num_cases=50):
    """Generate random test cases."""
    random_cases = []
    max_val = (1 << input_width) - 1
    
    for i in range(num_cases):
        i_val = random.randint(0, max_val)
        q_val = random.randint(0, max_val)
        random_cases.append((i_val, q_val, f"Random case {i+1}"))
    return random_cases

def write_vector_file(test_cases, output_path, input_width, output_width, output_frac):
    """Write test vectors to file using the requested format."""
    with open(output_path, 'w') as f:
        # Write header
        f.write("# Test vectors for complex_to_log_power module\n")
        f.write(f"# Format: Each test case consists of 2 lines:\n")
        f.write(f"# Line 1: I_value Q_value (both {input_width}-bit fixed-point integers)\n")
        f.write(f"# Line 2: Expected_output ({output_width}-bit fixed-point integer)\n")
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
    print("=== Generating test vectors for complex_to_log_power ===")
    print(f"Logic: 3 * floor(log2(I^2 + Q^2))")
    
    # Generate cases
    edge_cases = generate_edge_cases(INPUT_WIDTH)
    random_cases = generate_random_cases(INPUT_WIDTH, num_cases=50)
    test_cases = edge_cases + random_cases
    
    # Write to file
    try:
        # Adjust this path logic as needed for your project structure
        SIMULATOR_ROOT = Path(__file__).resolve().parent.parent.parent
        output_dir = SIMULATOR_ROOT / "rtl" / "simvectors"
    except NameError:
         output_dir = Path("simvectors") # Fallback if running standalone
         
    output_dir.mkdir(parents=True, exist_ok=True)
    output_path = output_dir / "log_power_vectors.txt"
    
    write_vector_file(test_cases, output_path, INPUT_WIDTH, OUTPUT_WIDTH, OUTPUT_FRAC)
    
    print(f"\n=== Successfully generated {len(test_cases)} test cases ===")
    print(f"Output file: {output_path}")

    # Debug Example
    print("\n--- Sample Verification ---")
    for i in range(3):
        i_val, q_val, _ = test_cases[i+5] # Skip zeros
        exp = calculate_expected_log_power(i_val, q_val, INPUT_WIDTH, OUTPUT_WIDTH, OUTPUT_FRAC)
        i_s = to_signed(i_val, INPUT_WIDTH)
        q_s = to_signed(q_val, INPUT_WIDTH)
        mag_sq = i_s**2 + q_s**2
        print(f"I: {i_s} Q: {q_s} | MagSq: {mag_sq} | Log2: {mag_sq.bit_length()-1} | Exp (x3): {exp}")

if __name__ == "__main__":
    main()