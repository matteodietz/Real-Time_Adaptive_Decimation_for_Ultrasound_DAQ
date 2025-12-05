import numpy as np
from scipy import signal
from pathlib import Path

SIMULATOR_ROOT = Path(__file__).resolve().parent
sys.path.append(str(SIMULATOR_ROOT))

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
def calculate_single_bin_log_power(complex_val, accum_width, accum_frac, power_width, power_frac):
    """
    Calculate hardware-accurate dB power using integer log2.
    Formula: db_power = 3 * int_log2(|complex_val|^2)
    
    This matches the complex_to_log_power.sv hardware module.
    Inputs are floating-point, output is floating-point dB value.
    
    Args:
        complex_val: Complex DFT accumulator value (floating point)
        accum_width: Width of accumulator (e.g., 64)
        accum_frac: Fractional bits in accumulator (e.g., 56)
        power_width: Width of power output (e.g., 32)
        power_frac: Fractional bits in power (e.g., 16)
    
    Returns:
        Floating-point dB power value
    """

    # Extract real and imaginary parts
    real_part = np.real(complex_val)
    imag_part = np.imag(complex_val)
    
    # Convert to fixed-point (as hardware would see them)
    accum_int_bits = accum_width - accum_frac
    real_fixed = float_to_fixed_point(real_part, accum_int_bits, accum_frac, signed=True)
    imag_fixed = float_to_fixed_point(imag_part, accum_int_bits, accum_frac, signed=True)
    
    # Calculate magnitude squared in fixed-point
    # real^2 + imag^2 (this gives us 2*accum_frac fractional bits)
    mag_squared_fixed = real_fixed * real_fixed + imag_fixed * imag_fixed
    
    # Handle zero/negative case
    if mag_squared_fixed <= 0:
        return 0.0  # Return minimum dB value
    
    # Integer log2: find position of MSB
    int_log2_val = mag_squared_fixed.bit_length() - 1
    
    # Multiply by 3 to approximate dB
    db_power_raw = 3 * int_log2_val
    
    # Adjust for fractional bit scaling
    # The magnitude squared has 2*accum_frac fractional bits
    # So we need to subtract the contribution of those fractional bits
    db_power_adjusted = db_power_raw - (3 * 2 * accum_frac)
    
    # Convert to fixed-point in power format
    power_int_bits = power_width - power_frac
    db_power_fixed = db_power_adjusted * (2 ** power_frac)
    
    # Clamp to valid range
    max_val = (1 << power_width) - 1
    db_power_clamped = max(0, min(int(db_power_fixed), max_val))
    
    # Convert back to floating-point for golden reference
    db_power_float = fixed_point_to_float(db_power_clamped, power_int_bits, power_frac, signed=True)
    
    return db_power_float

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
        p_hw = calculate_single_bin_log_power(val, accum_width, accum_frac, power_width, power_frac)
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