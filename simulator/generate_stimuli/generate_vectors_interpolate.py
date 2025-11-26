"""
Stimulus Generation for linear_interp_crossing module

Generates test vectors with edge cases and random inputs.
"""

import sys
from pathlib import Path
import random
import math

# Add the parent directory to path to import modules
SIMULATOR_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SIMULATOR_ROOT / "src"))

from fixed_float_conversions import float_to_fixed_point, fixed_point_to_float
from golden_model_floating_point import linear_interpolate_crossing

# Configuration parameters
FREQ_WIDTH = 32        # Width of frequency values
FREQ_FRAC_BITS = 16    # Fractional bits in frequency
ACCUM_DB_WIDTH = 32    # Width of dB values
ACCUM_DB_FRAC = 16     # Fractional bits in dB
THRESHOLD_DB = -20.0   # Threshold in dB (float)

def calculate_expected_f_star(f1_float, f2_float, L1_float, L2_float, threshold_db):
    """
    Calculate expected f_star using golden model.
    
    Args:
        f1_float: First frequency (float)
        f2_float: Second frequency (float)
        L1_float: dB level at f1 (float)
        L2_float: dB level at f2 (float)
        threshold_db: Threshold in dB (float)
    
    Returns:
        Expected f_star value (float), or None if invalid
    """
    f_star = linear_interpolate_crossing(f1_float, f2_float, L1_float, L2_float, threshold_db)
    
    # Check for invalid results
    if math.isnan(f_star) or math.isinf(f_star):
        return None
    
    return f_star

def generate_edge_cases():
    """
    Generate edge case test vectors.
    
    Returns:
        List of tuples (f1, f2, L1, L2, description)
    """
    edge_cases = [
        # Normal crossing cases
        (100.0, 200.0, -30.0, -10.0, "Normal positive slope crossing"),
        (100.0, 200.0, -10.0, -30.0, "Normal negative slope crossing"),
        (1000.0, 2000.0, -25.0, -15.0, "Crossing at midpoint"),
        
        # Threshold exactly at L1
        (100.0, 200.0, -20.0, -10.0, "Threshold equals L1"),
        
        # Threshold exactly at L2
        (100.0, 200.0, -30.0, -20.0, "Threshold equals L2"),
        
        # Threshold outside range (extrapolation)
        (100.0, 200.0, -30.0, -25.0, "Threshold above range"),
        (100.0, 200.0, -15.0, -10.0, "Threshold below range"),
        
        # Small frequency difference
        (100.0, 101.0, -30.0, -10.0, "Small frequency difference"),
        
        # Large frequency difference
        (100.0, 10000.0, -30.0, -10.0, "Large frequency difference"),
        
        # Small dB difference (steep slope)
        (100.0, 200.0, -20.5, -19.5, "Small dB difference"),
        
        # Large dB difference (gentle slope)
        (100.0, 200.0, -50.0, -5.0, "Large dB difference"),
        
        # Zero frequency start
        (0.0, 1000.0, -30.0, -10.0, "Zero start frequency"),
        
        # Same frequencies (invalid - division by zero in interpolation)
        # This should be caught but we test it anyway
        (100.0, 100.0, -30.0, -10.0, "Same frequencies (invalid)"),
        
        # Same dB levels (invalid - division by zero)
        (100.0, 200.0, -20.0, -20.0, "Same dB levels (invalid)"),
        
        # Fractional frequencies
        (123.456, 234.567, -25.0, -15.0, "Fractional frequencies"),
        
        # Fractional dB values
        (100.0, 200.0, -23.75, -16.25, "Fractional dB values"),
        
        # High frequency values
        (50000.0, 60000.0, -30.0, -10.0, "High frequency range"),
        
        # Negative slope with threshold in middle
        (500.0, 1500.0, -12.0, -28.0, "Negative slope interpolation"),
    ]
    
    return edge_cases

# def generate_random_cases(num_cases=50):
#     """
#     Generate random test cases.
    
#     Returns:
#         List of tuples (f1, f2, L1, L2, description)
#     """
#     random_cases = []
    
#     for i in range(num_cases):
#         # Random frequencies between 0 and 65535 (fits in 16.16 fixed point)
#         f1 = random.uniform(0, 30000)
#         f2 = random.uniform(f1 + 10, 40000)  # Ensure f2 > f1
        
#         # Random dB levels between -60 and 0
#         L1 = random.uniform(-60, 0)
#         L2 = random.uniform(-60, 0)
        
#         # Ensure L1 and L2 are different to avoid division by zero
#         while abs(L2 - L1) < 0.1:
#             L2 = random.uniform(-60, 0)
        
#         random_cases.append((f1, f2, L1, L2, f"Random case {i+1}"))
    
#     return random_cases

def generate_random_cases(num_cases=50):
    """
    Generate random test cases.
    Ensures that a valid crossing always exists: 
    (L1 <= THRESHOLD <= L2) or (L2 <= THRESHOLD <= L1)
    """
    random_cases = []
    
    for i in range(num_cases):
        # Random frequencies between 0 and 65535 (fits in 16.16 fixed point)
        f1 = random.uniform(0, 30000)
        f2 = random.uniform(f1 + 10, 40000)  # Ensure f2 > f1
        
        # --- LOGIC CHANGE START ---
        # Instead of picking L1/L2 randomly from anywhere, we pick one value
        # below the threshold and one value above the threshold.
        
        # 1. Pick a value below threshold (e.g., -60dB to -20.1dB)
        # Using -60 as arbitrary floor
        val_below = random.uniform(-60.0, THRESHOLD_DB)
        
        # 2. Pick a value above threshold (e.g., -19.9dB to +10dB)
        # Using +10 as arbitrary ceiling to test positive values too
        val_above = random.uniform(THRESHOLD_DB, 10.0)
        
        # 3. Ensure they aren't infinitesimally close to the threshold (avoid div by zero issues)
        while abs(val_above - val_below) < 0.1:
            val_below = random.uniform(-60.0, THRESHOLD_DB)
            val_above = random.uniform(THRESHOLD_DB, 10.0)
            
        # 4. Randomly assign to L1/L2 to create either Rising or Falling slope
        if random.choice([True, False]):
            # Rising slope (L1 < Th < L2)
            L1 = val_below
            L2 = val_above
            desc = f"Random valid rising crossing {i+1}"
        else:
            # Falling slope (L2 < Th < L1)
            L1 = val_above
            L2 = val_below
            desc = f"Random valid falling crossing {i+1}"
        # --- LOGIC CHANGE END ---
        
        random_cases.append((f1, f2, L1, L2, desc))
    
    return random_cases

def write_vector_file(test_cases, output_path, freq_width, freq_frac, db_width, db_frac, threshold_db):
    """
    Write test vectors to file.
    
    Format:
        Header comments
        Then for each test case:
        # Test case description
        f1_fixed f2_fixed L1_fixed L2_fixed
        expected_f_star_fixed invalid_flag
    """
    with open(output_path, 'w') as f:
        # Write header
        f.write("# Test vectors for linear_interp_crossing module\n")
        f.write(f"# FREQ_WIDTH = {freq_width}, FREQ_FRAC_BITS = {freq_frac}\n")
        f.write(f"# ACCUM_DB_WIDTH = {db_width}, ACCUM_DB_FRAC = {db_frac}\n")
        f.write(f"# THRESHOLD_DB = {threshold_db} dB\n")
        f.write("#\n")
        f.write("# Format: Each test case consists of 2 lines:\n")
        f.write("# Line 1: f1_fixed f2_fixed L1_fixed L2_fixed (hex values)\n")
        f.write("# Line 2: expected_f_star_fixed invalid_flag (hex and binary)\n")
        f.write("# Lines starting with '#' are comments and should be skipped\n")
        f.write("#\n")
        
        # Calculate fixed-point threshold
        threshold_fixed = float_to_fixed_point(
            threshold_db, 
            db_width - db_frac, 
            db_frac, 
            signed=True
        )
        
        f.write(f"# THRESHOLD_DB (fixed-point) = 0x{threshold_fixed:08x}\n")
        f.write("#\n")
        
        valid_cases = 0
        invalid_cases = 0
        
        # Write test cases
        for f1_float, f2_float, L1_float, L2_float, description in test_cases:
            # Convert to fixed point
            f1_fixed = float_to_fixed_point(f1_float, freq_width - freq_frac, freq_frac, signed=False)
            f2_fixed = float_to_fixed_point(f2_float, freq_width - freq_frac, freq_frac, signed=False)
            L1_fixed = float_to_fixed_point(L1_float, db_width - db_frac, db_frac, signed=True)
            L2_fixed = float_to_fixed_point(L2_float, db_width - db_frac, db_frac, signed=True)
            
            # Calculate expected output
            f_star_float = calculate_expected_f_star(f1_float, f2_float, L1_float, L2_float, threshold_db)
            
            if f_star_float is None or L1_float == L2_float:
                # Invalid case
                f_star_fixed = 0
                invalid_flag = 1
                invalid_cases += 1
            else:
                # Valid case
                # Clamp f_star to valid range [0, max_freq]
                max_freq = (1 << freq_width) - 1
                if f_star_float < 0:
                    f_star_float = 0
                elif f_star_float > (max_freq / (1 << freq_frac)):
                    f_star_float = max_freq / (1 << freq_frac)
                
                f_star_fixed = float_to_fixed_point(f_star_float, freq_width - freq_frac, freq_frac, signed=False)
                invalid_flag = 0
                valid_cases += 1
            
            # Write comment with description and float values
            f.write(f"# Test case: {description}\n")
            f.write(f"# f1={f1_float:.3f}, f2={f2_float:.3f}, L1={L1_float:.3f}dB, L2={L2_float:.3f}dB\n")
            if invalid_flag:
                f.write(f"# Expected: INVALID (division by zero or NaN)\n")
            else:
                f.write(f"# Expected f_star = {f_star_float:.3f} Hz\n")
            
            # Write input values (all on same line, in hex)
            f.write(f"{f1_fixed:08x} {f2_fixed:08x} {L1_fixed:08x} {L2_fixed:08x}\n")
            
            # Write expected output (f_star and invalid flag)
            f.write(f"{f_star_fixed:08x} {invalid_flag}\n")
        
        return valid_cases, invalid_cases

def main():
    """Generate all test vectors."""
    
    print("=== Generating test vectors for linear_interp_crossing ===")
    print(f"FREQ_WIDTH      = {FREQ_WIDTH}")
    print(f"FREQ_FRAC_BITS  = {FREQ_FRAC_BITS}")
    print(f"ACCUM_DB_WIDTH  = {ACCUM_DB_WIDTH}")
    print(f"ACCUM_DB_FRAC   = {ACCUM_DB_FRAC}")
    print(f"THRESHOLD_DB    = {THRESHOLD_DB} dB")
    print()
    
    # Generate edge cases
    edge_cases = generate_edge_cases()
    print(f"Generated {len(edge_cases)} edge cases")
    
    # Generate random cases
    random_cases = generate_random_cases(num_cases=50)
    print(f"Generated {len(random_cases)} random cases")
    
    # Combine all test cases
    test_cases = edge_cases + random_cases
    
    # Write to file
    output_dir = SIMULATOR_ROOT.parent / "rtl" / "simvectors"
    output_dir.mkdir(parents=True, exist_ok=True)
    output_path = output_dir / "linear_interp_vectors.txt"
    
    valid_cases, invalid_cases = write_vector_file(
        test_cases, output_path, 
        FREQ_WIDTH, FREQ_FRAC_BITS, 
        ACCUM_DB_WIDTH, ACCUM_DB_FRAC, 
        THRESHOLD_DB
    )
    
    print(f"\n=== Successfully generated {len(test_cases)} test cases ===")
    print(f"Output file: {output_path}")
    print("\nTest cases breakdown:")
    print(f"  - Edge cases: {len(edge_cases)}")
    print(f"  - Random cases: {len(random_cases)}")
    print(f"  - Valid cases: {valid_cases}")
    print(f"  - Invalid cases: {invalid_cases}")
    print(f"  - Total: {len(test_cases)}")
    
    # Show a few example calculations
    print("\n=== Example test cases ===")
    for i, (f1, f2, L1, L2, desc) in enumerate(test_cases[:3]):
        f_star = calculate_expected_f_star(f1, f2, L1, L2, THRESHOLD_DB)
        print(f"\nCase {i+1}: {desc}")
        print(f"  f1 = {f1:.3f} Hz, f2 = {f2:.3f} Hz")
        print(f"  L1 = {L1:.3f} dB, L2 = {L2:.3f} dB")
        if f_star is None:
            print(f"  Expected: INVALID")
        else:
            print(f"  Expected f_star = {f_star:.3f} Hz")

if __name__ == "__main__":
    main()