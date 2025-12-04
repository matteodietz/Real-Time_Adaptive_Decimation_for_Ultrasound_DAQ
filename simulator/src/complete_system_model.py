import numpy as np
from scipy import signal

# ==============================================================================
# 1. DFT Processor (Unchanged)
# ==============================================================================
def streaming_dft_processor(b, fs, freq_bins_to_calc, window='hann'):
    """
    Simulates a one-pass, streaming, sparse DFT (Goertzel-like).
    Returns a dictionary of {frequency: complex_accumulator_value}.
    """
    N = len(b)
    win = signal.windows.get_window(window, N)
    
    K = len(freq_bins_to_calc)
    A = np.zeros(K, dtype=np.complex128)
    W = np.ones(K, dtype=np.complex128)
    E = np.exp(-1j * 2 * np.pi * freq_bins_to_calc / fs)

    # streaming DFT calculation
    for n in range(N):
        x_n = b[n]
        h_n = win[n]
        A += x_n * h_n * W
        W *= E
        
    final_dft_bins = {freq: accumulator for freq, accumulator in zip(freq_bins_to_calc, A)}
    return final_dft_bins

# ==============================================================================
# 2. Hardware-Accurate Power Conversion
# ==============================================================================
def calculate_single_bin_log_power(complex_val, accum_width, accum_frac, power_width, power_frac):
    """
    Emulates the 'complex_to_log_power' SystemVerilog module.
    1. Quantizes Complex Float -> Fixed Point Integer (simulating DFT output register)
    2. Calculates Mag^2
    3. Finds Integer Log2 (MSB)
    4. Scales by 3
    """
    # 1. Quantize Input (DFT Output) to Fixed Point
    # This mimics the data arriving at the power module input
    scale_in = 2.0 ** accum_frac
    
    i_float = np.real(complex_val)
    q_float = np.imag(complex_val)
    
    # Simple quantization
    i_int = int(i_float * scale_in)
    q_int = int(q_float * scale_in)
    
    # Handle wrapping/overflow if simulation exceeds widths (Optional safety)
    # Mask to input width to simulate register behavior
    mask_in = (1 << accum_width) - 1
    i_int &= mask_in
    q_int &= mask_in
    
    # Convert back to signed for arithmetic
    if i_int & (1 << (accum_width - 1)): i_int -= (1 << accum_width)
    if q_int & (1 << (accum_width - 1)): q_int -= (1 << accum_width)
        
    # 2. Magnitude Squared (Stage 1)
    mag_sq = i_int * i_int + q_int * q_int
    
    if mag_sq == 0:
        return 0
        
    # 3. Priority Encoder / Integer Log2 (Stage 2)
    # bit_length() gives bits required to represent number. 
    # e.g., 4 (100) -> 3. MSB index is bit_length - 1.
    msb_index = mag_sq.bit_length() - 1
    
    # 4. Scale by 3 (Stage 3)
    # Logic: (msb_index << POWER_FRAC) * 3
    log2_fixed = msb_index << power_frac
    db_power = (log2_fixed << 1) + log2_fixed
    
    # Output Mask
    db_power &= (1 << power_width) - 1
    
    return db_power

def convert_to_hardware_db_power(dft_bins, accum_width=48, accum_frac=40, power_width=32, power_frac=16):
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
    # 1. Find Max (Emulates find_max_power module)
    if len(power_values) == 0:
        return 0, 0
        
    max_pwr = np.max(power_values)
    
    # 2. Calculate Threshold (Emulates calc_abs_threshold module)
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