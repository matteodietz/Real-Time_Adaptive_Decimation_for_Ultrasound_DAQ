"""
Generate simulation vectors for top.sv module.

Target Module: top (spectral_power_estimator + bandwidth_edge_detector)
Inputs:  Full PICMUS frame (IQ samples + window coefficients) + frequency bins
Outputs: Bandwidth edge detection results (f1, f2, L1, L2 for left and right edges)

Usage:
    python generate_vectors_top.py <dataset_type> <dataset_name> [num_test_cases]
    
Examples:
    python generate_vectors_top.py experiments contrast_speckle
    python generate_vectors_top.py simulation resolution_distorsion 100
    python generate_vectors_top.py in_vivo carotid_cross 50
"""
import numpy as np
from scipy import signal
from pathlib import Path
import sys
import random
import argparse

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
        calc_hardware_threshold,
        find_left_edge_hw,
        find_right_edge_points
    )
    from fixed_float_conversions import float_to_fixed_point, fixed_point_to_float
except ImportError as e:
    print(f"Error importing required modules: {e}")
    sys.exit(1)


# --- Dataset Configuration ---
DATASET_CONFIG = {
    'experiments': {
        'contrast_speckle': {
            'rf': 'contrast_speckle_expe_dataset_rf.hdf5',
            'iq': 'contrast_speckle_expe_dataset_iq.hdf5',
            'scan': 'contrast_speckle_expe_scan.hdf5'
        },
        'resolution_distorsion': {
            'rf': 'resolution_distorsion_expe_dataset_rf.hdf5',
            'iq': 'resolution_distorsion_expe_dataset_iq.hdf5',
            'scan': 'resolution_distorsion_expe_scan.hdf5'
        }
    },
    'in_vivo': {
        'carotid_cross': {
            'rf': 'carotid_cross_expe_dataset_rf.hdf5',
            'iq': 'carotid_cross_expe_dataset_iq.hdf5',
            'scan': 'carotid_cross_expe_scan.hdf5'
        },
        'carotid_long': {
            'rf': 'carotid_long_expe_dataset_rf.hdf5',
            'iq': 'carotid_long_expe_dataset_iq.hdf5',
            'scan': 'carotid_long_expe_scan.hdf5'
        }
    },
    'simulation': {
        'contrast_speckle': {
            'rf': 'contrast_speckle_simu_dataset_rf.hdf5',
            'iq': 'contrast_speckle_simu_dataset_iq.hdf5',
            'scan': 'contrast_speckle_simu_scan.hdf5'
        },
        'resolution_distorsion': {
            'rf': 'resolution_distorsion_simu_dataset_rf.hdf5',
            'iq': 'resolution_distorsion_simu_dataset_iq.hdf5',
            'scan': 'resolution_distorsion_simu_scan.hdf5'
        }
    }
}


def get_dataset_paths(dataset_type, dataset_name):
    """
    Get the full paths to dataset files.
    
    Args:
        dataset_type: 'experiments', 'in_vivo', or 'simulation'
        dataset_name: e.g., 'contrast_speckle', 'carotid_cross', etc.
    
    Returns:
        Tuple of (rf_path, iq_path, scan_path)
    """
    if dataset_type not in DATASET_CONFIG:
        raise ValueError(f"Invalid dataset type: {dataset_type}. Must be one of: {list(DATASET_CONFIG.keys())}")
    
    if dataset_name not in DATASET_CONFIG[dataset_type]:
        raise ValueError(f"Invalid dataset name: {dataset_name}. Must be one of: {list(DATASET_CONFIG[dataset_type].keys())}")
    
    config = DATASET_CONFIG[dataset_type][dataset_name]
    base_path = SIMULATOR_ROOT / "datasets" / dataset_type / dataset_name
    
    rf_path = base_path / config['rf']
    iq_path = base_path / config['iq']
    scan_path = base_path / config['scan']
    
    # Verify files exist
    for path in [rf_path, iq_path, scan_path]:
        if not path.exists():
            raise FileNotFoundError(f"Dataset file not found: {path}")
    
    return rf_path, iq_path, scan_path


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


def generate_test_case(test_name, baseline_iq_data, fs_baseline, S_bins, 
                       window_number, hw_params, max_magnitude):
    """
    Generate a single test case for top module.
    Uses the exact functions from complete_system_model for bandwidth edge detection.
    
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
    
    # # --- Calculate Frequency Steps for Oscillators ---
    # freq_steps = []
    # for freq in S_bins:
    #     normalized_freq = freq / fs_baseline
    #     freq_step = normalized_freq * (2 ** PHASE_WIDTH)
    #     if freq_step < 0:
    #         freq_step += (2.0 ** PHASE_WIDTH)
    #     freq_steps.append(int(freq_step) & ((1 << PHASE_WIDTH) - 1))
    
    # print(f"  Calculated {len(freq_steps)} frequency steps for oscillators")

    # --- Calculate Negative Frequency Steps for Oscillators ---
    freq_steps = []
    for freq in S_bins:
        normalized_freq = freq / fs_baseline
        
        # Calculate the positive step magnitude
        raw_step = normalized_freq * (2 ** PHASE_WIDTH)
        
        # Negate it! This creates the backward rotation (e^-jtheta)
        # Use round() to be precise, or int() for truncation
        neg_step = -round(raw_step) 
        
        # Apply mask to convert the negative number to its unsigned bit representation
        # Python handles the 2's complement wrap-around here automatically
        freq_steps.append(neg_step & ((1 << PHASE_WIDTH) - 1))
    
    print(f"  Calculated {len(freq_steps)} negative frequency steps for oscillators")
    
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
    
    # --- Calculate Hardware Threshold (using complete_system_model function) ---
    print("  Calculating threshold...")
    max_power_hw, abs_threshold_hw = calc_hardware_threshold(
        power_hw_db, THRESHOLD_DROP
    )
    print(f"  Max power: {max_power_hw:.2f} dB")
    print(f"  Absolute threshold: {abs_threshold_hw:.2f} dB")
    
    # Check if threshold is valid
    threshold_ok = abs_threshold_hw >= 0
    
    # --- Find Left Edge (using complete_system_model function) ---
    print("  Finding left edge...")
    f1_left, f2_left, L1_left, L2_left = find_left_edge_hw(
        freqs_sorted, power_hw_db, abs_threshold_hw
    )
    if f1_left is not None:
        print(f"  Left edge: f1={f1_left/1e6:.4f} MHz, f2={f2_left/1e6:.4f} MHz")
        print(f"             L1={L1_left:.2f} dB, L2={L2_left:.2f} dB")
    else:
        print("  Left edge: NOT FOUND")
    
    # --- Find Right Edge (using complete_system_model function) ---
    print("  Finding right edge...")
    f1_right, f2_right, L1_right, L2_right = find_right_edge_points(
        freqs_sorted, power_hw_db, abs_threshold_hw
    )
    if f1_right is not None:
        print(f"  Right edge: f1={f1_right/1e6:.4f} MHz, f2={f2_right/1e6:.4f} MHz")
        print(f"              L1={L1_right:.2f} dB, L2={L2_right:.2f} dB")
    else:
        print("  Right edge: NOT FOUND")
    
    # --- Format Stimuli ---
    
    # Calculate DELAY_CYCLES
    delay_cycles = start_sample
    
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
    
    # # Frequency bins (16-bit signed, Hz as integer)
    # freq_bins_hw = []
    # for freq in freqs_sorted:
    #     # Store frequency in Hz as signed 16-bit integer
    #     freq_val = int(freq) & 0xFFFF
    #     freq_bins_hw.append(freq_val)
    
    # # --- Format Expected Outputs ---
    
    # def fix_freq(f):
    #     """Convert frequency in Hz to fixed point, return 0 if None"""
    #     if f is None:
    #         return 0
    #     # Store as signed 16-bit integer in Hz
    #     return int(f) & 0xFFFF

    # --- UPDATED: Frequency Bins are just Indices ---
    # We create a list [0, 1, 2, ... K-1]
    freq_bins_hw = list(range(len(S_bins)))
    
    # Helper to convert Frequency Float to Index
    def fix_freq(f_val):
        if f_val is None: return 0
        # Find the index of this frequency in the sorted list
        # We use np.isclose to handle potential float precision issues
        idx = np.where(np.isclose(freqs_sorted, f_val))[0]
        if len(idx) > 0:
            return int(idx[0])
        return 0
    
    def fix_pwr(p):
        """Convert power in dB to fixed point, return 0 if None"""
        if p is None:
            return 0
        # Power is already in hardware format (8-bit unsigned integer)
        return int(p) & 0xFF
    
    # Expected outputs (bandwidth edge detection results)
    f1_left_expected = fix_freq(f1_left)
    f2_left_expected = fix_freq(f2_left)
    L1_left_expected = fix_pwr(L1_left)
    L2_left_expected = fix_pwr(L2_left)
    
    f1_right_expected = fix_freq(f1_right)
    f2_right_expected = fix_freq(f2_right)
    L1_right_expected = fix_pwr(L1_right)
    L2_right_expected = fix_pwr(L2_right)
    
    threshold_ok_expected = 1 if threshold_ok else 0

    return {
        'test_name': test_name,
        'num_bins': len(S_bins),
        'num_samples': len(baseline_iq_data),
        'window_size': WINDOW_SIZE,
        'delay_cycles': delay_cycles,
        'osc_latency': OSC_LATENCY,
        'threshold_drop': THRESHOLD_DROP,
        'angle': 0,  # Always angle 0 (center angle)
        'channel': int(test_name.split('_ch')[1].split('_')[0]),  # Extract from test_name
        'window_num': window_number,
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
        f.write("# Using exact functions from complete_system_model.py\n")
        f.write("#\n")
        f.write("# Format per test case:\n")
        f.write("#   TEST_NAME\n")
        f.write("#   NUM_BINS NUM_SAMPLES WINDOW_SIZE DELAY_CYCLES OSC_LATENCY THRESHOLD_DROP ANGLE CHANNEL WINDOW_NUM\n")
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
            f.write(f"{tc['delay_cycles']} {tc['osc_latency']} {tc['threshold_drop']} ")
            f.write(f"{tc['angle']} {tc['channel']} {tc['window_num']}\n")
            
            # Frequency steps
            for fs in tc['freq_steps_hw']:
                f.write(f"{fs & 0xFFFF:04x} ")
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
    
    print(f"\n Test vectors written to: {output_path}")


def main():
    # --- Parse Command Line Arguments ---
    parser = argparse.ArgumentParser(
        description='Generate simulation vectors for top.sv module',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog='''
Examples:
  %(prog)s experiments contrast_speckle
  %(prog)s simulation resolution_distorsion 100
  %(prog)s in_vivo carotid_cross 50

Available datasets:
  experiments: contrast_speckle, resolution_distorsion
  in_vivo: carotid_cross, carotid_long
  simulation: contrast_speckle, resolution_distorsion
        '''
    )
    
    parser.add_argument('-t', '--dataset_type', 
                        choices=['experiments', 'in_vivo', 'simulation'],
                        default='experiments',
                        help='Type of dataset')
    parser.add_argument('-d', '--dataset_name',
                        help='Name of the specific dataset',
                        default='contrast_speckle')
    parser.add_argument('-n', '--num_tests', 
                        type=int, 
                        default=10,
                        help='Number of test cases to generate (default: 5)')
    
    args = parser.parse_args()
    
    print("=" * 80)
    print("Top Module Stimulus Generation")
    print("Spectral Power Estimator + Bandwidth Edge Detector")
    print("Using exact functions from complete_system_model.py")
    print("=" * 80)
    print(f"\nDataset: {args.dataset_type}/{args.dataset_name}")
    print(f"Number of test cases: {args.num_tests}")
    
    # --- Hardware Parameters ---
    hw_params = {
        'IQ_WIDTH': 16,
        'WINDOW_WIDTH': 16,
        'ACCUM_WIDTH': 36,
        'ACCUM_FRAC': 28,
        'POWER_INPUT_WIDTH': 18,
        'POWER_WIDTH': 8,
        'POWER_FRAC': 0,
        'PHASE_WIDTH': 16,
        'OSC_LATENCY': 20,
        'WINDOW_SIZE': 256,
        'FREQ_BIN_WIDTH': 5, # 16
        'THRESHOLD_DROP': 30  # 30 dB
    }
    
    print("\nHardware Parameters:")
    for key, val in hw_params.items():
        print(f"  {key}: {val}")
    
    # --- Get Dataset Paths ---
    print("\n--- Loading Dataset Paths ---")
    try:
        rf_path, iq_path, scan_path = get_dataset_paths(args.dataset_type, args.dataset_name)
        print(f"  RF data: {rf_path}")
        print(f"  IQ data: {iq_path}")
        print(f"  Scan data: {scan_path}")
    except (ValueError, FileNotFoundError) as e:
        print(f"✗ Error: {e}")
        sys.exit(1)
    
    # --- Load PICMUS Data ---
    print("\n--- Loading PICMUS Data ---")
    try:
        rf_data, angles, _, _, fs_picmus, mod_freq, _, _, _ = load_picmus_rf_data(
            rf_path, iq_path, scan_path
        )
        print(f"  Loaded PICMUS data")
        print(f"  Modulation frequency: {mod_freq/1e6:.2f} MHz")
        print(f"  PICMUS sample rate: {fs_picmus/1e6:.2f} MHz")
    except Exception as e:
        print(f"  Failed to load PICMUS data: {e}")
        sys.exit(1)
    
    # --- AFE Processing Parameters ---
    adc_rate = 125e6
    baseline_decimation = 4
    
    # --- Define Frequency Bins ---
    delta_f = 0.25e6
    half_bw_est = mod_freq / 2
    
    s_coarse = np.linspace(-mod_freq, mod_freq, 8)
    # s_fine_left = np.linspace(-half_bw_est - delta_f, -half_bw_est + delta_f, 8)
    # s_fine_right = np.linspace(half_bw_est - delta_f, half_bw_est + delta_f, 8)
    s_fine_left = np.linspace(-2.32e6 - delta_f, -2.32e6 + delta_f, 8)
    s_fine_right = np.linspace(2.25e6 - delta_f, 2.25e6 + delta_f, 8)
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
    print(f" AFE processing complete. fs_baseline = {fs_baseline/1e6:.2f} MHz")
    
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
    last_third_start = 2 * num_windows_total // 3
    
    # --- Generate Test Cases ---
    print("\n--- Generating Test Cases ---")
    
    test_cases = []
    num_test_cases = args.num_tests
    
    for i in range(num_test_cases):
        # Random window from second half
        window_num = random.randint(last_third_start, num_windows_total - 2)
        
        # Random channel
        channel = random.randint(1, 127)
        
        test_name = f"{args.dataset_name}_ang0_ch{channel}_win{window_num}"
        
        print(f"\n--- Processing: {test_name} ({i+1}/{num_test_cases}) ---")
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
            print(f"  Test case generated")
        except Exception as e:
            print(f"  Failed: {e}")
            continue
    
    # --- Write Output File ---
    print("\n--- Writing Output File ---")
    
    output_dir = SIMULATOR_ROOT.parent / "rtl" / "simvectors"
    output_dir.mkdir(parents=True, exist_ok=True)
    
    # Create filename with dataset info
    if args.dataset_type == 'experiments' and args.dataset_name == 'contrast_speckle' and args.num_tests == 10:
        output_filename = "top_vectors.txt"
    else:
        output_filename = f"top_vectors_{args.dataset_type}_{args.dataset_name}.txt"
    output_path = output_dir / output_filename

    # output_filename = f"top_vectors_{args.dataset_type}_{args.dataset_name}.txt"
    # output_path = output_dir / output_filename
    
    write_vector_file(test_cases, output_path)
    
    print("\n" + "=" * 80)
    print(f"SUCCESS: Generated {len(test_cases)} test cases")
    print(f"Output file: {output_path}")
    print("=" * 80)


if __name__ == "__main__":
    main()