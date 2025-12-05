"""
Generate simulation vectors for dft_bandwidth_analysis_top.sv module.
Uses Real PICMUS Data + Synthetic Hardware-Accurate Golden Model.

Outputs raw edge points (f1, f2, L1, L2)
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
        find_right_edge_points,
        linear_interpolate_hw
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

def generate_test_case_top(test_name, iq_data_raw, fs, freq_bins, threshold_drop_db,
                           iq_width, window_width, accum_width, 
                           power_width, power_frac, 
                           freq_bin_width, freq_interp_width, freq_interp_frac,
                           phase_width):
    """
    Generates a single test case for the Top Level Module.
    """
    print(f"\n=== Generating test case: {test_name} ===")
    
    N = len(iq_data_raw)
    K = len(freq_bins)
    
    # -------------------------------------------------------------------------
    # 1. Input Scaling (Critical for Hardware Fixed Point)
    # -------------------------------------------------------------------------
    iq_frac_bits = 14
    iq_int_bits = iq_width - iq_frac_bits 
    
    max_val = np.max(np.abs(iq_data_raw))
    scale_factor = 1.5 / max_val if max_val > 0 else 1.0
    iq_data_scaled = iq_data_raw * scale_factor
    
    print(f"  Input Peak (Raw): {max_val:.2e} -> Scaled: {np.max(np.abs(iq_data_scaled)):.2f}")

    # -------------------------------------------------------------------------
    # 2. Run Hardware-Accurate Pipeline
    # -------------------------------------------------------------------------
    
    # A. DFT
    dft_bins = streaming_dft_processor(iq_data_scaled, fs, freq_bins, window='hann')
    
    # B. Power Conversion
    freqs_sorted, power_hw_db = convert_to_hardware_db_power(
        dft_bins, accum_width=accum_width, accum_frac=40, 
        power_width=power_width, power_frac=power_frac
    )
    
    # C. Threshold Calculation
    # thresh_drop_int = int(threshold_drop_db * (2**power_frac))
    max_pwr, abs_threshold = calc_hardware_threshold(power_hw_db, thresh_drop_db)
    
    # D. Left Edge
    f1_L, f2_L, L1_L, L2_L = find_left_edge_hw(freqs_sorted, power_hw_db, abs_threshold)
    
    # E. Right Edge
    f1_R, f2_R, L1_R, L2_R = find_right_edge_points(freqs_sorted, power_hw_db, abs_threshold)
    
    # Debug print (Optional interpolation check)
    if f1_L is not None and f1_R is not None:
        f_star_L = linear_interpolate_hw(f1_L, f2_L, L1_L, L2_L, abs_threshold)
        f_star_R = linear_interpolate_hw(f1_R, f2_R, L1_R, L2_R, abs_threshold)
        print(f"  Edges Found (Interp): [{f_star_L/1e6:.3f} MHz, {f_star_R/1e6:.3f} MHz]")
    else:
        print("  Edges NOT Found (Signal too weak or no crossing)")

    # -------------------------------------------------------------------------
    # 3. Generate Hardware Inputs (Quantization)
    # -------------------------------------------------------------------------
    
    # I/Q Samples
    i_samples_hw = [float_to_fixed_point(np.real(s), iq_int_bits, iq_frac_bits, signed=True) 
                    for s in iq_data_scaled]
    q_samples_hw = [float_to_fixed_point(np.imag(s), iq_int_bits, iq_frac_bits, signed=True) 
                    for s in iq_data_scaled]
    
    # Window
    win_coeffs_float = signal.windows.get_window('hann', N)
    win_hw = [float_to_fixed_point(w, 2, 14, signed=True) for w in win_coeffs_float]
    
    # Config: Frequency Bins
    fb_frac = 12 
    fb_int = freq_bin_width - fb_frac
    
    freq_bins_hw = []
    freq_steps_hw = []
    
    for f_hz in freqs_sorted:
        # 1. freq_bin_i
        f_mhz = f_hz / 1e6
        fb_val = float_to_fixed_point(f_mhz, fb_int, fb_frac, signed=True)
        freq_bins_hw.append(fb_val)
        
        # 2. freq_steps_i
        norm_freq = f_hz / fs
        step_real = norm_freq * (2.0 ** phase_width)
        if step_real < 0: step_real += (2.0 ** phase_width)
        step_int = int(step_real) & ((1 << phase_width) - 1)
        freq_steps_hw.append(step_int)

    # -------------------------------------------------------------------------
    # 4. Generate Hardware Expectations (Edge Points Only)
    # -------------------------------------------------------------------------
    
    # Helper to fix freq (Hz -> MHz -> Fixed Point Q4.12)
    def fix_freq(f): 
        if f is None: return 0
        return float_to_fixed_point(f/1e6, fb_int, fb_frac, signed=True)
    
    # Helper to fix power (Integer -> 32-bit vector)
    def fix_pwr(p): 
        if p is None: return 0
        # Mask to 32 bits (unsigned behavior for vectors)
        return int(p) & 0xFFFFFFFF

    # --- LEFT EDGE EXPECTATIONS ---
    exp_f1_L = fix_freq(f1_L)
    exp_f2_L = fix_freq(f2_L)
    exp_L1_L = fix_pwr(L1_L)
    exp_L2_L = fix_pwr(L2_L)

    # --- RIGHT EDGE EXPECTATIONS ---
    exp_f1_R = fix_freq(f1_R)
    exp_f2_R = fix_freq(f2_R)
    exp_L1_R = fix_pwr(L1_R)
    exp_L2_R = fix_pwr(L2_R)

    # Valid is high only if both edges were found
    valid_expect = 1 if (f1_L is not None and f1_R is not None) else 0

    return {
        'test_name': test_name,
        'N': N, 'K': K, 'fs': fs,
        'i_samples': i_samples_hw,
        'q_samples': q_samples_hw,
        'window_coeffs': win_hw,
        'freq_bins_hw': freq_bins_hw,
        'freq_steps_hw': freq_steps_hw,
        # Outputs
        'valid_expect': valid_expect,
        'exp_f1_L': exp_f1_L, 'exp_f2_L': exp_f2_L,
        'exp_L1_L': exp_L1_L, 'exp_L2_L': exp_L2_L,
        'exp_f1_R': exp_f1_R, 'exp_f2_R': exp_f2_R,
        'exp_L1_R': exp_L1_R, 'exp_L2_R': exp_L2_R,
    }

def write_vector_file(test_cases, output_path, iq_width, num_bins):
    with open(output_path, 'w') as f:
        f.write("# Simulation vectors for dft_bandwidth_analysis_top.sv\n")
        f.write("# Format: TEST_NAME, N, K, FREQ_STEPS, FREQ_BINS, SAMPLES(I/Q/Win), EXPECTED_EDGES\n\n")
        
        for tc in test_cases:
            f.write(f"TEST {tc['test_name']}\n")
            f.write(f"PARAMS {tc['N']} {tc['K']}\n")
            
            # Config
            f.write("FREQ_STEPS ")
            for step in tc['freq_steps_hw']: f.write(f"{step:08x} ")
            f.write("\n")
            
            f.write("FREQ_BINS ")
            for fb in tc['freq_bins_hw']: f.write(f"{fb:04x} ")
            f.write("\n")
            
            # Data
            f.write("SAMPLES\n")
            for n in range(tc['N']):
                f.write(f"{tc['i_samples'][n]:04x} {tc['q_samples'][n]:04x} {tc['window_coeffs'][n]:04x}\n")
            
            # Expected Output: Edge Points
            # Format: VALID
            #         LEFT:  f1 f2 L1 L2
            #         RIGHT: f1 f2 L1 L2
            f.write(f"EXPECTED {tc['valid_expect']}\n")
            f.write(f"LEFT  {tc['exp_f1_L']:04x} {tc['exp_f2_L']:04x} {tc['exp_L1_L']:08x} {tc['exp_L2_L']:08x}\n")
            f.write(f"RIGHT {tc['exp_f1_R']:04x} {tc['exp_f2_R']:04x} {tc['exp_L1_R']:08x} {tc['exp_L2_R']:08x}\n")
            
            f.write("\n")

def main():
    print("=== Generating Top-Level Stimuli ===\n")
    
    # --- Hardware Parameters ---
    IQ_WIDTH = 16
    WINDOW_WIDTH = 16
    ACCUM_WIDTH = 48 
    POWER_WIDTH = 32
    POWER_FRAC = 16
    FREQ_BIN_WIDTH = 16
    FREQ_WIDTH = 32
    FREQ_FRAC_BITS = 16
    PHASE_WIDTH = 32
    NUM_BINS = 24
    
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
                
                tc = generate_test_case_top(
                    name, time_window, fs_baseline, S_bins, THRESHOLD_DROP_DB,
                    IQ_WIDTH, WINDOW_WIDTH, ACCUM_WIDTH, 
                    POWER_WIDTH, POWER_FRAC,
                    FREQ_BIN_WIDTH, FREQ_WIDTH, FREQ_FRAC_BITS,
                    PHASE_WIDTH
                )
                test_cases.append(tc)
                
        except Exception as e:
            print(f"Error: {e}")
            import traceback
            traceback.print_exc()

    output_dir = SIMULATOR_ROOT.parent / "rtl" / "simvectors"
    output_dir.mkdir(parents=True, exist_ok=True)
    output_path = output_dir / "bandwidth_edge_detector_vectors.txt"
    
    write_vector_file(test_cases, output_path, IQ_WIDTH, NUM_BINS)
    print(f"\nStimuli generated at: {output_path}")

if __name__ == "__main__":
    main()