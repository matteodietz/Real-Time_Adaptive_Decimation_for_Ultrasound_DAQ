"""
Generate simulation vectors for bandwidth_edge_detector.sv module.

Target Module: bandwidth_edge_detector
Inputs:  Array of dB Power Values (Fixed Point), Array of Frequency Bins
Outputs: Left Edge (f1, f2, L1, L2), Right Edge (f1, f2, L1, L2)

This script generates the Power Spectrum inputs by running the pre-requisite
signal processing steps (DFT + Power Conversion) in software.
"""
import numpy as np
from scipy import signal
from pathlib import Path
import sys

# 1. Setup Paths
SIMULATOR_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SIMULATOR_ROOT / "src"))

# 2. Imports
try:
    from fixed_float_conversions import float_to_fixed_point
    from complete_system_model import (
        streaming_dft_processor,
        convert_to_hardware_db_power,
        calc_hardware_threshold,
        find_left_edge_hw,
        find_right_edge_points # Using the function name from your model
    )
except ImportError as e:
    print(f"Error importing models: {e}")
    sys.exit(1)

try:
    from afe_interface_rf import load_picmus_rf_data
    from virtual_afe import run_virtual_afe_processing
    PICMUS_AVAILABLE = True
except ImportError:
    print("Warning: PICMUS data loading modules not available.")
    PICMUS_AVAILABLE = False

def generate_test_case_edge_det(test_name, iq_data_raw, fs, freq_bins, threshold_drop_db,
                                iq_width, accum_width, 
                                power_width, power_frac, 
                                freq_bin_width):
    """
    Generates a single test case for the Bandwidth Edge Detector.
    """
    print(f"\n=== Generating test case: {test_name} ===")
    
    # -------------------------------------------------------------------------
    # 1. Pre-Processing (Emulating the previous hardware stages)
    # -------------------------------------------------------------------------
    
    # Scale Input to full range (Crucial for valid dB values)
    iq_frac_bits = 14
    max_val = np.max(np.abs(iq_data_raw))
    scale_factor = 1.5 / max_val if max_val > 0 else 1.0
    iq_data_scaled = iq_data_raw * scale_factor
    
    # Run DFT
    dft_bins = streaming_dft_processor(iq_data_scaled, fs, freq_bins, window='hann')
    
    # Run Power Conversion
    # The output 'power_hw_db' is the INPUT STIMULUS for our DUT
    freqs_sorted, power_hw_db = convert_to_hardware_db_power(
        dft_bins, accum_width=accum_width, accum_frac=40, 
        power_width=power_width, power_frac=power_frac
    )
    
    print(f"  Max Power (Input to DUT): {np.max(power_hw_db)} (Fixed Point)")

    # -------------------------------------------------------------------------
    # 2. Run DUT Logic Model (Golden Reference)
    # -------------------------------------------------------------------------
    
    # TODO: this is not needed since complete system model takes float threshold db (positive) not fixed
    # Convert Threshold Drop to Fixed Point Integer
    # thresh_drop_int = int(threshold_drop_db * (2**power_frac))
    
    # A. Calculate Threshold (Internal to DUT)
    max_pwr, abs_threshold = calc_hardware_threshold(power_hw_db, thresh_drop_db)
    print(f"  Calculated Threshold: {abs_threshold}")
    
    # B. Find Left Edge
    f1_L, f2_L, L1_L, L2_L = find_left_edge_hw(freqs_sorted, power_hw_db, abs_threshold)
    
    # C. Find Right Edge
    f1_R, f2_R, L1_R, L2_R = find_right_edge_points(freqs_sorted, power_hw_db, abs_threshold)
    
    if f1_L is not None and f1_R is not None:
        print(f"  Edges Found at bins: {f1_L/1e6:.2f}MHz / {f1_R/1e6:.2f}MHz")
    else:
        print("  Edges NOT Found")

    # -------------------------------------------------------------------------
    # 3. Format Stimuli (Inputs to DUT)
    # -------------------------------------------------------------------------
    
    # Config: Frequency Bins
    # Assuming Q(int).12 format for MHz representation inside the 32-bit word
    fb_frac = 12 
    fb_int = freq_bin_width - fb_frac
    
    freq_bins_hw = []
    
    for f_hz in freqs_sorted:
        f_mhz = f_hz / 1e6
        fb_val = float_to_fixed_point(f_mhz, fb_int, fb_frac, signed=True)
        freq_bins_hw.append(fb_val)
        
    # Power Values (Already integers from convert_to_hardware_db_power)
    # Just ensure they are masked to width
    # power_vals_hw = [int(p) & ((1<<power_width)-1) for p in power_hw_db]

    # -------------------------------------------------------------------------
    # 4. Format Expectations (Outputs from DUT)
    # -------------------------------------------------------------------------
    
    def fix_freq(f): 
        if f is None: return 0
        return float_to_fixed_point(f/1e6, fb_int, fb_frac, signed=True)
    
    def fix_pwr(p): 
        if p is None: return 0
        return int(p) & ((1<<power_width)-1)

    return {
        'test_name': test_name,
        'K': len(freq_bins),
        'power_vals_hw': power_vals_hw,
        'freq_bins_hw': freq_bins_hw,
        # Expected Output: Left
        'exp_f1_L': fix_freq(f1_L), 'exp_f2_L': fix_freq(f2_L),
        'exp_L1_L': fix_pwr(L1_L),  'exp_L2_L': fix_pwr(L2_L),
        # Expected Output: Right
        'exp_f1_R': fix_freq(f1_R), 'exp_f2_R': fix_freq(f2_R),
        'exp_L1_R': fix_pwr(L1_R),  'exp_L2_R': fix_pwr(L2_R),
        # Valid
        'valid_expect': 1 if (f1_L is not None and f1_R is not None) else 0
    }

def write_vector_file(test_cases, output_path):
    with open(output_path, 'w') as f:
        f.write("# Simulation vectors for bandwidth_edge_detector.sv\n")
        f.write("# Format:\n")
        f.write("# TEST_NAME\n")
        f.write("# NUM_BINS\n")
        f.write("# FREQ_BINS (Array)\n")
        f.write("# POWER_VALS (Array)\n")
        f.write("# EXPECTED VALID\n")
        f.write("# EXPECTED LEFT (f1 f2 L1 L2)\n")
        f.write("# EXPECTED RIGHT (f1 f2 L1 L2)\n\n")
        
        for tc in test_cases:
            f.write(f"{tc['test_name']}\n")
            f.write(f"{tc['K']}\n")
            
            # 1. Frequency Bins Input
            for fb in tc['freq_bins_hw']: f.write(f"{fb:08x} ")
            f.write("\n")
            
            # 2. Power Values Input
            for p in tc['power_vals_hw']: f.write(f"{p:08x} ")
            f.write("\n")
            
            # 3. Expected Valid
            f.write(f"{tc['valid_expect']}\n")
            
            # 4. Expected Left Edge
            f.write(f"{tc['exp_f1_L']:08x} {tc['exp_f2_L']:08x} {tc['exp_L1_L']:08x} {tc['exp_L2_L']:08x}\n")
            
            # 5. Expected Right Edge
            f.write(f"{tc['exp_f1_R']:08x} {tc['exp_f2_R']:08x} {tc['exp_L1_R']:08x} {tc['exp_L2_R']:08x}\n")
            
            f.write("\n")

def main():
    print("=== Generating Edge Detector Stimuli ===\n")
    
    # --- Hardware Parameters (Must Match DUT) ---
    IQ_WIDTH = 16
    WINDOW_WIDTH = 16
    ACCUM_WIDTH = 48 
    POWER_WIDTH = 32
    POWER_FRAC = 16
    FREQ_BIN_WIDTH = 32 # Updated to match your module definition
    
    THRESHOLD_DROP_DB = 30.0
    
    test_cases = []
    
    if PICMUS_AVAILABLE:
        try:
            print("Loading PICMUS...")
            rf_path = SIMULATOR_ROOT.parent / "simulator/datasets/experiments/contrast_speckle/contrast_speckle_expe_dataset_rf.hdf5"
            iq_path = SIMULATOR_ROOT.parent / "simulator/datasets/experiments/contrast_speckle/contrast_speckle_expe_dataset_iq.hdf5"
            scan_path = SIMULATOR_ROOT.parent / "simulator/datasets/experiments/contrast_speckle/contrast_speckle_expe_scan.hdf5"
            
            rf_data, angles, _, _, fs_picmus, mod_freq, _, _, _ = load_picmus_rf_data(rf_path, iq_path, scan_path)
            
            adc_rate = 125e6
            baseline_decimation = 4
            
            # Bins Definition
            delta_f = 0.25e6
            half_bw_est = mod_freq / 2
            s_coarse = np.linspace(-mod_freq, mod_freq, 8)
            s_fine_left = np.linspace(-half_bw_est - delta_f, -half_bw_est + delta_f, 8)
            s_fine_right = np.linspace(half_bw_est - delta_f, half_bw_est + delta_f, 8)
            S_bins = np.unique(np.concatenate([s_coarse, s_fine_left, s_fine_right]))
            
            configs = [
                ("picmus_ang0_ch64_win29", 64, np.argmin(np.abs(angles)), 29),
                ("picmus_ang0_ch32_win15", 32, np.argmin(np.abs(angles)), 15),
                ("picmus_ang0_ch96_win30", 96, np.argmin(np.abs(angles)), 30),
            ]
            
            processed_angles = {}
            nperseg = 256
            hop = nperseg // 2

            for name, ch, ang_idx, win_idx in configs:
                if ang_idx not in processed_angles:
                    print(f"  Running AFE for Angle {ang_idx}...")
                    iq_data_angle, _, fs_base = run_virtual_afe_processing(
                        rf_data=rf_data, angle_index=ang_idx, fs_picmus=fs_picmus,
                        modulation_frequency=mod_freq, decimation_factor=baseline_decimation,
                        adc_sample_rate=adc_rate
                    )
                    processed_angles[ang_idx] = (iq_data_angle, fs_base)
                
                baseline_iq_data, fs_baseline = processed_angles[ang_idx]
                
                start = win_idx * hop
                end = start + nperseg
                if end > baseline_iq_data.shape[0]: continue
                
                time_window = baseline_iq_data[start:end, ch]
                
                tc = generate_test_case_edge_det(
                    name, time_window, fs_baseline, S_bins, THRESHOLD_DROP_DB,
                    IQ_WIDTH, ACCUM_WIDTH, 
                    POWER_WIDTH, POWER_FRAC,
                    FREQ_BIN_WIDTH
                )
                test_cases.append(tc)
                
        except Exception as e:
            print(f"Error: {e}")
            import traceback
            traceback.print_exc()

    # Write Output
    output_dir = SIMULATOR_ROOT.parent / "rtl" / "simvectors"
    output_dir.mkdir(parents=True, exist_ok=True)
    output_path = output_dir / "edge_detector_vectors.txt"
    
    write_vector_file(test_cases, output_path)
    print(f"\nStimuli generated at: {output_path}")

if __name__ == "__main__":
    main()