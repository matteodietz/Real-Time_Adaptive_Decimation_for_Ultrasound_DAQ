# """
# Generate simulation vectors for dft_accumulation.sv module using only PICMUS data.
# """
# import numpy as np
# from scipy import signal
# from pathlib import Path
# import sys

# # Add parent directory to path to import golden model
# SIMULATOR_ROOT = Path(__file__).resolve().parent.parent
# sys.path.insert(0, str(SIMULATOR_ROOT / "src"))

# from golden_model_floating_point import streaming_dft_processor
# from fixed_float_conversions import float_to_fixed_point

# # Import data loading functions
# try:
#     from afe_interface_rf import load_picmus_rf_data
#     from virtual_afe import run_virtual_afe_processing
#     PICMUS_AVAILABLE = True
# except ImportError:
#     print("Error: PICMUS data loading modules not available.")
#     PICMUS_AVAILABLE = False

# def generate_test_case_data(test_name, iq_data_raw, fs, freq_bins, window_type,
#                             iq_width, window_width, accum_width, osc_width, num_bins, normalize=False, max_magnitude=1.0):
#     """
#     Takes raw (small magnitude) IQ data, scales it to full-scale fixed-point range,
#     runs the Golden Model, and generates hex strings for the testbench.
#     """
#     print(f"\n=== Generating test case: {test_name} ===")
    
#     N = len(iq_data_raw)
#     K = len(freq_bins)

#     print(f"  Sample length: {N}")
#     print(f"  Number of bins: {K}")
#     print(f"  Frequency bins: {freq_bins/1e6} MHz")
    
#     # -------------------------------------------------------------------------
#     # 1. Determine Scaling Factor
#     # -------------------------------------------------------------------------
#     # We want to map the maximum absolute value of the input signal to the 
#     # maximum representable value of the Fixed-Point format (Q2.14).
#     # Q2.14 range is [-2.0, 1.999...]. We target ~1.0 to ~1.8 for safety.
    
#     iq_frac_bits = 14
#     iq_int_bits = iq_width - iq_frac_bits # 2 bits
    
#     # Find peak in the current window
#     max_val = np.max(np.abs(iq_data_raw))
    
#     # Target value (e.g., 1.5 to leave some headroom, or full 2.0)
#     # Using 1.0 is safe and standard for normalized logic.
#     target_peak = 1.5 
    
#     if max_val > 0:
#         scale_factor = target_peak / max_val
#     else:
#         scale_factor = 1.0
        
#     print(f"  Input Peak: {max_val:.2e}")
#     print(f"  Scaling Factor: {scale_factor:.2f}")
    
#     # -------------------------------------------------------------------------
#     # 2. Scale Data & Run Golden Model
#     # -------------------------------------------------------------------------
#     # Apply scaling to input BEFORE processing
#     # This emulates the Analog/Digital Gain that makes the signal audible/visible
#     iq_data_scaled = iq_data_raw * scale_factor
    
#     print(f"  Scaled Peak: {np.max(np.abs(iq_data_scaled)):.2f}")
    
#     # Run Golden Model on SCALED data
#     dft_bins = streaming_dft_processor(iq_data_scaled, fs, freq_bins, window=window_type)
    
#     # Extract results (Sorted)
#     freqs = np.array(list(dft_bins.keys()))
#     accumulators = np.array(list(dft_bins.values()))
#     sort_indices = np.argsort(freqs)
#     freqs_sorted = freqs[sort_indices]
#     accums_sorted = accumulators[sort_indices]
    
#     # -------------------------------------------------------------------------
#     # 3. Generate Hardware Coefficients (Window & W)
#     # -------------------------------------------------------------------------
#     # Window
#     window_coeffs = signal.windows.get_window(window_type, N)
    
#     # Oscillator W[n,k]
#     # W starts at 1+0j and rotates by exp(-j*2*pi*f/fs)
#     E = np.exp(-1j * 2 * np.pi * freqs_sorted / fs) 
#     W_values = np.zeros((N, K), dtype=np.complex128)
#     W_values[0, :] = 1.0 + 0j
#     for n in range(1, N):
#         W_values[n, :] = W_values[n-1, :] * E

#     # -------------------------------------------------------------------------
#     # 4. Quantize Everything to Fixed Point (Hex)
#     # -------------------------------------------------------------------------
    
#     # A. Inputs (Scaled I/Q)
#     i_samples_hw = [float_to_fixed_point(np.real(s), iq_int_bits, iq_frac_bits, signed=True) 
#                     for s in iq_data_scaled]
#     q_samples_hw = [float_to_fixed_point(np.imag(s), iq_int_bits, iq_frac_bits, signed=True) 
#                     for s in iq_data_scaled]
                    
#     # B. Window Coeffs
#     # Q2.14 (matches window width)
#     win_frac = 14
#     win_int = window_width - win_frac
#     window_coeffs_hw = [float_to_fixed_point(w, win_int, win_frac, signed=True) 
#                         for w in window_coeffs]
                        
#     # C. Oscillator W
#     # Q3.24 (27 bits usually, here customized by osc_width)
#     # Assuming OSC_WIDTH=32 -> Q8.24 or Q4.28? 
#     # Let's match the param: OSC_WIDTH_FRAC = 24? 
#     # NOTE: User param OSC_WIDTH=32. Let's assume Q2.30 for high precision or Q4.28.
#     # The snippet used: osc_frac_bits = 28
#     osc_frac_bits = 28
#     osc_int_bits = osc_width - osc_frac_bits
    
#     W_real_hw = np.zeros((N, K), dtype=object) # Use object to hold large ints
#     W_imag_hw = np.zeros((N, K), dtype=object)
    
#     for n in range(N):
#         for k in range(K):
#             W_real_hw[n, k] = float_to_fixed_point(np.real(W_values[n, k]), osc_int_bits, osc_frac_bits, signed=True)
#             W_imag_hw[n, k] = float_to_fixed_point(np.imag(W_values[n, k]), osc_int_bits, osc_frac_bits, signed=True)

#     # D. Expected Accumulators
#     # Q8.40 (48 bits) or similar.
#     # The accumulator results from the golden model are already "scaled" 
#     # because we fed it scaled inputs. We just convert them directly.
#     accum_frac_bits = 40 # 56 in previous, 40 in recent module. Let's use 40.
#     accum_int_bits = accum_width - accum_frac_bits
    
#     A_real_hw = [float_to_fixed_point(np.real(a), accum_int_bits, accum_frac_bits, signed=True) 
#                  for a in accums_sorted]
#     A_imag_hw = [float_to_fixed_point(np.imag(a), accum_int_bits, accum_frac_bits, signed=True) 
#                  for a in accums_sorted]

#     return {
#         'test_name': test_name,
#         'num_samples': N,
#         'num_bins': K,
#         'fs': fs,
#         'freq_bins': freqs_sorted,
#         'i_samples': i_samples_hw,
#         'q_samples': q_samples_hw,
#         'window_coeffs': window_coeffs_hw,
#         'W_real': W_real_hw,
#         'W_imag': W_imag_hw,
#         'expected_A_real': A_real_hw,
#         'expected_A_imag': A_imag_hw,
#         # Save floats for debugging if needed
#         'golden_A_mag': [np.abs(a) for a in accums_sorted]
#     }

# def write_vector_file(test_cases, output_path, iq_width, window_width, accum_width, osc_width):
#     """
#     Writes the test vectors to the specified file.
#     """
#     with open(output_path, 'w') as f:
#         # Header
#         f.write("# Simulation vectors for dft_accumulation.sv\n")
#         f.write(f"# IQ_WIDTH = {iq_width}\n")
#         f.write(f"# WINDOW_WIDTH = {window_width}\n")
#         f.write(f"# ACCUM_WIDTH = {accum_width}\n")
#         f.write(f"# OSC_WIDTH = {osc_width}\n")
#         f.write("#\n")
#         f.write("# Format per test case:\n")
#         f.write("# <test_name>\n")
#         f.write("# <num_samples> <num_bins> <fs>\n")
#         f.write("# FREQ_BINS <freq0> <freq1> ...\n")
#         f.write("# SAMPLES (per line: I Q window_coeff W_real[0..K-1] W_imag[0..K-1])\n")
#         f.write("# EXPECTED A_real[0..K-1] A_imag[0..K-1]\n")
#         f.write("# GOLDEN_MAG (float reference)\n")
#         f.write("#\n\n")
        
#         for tc in test_cases:
#             f.write(f"{tc['test_name']}\n")
#             f.write(f"{tc['num_samples']} {tc['num_bins']} {tc['fs']:.6e}\n")
            
#             f.write("FREQ_BINS ")
#             for freq in tc['freq_bins']:
#                 f.write(f"{freq/1e6:.6f} ") # Write in MHz
#             f.write("\n")
            
#             f.write("SAMPLES\n")
#             for n in range(tc['num_samples']):
#                 # I, Q, Window
#                 f.write(f"{tc['i_samples'][n]:04x} ") # Adjust hex width if needed
#                 f.write(f"{tc['q_samples'][n]:04x} ")
#                 f.write(f"{tc['window_coeffs'][n]:04x} ")
                
#                 # W values
#                 for k in range(tc['num_bins']):
#                     f.write(f"{tc['W_real'][n, k]:08x} ")
#                 for k in range(tc['num_bins']):
#                     f.write(f"{tc['W_imag'][n, k]:08x} ")
#                 f.write("\n")
            
#             f.write("EXPECTED\n")
#             for k in range(tc['num_bins']):
#                 f.write(f"{tc['expected_A_real'][k]:012x}\n") # 48 bits = 12 hex chars
#             for k in range(tc['num_bins']):
#                 f.write(f"{tc['expected_A_imag'][k]:012x}\n")
#             f.write("\n")
            
#             f.write("GOLDEN_MAG ")
#             for val in tc['golden_A_mag']:
#                 f.write(f"{val:.4e} ")
#             f.write("\n\n")

# def main():
#     print("=== Generating Simulation Vectors for dft_accumulation.sv ===\n")
    
#     # Hardware parameters (Must match SystemVerilog)
#     IQ_WIDTH = 16           
#     WINDOW_WIDTH = 16       
#     ACCUM_WIDTH = 48        # Changed to 48 as per recent modules
#     OSC_WIDTH = 32          # Changed to 32 as per recent modules
#     NUM_BINS = 24           
    
#     # Parameters for Logic
#     NPERSEG = 256
#     HOP = NPERSEG // 2
    
#     test_cases = []
    
#     if PICMUS_AVAILABLE:
#         try:
#             # 1. Load Data
#             print("Loading PICMUS Dataset...")
#             rf_path = SIMULATOR_ROOT.parent / "simulator/datasets/experiments/contrast_speckle/contrast_speckle_expe_dataset_rf.hdf5"
#             iq_path = SIMULATOR_ROOT.parent / "simulator/datasets/experiments/contrast_speckle/contrast_speckle_expe_dataset_iq.hdf5"
#             scan_path = SIMULATOR_ROOT.parent / "simulator/datasets/experiments/contrast_speckle/contrast_speckle_expe_scan.hdf5"
            
#             rf_data, angles, _, _, fs_picmus, mod_freq, _, _, _ = load_picmus_rf_data(rf_path, iq_path, scan_path)
            
#             # 2. Virtual AFE Processing (Get full I/Q Lines)
#             # We process specific angles of interest here
#             adc_rate = 125e6
#             baseline_decimation = 4
            
#             # Define Test Configurations: (TestName, Channel, AngleIndex, WindowIndex)
#             # Note: WindowIndex refers to the temporal window inside the A-line
#             configs = [
#                 ("picmus_ang0_ch64_win29", 64, np.argmin(np.abs(angles)), 29),
#                 ("picmus_ang0_ch32_win15", 32, np.argmin(np.abs(angles)), 15),
#                 ("picmus_ang0_ch96_win30", 96, np.argmin(np.abs(angles)), 30),
#                 # Add an angle 10 degrees if desired, finding index for ~10 deg
#                 # ("picmus_ang10_ch64_win29", 64, 10, 29) 
#             ]
            
#             # Define Frequency Bins (Fixed for all tests usually)
#             delta_f = 0.25e6
#             half_bw_est = mod_freq / 2
#             s_coarse = np.linspace(-mod_freq, mod_freq, 8)
#             s_fine_left = np.linspace(-half_bw_est - delta_f, -half_bw_est + delta_f, 8)
#             s_fine_right = np.linspace(half_bw_est - delta_f, half_bw_est + delta_f, 8)
#             S_bins = np.unique(np.concatenate([s_coarse, s_fine_left, s_fine_right]))
            
#             # Cache processed angles to avoid re-running AFE for same angle
#             processed_angles = {} 

#             for name, ch, ang_idx, win_idx in configs:
#                 print(f"\nProcessing Config: {name} (AngIdx: {ang_idx}, Ch: {ch}, Win: {win_idx})")
                
#                 # Retrieve or Compute AFE data for this angle
#                 if ang_idx not in processed_angles:
#                     print("  Running Virtual AFE for Angle Index", ang_idx)
#                     iq_data_angle, _, fs_base = run_virtual_afe_processing(
#                         rf_data=rf_data, angle_index=ang_idx, fs_picmus=fs_picmus,
#                         modulation_frequency=mod_freq, decimation_factor=baseline_decimation,
#                         adc_sample_rate=adc_rate
#                     )
#                     processed_angles[ang_idx] = (iq_data_angle, fs_base)
                
#                 baseline_iq_data, fs_baseline = processed_angles[ang_idx]
                
#                 # Extract specific STFT window
#                 start_sample = win_idx * HOP
#                 end_sample = start_sample + NPERSEG
                
#                 # Check bounds
#                 if end_sample > baseline_iq_data.shape[0]:
#                     print(f"  Warning: Window {win_idx} out of bounds. Skipping.")
#                     continue
                    
#                 time_window_data = baseline_iq_data[start_sample:end_sample, ch]
                
#                 # Generate Test Case Data
#                 tc = generate_test_case_data(
#                     name, 
#                     time_window_data, 
#                     fs_baseline, 
#                     S_bins, 
#                     'hann',
#                     IQ_WIDTH, WINDOW_WIDTH, ACCUM_WIDTH, OSC_WIDTH, NUM_BINS
#                 )
#                 test_cases.append(tc)
                
#         except Exception as e:
#             print(f"Error processing PICMUS data: {e}")
#             import traceback
#             traceback.print_exc()
            
#     # 3. Write Output
#     output_dir = SIMULATOR_ROOT.parent / "rtl" / "simvectors"
#     output_dir.mkdir(parents=True, exist_ok=True)
#     output_path = output_dir / "dft_accumulation_vectors.txt"
    
#     write_vector_file(test_cases, output_path, IQ_WIDTH, WINDOW_WIDTH, ACCUM_WIDTH, OSC_WIDTH)
    
#     print(f"\n=== Successfully generated {len(test_cases)} test cases ===")
#     print(f"Output file: {output_path}")

# if __name__ == "__main__":
#     main()

"""
Generate simulation vectors for top.sv module.

Target Module: top (spectral_power_estimator + bandwidth_edge_detector)
Inputs:  Full PICMUS frame (IQ samples + window coefficients) + frequency bins
Outputs: Bandwidth edge detection results (f1, f2, L1, L2 for left and right edges)

This script combines the stimulus generation from spectral_power_estimator
and bandwidth_edge_detector.
"""
import numpy as np
from scipy import signal
from pathlib import Path
import sys
import random

# --- Setup Paths ---
try:
    SIMULATOR_ROOT = Path(__file__).resolve().parent.parent
except NameError:
    SIMULATOR_ROOT = Path.cwd().parent

sys.path.insert(0, str(SIMULATOR_ROOT / "src"))

# --- Imports ---
try:
    from afe_interface_rf import load_picmus_rf_data
    from virtual_afe import run_virtual_afe_processing
    from complete_system_model import (
        streaming_dft_processor, 
        convert_to_hardware_db_power,
        calculate_hw_log_power
    )
    from fixed_float_conversions import float_to_fixed_point, fixed_point_to_float
except ImportError as e:
    print(f"Error importing required modules: {e}")
    sys.exit(1)


def clip_accumulator_to_32bit(accum_val_64bit, accum_frac_64=56):
    """
    Clip 64-bit accumulator (Q8.56) to 32-bit representation (Q8.24).
    
    The hardware takes the upper 32 bits [63:32], which gives us Q8.24 format.
    Values too small to be represented in 24 fractional bits get clamped to 0.
    
    Args:
        accum_val_64bit: Complex value in Q8.56 format (as float)
        accum_frac_64: Fractional bits in 64-bit format (56)
    
    Returns:
        Complex value clamped to Q8.24 representable range
    """
    min_representable = 2.0 ** (-24)
    
    # Clamp real and imaginary parts separately
    real_part = accum_val_64bit.real
    imag_part = accum_val_64bit.imag
    
    # Clamp to zero if magnitude too small
    if abs(real_part) < min_representable:
        real_part = 0.0
    if abs(imag_part) < min_representable:
        imag_part = 0.0
    
    return complex(real_part, imag_part)


def find_bandwidth_edges(power_db, freq_bins, threshold_drop_db):
    """
    Software model of bandwidth edge detection.
    
    Args:
        power_db: Array of power values in dB (hardware format, 8-bit unsigned)
        freq_bins: Array of frequency bin values
        threshold_drop_db: Threshold drop below max in dB
    
    Returns:
        Dictionary with edge detection results
    """
    # Find maximum power
    max_power = np.max(power_db)
    
    # Calculate absolute threshold
    abs_threshold = max_power - threshold_drop_db
    
    # Check if threshold is valid (non-negative)
    threshold_ok = abs_threshold >= 0
    
    if not threshold_ok:
        print(f"  Warning: Invalid threshold (max_power={max_power}, threshold={abs_threshold})")
        return {
            'threshold_ok': False,
            'f1_left': 0,
            'f2_left': 0,
            'L1_left': 0,
            'L2_left': 0,
            'f1_right': 0,
            'f2_right': 0,
            'L1_right': 0,
            'L2_right': 0
        }
    
    # Find left edge (search from left/low frequencies)
    f1_left = 0
    f2_left = 0
    L1_left = 0
    L2_left = 0
    left_edge_found = False
    
    for i in range(len(power_db) - 1):
        if power_db[i] < abs_threshold and power_db[i+1] >= abs_threshold:
            f1_left = freq_bins[i]
            f2_left = freq_bins[i+1]
            L1_left = power_db[i]
            L2_left = power_db[i+1]
            left_edge_found = True
            break
    
    # Find right edge (search from right/high frequencies)
    f1_right = 0
    f2_right = 0
    L1_right = 0
    L2_right = 0
    right_edge_found = False
    
    for i in range(len(power_db) - 1, 0, -1):
        if power_db[i] < abs_threshold and power_db[i-1] >= abs_threshold:
            f1_right = freq_bins[i]
            f2_right = freq_bins[i-1]
            L1_right = power_db[i]
            L2_right = power_db[i-1]
            right_edge_found = True
            break
    
    return {
        'threshold_ok': threshold_ok,
        'left_edge_found': left_edge_found,
        'right_edge_found': right_edge_found,
        'f1_left': f1_left,
        'f2_left': f2_left,
        'L1_left': L1_left,
        'L2_left': L2_left,
        'f1_right': f1_right,
        'f2_right': f2_right,
        'L1_right': L1_right,
        'L2_right': L2_right
    }


def generate_test_case(test_name, baseline_iq_data, fs_baseline, S_bins, 
                       window_number, hw_params, max_magnitude):
    """
    Generate a single test case for top module.
    
    Args:
        test_name: Name identifier for this test case
        baseline_iq_data: Full A-line of IQ data from AFE processing
        fs_baseline: Sampling frequency after AFE
        S_bins: Frequency bins to calculate DFT at
        window_number: Which 256-sample window to analyze (0-based)
        hw_params: Dictionary with hardware parameters
        max_magnitude: Maximum IQ magnitude for normalization
    
    Returns:
        Dictionary with test case data
    """
    print(f"\n=== Generating Test Case: {test_name} ===")
    print(f"  Window number: {window_number}")
    
    # --- Extract Hardware Parameters ---
    IQ_WIDTH = hw_params['IQ_WIDTH']
    WINDOW_WIDTH = hw_params['WINDOW_WIDTH']
    ACCUM_WIDTH = hw_params['ACCUM_WIDTH']
    ACCUM_FRAC = hw_params['ACCUM_FRAC']
    POWER_INPUT_WIDTH = hw_params['POWER_INPUT_WIDTH']
    POWER_WIDTH = hw_params['POWER_WIDTH']
    POWER_FRAC = hw_params['POWER_FRAC']
    PHASE_WIDTH = hw_params['PHASE_WIDTH']
    OSC_LATENCY = hw_params['OSC_LATENCY']
    WINDOW_SIZE = hw_params['WINDOW_SIZE']
    FREQ_BIN_WIDTH = hw_params['FREQ_BIN_WIDTH']
    THRESHOLD_DROP = hw_params['THRESHOLD_DROP']
    
    # --- Calculate Window Parameters ---
    nperseg = WINDOW_SIZE
    hop = nperseg // 2  # 50% overlap
    
    start_sample = window_number * hop
    end_sample = start_sample + nperseg
    
    if end_sample > len(baseline_iq_data):
        raise ValueError(f"Window extends beyond data: end={end_sample}, data_len={len(baseline_iq_data)}")
    
    # Extract the specific window
    time_window_data_raw = baseline_iq_data[start_sample:end_sample]
    
    # --- Normalization and Scaling ---
    iq_frac_bits = 14
    iq_int_bits = IQ_WIDTH - iq_frac_bits
    
    # Calculate scale factor based on max_magnitude
    target_max_val = 2 ** (iq_int_bits - 1)
    scale_factor = target_max_val / max_magnitude
    print(f"  [Normalization] Max magnitude: {max_magnitude:.4f}")
    print(f"  [Normalization] Target max: {target_max_val}")
    print(f"  [Normalization] Scale factor: {scale_factor:.4f}")
    
    # Scale the window data
    time_window_data = time_window_data_raw * scale_factor
    
    # Scale the full frame data for stimulus
    baseline_iq_data_scaled = baseline_iq_data * scale_factor
    
    # --- Generate Hann Window Coefficients ---
    hann_window = signal.windows.hann(nperseg)
    print(f"  Generated Hann window coefficients")
    
    # --- Calculate Frequency Steps for Oscillators ---
    freq_steps = []
    for freq in S_bins:
        normalized_freq = freq / fs_baseline
        freq_step = normalized_freq * (2 ** PHASE_WIDTH)
        if freq_step < 0:
            freq_step += (2.0 ** PHASE_WIDTH)
        freq_steps.append(int(freq_step) & ((1 << PHASE_WIDTH) - 1))
    
    print(f"  Calculated {len(freq_steps)} frequency steps for oscillators")
    
    # --- Run Software DFT Model ---
    print("  Running streaming_dft_processor...")
    dft_bins = streaming_dft_processor(time_window_data, fs_baseline, S_bins, window='hann')
    print(f"  DFT computed for {len(dft_bins)} bins")
    
    # --- Clip Accumulator Values to 32-bit (Q8.24) ---
    print("  Clipping accumulator values from 64-bit (Q8.56) to 32-bit (Q8.24)...")
    dft_bins_clipped = {}
    for freq, complex_val in dft_bins.items():
        clipped_val = clip_accumulator_to_32bit(complex_val, ACCUM_FRAC)
        dft_bins_clipped[freq] = clipped_val

    # --- Convert to Hardware dB Power ---
    print("  Converting to hardware dB power...")
    input_width_log = POWER_INPUT_WIDTH
    input_frac_log = POWER_INPUT_WIDTH - (ACCUM_WIDTH - ACCUM_FRAC)  # Q8.24 has 24 frac bits
    
    freqs_sorted, power_hw_db = convert_to_hardware_db_power(
        dft_bins_clipped, 
        input_width_log, 
        input_frac_log, 
        POWER_WIDTH, 
        POWER_FRAC
    )
    print(f"  Power values (dB): min={np.min(power_hw_db):.2f}, max={np.max(power_hw_db):.2f}")
    
    # --- Run Bandwidth Edge Detection ---
    print("  Running bandwidth edge detection...")
    edge_results = find_bandwidth_edges(power_hw_db, freqs_sorted, THRESHOLD_DROP)
    
    if edge_results['threshold_ok']:
        print(f"  Left edge: f1={edge_results['f1_left']:.2f} Hz, f2={edge_results['f2_left']:.2f} Hz")
        print(f"  Right edge: f1={edge_results['f1_right']:.2f} Hz, f2={edge_results['f2_right']:.2f} Hz")
    else:
        print(f"  Warning: Threshold not valid, edge detection skipped")
    
    # --- Format Stimuli ---
    
    # Calculate DELAY_CYCLES
    delay_cycles = start_sample + OSC_LATENCY
    
    # IQ samples (full frame, normalized and scaled, 16-bit fixed point Q2.14)
    i_samples_hw = []
    q_samples_hw = []
    for sample in baseline_iq_data_scaled:
        i_val = float_to_fixed_point(sample.real, iq_int_bits, iq_frac_bits, signed=True)
        q_val = float_to_fixed_point(sample.imag, iq_int_bits, iq_frac_bits, signed=True)
        i_samples_hw.append(i_val)
        q_samples_hw.append(q_val)
    
    # Window coefficients (16-bit fixed point Q2.14)
    window_frac_bits = 14
    window_int_bits = WINDOW_WIDTH - window_frac_bits
    window_coeffs_hw = []
    for coeff in hann_window:
        w_val = float_to_fixed_point(coeff, window_int_bits, window_frac_bits, signed=True)
        window_coeffs_hw.append(w_val)
    
    # Frequency steps (32-bit unsigned)
    freq_steps_hw = freq_steps
    
    # Frequency bins (16-bit signed, Hz as fixed point)
    freq_bins_hw = []
    for freq in freqs_sorted:
        # Store frequency in Hz as signed 16-bit integer
        freq_val = int(freq) & 0xFFFF
        freq_bins_hw.append(freq_val)
    
    # Expected outputs (bandwidth edge detection results)
    # Convert frequencies to 16-bit signed
    f1_left_expected = int(edge_results['f1_left']) & 0xFFFF
    f2_left_expected = int(edge_results['f2_left']) & 0xFFFF
    f1_right_expected = int(edge_results['f1_right']) & 0xFFFF
    f2_right_expected = int(edge_results['f2_right']) & 0xFFFF
    
    # Powers are already in hardware format (8-bit unsigned)
    L1_left_expected = int(edge_results['L1_left']) & 0xFF
    L2_left_expected = int(edge_results['L2_left']) & 0xFF
    L1_right_expected = int(edge_results['L1_right']) & 0xFF
    L2_right_expected = int(edge_results['L2_right']) & 0xFF
    
    threshold_ok_expected = 1 if edge_results['threshold_ok'] else 0
    
    return {
        'test_name': test_name,
        'num_bins': len(S_bins),
        'num_samples': len(baseline_iq_data),
        'window_size': WINDOW_SIZE,
        'delay_cycles': delay_cycles,
        'osc_latency': OSC_LATENCY,
        'threshold_drop': THRESHOLD_DROP,
        # Inputs
        'i_samples_hw': i_samples_hw,
        'q_samples_hw': q_samples_hw,
        'window_coeffs_hw': window_coeffs_hw,
        'freq_steps_hw': freq_steps_hw,
        'freq_bins_hw': freq_bins_hw,
        # Expected outputs
        'threshold_ok_expected': threshold_ok_expected,
        'f1_left_expected': f1_left_expected,
        'f2_left_expected': f2_left_expected,
        'L1_left_expected': L1_left_expected,
        'L2_left_expected': L2_left_expected,
        'f1_right_expected': f1_right_expected,
        'f2_right_expected': f2_right_expected,
        'L1_right_expected': L1_right_expected,
        'L2_right_expected': L2_right_expected
    }


def write_vector_file(test_cases, output_path):
    """Write test cases to file in format for SystemVerilog testbench"""
    with open(output_path, 'w') as f:
        f.write("# Simulation vectors for top.sv\n")
        f.write("# Generated from spectral_power_estimator + bandwidth_edge_detector\n")
        f.write("#\n")
        f.write("# Format per test case:\n")
        f.write("#   TEST_NAME\n")
        f.write("#   NUM_BINS NUM_SAMPLES WINDOW_SIZE DELAY_CYCLES OSC_LATENCY THRESHOLD_DROP\n")
        f.write("#   FREQ_STEPS (hex, space-separated)\n")
        f.write("#   FREQ_BINS (hex, space-separated)\n")
        f.write("#   WINDOW_COEFFS (hex, space-separated)\n")
        f.write("#   I_SAMPLES (hex, space-separated, full frame)\n")
        f.write("#   Q_SAMPLES (hex, space-separated, full frame)\n")
        f.write("#   EXPECTED_OUTPUTS: threshold_ok f1_left f2_left L1_left L2_left f1_right f2_right L1_right L2_right\n")
        f.write("#\n\n")
        
        for tc in test_cases:
            f.write(f"{tc['test_name']}\n")
            f.write(f"{tc['num_bins']} {tc['num_samples']} {tc['window_size']} ")
            f.write(f"{tc['delay_cycles']} {tc['osc_latency']} {tc['threshold_drop']}\n")
            
            # Frequency steps
            for fs in tc['freq_steps_hw']:
                f.write(f"{fs & 0xFFFFFFFF:08x} ")
            f.write("\n")
            
            # Frequency bins
            for fb in tc['freq_bins_hw']:
                f.write(f"{fb & 0xFFFF:04x} ")
            f.write("\n")
            
            # Window coefficients
            for wc in tc['window_coeffs_hw']:
                f.write(f"{wc & 0xFFFF:04x} ")
            f.write("\n")
            
            # I samples (full frame)
            for i_s in tc['i_samples_hw']:
                f.write(f"{i_s & 0xFFFF:04x} ")
            f.write("\n")
            
            # Q samples (full frame)
            for q_s in tc['q_samples_hw']:
                f.write(f"{q_s & 0xFFFF:04x} ")
            f.write("\n")
            
            # Expected outputs
            f.write(f"{tc['threshold_ok_expected']} ")
            f.write(f"{tc['f1_left_expected']:04x} {tc['f2_left_expected']:04x} ")
            f.write(f"{tc['L1_left_expected']:02x} {tc['L2_left_expected']:02x} ")
            f.write(f"{tc['f1_right_expected']:04x} {tc['f2_right_expected']:04x} ")
            f.write(f"{tc['L1_right_expected']:02x} {tc['L2_right_expected']:02x}\n")
            
            f.write("\n")
    
    print(f"\n✓ Test vectors written to: {output_path}")


def main():
    print("=" * 80)
    print("Top Module Stimulus Generation")
    print("Spectral Power Estimator + Bandwidth Edge Detector")
    print("=" * 80)
    
    # --- Hardware Parameters ---
    hw_params = {
        'IQ_WIDTH': 16,
        'WINDOW_WIDTH': 16,
        'ACCUM_WIDTH': 64,
        'ACCUM_FRAC': 56,
        'POWER_INPUT_WIDTH': 32,
        'POWER_WIDTH': 8,
        'POWER_FRAC': 0,
        'PHASE_WIDTH': 32,
        'OSC_LATENCY': 35,
        'WINDOW_SIZE': 256,
        'FREQ_BIN_WIDTH': 16,
        'THRESHOLD_DROP': 30  # 30 dB
    }
    
    print("\nHardware Parameters:")
    for key, val in hw_params.items():
        print(f"  {key}: {val}")
    
    # --- Load PICMUS Data ---
    print("\n--- Loading PICMUS Data ---")
    
    rf_path = SIMULATOR_ROOT / "datasets/experiments/contrast_speckle/contrast_speckle_expe_dataset_rf.hdf5"
    iq_path = SIMULATOR_ROOT / "datasets/experiments/contrast_speckle/contrast_speckle_expe_dataset_iq.hdf5"
    scan_path = SIMULATOR_ROOT / "datasets/experiments/contrast_speckle/contrast_speckle_expe_scan.hdf5"
    
    try:
        rf_data, angles, _, _, fs_picmus, mod_freq, _, _, _ = load_picmus_rf_data(
            rf_path, iq_path, scan_path
        )
        print(f"✓ Loaded PICMUS data")
        print(f"  Modulation frequency: {mod_freq/1e6:.2f} MHz")
        print(f"  PICMUS sample rate: {fs_picmus/1e6:.2f} MHz")
    except Exception as e:
        print(f"✗ Failed to load PICMUS data: {e}")
        sys.exit(1)
    
    # --- AFE Processing Parameters ---
    adc_rate = 125e6
    baseline_decimation = 4
    
    # --- Define Frequency Bins ---
    delta_f = 0.25e6
    half_bw_est = mod_freq / 2
    
    s_coarse = np.linspace(-mod_freq, mod_freq, 8)
    s_fine_left = np.linspace(-half_bw_est - delta_f, -half_bw_est + delta_f, 8)
    s_fine_right = np.linspace(half_bw_est - delta_f, half_bw_est + delta_f, 8)
    S_bins = np.unique(np.concatenate([s_coarse, s_fine_left, s_fine_right]))
    
    print(f"\nFrequency bins: {len(S_bins)} bins")
    print(f"  Range: [{S_bins[0]/1e6:.3f}, {S_bins[-1]/1e6:.3f}] MHz")
    
    # --- Calculate Valid Window Range ---
    nperseg = 256
    hop = nperseg // 2
    
    # Get center angle
    center_angle_index = np.argmin(np.abs(angles))
    
    # Run AFE processing once for center angle
    print(f"\nRunning virtual AFE processing for angle {center_angle_index}...")
    baseline_iq_data_full, _, fs_baseline = run_virtual_afe_processing(
        rf_data=rf_data,
        angle_index=center_angle_index,
        fs_picmus=fs_picmus,
        modulation_frequency=mod_freq,
        decimation_factor=baseline_decimation,
        adc_sample_rate=adc_rate
    )
    print(f"✓ AFE processing complete. fs_baseline = {fs_baseline/1e6:.2f} MHz")
    
    # Calculate maximum IQ magnitude for normalization
    max_iq = np.max(np.abs(baseline_iq_data_full))
    max_iq_safe = max_iq
    print(f"\nMaximum IQ magnitude: {max_iq_safe:.6f}")
    
    # Calculate total number of valid windows
    total_samples = baseline_iq_data_full.shape[0]
    num_windows_total = int(np.floor((total_samples - nperseg) / hop)) + 1
    print(f"\nTotal samples in A-line: {total_samples}")
    print(f"Total valid windows: {num_windows_total}")
    print(f"Valid window range: 0 to {num_windows_total - 1}")
    
    # Select windows from second half
    second_half_start = num_windows_total // 2
    
    # --- Generate Test Cases ---
    print("\n--- Generating Test Cases ---")
    
    test_cases = []
    num_test_cases = 5
    
    for i in range(num_test_cases):
        # Random window from second half
        window_num = random.randint(second_half_start, num_windows_total - 1)
        
        # Random channel
        channel = random.randint(1, 127)
        
        test_name = f"picmus_ang0_ch{channel}_win{window_num}"
        
        print(f"\n--- Processing: {test_name} ---")
        print(f"  Channel: {channel}, Window: {window_num}")
        
        # Extract channel data
        baseline_iq_data_channel = baseline_iq_data_full[:, channel]
        
        # Generate test case
        try:
            tc = generate_test_case(
                test_name=test_name,
                baseline_iq_data=baseline_iq_data_channel,
                fs_baseline=fs_baseline,
                S_bins=S_bins,
                window_number=window_num,
                hw_params=hw_params,
                max_magnitude=max_iq_safe
            )
            
            test_cases.append(tc)
            print(f"  ✓ Test case generated")
        except Exception as e:
            print(f"  ✗ Failed: {e}")
            continue
    
    # --- Write Output File ---
    print("\n--- Writing Output File ---")
    
    output_dir = SIMULATOR_ROOT.parent / "rtl" / "simvectors"
    output_dir.mkdir(parents=True, exist_ok=True)
    output_path = output_dir / "top_vectors.txt"
    
    write_vector_file(test_cases, output_path)
    
    print("\n" + "=" * 80)
    print(f"SUCCESS: Generated {len(test_cases)} test cases")
    print("=" * 80)


if __name__ == "__main__":
    main()