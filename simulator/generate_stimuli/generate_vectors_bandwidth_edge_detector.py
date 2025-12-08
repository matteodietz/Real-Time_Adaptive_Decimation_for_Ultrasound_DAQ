"""
Generate simulation vectors for bandwidth_edge_detector.sv module.

Target Module: bandwidth_edge_detector
Inputs:  Array of dB Power Values (Fixed Point), Array of Frequency Bins
Outputs: Left Edge (f1, f2, L1, L2), Right Edge (f1, f2, L1, L2)

This script follows the exact processing flow from the complete system model.
"""
import numpy as np
from scipy import signal
from pathlib import Path
import sys

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
    from fixed_float_conversions import float_to_fixed_point
except ImportError as e:
    print(f"Error importing required modules: {e}")
    sys.exit(1)


def generate_test_case(test_name, time_window_data_raw, fs_baseline, S_bins, 
                       threshold_db, hw_params):
    """
    Generate a single test case following the exact flow from the complete system model.
    
    Args:
        test_name: Name identifier for this test case
        time_window_data_raw: Raw IQ time domain data (256 samples)
        fs_baseline: Sampling frequency
        S_bins: Frequency bins to calculate DFT at
        threshold_db: Threshold in dB (e.g., 30.0)
        hw_params: Dictionary with hardware parameters
    
    Returns:
        Dictionary with test case data
    """
    print(f"\n=== Generating Test Case: {test_name} ===")
    
    # --- Extract Hardware Parameters ---
    INPUT_WIDTH_LOG = hw_params['INPUT_WIDTH_LOG']
    ACCUM_WIDTH = hw_params['ACCUM_WIDTH']
    ACCUM_FRAC = hw_params['ACCUM_FRAC']
    POWER_WIDTH = hw_params['POWER_WIDTH']
    POWER_FRAC = hw_params['POWER_FRAC']
    FREQ_BIN_WIDTH = hw_params['FREQ_BIN_WIDTH']
    
    # --- Step 1: Scaling (from complete_system_model) ---
    max_val = np.max(np.abs(time_window_data_raw))
    scale_factor = 1.5 / max_val if max_val > 0 else 1.0
    time_window_data = time_window_data_raw * scale_factor
    print(f"  Scaled data: max_val={max_val:.4f}, scale={scale_factor:.4f}")
    
    # --- Step 2: Core Streaming DFT Processor ---
    print("  Step 2: Running streaming_dft_processor...")
    dft_bins = streaming_dft_processor(time_window_data, fs_baseline, S_bins, window='hann')
    print(f"  DFT computed for {len(dft_bins)} bins")
    
    # --- Step 3: Convert to Hardware dB Power ---
    print("  Step 3: Converting to hardware dB power...")
    freqs_sorted, power_hw_db = convert_to_hardware_db_power(
        dft_bins, 
        INPUT_WIDTH_LOG, 
        INPUT_WIDTH_LOG - (ACCUM_WIDTH - ACCUM_FRAC), 
        POWER_WIDTH, 
        POWER_FRAC
    )
    print(f"  Power values (dB): min={np.min(power_hw_db):.2f}, max={np.max(power_hw_db):.2f}")
    
    # --- Step 4: Calculate Hardware Threshold ---
    print("  Step 4: Calculating threshold...")
    max_power_hw, abs_threshold_hw = calc_hardware_threshold(
        power_hw_db, threshold_db
    )
    print(f"  Max power: {max_power_hw:.2f} (fixed-point)")
    print(f"  Absolute threshold: {abs_threshold_hw:.2f} (fixed-point)")
    
    # --- Step 5: Find Left Edge Points ---
    print("  Step 5: Finding left edge...")
    f1_left, f2_left, L1_left, L2_left = find_left_edge_hw(
        freqs_sorted, power_hw_db, abs_threshold_hw
    )
    if f1_left is not None:
        print(f"  Left edge: f1={f1_left/1e6:.4f} MHz, f2={f2_left/1e6:.4f} MHz")
        print(f"             L1={L1_left:.2f} dB, L2={L2_left:.2f} dB")
    else:
        print("  Left edge: NOT FOUND")
    
    # --- Step 6: Find Right Edge Points ---
    print("  Step 6: Finding right edge...")
    f1_right, f2_right, L1_right, L2_right = find_right_edge_points(
        freqs_sorted, power_hw_db, abs_threshold_hw
    )
    if f1_right is not None:
        print(f"  Right edge: f1={f1_right/1e6:.4f} MHz, f2={f2_right/1e6:.4f} MHz")
        print(f"              L1={L1_right:.2f} dB, L2={L2_right:.2f} dB")
    else:
        print("  Right edge: NOT FOUND")
    
    # --- Format Inputs (Stimuli for DUT) ---
    
    # Frequency bins: Convert Hz to MHz, then to fixed point
    # Using signed representation for frequency (can be negative)
    freq_bin_frac = 12  # Q(FREQ_BIN_WIDTH-12).12
    freq_bin_int = FREQ_BIN_WIDTH - freq_bin_frac
    
    freq_bins_hw = []
    for f_hz in freqs_sorted:
        f_mhz = f_hz / 1e6
        fb_val = float_to_fixed_point(f_mhz, freq_bin_int, freq_bin_frac, signed=True)
        freq_bins_hw.append(fb_val)
    
    # Power values: Already in fixed point representation from model
    # Convert to unsigned fixed point integers for file writing
    power_int_bits = POWER_WIDTH - POWER_FRAC
    power_vals_hw = [
        float_to_fixed_point(p, power_int_bits, POWER_FRAC, signed=False) 
        for p in power_hw_db
    ]
    
    # --- Format Outputs (Expected from DUT) ---
    
    def fix_freq(f):
        """Convert frequency in Hz to fixed point, return 0 if None"""
        if f is None:
            return 0
        f_mhz = f / 1e6
        return float_to_fixed_point(f_mhz, freq_bin_int, freq_bin_frac, signed=True)
    
    def fix_pwr(p):
        """Convert power in dB to fixed point, return 0 if None"""
        if p is None:
            return 0
        return float_to_fixed_point(p, power_int_bits, POWER_FRAC, signed=False)
    
    # Determine if both edges were found
    valid_expect = 1 if (f1_left is not None and f1_right is not None) else 0
    
    return {
        'test_name': test_name,
        'K': len(S_bins),
        # Inputs to DUT
        'power_vals_hw': power_vals_hw,
        'freq_bins_hw': freq_bins_hw,
        # Expected outputs from DUT - Left Edge
        'exp_f1_left': fix_freq(f1_left),
        'exp_f2_left': fix_freq(f2_left),
        'exp_L1_left': fix_pwr(L1_left),
        'exp_L2_left': fix_pwr(L2_left),
        # Expected outputs from DUT - Right Edge
        'exp_f1_right': fix_freq(f1_right),
        'exp_f2_right': fix_freq(f2_right),
        'exp_L1_right': fix_pwr(L1_right),
        'exp_L2_right': fix_pwr(L2_right),
        # Valid signal
        'valid_expect': valid_expect
    }


def write_vector_file(test_cases, output_path):
    """Write test cases to file in format for SystemVerilog testbench"""
    with open(output_path, 'w') as f:
        f.write("# Simulation vectors for bandwidth_edge_detector.sv\n")
        f.write("# Generated from complete_system_model with PICMUS data\n")
        f.write("#\n")
        f.write("# Format per test case:\n")
        f.write("#   TEST_NAME\n")
        f.write("#   NUM_BINS\n")
        f.write("#   FREQ_BINS (space-separated hex values)\n")
        f.write("#   POWER_VALS (space-separated hex values)\n")
        f.write("#   EXPECTED_VALID (0 or 1)\n")
        f.write("#   EXPECTED_LEFT (f1 f2 L1 L2 in hex)\n")
        f.write("#   EXPECTED_RIGHT (f1 f2 L1 L2 in hex)\n")
        f.write("#\n\n")
        
        for tc in test_cases:
            f.write(f"{tc['test_name']}\n")
            f.write(f"{tc['K']}\n")
            
            # Frequency bins (inputs)
            for fb in tc['freq_bins_hw']:
                f.write(f"{fb & 0xFFFFFFFF:08x} ")
            f.write("\n")
            
            # Power values (inputs)
            for p in tc['power_vals_hw']:
                f.write(f"{p & 0xFFFFFFFF:08x} ")
            f.write("\n")
            
            # Expected valid
            f.write(f"{tc['valid_expect']}\n")
            
            # Expected left edge outputs
            f.write(f"{tc['exp_f1_left'] & 0xFFFFFFFF:08x} ")
            f.write(f"{tc['exp_f2_left'] & 0xFFFFFFFF:08x} ")
            f.write(f"{tc['exp_L1_left'] & 0xFFFFFFFF:08x} ")
            f.write(f"{tc['exp_L2_left'] & 0xFFFFFFFF:08x}\n")
            
            # Expected right edge outputs
            f.write(f"{tc['exp_f1_right'] & 0xFFFFFFFF:08x} ")
            f.write(f"{tc['exp_f2_right'] & 0xFFFFFFFF:08x} ")
            f.write(f"{tc['exp_L1_right'] & 0xFFFFFFFF:08x} ")
            f.write(f"{tc['exp_L2_right'] & 0xFFFFFFFF:08x}\n")
            
            f.write("\n")
    
    print(f"\n✓ Test vectors written to: {output_path}")


def main():
    print("=" * 80)
    print("Bandwidth Edge Detector Stimulus Generation")
    print("Following exact flow from complete_system_model.py")
    print("=" * 80)
    
    # --- Hardware Parameters (from complete_system_model test script) ---
    hw_params = {
        'ACCUM_WIDTH': 64,
        'ACCUM_FRAC': 56,
        'INPUT_WIDTH_LOG': 32,
        'POWER_WIDTH': 8,
        'POWER_FRAC': 0,
        'FREQ_BIN_WIDTH': 16,  # Updated to match module
        'threshold_db': 30.0
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
    
    # --- Define Frequency Bins (from complete_system_model) ---
    delta_f = 0.25e6
    half_bw_est = mod_freq / 2
    
    s_coarse = np.linspace(-mod_freq, mod_freq, 8)
    s_fine_left = np.linspace(-half_bw_est - delta_f, -half_bw_est + delta_f, 8)
    s_fine_right = np.linspace(half_bw_est - delta_f, half_bw_est + delta_f, 8)
    S_bins = np.unique(np.concatenate([s_coarse, s_fine_left, s_fine_right]))
    
    print(f"\nFrequency bins: {len(S_bins)} bins")
    print(f"  Range: [{S_bins[0]/1e6:.3f}, {S_bins[-1]/1e6:.3f}] MHz")
    
    # --- STFT Parameters (from complete_system_model) ---
    nperseg = 256
    hop = nperseg // 2
    
    # --- Generate Test Cases ---
    print("\n--- Generating Test Cases ---")
    
    test_configs = [
        ("picmus_ang0_ch64_win29", 64, 29),
        ("picmus_ang0_ch32_win15", 32, 15),
        ("picmus_ang0_ch96_win30", 96, 30),
    ]
    
    test_cases = []
    
    # Get center angle
    center_angle_index = np.argmin(np.abs(angles))
    
    # Run AFE processing once for center angle
    print(f"\nRunning virtual AFE processing for angle {center_angle_index}...")
    baseline_iq_data, _, fs_baseline = run_virtual_afe_processing(
        rf_data=rf_data,
        angle_index=center_angle_index,
        fs_picmus=fs_picmus,
        modulation_frequency=mod_freq,
        decimation_factor=baseline_decimation,
        adc_sample_rate=adc_rate
    )
    print(f"✓ AFE processing complete. fs_baseline = {fs_baseline/1e6:.2f} MHz")
    
    # Generate test cases
    for test_name, channel, window_num in test_configs:
        print(f"\n--- Processing: {test_name} ---")
        print(f"  Channel: {channel}, Window: {window_num}")
        
        # Extract time window
        start_sample = window_num * hop
        end_sample = start_sample + nperseg
        
        if end_sample > baseline_iq_data.shape[0]:
            print(f"  ✗ Skipping: window extends beyond data")
            continue
        
        time_window_data_raw = baseline_iq_data[start_sample:end_sample, channel]
        
        # Generate test case
        tc = generate_test_case(
            test_name=test_name,
            time_window_data_raw=time_window_data_raw,
            fs_baseline=fs_baseline,
            S_bins=S_bins,
            threshold_db=hw_params['threshold_db'],
            hw_params=hw_params
        )
        
        test_cases.append(tc)
        print(f"  ✓ Test case generated")
    
    # --- Write Output File ---
    print("\n--- Writing Output File ---")
    
    output_dir = SIMULATOR_ROOT.parent / "rtl" / "simvectors"
    output_dir.mkdir(parents=True, exist_ok=True)
    output_path = output_dir / "edge_detector_vectors.txt"
    
    write_vector_file(test_cases, output_path)
    
    print("\n" + "=" * 80)
    print(f"SUCCESS: Generated {len(test_cases)} test cases")
    print("=" * 80)


if __name__ == "__main__":
    main()