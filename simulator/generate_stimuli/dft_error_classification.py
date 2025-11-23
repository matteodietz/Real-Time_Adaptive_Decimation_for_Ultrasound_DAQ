import os
import re
from fixed_float_conversions import fixed_point_to_float

# Configuration
INT_BITS = 64
FRAC_BITS = 56
SIGNED = True

# Path to input file: parent_dir / dft_error_eval / filename
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
INPUT_FILE = os.path.join(SCRIPT_DIR, "dft_error_eval", "sanity_3.txt")  # file to investigate


# Regex patterns to parse the file
bin_pattern = re.compile(r"ERROR: Bin (\d+) mismatch")
value_pattern = re.compile(
    r"(A_real|A_imag): Expected=([0-9a-fA-F]+), Got=([0-9a-fA-F]+),"
)

def fixed_hex_to_float(hex_string):
    """Convert hex string (no 0x prefix) to float using your conversion function."""
    value_int = int(hex_string, 16)
    return fixed_point_to_float(value_int, INT_BITS, FRAC_BITS, SIGNED)

def percent_error(expected, got):
    """Compute absolute and percent error."""
    abs_err = abs(expected - got)
    if expected == 0:
        pct_err = float('nan')
    else:
        pct_err = abs_err / abs(expected) * 100
    return abs_err, pct_err


def main():
    print(f"Reading file: {INPUT_FILE}\n")

    with open(INPUT_FILE, "r") as f:
        lines = f.readlines()

    current_bin = None

    for line in lines:
        # Detect: ERROR: Bin X mismatch
        m_bin = bin_pattern.search(line)
        if m_bin:
            current_bin = int(m_bin.group(1))
            print(f"\n=== Bin {current_bin} ===")
            continue

        # Detect: A_real / A_imag lines
        m_val = value_pattern.search(line)
        if m_val:
            label = m_val.group(1)
            expected_hex = m_val.group(2)
            got_hex = m_val.group(3)

            # Convert to float
            expected_float = fixed_hex_to_float(expected_hex)
            got_float = fixed_hex_to_float(got_hex)

            # Compute errors
            abs_err, pct_err = percent_error(expected_float, got_float)

            # Print results
            print(f"{label}:")
            print(f"  Expected float = {expected_float}")
            print(f"  Got float      = {got_float}")
            print(f"  Abs error      = {abs_err}")
            print(f"  % error        = {pct_err:.6f}%\n")


if __name__ == "__main__":
    main()
