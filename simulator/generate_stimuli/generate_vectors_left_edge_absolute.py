"""
Generate simulation vectors for find_bw_left_edge.sv module
Updated to use ABSOLUTE power values (Unsigned) to match hardware architecture.
"""
import numpy as np
from scipy import signal
from pathlib import Path
import sys

# Add parent directory to path to import golden model
SIMULATOR_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SIMULATOR_ROOT / "src"))

# We import the search function, but we will redefine the power conversion locally
# to ensure it behaves exactly as we want (Absolute, not normalized).
from golden_model_floating_point import (
    streaming_dft_processor,
    find_left_edge_points
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

# --- Local Helper: Absolute Power Conversion ---
def convert_to_sorted_db_power_absolute(dft_bins):
    """
    Converts complex accumulator values to sorted, ABSOLUTE dB power.
    Does NOT normalize to 0 dB.
    """
    freqs = np.array(list(dft_bins.keys()))
    accumulators = np.array(list(dft_bins.values()))
    
    # Calculate Magnitude Squared
    powers = np.abs(accumulators)**2
    if np.max(powers) == 0: 
        return freqs, np.zeros_like(powers) # Return 0s if empty
    
    # Convert to dB: 10 * log10(P)
    # Add epsilon to avoid log(0)
    power_db = 10 * np.log10(powers + 1e-20)
    
    # Clamp negative values to 0 (Hardware is unsigned)
    # Realistically, 16-bit inputs won't produce negative 10*log10 unless P < 1.
    power_db = np.maximum(power_db, 0.0)
    
    # Sort by frequency
    sort_indices = np.argsort(freqs)
    freqs_sorted = freqs[sort_indices]
    power_db_sorted = power_db[sort_indices]
    
    return freqs_sorted, power_db_sorted

def generate_test_case(test_name, iq_data, fs, freq_bins, threshold_drop_db, 
                       accum_width, freq_bin_width, num_accums):
    """
    Generate a single test case using Absolute Power logic.
    """
    print(f"\n=== Generating test case: {test_name} ===")
    
    # 1. Run DFT
    dft_bins = streaming_dft_processor(iq_data, fs, freq_bins, window='hann')
    
    # 2. Convert to Absolute dB (e.g., 80 dB, 90 dB...)
    freqs_sorted, power_db_sorted = convert_to_sorted_db_power_absolute(dft_bins)
    
    # 3. Calculate Absolute Threshold
    # Hardware logic: Threshold = Max_Power - Drop
    max_pwr = np.max(power_db_sorted)
    abs_threshold = max_pwr - threshold_drop_db
    
    # Clamp threshold to 0 if negative (though unlikely with proper signals)
    if abs_threshold < 0: abs_threshold = 0
    
    # 4. Find Edge using Absolute Threshold
    f1_golden, f2_golden, L1_golden, L2_golden = find_left_edge_points(
        freqs_sorted, power_db_sorted, threshold_db=abs_threshold
    )
    
    print(f"Golden model results (Absolute dB):")
    print(f"  Max Power: {max_pwr:.2f} dB")
    print(f"  Drop: {threshold_drop_db} dB -> Abs Threshold: {abs_threshold:.2f} dB")
    
    if f1_golden is not None:
        print(f"  Crossing found between {L1_golden:.2f} dB and {L2_golden:.2f} dB")
    else:
        print(f"  No crossing found!")
    
    # 5. Convert to Hardware Fixed Point
    
    # Frequency: Q(int).12 (e.g. +/- 8 MHz range)
    freq_frac_bits = 12
    freq_int_bits = freq_bin_width - freq_frac_bits
    
    freq_bins_hw = []
    for f in freqs_sorted:
        f_mhz = f / 1e6
        fixed_val = float_to_fixed_point(f_mhz, freq_int_bits, freq_frac_bits, signed=True)
        freq_bins_hw.append(fixed_val)
    
    # Power: Unsigned Q(int).8
    # e.g. 18 bit width -> 10 integer bits (0..1023 dB), 8 fractional bits
    power_frac_bits = 8
    power_int_bits = accum_width - power_frac_bits
    
    power_db_hw = [float_to_fixed_point(p, power_int_bits, power_frac_bits, signed=False) 
                   for p in power_db_sorted]
                   
    # Threshold for HW input
    threshold_hw = float_to_fixed_point(abs_threshold, power_int_bits, power_frac_bits, signed=False)
    
    # Expected Outputs
    f1_hw = float_to_fixed_point(f1_golden / 1e6, freq_int_bits, freq_frac_bits, signed=True) if f1_golden is not None else 0
    f2_hw = float_to_fixed_point(f2_golden / 1e6, freq_int_bits, freq_frac_bits, signed=True) if f2_golden is not None else 0
    L1_hw = float_to_fixed_point(L1_golden, power_int_bits, power_frac_bits, signed=False) if L1_golden is not None else 0
    L2_hw = float_to_fixed_point(L2_golden, power_int_bits, power_frac_bits, signed=False) if L2_golden is not None else 0
    
    valid = 1 if all(v is not None for v in [f1_golden, f2_golden, L1_golden, L2_golden]) else 0
    
    return {
        'test_name': test_name,
        'num_accums': len(freqs_sorted),
        'freq_bins': freq_bins_hw,
        'power_db': power_db_hw,
        'threshold_hw': threshold_hw, # Writing the calculated ABSOLUTE threshold
        'expected_f1': f1_hw,
        'expected_f2': f2_hw,
        'expected_L1': L1_hw,
        'expected_L2': L2_hw,
        'expected_valid': valid,
        'golden_f1': f1_golden,
        'golden_f2': f2_golden,
        'golden_L1': L1_golden,
        'golden_L2': L2_golden
    }

def generate_synth_test_case(test_name, iq_data, db_data, fs, freq_bins, threshold_drop_db, 
                       accum_width, freq_bin_width, num_accums):
    """
    Generate synthetic test case. db_data must be absolute.
    """
    print(f"\n=== Generating test case: {test_name} ===")
    
    freqs_sorted = freq_bins # Assuming already sorted for synth
    power_db_sorted = db_data
    
    # Calculate Absolute Threshold
    max_pwr = np.max(power_db_sorted)
    abs_threshold = max_pwr - threshold_drop_db
    if abs_threshold < 0: abs_threshold = 0
    
    f1_golden, f2_golden, L1_golden, L2_golden = find_left_edge_points(
        freqs_sorted, power_db_sorted, threshold_db=abs_threshold
    )
    
    # ... (Same conversion logic as above) ...
    freq_frac_bits = 12
    freq_int_bits = freq_bin_width - freq_frac_bits
    
    freq_bins_hw = []
    for f in freqs_sorted:
        f_mhz = f / 1e6
        fixed_val = float_to_fixed_point(f_mhz, freq_int_bits, freq_frac_bits, signed=True)
        freq_bins_hw.append(fixed_val)
    
    power_frac_bits = 8
    power_int_bits = accum_width - power_frac_bits
    
    power_db_hw = [float_to_fixed_point(p, power_int_bits, power_frac_bits, signed=False) 
                   for p in power_db_sorted]
    
    threshold_hw = float_to_fixed_point(abs_threshold, power_int_bits, power_frac_bits, signed=False)
    
    f1_hw = float_to_fixed_point(f1_golden / 1e6, freq_int_bits, freq_frac_bits, signed=True) if f1_golden is not None else 0
    f2_hw = float_to_fixed_point(f2_golden / 1e6, freq_int_bits, freq_frac_bits, signed=True) if f2_golden is not None else 0
    L1_hw = float_to_fixed_point(L1_golden, power_int_bits, power_frac_bits, signed=False) if L1_golden is not None else 0
    L2_hw = float_to_fixed_point(L2_golden, power_int_bits, power_frac_bits, signed=False) if L2_golden is not None else 0
    
    valid = 1 if all(v is not None for v in [f1_golden, f2_golden, L1_golden, L2_golden]) else 0
    
    return {
        'test_name': test_name,
        'num_accums': len(freqs_sorted),
        'freq_bins': freq_bins_hw,
        'power_db': power_db_hw,
        'threshold_hw': threshold_hw,
        'expected_f1': f1_hw,
        'expected_f2': f2_hw,
        'expected_L1': L1_hw,
        'expected_L2': L2_hw,
        'expected_valid': valid,
        'golden_f1': f1_golden,
        'golden_f2': f2_golden,
        'golden_L1': L1_golden,
        'golden_L2': L2_golden
    }

def write_vector_file(test_cases, output_path, accum_width, freq_bin_width):
    with open(output_path, 'w') as f:
        f.write("# Simulation vectors for find_bw_left_edge.sv (ABSOLUTE THRESHOLD)\n")
        f.write(f"# ACCUM_WIDTH = {accum_width} (Unsigned Q10.8 dB)\n")
        f.write(f"# FREQ_BIN_WIDTH = {freq_bin_width}\n")
        f.write("#\n")
        f.write("# Format per test case:\n")
        f.write("# TEST_NAME\n")
        f.write("# NUM_ACCUMS\n")
        f.write("# ABS_THRESHOLD (Calculated as Max - Drop)\n")
        f.write("# FREQ_BINS ...\n")
        f.write("# POWER_DB ...\n")
        f.write("# EXPECTED ...\n")
        f.write("# GOLDEN ...\n\n")
        
        for tc in test_cases:
            f.write(f"{tc['test_name']}\n")
            f.write(f"{tc['num_accums']}\n")
            f.write(f"{tc['threshold_hw']}\n") # Writing the CALCULATED ABS threshold
            
            for fb in tc['freq_bins']:
                f.write(f"{fb:03x} ")
            f.write("\n")
            
            for p in tc['power_db']:
                f.write(f"{p:04x} ")
            f.write("\n")
            
            f.write(f"{tc['expected_f1']:03x} {tc['expected_f2']:03x} {tc['expected_L1']:04x} "
                   f"{tc['expected_L2']:04x} {tc['expected_valid']}\n")
            
            if tc['golden_f1'] is not None:
                f.write(f"GOLDEN {tc['golden_f1']/1e6:.6f} {tc['golden_f2']/1e6:.6f} "
                       f"{tc['golden_L1']:.6f} {tc['golden_L2']:.6f}\n")
            else:
                f.write(f"GOLDEN nan nan nan nan\n")
            
            f.write("\n")

def main():
    print("=== Generating Simulation Vectors for find_bw_left_edge.sv ===\n")
    
    ACCUM_WIDTH = 18
    FREQ_BIN_WIDTH = 16
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
            
            # Use 30 dB relative drop
            threshold_drop = 30 
            
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

            # ===== Synthethic Test Case ===== 
            # Shifted to positive values to match hardware behavior
            # Noise floor ~20dB, Signal ~90dB
            db_data = np.full(len(S_bins), 20.0) 
            db_data[1:4] = 90.0 # High power in middle-left (for left edge finding)
            
            tc = generate_synth_test_case(
                "synth_test_1", None, db_data, fs_baseline, S_bins, threshold_drop,
                ACCUM_WIDTH, FREQ_BIN_WIDTH, NUM_ACCUMS
            )
            test_cases.append(tc)
                
        except Exception as e:
            print(f"Error loading PICMUS data: {e}")
            import traceback
            traceback.print_exc()

    output_dir = SIMULATOR_ROOT.parent / "rtl" / "simvectors"
    output_dir.mkdir(parents=True, exist_ok=True)
    output_path = output_dir / "find_bw_left_edge_vectors_absolute.txt"
    
    write_vector_file(test_cases, output_path, ACCUM_WIDTH, FREQ_BIN_WIDTH)
    print(f"\n=== Successfully generated {len(test_cases)} test cases ===")

if __name__ == "__main__":
    main()