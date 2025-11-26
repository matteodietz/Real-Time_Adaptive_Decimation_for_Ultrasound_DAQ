"""
Generate simulation vectors for find_bw_right_edge.sv module
"""
import numpy as np
from scipy import signal
from pathlib import Path
import sys

# Add parent directory to path to import golden model
SIMULATOR_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SIMULATOR_ROOT / "src"))

# --- CHANGE 1: Import the Right Edge function ---
from golden_model_floating_point import (
    streaming_dft_processor,
    convert_to_sorted_db_power,
    find_right_edge_points  # <--- CHANGED FROM LEFT TO RIGHT
)

from fixed_float_conversions import float_to_fixed_point, fixed_point_to_float

# Import data loading functions
try:
    from afe_interface_rf import load_picmus_rf_data
    from virtual_afe import run_virtual_afe_processing
    PICMUS_AVAILABLE = True
except ImportError:
    print("Warning: PICMUS data loading modules not available. Skipping real data tests.")
    PICMUS_AVAILABLE = False

def generate_test_case(test_name, iq_data, fs, freq_bins, threshold_db, 
                       accum_width, freq_bin_width, num_accums):
    """
    Generate a single test case for the RIGHT edge finder.
    """
    print(f"\n=== Generating test case: {test_name} ===")
    
    # Run golden model
    dft_bins = streaming_dft_processor(iq_data, fs, freq_bins, window='hann')
    freqs_sorted, power_db_norm_sorted = convert_to_sorted_db_power(dft_bins)
    
    # --- CHANGE 2: Call Right Edge Finder ---
    f1_golden, f2_golden, L1_golden, L2_golden = find_right_edge_points(
        freqs_sorted, power_db_norm_sorted, threshold_db=threshold_db
    )
    
    print(f"Golden model results:")
    print(f"  Number of frequency bins: {len(freqs_sorted)}")
    if f1_golden is not None:
        print(f"  f1 = {f1_golden/1e6:.6f} MHz, f2 = {f2_golden/1e6:.6f} MHz")
        print(f"  L1 = {L1_golden:.3f} dB, L2 = {L2_golden:.3f} dB")
        print(f"  Right Bandwidth edge at: {f1_golden/1e6:.6f} MHz")
    else:
        print(f"  No crossing found!")
    
    # Convert to fixed point for hardware
    freq_frac_bits = 12
    freq_int_bits = freq_bin_width - freq_frac_bits
    
    freq_bins_hw = []
    for f in freqs_sorted:
        f_mhz = f / 1e6
        fixed_val = float_to_fixed_point(f_mhz, freq_int_bits, freq_frac_bits, signed=True)
        freq_bins_hw.append(fixed_val)
    
    power_frac_bits = 8
    power_int_bits = accum_width - power_frac_bits
    power_db_hw = [float_to_fixed_point(p, power_int_bits, power_frac_bits, signed=True) 
                   for p in power_db_norm_sorted]
    
    f1_hw = float_to_fixed_point(f1_golden / 1e6, freq_int_bits, freq_frac_bits, signed=True) if f1_golden is not None else 0
    f2_hw = float_to_fixed_point(f2_golden / 1e6, freq_int_bits, freq_frac_bits, signed=True) if f2_golden is not None else 0
    L1_hw = float_to_fixed_point(L1_golden, power_int_bits, power_frac_bits, signed=True) if L1_golden is not None else 0
    L2_hw = float_to_fixed_point(L2_golden, power_int_bits, power_frac_bits, signed=True) if L2_golden is not None else 0
    
    valid = 1 if all(v is not None for v in [f1_golden, f2_golden, L1_golden, L2_golden]) else 0
    
    return {
        'test_name': test_name,
        'num_accums': len(freqs_sorted),
        'freq_bins': freq_bins_hw,
        'power_db': power_db_hw,
        'threshold_db': threshold_db,
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

def generate_synth_test_case(test_name, iq_data, db_data, fs, freq_bins, threshold_db, 
                       accum_width, freq_bin_width, num_accums):
    """
    Generate a single synthetic test case for the RIGHT edge finder.
    """
    print(f"\n=== Generating test case: {test_name} ===")
    
    # Run golden model
    dft_bins = streaming_dft_processor(iq_data, fs, freq_bins, window='hann')
    freqs_sorted, power_db_norm_sorted = convert_to_sorted_db_power(dft_bins)
    
    # --- CHANGE 3: Call Right Edge Finder ---
    f1_golden, f2_golden, L1_golden, L2_golden = find_right_edge_points(
        freqs_sorted, db_data, threshold_db=threshold_db
    )
    
    print(f"Golden model results:")
    if f1_golden is not None:
        print(f"  f1 = {f1_golden/1e6:.6f} MHz, f2 = {f2_golden/1e6:.6f} MHz")
        print(f"  L1 = {L1_golden:.3f} dB, L2 = {L2_golden:.3f} dB")
    else:
        print(f"  No crossing found!")
    
    # Convert to fixed point
    freq_frac_bits = 12
    freq_int_bits = freq_bin_width - freq_frac_bits
    
    freq_bins_hw = []
    for f in freqs_sorted:
        f_mhz = f / 1e6
        fixed_val = float_to_fixed_point(f_mhz, freq_int_bits, freq_frac_bits, signed=True)
        freq_bins_hw.append(fixed_val)
    
    power_frac_bits = 8
    power_int_bits = accum_width - power_frac_bits
    power_db_hw = [float_to_fixed_point(p, power_int_bits, power_frac_bits, signed=True) 
                   for p in db_data]
    
    f1_hw = float_to_fixed_point(f1_golden / 1e6, freq_int_bits, freq_frac_bits, signed=True) if f1_golden is not None else 0
    f2_hw = float_to_fixed_point(f2_golden / 1e6, freq_int_bits, freq_frac_bits, signed=True) if f2_golden is not None else 0
    L1_hw = float_to_fixed_point(L1_golden, power_int_bits, power_frac_bits, signed=True) if L1_golden is not None else 0
    L2_hw = float_to_fixed_point(L2_golden, power_int_bits, power_frac_bits, signed=True) if L2_golden is not None else 0
    
    valid = 1 if all(v is not None for v in [f1_golden, f2_golden, L1_golden, L2_golden]) else 0
    
    return {
        'test_name': test_name,
        'num_accums': len(freqs_sorted),
        'freq_bins': freq_bins_hw,
        'power_db': power_db_hw,
        'threshold_db': threshold_db,
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
    """
    Write test vectors to file.
    """
    with open(output_path, 'w') as f:
        # --- CHANGE 4: Update Header Info ---
        f.write("# Simulation vectors for find_bw_right_edge.sv\n")
        f.write(f"# ACCUM_WIDTH = {accum_width}\n")
        f.write(f"# FREQ_BIN_WIDTH = {freq_bin_width}\n")
        f.write("#\n")
        f.write("# Frequency representation: Q{}.{} fixed-point in MHz\n".format(
            freq_bin_width - 6, 6))
        f.write("# Power representation: Q{}.{} fixed-point in dB\n".format(
            accum_width - 8, 8))
        f.write("#\n")
        f.write("# Format per test case:\n")
        f.write("# TEST_NAME <n>\n")
        f.write("# NUM_ACCUMS <n>\n")
        f.write("# THRESHOLD_DB <value>\n")
        f.write("# FREQ_BINS <n values in hex> (frequencies in MHz)\n")
        f.write("# POWER_DB <n values in hex> (power in dB normalized)\n")
        f.write("# EXPECTED f1 f2 L1 L2 valid (all in hex)\n")
        f.write("# GOLDEN f1 f2 L1 L2 (floating point in MHz and dB for reference)\n")
        f.write("#\n\n")
        
        for tc in test_cases:
            f.write(f"{tc['test_name']}\n")
            f.write(f"{tc['num_accums']}\n")
            f.write(f"{tc['threshold_db']}\n")
            
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
    print("=== Generating Simulation Vectors for find_bw_right_edge.sv ===\n")
    
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
                rf_data=rf_data,
                angle_index=center_angle_index,
                fs_picmus=fs_picmus,
                modulation_frequency=mod_freq,
                decimation_factor=baseline_decimation,
                adc_sample_rate=adc_rate
            )
            
            nperseg = 256
            hop = nperseg // 2
            
            delta_f = 0.25e6
            half_bw_est = mod_freq / 2
            s_coarse = np.linspace(-mod_freq, mod_freq, 8)
            s_fine_left = np.linspace(-half_bw_est - delta_f, -half_bw_est + delta_f, 8)
            s_fine_right = np.linspace(half_bw_est - delta_f, half_bw_est + delta_f, 8)
            S_bins = np.unique(np.concatenate([s_coarse, s_fine_left, s_fine_right]))
            
            threshold_db = -30
            
            test_configs = [
                ("picmus_ch64_win29", 64, 29),
                ("picmus_ch64_win15", 64, 15),
                ("picmus_ch64_win27", 64, 27),
                ("picmus_ch64_win31", 96, 31),
                ("picmus_ch32_win29", 32, 29),
            ]
            
            for test_name, channel, window_num in test_configs:
                print(f"\n--- Processing {test_name}: Channel {channel}, Window {window_num} ---")
                
                start_sample = window_num * hop
                end_sample = start_sample + nperseg
                time_window_data = baseline_iq_data[start_sample:end_sample, channel]
                
                tc = generate_test_case(
                    test_name,
                    time_window_data,
                    fs_baseline,
                    S_bins,
                    threshold_db,
                    ACCUM_WIDTH,
                    FREQ_BIN_WIDTH,
                    NUM_ACCUMS
                )
                test_cases.append(tc)

            # ===== Synthetic Test Case ===== 
            synth_test_config = [
                ("synth_test_1", 64, 29),
            ]

            for test_name, channel, window_num in synth_test_config:
                print(f"\n=== Generating SYNTHETIC test with multiple threshold crossings ===")

                start_sample = window_num * hop
                end_sample = start_sample + nperseg
                time_window_data = baseline_iq_data[start_sample:end_sample, channel]

                # Reuse the same synthetic data shape (Pulse in middle)
                # It is valid for Right edge too (it will find the falling edge on the right)
                db_data = np.zeros(len(S_bins))
                db_data[0] = -40
                db_data[3] = -40
                db_data[4] = -40
                db_data[5] = -40
                db_data[-1] = -40
                db_data[-4] = -40
                db_data[-5] = -40
                db_data[-6] = -40

                tc = generate_synth_test_case(
                    test_name,
                    time_window_data,
                    db_data,
                    fs_baseline,
                    S_bins,
                    threshold_db,
                    ACCUM_WIDTH,
                    FREQ_BIN_WIDTH,
                    NUM_ACCUMS
                )
                test_cases.append(tc)
                
        except Exception as e:
            print(f"Error loading PICMUS data: {e}")
            import traceback
            traceback.print_exc()

    # Write to file
    output_dir = SIMULATOR_ROOT.parent / "rtl" / "simvectors"
    output_dir.mkdir(parents=True, exist_ok=True)
    # --- CHANGE 5: Updated Output Filename ---
    output_path = output_dir / "find_bw_right_edge_vectors.txt"
    
    write_vector_file(test_cases, output_path, ACCUM_WIDTH, FREQ_BIN_WIDTH)
    
    print(f"\n=== Successfully generated {len(test_cases)} test cases ===")
    print(f"Output file: {output_path}")

if __name__ == "__main__":
    main()