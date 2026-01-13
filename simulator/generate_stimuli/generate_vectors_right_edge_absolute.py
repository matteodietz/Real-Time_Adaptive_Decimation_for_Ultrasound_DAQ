"""
Generate simulation vectors for find_bw_right_edge_absolute.sv module.
Updated to use complete_system_model functions and output bin indices instead of frequencies.
"""
import numpy as np
from scipy import signal
from pathlib import Path
import sys

# Add parent directory to path
SIMULATOR_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SIMULATOR_ROOT / "src"))

# Import from complete_system_model (most accurate hardware model)
from complete_system_model import (
    streaming_dft_processor,
    convert_to_hardware_db_power,
    calc_hardware_threshold,
    find_right_edge_points  # Use RIGHT edge function
)

from fixed_float_conversions import float_to_fixed_point

# Import data loading functions
try:
    from afe_interface_rf import load_picmus_rf_data
    from virtual_afe import run_virtual_afe_processing
    PICMUS_AVAILABLE = True
except ImportError:
    print("Warning: PICMUS data loading modules not available. Skipping real data tests.")
    PICMUS_AVAILABLE = False


def clip_accumulator_to_32bit(accum_val_64bit, accum_frac_64=56):
    """
    Clip 64-bit accumulator (Q8.56) to 32-bit representation (Q8.24).
    Matches the hardware behavior in complex_to_log_power_tmux.sv
    """
    min_representable = 2.0 ** (-24)
    
    real_part = accum_val_64bit.real
    imag_part = accum_val_64bit.imag
    
    if abs(real_part) < min_representable:
        real_part = 0.0
    if abs(imag_part) < min_representable:
        imag_part = 0.0
    
    return complex(real_part, imag_part)


def generate_test_case(test_name, iq_data, fs, freq_bins, threshold_drop_db, 
                       accum_width, freq_bin_width, num_accums):
    """
    Generate a single test case using hardware-accurate functions.
    Returns bin indices instead of frequency values.
    """
    print(f"\n=== Generating test case: {test_name} ===")
    
    # --- 1. Input Scaling (Matches hardware DFT input range) ---
    IQ_WIDTH = 16
    IQ_FRAC_BITS = 14
    IQ_INT_BITS = IQ_WIDTH - IQ_FRAC_BITS  # 2 bits
    
    max_magnitude = np.max(np.abs(iq_data))
    target_max_val = 2.0 ** (IQ_INT_BITS - 1)  # ~2.0 for Q2.14
    
    if max_magnitude > 0:
        scale_factor = target_max_val / max_magnitude
        print(f"  [Scaling] Input Max: {max_magnitude:.2e} -> Target: {target_max_val}")
        print(f"  [Scaling] Scale Factor: {scale_factor:.4f}")
    else:
        scale_factor = 1.0
        print("  [Scaling] Input is zero/empty.")

    iq_data_scaled = iq_data * scale_factor
    
    # --- 2. Run DFT on scaled data ---
    dft_bins = streaming_dft_processor(iq_data_scaled, fs, freq_bins, window='hann')
    print(f"  DFT computed for {len(dft_bins)} bins")
    
    # --- 3. Clip Accumulator to 32-bit (Q8.24) ---
    dft_bins_clipped = {}
    for freq, complex_val in dft_bins.items():
        clipped_val = clip_accumulator_to_32bit(complex_val, accum_frac_64=56)
        dft_bins_clipped[freq] = clipped_val
    print("  Accumulator clipped from 64-bit to 32-bit")
    
    # --- 4. Convert to Hardware dB Power ---
    POWER_INPUT_WIDTH = 18
    POWER_WIDTH = accum_width
    POWER_FRAC = 0
    input_frac_log = POWER_INPUT_WIDTH - 8  # 24 frac bits in Q8.24
    
    freqs_sorted, power_hw_db = convert_to_hardware_db_power(
        dft_bins_clipped,
        POWER_INPUT_WIDTH,
        input_frac_log,
        POWER_WIDTH,
        POWER_FRAC
    )
    print(f"  Power values (dB): min={np.min(power_hw_db):.2f}, max={np.max(power_hw_db):.2f}")
    
    # --- 5. Calculate Hardware Threshold ---
    max_power_hw, abs_threshold_hw = calc_hardware_threshold(
        power_hw_db, threshold_drop_db
    )
    print(f"  Max power: {max_power_hw:.2f} dB")
    print(f"  Absolute threshold: {abs_threshold_hw:.2f} dB")
    
    # --- 6. Find Right Edge (returns frequencies) ---
    f1_golden_freq, f2_golden_freq, L1_golden, L2_golden = find_right_edge_points(
        freqs_sorted, power_hw_db, abs_threshold_hw
    )
    
    if f1_golden_freq is not None:
        print(f"  Crossing found between {L1_golden:.2f} dB and {L2_golden:.2f} dB")
        print(f"  Frequencies: f1={f1_golden_freq/1e6:.4f} MHz, f2={f2_golden_freq/1e6:.4f} MHz")
    else:
        print(f"  No crossing found!")
    
    # --- 7. Convert to Hardware Format ---
    
    # Generate frequency bin indices (0 to NUM_BINS-1)
    freq_bins_hw = list(range(len(freqs_sorted)))
    
    # Power values (already integers from hardware model)
    power_db_hw = [int(p) & 0xFF for p in power_hw_db]
    
    # Threshold
    threshold_hw = int(abs_threshold_hw) & 0xFF
    
    # Convert frequencies to indices
    def freq_to_index(freq_val):
        """Convert frequency to its index in the sorted frequency array"""
        if freq_val is None:
            return None
        idx = np.where(np.isclose(freqs_sorted, freq_val))[0]
        if len(idx) > 0:
            return int(idx[0])
        return None
    
    def power_to_hw(power_val):
        """Convert power value to hardware format"""
        if power_val is None:
            return None
        return int(power_val) & 0xFF
    
    # Convert golden frequencies to indices
    f1_golden_idx = freq_to_index(f1_golden_freq)
    f2_golden_idx = freq_to_index(f2_golden_freq)
    
    # Expected outputs as indices (for hardware comparison)
    f1_hw = f1_golden_idx if f1_golden_idx is not None else 0
    f2_hw = f2_golden_idx if f2_golden_idx is not None else 0
    L1_hw = power_to_hw(L1_golden) if L1_golden is not None else 0
    L2_hw = power_to_hw(L2_golden) if L2_golden is not None else 0
    
    valid = 1 if all(v is not None for v in [f1_golden_idx, f2_golden_idx, L1_golden, L2_golden]) else 0
    
    print(f"  Golden indices: f1_idx={f1_golden_idx}, f2_idx={f2_golden_idx}")
    
    return {
        'test_name': test_name,
        'num_accums': len(freqs_sorted),
        'freq_bins': freq_bins_hw,  # Bin indices 0-23
        'power_db': power_db_hw,
        'threshold_hw': threshold_hw,
        'expected_f1': f1_hw,
        'expected_f2': f2_hw,
        'expected_L1': L1_hw,
        'expected_L2': L2_hw,
        'expected_valid': valid,
        'golden_f1_idx': f1_golden_idx,  # Store as INDEX
        'golden_f2_idx': f2_golden_idx,  # Store as INDEX
        'golden_L1': L1_golden,
        'golden_L2': L2_golden
    }


def generate_synth_test_case(test_name, db_data, freq_bins, threshold_drop_db, 
                             accum_width, freq_bin_width, num_accums):
    """
    Generate synthetic test case with pre-defined power values.
    """
    print(f"\n=== Generating test case: {test_name} ===")
    
    freqs_sorted = freq_bins
    power_db_sorted = db_data
    
    # Calculate Absolute Threshold
    max_pwr = np.max(power_db_sorted)
    abs_threshold = max_pwr - threshold_drop_db
    if abs_threshold < 0:
        abs_threshold = 0
    
    # Find right edge
    f1_golden_freq, f2_golden_freq, L1_golden, L2_golden = find_right_edge_points(
        freqs_sorted, power_db_sorted, abs_threshold
    )
    
    if f1_golden_freq is not None:
        print(f"  Crossing found between {L1_golden:.2f} dB and {L2_golden:.2f} dB")
    
    # Generate frequency bin indices (0 to NUM_BINS-1)
    freq_bins_hw = list(range(len(freqs_sorted)))
    
    # Convert to hardware format
    power_db_hw = [int(p) & 0xFF for p in power_db_sorted]
    threshold_hw = int(abs_threshold) & 0xFF
    
    # Convert frequencies to indices
    def freq_to_index(freq_val):
        if freq_val is None:
            return None
        idx = np.where(np.isclose(freqs_sorted, freq_val))[0]
        if len(idx) > 0:
            return int(idx[0])
        return None
    
    def power_to_hw(power_val):
        if power_val is None:
            return None
        return int(power_val) & 0xFF
    
    # Convert golden frequencies to indices
    f1_golden_idx = freq_to_index(f1_golden_freq)
    f2_golden_idx = freq_to_index(f2_golden_freq)
    
    f1_hw = f1_golden_idx if f1_golden_idx is not None else 0
    f2_hw = f2_golden_idx if f2_golden_idx is not None else 0
    L1_hw = power_to_hw(L1_golden) if L1_golden is not None else 0
    L2_hw = power_to_hw(L2_golden) if L2_golden is not None else 0
    
    valid = 1 if all(v is not None for v in [f1_golden_idx, f2_golden_idx, L1_golden, L2_golden]) else 0
    
    print(f"  Golden indices: f1_idx={f1_golden_idx}, f2_idx={f2_golden_idx}")
    
    return {
        'test_name': test_name,
        'num_accums': len(freqs_sorted),
        'freq_bins': freq_bins_hw,  # Bin indices 0-23
        'power_db': power_db_hw,
        'threshold_hw': threshold_hw,
        'expected_f1': f1_hw,
        'expected_f2': f2_hw,
        'expected_L1': L1_hw,
        'expected_L2': L2_hw,
        'expected_valid': valid,
        'golden_f1_idx': f1_golden_idx,  # Store as INDEX
        'golden_f2_idx': f2_golden_idx,  # Store as INDEX
        'golden_L1': L1_golden,
        'golden_L2': L2_golden
    }


def write_vector_file(test_cases, output_path, accum_width, freq_bin_width):
    with open(output_path, 'w') as f:
        f.write("# Simulation vectors for find_bw_right_edge_absolute.sv\n")
        f.write("# Using complete_system_model functions (hardware-accurate)\n")
        f.write(f"# ACCUM_WIDTH = {accum_width} (Unsigned dB, no fractional bits)\n")
        f.write(f"# FREQ_BIN_WIDTH = {freq_bin_width} (5 bits for indices 0-23)\n")
        f.write("# Outputs are BIN INDICES, not frequency values\n")
        f.write("#\n")
        f.write("# Format per test case:\n")
        f.write("# TEST_NAME\n")
        f.write("# NUM_ACCUMS\n")
        f.write("# ABS_THRESHOLD (Calculated as Max - Drop)\n")
        f.write("# FREQ_BINS ... (bin indices 0-23 in hex)\n")
        f.write("# POWER_DB ... (hex, space-separated)\n")
        f.write("# EXPECTED f1_idx f2_idx L1 L2 valid (indices, not frequencies!)\n")
        f.write("# GOLDEN f1_idx f2_idx L1 L2 (indices for reference)\n")
        f.write("#\n\n")
        
        for tc in test_cases:
            f.write(f"{tc['test_name']}\n")
            f.write(f"{tc['num_accums']}\n")
            f.write(f"{tc['threshold_hw']}\n")
            
            # Write frequency bin indices (0-23) - 5 bits, use :02x
            for fb in tc['freq_bins']:
                f.write(f"{fb:02x} ")
            f.write("\n")
            
            # Write power values - 8 bits, use :02x
            for p in tc['power_db']:
                f.write(f"{p:02x} ")
            f.write("\n")
            
            f.write(f"{tc['expected_f1']:02x} {tc['expected_f2']:02x} {tc['expected_L1']:02x} "
                   f"{tc['expected_L2']:02x} {tc['expected_valid']}\n")
            
            # Write golden as INDICES, not frequencies
            if tc['golden_f1_idx'] is not None:
                f.write(f"GOLDEN {tc['golden_f1_idx']} {tc['golden_f2_idx']} "
                       f"{tc['golden_L1']} {tc['golden_L2']}\n")
            else:
                f.write(f"GOLDEN nan nan nan nan\n")
            
            f.write("\n")
    
    print(f"\nVectors written to: {output_path}")


def main():
    print("=== Generating Simulation Vectors for find_bw_right_edge_absolute.sv ===")
    print("Using complete_system_model functions (hardware-accurate)")
    print("Outputs: Bin indices instead of frequency values\n")
    
    ACCUM_WIDTH = 8  # Power in dB (unsigned, no fractional bits)
    FREQ_BIN_WIDTH = 5  # 5 bits for indices 0-23
    NUM_ACCUMS = 24
    
    test_cases = []
    
    if PICMUS_AVAILABLE:
        print("\n========== PICMUS Real Data Test Cases ==========")
        try:
            rf_path = SIMULATOR_ROOT.parent / "simulator/datasets/experiments/contrast_speckle/contrast_speckle_expe_dataset_rf.hdf5"
            iq_path = SIMULATOR_ROOT.parent / "simulator/datasets/experiments/contrast_speckle/contrast_speckle_expe_dataset_iq.hdf5"
            scan_path = SIMULATOR_ROOT.parent / "simulator/datasets/experiments/contrast_speckle/contrast_speckle_expe_scan.hdf5"
            
            adc_rate = 125e6
            baseline_decimation = 4
            
            rf_data, angles, _, _, fs_picmus, mod_freq, _, _, _ = load_picmus_rf_data(rf_path, iq_path, scan_path)
            center_angle_index = np.argmin(np.abs(angles))
            baseline_iq_data, _, fs_baseline = run_virtual_afe_processing(
                rf_data=rf_data, angle_index=center_angle_index, fs_picmus=fs_picmus,
                modulation_frequency=mod_freq, decimation_factor=baseline_decimation, adc_sample_rate=adc_rate
            )
            
            nperseg = 256
            hop = nperseg // 2
            
            delta_f = 0.25e6
            half_bw_est = mod_freq / 2
            s_coarse = np.linspace(-mod_freq, mod_freq, 8)
            s_fine_left = np.linspace(-half_bw_est - delta_f, -half_bw_est + delta_f, 8)
            s_fine_right = np.linspace(half_bw_est - delta_f, half_bw_est + delta_f, 8)
            S_bins = np.unique(np.concatenate([s_coarse, s_fine_left, s_fine_right]))
            
            threshold_drop = 30  # 30 dB drop
            
            test_configs = [
                ("picmus_ch64_win29", 64, 29),
                ("picmus_ch64_win15", 64, 15),
                ("picmus_ch64_win27", 64, 27),
            ]
            
            for test_name, channel, window_num in test_configs:
                start_sample = window_num * hop
                end_sample = start_sample + nperseg
                time_window_data = baseline_iq_data[start_sample:end_sample, channel]
                
                tc = generate_test_case(
                    test_name, time_window_data, fs_baseline, S_bins, threshold_drop,
                    ACCUM_WIDTH, FREQ_BIN_WIDTH, NUM_ACCUMS
                )
                test_cases.append(tc)

            # Synthetic Test Case
            # High power in middle-right for right edge finding
            db_data = np.full(len(S_bins), 20.0)
            db_data[-4:-1] = 90.0  # High power in right side
            db_data[13:16] = 90.0  # High power in middle-right
            
            tc = generate_synth_test_case(
                "synth_test_1", db_data, S_bins, threshold_drop,
                ACCUM_WIDTH, FREQ_BIN_WIDTH, NUM_ACCUMS
            )
            test_cases.append(tc)
                
        except Exception as e:
            print(f"Error loading PICMUS data: {e}")
            import traceback
            traceback.print_exc()

    output_dir = SIMULATOR_ROOT.parent / "rtl" / "simvectors"
    output_dir.mkdir(parents=True, exist_ok=True)
    output_path = output_dir / "find_bw_right_edge_vectors_absolute.txt"
    
    write_vector_file(test_cases, output_path, ACCUM_WIDTH, FREQ_BIN_WIDTH)
    print(f"\n=== Successfully generated {len(test_cases)} test cases ===")

if __name__ == "__main__":
    main()