"""
analyze_results.py

Analyzes the functional accuracy of the FPGA Top Level Simulation.
1. Calculates High-Precision Ground Truth (FFT based) for every test case.
2. Maps Hardware Bin Indices (0..23) back to Physical Frequencies (MHz).
3. Performs Linear Interpolation on Hardware results to find f_star.
4. Compares f_star against Ground Truth and computes Accuracy/Safety metrics.
"""

import pandas as pd
import numpy as np
from scipy import signal
import argparse
from pathlib import Path
import sys

# -----------------------------------------------------------------------------
# 1. Setup Paths & Imports
# -----------------------------------------------------------------------------
try:
    CURRENT_DIR = Path(__file__).resolve().parent
    SIMULATOR_SRC = CURRENT_DIR.parent.parent / "simulator" / "src"
    
    if not SIMULATOR_SRC.exists():
        raise FileNotFoundError(f"Simulator src not found at {SIMULATOR_SRC}")
        
    sys.path.insert(0, str(SIMULATOR_SRC))

    from afe_interface_rf import load_picmus_rf_data
    from virtual_afe import run_virtual_afe_processing

except ImportError as e:
    print(f"Error importing simulator modules: {e}")
    sys.exit(1)

# -----------------------------------------------------------------------------
# 2. Configuration
# -----------------------------------------------------------------------------
DATASET_CONFIG = {
    'experiments': {
        'contrast_speckle': ('contrast_speckle_expe_dataset_rf.hdf5', 'contrast_speckle_expe_dataset_iq.hdf5', 'contrast_speckle_expe_scan.hdf5'),
        'resolution_distorsion': ('resolution_distorsion_expe_dataset_rf.hdf5', 'resolution_distorsion_expe_dataset_iq.hdf5', 'resolution_distorsion_expe_scan.hdf5')
    },
    'in_vivo': {
        'carotid_cross': ('carotid_cross_expe_dataset_rf.hdf5', 'carotid_cross_expe_dataset_iq.hdf5', 'carotid_cross_expe_scan.hdf5'),
        'carotid_long': ('carotid_long_expe_dataset_rf.hdf5', 'carotid_long_expe_dataset_iq.hdf5', 'carotid_long_expe_scan.hdf5')
    },
    'simulation': {
        'contrast_speckle': ('contrast_speckle_simu_dataset_rf.hdf5', 'contrast_speckle_simu_dataset_iq.hdf5', 'contrast_speckle_simu_scan.hdf5'),
        'resolution_distorsion': ('resolution_distorsion_simu_dataset_rf.hdf5', 'resolution_distorsion_simu_dataset_iq.hdf5', 'resolution_distorsion_simu_scan.hdf5')
    }
}

def get_dataset_paths(dataset_type, dataset_name):
    sim_root = SIMULATOR_SRC.parent
    base = sim_root / "datasets" / dataset_type / dataset_name
    files = DATASET_CONFIG[dataset_type][dataset_name]
    return base/files[0], base/files[1], base/files[2]

# -----------------------------------------------------------------------------
# 3. Helpers: Interpolation & Frequencies
# -----------------------------------------------------------------------------
def get_sorted_frequency_bins(mod_freq):
    """
    Reconstructs the exact S_bins array used in generation.
    Returns: Sorted numpy array of frequencies in Hz.
    """
    delta_f = 1e6 # 1e6 very coarse, 0.5e6 medium, 0.25e6 finde
    half_bw_est = mod_freq / 2

    half_bw_est_left = 2.32e6 # for in vivo datasets for the refinement step
    half_bw_est_right = 2.25e6 # for in vivo datasets for the refinement step

    s_coarse = np.linspace(-mod_freq, mod_freq, 8)
    # s_fine_left = np.linspace(-half_bw_est - delta_f, -half_bw_est + delta_f, 8) 
    # s_fine_right = np.linspace(half_bw_est - delta_f, half_bw_est + delta_f, 8) 
    s_fine_left = np.linspace(-half_bw_est_left - delta_f, -half_bw_est_left + delta_f, 8)
    s_fine_right = np.linspace(half_bw_est_right - delta_f, half_bw_est_right + delta_f, 8)
    
    # Concatenate and Sort (Crucial: HW indices correspond to sorted array)
    S_bins = np.unique(np.concatenate([s_coarse, s_fine_left, s_fine_right]))
    return np.sort(S_bins)

def linear_interpolate_hw(f1, f2, L1, L2, abs_threshold):
    """
    Performs the final linear interpolation to find the precise edge frequency.
    Matches the logic used in the complete system model.
    """
    # Check for NaNs or invalid inputs
    if any(np.isnan(v) for v in [f1, f2, L1, L2]):
        return float('nan')
        
    if (L2 - L1) == 0:
        return float('nan') # Avoid division by zero

    # Standard linear interpolation formula
    # f_star = f1 + (f2 - f1) * (threshold - L1) / (L2 - L1)
    f_star = f1 + (f2 - f1) * (abs_threshold - L1) / (L2 - L1)
    return f_star

# -----------------------------------------------------------------------------
# 4. Ground Truth Calculation
# -----------------------------------------------------------------------------
def calculate_ground_truth_edges(time_window_data, fs, threshold_drop_db=30.0):
    """
    Calculates the True Bandwidth Edges using High-Res FFT.
    """
    n_fft = 256 
    win = signal.windows.hann(len(time_window_data))
    
    spectrum = np.abs(np.fft.fft(time_window_data * win, n=n_fft))**2
    freqs = np.fft.fftfreq(n_fft, d=1/fs)
    
    spectrum_shifted = np.fft.fftshift(spectrum)
    freqs_shifted = np.fft.fftshift(freqs)
    
    peak_val = np.max(spectrum_shifted)
    if peak_val == 0:
        return float('nan'), float('nan')
        
    spectrum_db = 10 * np.log10(spectrum_shifted)
    spectrum_db_norm = spectrum_db - np.max(spectrum_db)
    
    threshold = -threshold_drop_db
    above_idx = np.where(spectrum_db_norm > threshold)[0]
    
    if len(above_idx) > 0:
        idx_left = above_idx[0]
        idx_right = above_idx[-1]
        f_left_mhz = freqs_shifted[idx_left] / 1e6
        f_right_mhz = freqs_shifted[idx_right] / 1e6
        return f_left_mhz, f_right_mhz
    else:
        return float('nan'), float('nan')

# -----------------------------------------------------------------------------
# 5. Main Analysis Logic
# -----------------------------------------------------------------------------
def main():
    parser = argparse.ArgumentParser(description="Analyze FPGA Results vs Ground Truth")
    parser.add_argument('csv_file', type=str, help="Path to the Results CSV file")
    parser.add_argument('--type', type=str, default='experiments', help="Dataset Type")
    parser.add_argument('--name', type=str, default='contrast_speckle', help="Dataset Name")
    parser.add_argument('--threshold', type=float, default=30.0, help="Threshold Drop in dB")
    args = parser.parse_args()

    csv_path = Path(args.csv_file)
    if not csv_path.exists():
        print(f"Error: CSV file not found at {csv_path}")
        sys.exit(1)

    print("="*60)
    print(f"Analyzing Results: {csv_path.name}")
    print(f"Dataset:           {args.type}/{args.name}")
    print("="*60)

    # --- Load Dataset ---
    print("Loading PICMUS Dataset...")
    try:
        rf_path, iq_path, scan_path = get_dataset_paths(args.type, args.name)
        rf_data, angles, _, _, fs_picmus, mod_freq, _, _, _ = load_picmus_rf_data(rf_path, iq_path, scan_path)
        
        # Run AFE
        adc_rate = 125e6
        decimation = 4
        center_angle_idx = np.argmin(np.abs(angles))
        
        print("Running Virtual AFE...")
        baseline_iq, _, fs_baseline = run_virtual_afe_processing(
            rf_data, center_angle_idx, fs_picmus, mod_freq, decimation, adc_rate
        )
    except Exception as e:
        print(f"Failed to load/process dataset: {e}")
        sys.exit(1)

    # --- Reconstruct Frequency Bins ---
    sorted_bins_hz = get_sorted_frequency_bins(mod_freq)

    # ===== ADD THIS SECTION HERE =====
    print("\n" + "="*80)
    print(" FREQUENCY BIN CONFIGURATION")
    print("="*80)
    print(f"Total bins: {len(sorted_bins_hz)}")
    print(f"Modulation frequency: {mod_freq/1e6:.4f} MHz")
    print(f"\nBin mapping (Index → Frequency):")
    print("-" * 40)
    for idx, freq in enumerate(sorted_bins_hz):
        freq_mhz = freq / 1e6
        
        # Identify which region this bin belongs to
        if -2.51e6 <= freq <= -2.01e6:
            region = "FINE LEFT"
        elif 1.45e6 <= freq <= 1.95e6:
            region = "FINE RIGHT"
        else:
            region = "COARSE"
        
        print(f"  Bin {idx:2d}: {freq_mhz:+8.4f} MHz  ({region})")

    print("="*80 + "\n")
    # ===== END OF ADDED SECTION =====
    
    # Helper to map Index -> MHz
    def map_idx_to_mhz(idx):
        if np.isnan(idx) or idx < 0 or idx >= len(sorted_bins_hz):
            return float('nan')
        return sorted_bins_hz[int(idx)] / 1e6

    # --- Process CSV ---
    df = pd.read_csv(csv_path)
    
    # 1. Calculate Ground Truth (High Res FFT)
    gt_f_left = []
    gt_f_right = []
    nperseg = 256
    hop = nperseg // 2

    print(f"Processing {len(df)} test cases...")

    for index, row in df.iterrows():
        channel = int(row['channel'])
        window_idx = int(row['window'])
        
        start_samp = window_idx * hop
        end_samp = start_samp + nperseg
        
        if end_samp > baseline_iq.shape[0]:
            gt_f_left.append(float('nan'))
            gt_f_right.append(float('nan'))
            continue

        time_window = baseline_iq[start_samp:end_samp, channel]
        f_l, f_r = calculate_ground_truth_edges(time_window, fs_baseline, args.threshold)
        
        gt_f_left.append(f_l)
        gt_f_right.append(f_r)

    df['GT_F_Left_MHz'] = gt_f_left
    df['GT_F_Right_MHz'] = gt_f_right

    # Add to analyze_results.py after calculating GT edges:
    print(f"\nRight Edge Distribution:")
    print(f"  Mean GT Right Edge: {df['GT_F_Right_MHz'].mean():.3f} MHz")
    print(f"  Expected bin center: {1.7e6/1e6:.3f} MHz")
    print(f"  Difference: {abs(df['GT_F_Right_MHz'].mean() - 1.7e6/1e6):.3f} MHz")

    # Add to analyze_results.py after calculating GT edges:
    print(f"\nLeft Edge Distribution:")
    print(f"  Mean GT Left Edge: {df['GT_F_Left_MHz'].mean():.3f} MHz")
    print(f"  Expected bin center: {-2.26e6/1e6:.3f} MHz")
    print(f"  Difference: {abs(df['GT_F_Left_MHz'].mean() - (-2.26e6)/1e6):.3f} MHz")

    # 2. Hardware: Map Indices to MHz and Interpolate
    
    # Map raw indices to MHz frequencies
    # df['act_f...'] contains bin indices (0..23)
    f1_L_mhz = df['act_f1_left'].apply(map_idx_to_mhz)
    f2_L_mhz = df['act_f2_left'].apply(map_idx_to_mhz)
    f1_R_mhz = df['act_f1_right'].apply(map_idx_to_mhz)
    f2_R_mhz = df['act_f2_right'].apply(map_idx_to_mhz)
    
    # Interpolate using hardware power values and threshold
    df['ACT_F_Star_Left_MHz'] = df.apply(
        lambda row: linear_interpolate_hw(
            map_idx_to_mhz(row['act_f1_left']), 
            map_idx_to_mhz(row['act_f2_left']), 
            row['act_L1_left'], 
            row['act_L2_left'], 
            row['abs_threshold']
        ), axis=1
    )

    df['ACT_F_Star_Right_MHz'] = df.apply(
        lambda row: linear_interpolate_hw(
            map_idx_to_mhz(row['act_f1_right']), 
            map_idx_to_mhz(row['act_f2_right']), 
            row['act_L1_right'], 
            row['act_L2_right'], 
            row['abs_threshold']
        ), axis=1
    )

    # # ===== ADD THIS SECTION HERE =====
    # # -------------------------------------------------------------------------
    # # DETAILED CASE-BY-CASE COMPARISON
    # # -------------------------------------------------------------------------
    # print("\n" + "="*80)
    # print(" DETAILED EDGE COMPARISON (Test Case by Test Case)")
    # print("="*80)

    # for idx, row in df.iterrows():
    #     print(f"\n--- Test Case {idx+1}: Channel {int(row['channel'])}, Window {int(row['window'])} ---")
        
    #     # Calculate bandwidth on the fly
    #     bw_gt = row['GT_F_Right_MHz'] - row['GT_F_Left_MHz']
    #     bw_act = row['ACT_F_Star_Right_MHz'] - row['ACT_F_Star_Left_MHz']
        
    #     # Ground Truth
    #     print(f"  GROUND TRUTH (FFT):")
    #     print(f"    Left Edge:  {row['GT_F_Left_MHz']:.4f} MHz")
    #     print(f"    Right Edge: {row['GT_F_Right_MHz']:.4f} MHz")
    #     print(f"    Bandwidth:  {bw_gt:.4f} MHz")
        
    #     # Hardware Raw Bins
    #     print(f"\n  HARDWARE RAW (Bin Indices):")
    #     print(f"    Left:  f1={int(row['act_f1_left']):2d}, f2={int(row['act_f2_left']):2d} | L1={int(row['act_L1_left']):3d} dB, L2={int(row['act_L2_left']):3d} dB")
    #     print(f"    Right: f1={int(row['act_f1_right']):2d}, f2={int(row['act_f2_right']):2d} | L1={int(row['act_L1_right']):3d} dB, L2={int(row['act_L2_right']):3d} dB")
    #     print(f"    Threshold: {int(row['abs_threshold'])} dB")
        
    #     # Hardware Mapped to Frequencies
    #     f1_L = map_idx_to_mhz(row['act_f1_left'])
    #     f2_L = map_idx_to_mhz(row['act_f2_left'])
    #     f1_R = map_idx_to_mhz(row['act_f1_right'])
    #     f2_R = map_idx_to_mhz(row['act_f2_right'])
        
    #     print(f"\n  HARDWARE BINS → FREQUENCIES:")
    #     print(f"    Left:  f1={f1_L:.4f} MHz, f2={f2_L:.4f} MHz")
    #     print(f"    Right: f1={f1_R:.4f} MHz, f2={f2_R:.4f} MHz")
        
    #     # Hardware After Interpolation
    #     print(f"\n  HARDWARE INTERPOLATED (Final):")
    #     print(f"    Left Edge:  {row['ACT_F_Star_Left_MHz']:.4f} MHz")
    #     print(f"    Right Edge: {row['ACT_F_Star_Right_MHz']:.4f} MHz")
    #     print(f"    Bandwidth:  {bw_act:.4f} MHz")
        
    #     # Errors (check for NaN to avoid division issues)
    #     if not (np.isnan(row['GT_F_Left_MHz']) or np.isnan(row['ACT_F_Star_Left_MHz'])):
    #         err_left = row['ACT_F_Star_Left_MHz'] - row['GT_F_Left_MHz']
    #         mape_left = abs(err_left / row['GT_F_Left_MHz']) * 100
    #     else:
    #         err_left = float('nan')
    #         mape_left = float('nan')
        
    #     if not (np.isnan(row['GT_F_Right_MHz']) or np.isnan(row['ACT_F_Star_Right_MHz'])):
    #         err_right = row['ACT_F_Star_Right_MHz'] - row['GT_F_Right_MHz']
    #         mape_right = abs(err_right / row['GT_F_Right_MHz']) * 100
    #     else:
    #         err_right = float('nan')
    #         mape_right = float('nan')
        
    #     if not (np.isnan(bw_gt) or np.isnan(bw_act)):
    #         err_bw = bw_act - bw_gt
    #         mape_bw = abs(err_bw / bw_gt) * 100
    #     else:
    #         err_bw = float('nan')
    #         mape_bw = float('nan')
        
    #     print(f"\n  ERRORS:")
    #     print(f"    Left:  {err_left:+.4f} MHz ({mape_left:.2f}% MAPE)")
    #     print(f"    Right: {err_right:+.4f} MHz ({mape_right:.2f}% MAPE)")
    #     print(f"    BW:    {err_bw:+.4f} MHz ({mape_bw:.2f}% MAPE)")

    # print("\n" + "="*80)
    # # ===== END OF ADDED SECTION =====

    # -------------------------------------------------------------------------
    # 3. Calculate Derived Metrics
    # -------------------------------------------------------------------------
    
    # A. Bandwidth (Right - Left)
    df['BW_GT_MHz'] = df['GT_F_Right_MHz'] - df['GT_F_Left_MHz']
    df['BW_ACT_MHz'] = df['ACT_F_Star_Right_MHz'] - df['ACT_F_Star_Left_MHz']
    
    # B. Max Absolute Frequency (for Nyquist/Decimation)
    df['MaxAbs_GT_MHz'] = np.maximum(np.abs(df['GT_F_Left_MHz']), np.abs(df['GT_F_Right_MHz']))
    df['MaxAbs_ACT_MHz'] = np.maximum(np.abs(df['ACT_F_Star_Left_MHz']), np.abs(df['ACT_F_Star_Right_MHz']))
    
    # C. Decimation Factor M
    # M = floor(125 / (4 * MaxAbs))
    def calc_decimation(max_freq):
        # Handle cases where max_freq is small or nan
        if np.isnan(max_freq) or max_freq <= 0.1: 
            return 1.0 
        
        fs_min = 4.0 * max_freq
        if fs_min >= 125.0:
            return 1.0 
            
        return np.floor(125.0 / fs_min)

    df['M_GT'] = df['MaxAbs_GT_MHz'].apply(calc_decimation)
    df['M_ACT'] = df['MaxAbs_ACT_MHz'].apply(calc_decimation)
    
    # -------------------------------------------------------------------------
    # 4. Aggregated Statistics & Printing
    # -------------------------------------------------------------------------
    
    # Filter for valid comparisons (where both GT and ACT found edges)
    valid_df = df.dropna(subset=['BW_GT_MHz', 'BW_ACT_MHz'])
    
    total_cases = len(df)
    valid_cases = len(valid_df)
    
    print("\n" + "="*60)
    print(" FUNCTIONAL ACCURACY METRICS")
    print("="*60)
    print(f"Total Test Cases:  {total_cases}")
    print(f"Valid Comparisons: {valid_cases} ({valid_cases/total_cases*100:.1f}%)")
    
    if valid_cases == 0:
        print("No valid comparisons found. Exiting.")
        return

    # Metric 1: Left Edge Accuracy
    err_left = valid_df['ACT_F_Star_Left_MHz'] - valid_df['GT_F_Left_MHz']
    mae_left = np.mean(np.abs(err_left))
    std_left = np.std(err_left)
    # NEW: MAPE Left
    mape_left = np.mean(np.abs(err_left / valid_df['GT_F_Left_MHz'])) * 100

    # Metric 2: Right Edge Accuracy
    err_right = valid_df['ACT_F_Star_Right_MHz'] - valid_df['GT_F_Right_MHz']
    mae_right = np.mean(np.abs(err_right))
    std_right = np.std(err_right)
    # NEW: MAPE Right
    mape_right = np.mean(np.abs(err_right / valid_df['GT_F_Right_MHz'])) * 100

    # Metric 3: Total Bandwidth Accuracy
    err_bw = valid_df['BW_ACT_MHz'] - valid_df['BW_GT_MHz']
    mae_bw = np.mean(np.abs(err_bw))
    bias_bw = np.mean(err_bw) 
    mape_bw = np.mean(np.abs(err_bw / valid_df['BW_GT_MHz'])) * 100

    # Metric 4: Safety Check (Overshoot)
    # Check if estimated bandwidth covers the ground truth bandwidth
    safe_bw_count = np.sum(valid_df['BW_ACT_MHz'] >= valid_df['BW_GT_MHz'])
    safety_ratio = (safe_bw_count / valid_cases) * 100

    # Metric 5: Nyquist / Max Edge Error
    err_max_edge = np.abs(valid_df['MaxAbs_ACT_MHz'] - valid_df['MaxAbs_GT_MHz'])
    mae_max_edge = np.mean(err_max_edge)
    # NEW: MAPE Max Edge
    mape_max_edge = np.mean(np.abs(err_max_edge / valid_df['MaxAbs_GT_MHz'])) * 100

    # Metric 6: Decimation Accuracy
    # Exact Match
    dec_matches = np.sum(valid_df['M_ACT'] == valid_df['M_GT'])
    dec_accuracy = (dec_matches / valid_cases) * 100
    
    # Safe Decimation (Estimated M <= Ground Truth M)
    dec_safe_count = np.sum(valid_df['M_ACT'] <= valid_df['M_GT'])
    dec_safety_ratio = (dec_safe_count / valid_cases) * 100

    print("\n--- 1. Edge Accuracy ---")
    print(f"Left Edge MAE:      {mae_left:.4f} MHz")
    print(f"Left Edge MAPE:     {mape_left:.2f} %")
    print(f"Left Edge StdDev:   {std_left:.4f} MHz")
    print(f"Right Edge MAE:     {mae_right:.4f} MHz")
    print(f"Right Edge MAPE:    {mape_right:.2f} %")
    print(f"Right Edge StdDev:  {std_right:.4f} MHz")
    
    print("\n--- 2. Bandwidth Estimation ---")
    print(f"BW MAE:             {mae_bw:.4f} MHz")
    print(f"BW Bias:            {bias_bw:.4f} MHz (+ means Overestimated)")
    print(f"BW MAPE:            {mape_bw:.2f} %")
    print(f"BW Safety Score:    {safety_ratio:.1f} % (Est BW >= GT BW)")
    
    print("\n--- 3. Sampling Rate & Decimation ---")
    print(f"Max Edge MAE:       {mae_max_edge:.4f} MHz")
    print(f"Max Edge MAPE:      {mape_max_edge:.2f} %")
    print(f"Decimation Match:   {dec_accuracy:.1f} % (M_est == M_gt)")
    print(f"Decimation Safety:  {dec_safety_ratio:.1f} % (M_est <= M_gt)")
    
    # Save
    output_csv = csv_path.parent / f"analyzed_{csv_path.name}"
    df.to_csv(output_csv, index=False)
    print(f"\nSaved analyzed results to: {output_csv}")

if __name__ == "__main__":
    main()