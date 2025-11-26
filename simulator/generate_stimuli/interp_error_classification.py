import os
import re
import sys

# Add the parent directory to sys.path to find fixed_float_conversions
# Adjust this if your directory structure is different
sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

try:
    from fixed_float_conversions import fixed_point_to_float
except ImportError:
    # Fallback for standalone testing if module not found
    print("Warning: fixed_float_conversions not found. Using dummy conversion.")
    def fixed_point_to_float(val, a, b, c): return float(val) / (2**16)

# Configuration
INT_BITS = 32
FRAC_BITS = 16
SIGNED = True

# Path to input file
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
INPUT_FILE = os.path.join(SCRIPT_DIR, "interp_error_eval", "interp_error_eval.txt")

# --- Regex Patterns ---

test_case_pattern = re.compile(r"--- Test Case (\d+) ---")

# Matches: Expected: f_star = 0x00960000, invalid = 0
expected_pattern = re.compile(r"Expected: f_star = (0x[0-9a-fA-F]+), invalid = (\d)")

# Matches BOTH Success and Error lines
# Logic:
# 1. Start with SUCCESS or ERROR
# 2. Match "f_star match." or "f_star mismatch."
# 3. OPTIONAL Group (?: ... )?: Look for "Expected: 0x..., " (Only present in ERROR lines)
# 4. Mandatory: Look for "Got: 0x..."
got_pattern = re.compile(
    r"(?P<status>SUCCESS|ERROR): f_star (?:match|mismatch)\. "
    r"(?:Expected: (?P<err_exp>0x[0-9a-fA-F]+), )?"
    r"Got: (?P<got>0x[0-9a-fA-F]+) \(diff: (?P<diff>\d+)\)"
)

def fixed_hex_to_float(hex_string):
    """Convert hex string (0xNNNNNNNN) to float."""
    if not hex_string: return 0.0
    value_int = int(hex_string, 16)
    return fixed_point_to_float(value_int, INT_BITS, FRAC_BITS, SIGNED)

def percent_error(expected, got):
    """Compute absolute and percent error."""
    abs_err = abs(expected - got)
    if expected == 0:
        # Avoid division by zero
        pct_err = 0.0 if got == 0 else float('inf')
    else:
        pct_err = (abs_err / abs(expected)) * 100.0
    return abs_err, pct_err

def main():
    if not os.path.exists(INPUT_FILE):
        print(f"Error: File not found at {INPUT_FILE}")
        return

    print(f"Reading file: {INPUT_FILE}\n")

    with open(INPUT_FILE, "r") as f:
        lines = f.readlines()

    current_test = None
    expected_value = None
    invalid_flag = None

    for line in lines:
        line = line.strip()
        
        # 1. Detect Header: --- Test Case N ---
        m_test = test_case_pattern.search(line)
        if m_test:
            current_test = int(m_test.group(1))
            print(f"\n=== Test Case {current_test} ===")
            expected_value = None
            invalid_flag = None
            continue

        # 2. Detect Expected Line
        m_exp = expected_pattern.search(line)
        if m_exp:
            expected_hex = m_exp.group(1)
            invalid_flag = int(m_exp.group(2))
            expected_value = fixed_hex_to_float(expected_hex)
            continue

        # 3. Detect Result Line (SUCCESS or ERROR)
        m_got = got_pattern.search(line)
        if m_got:
            status = m_got.group("status")     # SUCCESS or ERROR
            got_hex = m_got.group("got")       # The 0x... value
            diff = int(m_got.group("diff"))    # The integer diff
            
            # Note: We ignore m_got.group("err_exp") because we already 
            # parsed the trusted expected value from the previous line.

            got_value = fixed_hex_to_float(got_hex)

            if expected_value is not None:
                abs_err, pct_err = percent_error(expected_value, got_value)
                
                print(f"Status:         {status}")
                print(f"Expected f_star: {expected_value:.6f}")
                print(f"Got f_star:      {got_value:.6f}")
                print(f"Abs Error:       {abs_err:.6f}")
                print(f"Rel Error:       {pct_err:.6f} %")
                print(f"Integer Diff:    {diff}")
                
                if invalid_flag:
                    print("Note: marked as invalid in testbench")
            else:
                print(f"Warning: Result found but no 'Expected' line parsed for Test {current_test}")

if __name__ == "__main__":
    main()