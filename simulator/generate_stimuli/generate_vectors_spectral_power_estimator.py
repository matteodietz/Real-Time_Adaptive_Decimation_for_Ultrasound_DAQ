"""
Generate simulation vectors for spectral_power_estimator.sv module.

Target Module: spectral_power_estimator
Inputs:  Full PICMUS frame (IQ samples + window coefficients)
Outputs: dB Power values for each frequency bin

This script follows the exact processing flow from the complete system model
up to the power conversion stage.
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
    # The minimum absolute value representable in Q8.24 is 2^(-24)
    # When we take upper 32 bits from Q8.56, we lose the lower 32 bits
    # This means we lose precision below 2^(-24) in the final Q8.24 format
    
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
    Generate a single test case for spectral_power_estimator.
    
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
    
    # --- Calculate Window Parameters ---
    nperseg = WINDOW_SIZE
    hop = nperseg // 2  # 50% overlap
    
    start_sample = window_number * hop
    end_sample = start_sample + nperseg
    
    if end_sample > len(baseline_iq_data):
        raise ValueError(f"Window extends beyond data: end={end_sample}, data_len={len(baseline_iq_data)}")
    
    # Extract the specific window
    time_window_data_raw = baseline_iq_data[start_sample:end_sample]
    
    # --- Normalization and Scaling (following dft_power_vectors logic) ---
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
    
    # --- Step 2: Generate Hann Window Coefficients ---
    hann_window = signal.windows.hann(nperseg)
    print(f"  Generated Hann window coefficients")
    
    # --- Step 3: Calculate Frequency Steps for Oscillators ---
    # freq_step = (target_freq / fs) * 2^PHASE_WIDTH
    freq_steps = []
    for freq in S_bins:
        normalized_freq = freq / fs_baseline
        freq_step = normalized_freq * (2 ** PHASE_WIDTH)
        if freq_step < 0:
            freq_step += (2.0 ** PHASE_WIDTH)
        freq_steps.append(int(freq_step) & ((1 << PHASE_WIDTH) - 1))
    
    print(f"  Calculated {len(freq_steps)} frequency steps for oscillators")
    
    # --- Step 4: Run Software DFT Model ---
    print("  Running streaming_dft_processor...")
    dft_bins = streaming_dft_processor(time_window_data, fs_baseline, S_bins, window='hann')
    print(f"  DFT computed for {len(dft_bins)} bins")
    
    # --- Step 5: Clip Accumulator Values to 32-bit (Q8.24) ---
    print("  Clipping accumulator values from 64-bit (Q8.56) to 32-bit (Q8.24)...")
    dft_bins_clipped = {}
    for freq, complex_val in dft_bins.items():
        clipped_val = clip_accumulator_to_32bit(complex_val, ACCUM_FRAC)
        dft_bins_clipped[freq] = clipped_val

    # --- Step 6: Convert to Hardware dB Power ---
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
    
    # --- Format Stimuli ---
    
    # Calculate DELAY_CYCLES: when DFT should start
    # This is the sample index where our window starts
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
    
    # Expected power values (8-bit unsigned Q8.0)
    power_vals_expected = []
    for power_db in power_hw_db:
        p_val = float_to_fixed_point(power_db, POWER_WIDTH, POWER_FRAC, signed=False)
        power_vals_expected.append(p_val)
    
    return {
        'test_name': test_name,
        'num_bins': len(S_bins),
        'num_samples': len(baseline_iq_data),
        'window_size': WINDOW_SIZE,
        'delay_cycles': delay_cycles,
        'osc_latency': OSC_LATENCY,
        # Inputs
        'i_samples_hw': i_samples_hw,
        'q_samples_hw': q_samples_hw,
        'window_coeffs_hw': window_coeffs_hw,
        'freq_steps_hw': freq_steps_hw,
        # Expected outputs
        'power_vals_expected': power_vals_expected
    }


def write_vector_file(test_cases, output_path):
    """Write test cases to file in format for SystemVerilog testbench"""
    with open(output_path, 'w') as f:
        f.write("# Simulation vectors for spectral_power_estimator.sv\n")
        f.write("# Generated from complete_system_model with PICMUS data\n")
        f.write("#\n")
        f.write("# Format per test case:\n")
        f.write("#   TEST_NAME\n")
        f.write("#   NUM_BINS NUM_SAMPLES WINDOW_SIZE DELAY_CYCLES OSC_LATENCY\n")
        f.write("#   FREQ_STEPS (hex, space-separated)\n")
        f.write("#   WINDOW_COEFFS (hex, space-separated)\n")
        f.write("#   I_SAMPLES (hex, space-separated, full frame)\n")
        f.write("#   Q_SAMPLES (hex, space-separated, full frame)\n")
        f.write("#   EXPECTED_POWER_DB (hex, space-separated)\n")
        f.write("#\n\n")
        
        for tc in test_cases:
            f.write(f"{tc['test_name']}\n")
            f.write(f"{tc['num_bins']} {tc['num_samples']} {tc['window_size']} ")
            f.write(f"{tc['delay_cycles']} {tc['osc_latency']}\n")
            
            # Frequency steps
            for fs in tc['freq_steps_hw']:
                f.write(f"{fs & 0xFFFFFFFF:08x} ")
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
            
            # Expected power values
            for p in tc['power_vals_expected']:
                f.write(f"{p & 0xFF:02x} ")
            f.write("\n")
            
            f.write("\n")
    
    print(f"\n✓ Test vectors written to: {output_path}")


def main():
    print("=" * 80)
    print("Spectral Power Estimator Stimulus Generation")
    print("Following exact flow from complete_system_model.py")
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
        'OSC_LATENCY': 36,
        'WINDOW_SIZE': 256
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
    output_path = output_dir / "spectral_power_estimator_vectors.txt"
    
    write_vector_file(test_cases, output_path)
    
    print("\n" + "=" * 80)
    print(f"SUCCESS: Generated {len(test_cases)} test cases")
    print("=" * 80)


if __name__ == "__main__":
    main()