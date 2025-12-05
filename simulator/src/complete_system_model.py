import numpy as np
from scipy import signal
from pathlib import Path
import sys
import math

SIMULATOR_ROOT = Path(__file__).resolve().parent.parent
sys.path.append(str(SIMULATOR_ROOT))

# 3. Construct the path to the folder containing the file (.../simulator/generate_stimuli)
TARGET_DIR = SIMULATOR_ROOT / "generate_stimuli"

# 4. Add that specific directory to the python path
if str(TARGET_DIR) not in sys.path:
    sys.path.append(str(TARGET_DIR))

# 5. Now Python can find the file inside that directory
from fixed_float_conversions import float_to_fixed_point, fixed_point_to_float

# ==============================================================================
# 1. DFT Processor
# ==============================================================================
def streaming_dft_processor(b, fs, freq_bins_to_calc, window='hann'):
    """
    Simulates a one-pass, streaming, sparse DFT.
    Returns a dictionary of {frequency: complex_accumulator_value}.
    """
    N = len(b)
    win = signal.windows.get_window(window, N)
    
    K = len(freq_bins_to_calc)
    A = np.zeros(K, dtype=np.complex128)
    W = np.ones(K, dtype=np.complex128)
    E = np.exp(-1j * 2 * np.pi * freq_bins_to_calc / fs)

    # Streaming DFT calculation
    for n in range(N):
        x_n = b[n]
        h_n = win[n]
        A += x_n * h_n * W
        W *= E
    
    # Dictionary of frequency bins with their corresponding accumulator value (DFT)
    final_dft_bins = {freq: accumulator for freq, accumulator in zip(freq_bins_to_calc, A)}
    return final_dft_bins

# ==============================================================================
# 2. Hardware-Accurate Power Conversion
# ==============================================================================
def ilog2_abs2(z: complex) -> int:
    """
    Returns 3 floor(log2(|z|^2)) for a complex number z = a + ib.
    """
    # squared magnitude = a^2 + b^2
    mag2 = (z.real * z.real) + (z.imag * z.imag)

    if mag2 == 0:
        raise ValueError("log2(0) is undefined")

    return 3 * math.floor(math.log2(mag2))

def convert_to_hardware_db_power(dft_bins, accum_width=64, accum_frac=56, power_width=32, power_frac=16):
    """
    Takes DFT results and converts them to the sorted hardware-equivalent 
    unsigned integer power values.
    """
    freqs = np.array(list(dft_bins.keys()))
    complex_vals = np.array(list(dft_bins.values()))
    
    # Sort by frequency
    sort_indices = np.argsort(freqs)
    freqs_sorted = freqs[sort_indices]
    complex_sorted = complex_vals[sort_indices]
    
    power_values = []
    for val in complex_sorted:
        # p_hw = calculate_single_bin_log_power(val, accum_width, accum_frac, power_width, power_frac)
        p_hw = ilog2_abs2(val)
        power_values.append(p_hw)
        
    return freqs_sorted, np.array(power_values, dtype=object)

# ==============================================================================
# 3. Hardware Threshold Calculation
# ==============================================================================
def calc_hardware_threshold(power_values, threshold_drop_fixed):
    """
    Emulates find_max_power.sv and calc_abs_threshold.sv modules.
    All inputs must be Integers (Fixed Point representations).
    """
    # Find Max (Emulates find_max_power module)
    if len(power_values) == 0:
        return 0, 0
        
    max_pwr = np.max(power_values)
    
    # Calculate Threshold (Emulates calc_abs_threshold module)
    # Logic: if max < drop, thresh = 0, else thresh = max - drop
    if max_pwr < threshold_drop_fixed:
        abs_threshold = 0
    else:
        abs_threshold = max_pwr - threshold_drop_fixed
        
    return max_pwr, abs_threshold

# ==============================================================================
# 4. Left Edge Finder
# ==============================================================================
def find_left_edge_hw(freqs_sorted, power_vals_sorted_db, abs_threshold_db):
    """
    Finds the two adjacent points that cross the threshold for the left edge.
    This corresponds to the find_bw_left_edge_absolute.sv module.
    """
    # Start search from the center (0 Hz)
    start_search_idx = np.argmin(np.abs(freqs_sorted))
    
    f1, f2, L1, L2 = (None,) * 4 # Use None to indicate "not found"
    
    # Search from the center downwards into negative frequencies
    for i in range(start_search_idx, 0, -1):
        # Crossing condition is: power[i-1] < threshold <= power[i]
        if power_vals_sorted_db[i-1] < abs_threshold_db <= power_vals_sorted_db[i]:
            L1, L2 = power_vals_sorted_db[i-1], power_vals_sorted_db[i]
            f1, f2 = freqs_sorted[i-1], freqs_sorted[i]
            
    return f1, f2, L1, L2

# ==============================================================================
# 5. Right Edge Finder
# ==============================================================================
def find_right_edge_points(freqs_sorted, power_vals_sorted_db, abs_threshold_db):
    """
    Finds the two adjacent points that cross the threshold for the right edge.
    This corresponds to a find_bw_right_edge_absolute.sv module.
    """
    # Start search from the center (0 Hz)
    start_search_idx = np.argmin(np.abs(freqs_sorted)) + 1
    
    f1, f2, L1, L2 = (None,) * 4 # Use None to indicate "not found"

    # Search from the center upwards into positive frequencies
    for i in range(start_search_idx, len(freqs_sorted) - 1):
        # Crossing condition is: power[i+1] < threshold <= power[i]
        if power_vals_sorted_db[i+1] < abs_threshold_db <= power_vals_sorted_db[i]:
            L1, L2 = power_vals_sorted_db[i], power_vals_sorted_db[i+1]
            f1, f2 = freqs_sorted[i], freqs_sorted[i+1]
            
    return f1, f2, L1, L2

# ==============================================================================
# 6. Interpolation
# ==============================================================================
def linear_interpolate_hw(f1, f2, L1, L2, abs_threshold):
    """
    Performs the final linear interpolation to find the precise edge frequency.
    This corresponds to the linear_interp_crossing.sv module.
    """
    if any(v is None for v in [f1, f2, L1, L2]) or (L2 - L1) == 0:
        return float('nan') # Return Not-a-Number if inputs are invalid

    # Standard linear interpolation formula
    f_star = f1 + (f2 - f1) * (abs_threshold - L1) / (L2 - L1)
    return f_star