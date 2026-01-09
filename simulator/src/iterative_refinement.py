import numpy as np
from scipy import signal
import matplotlib.pyplot as plt
from pathlib import Path
import sys
import math

# --- User Imports ---
# Ensure these files are in the python path or same directory
from afe_interface_rf import load_picmus_rf_data
from virtual_afe import run_virtual_afe_processing
from complete_system_model import (
    streaming_dft_processor, 
    convert_to_hardware_db_power,
    calc_hardware_threshold,
    find_left_edge_hw,
    find_right_edge_points,
    linear_interpolate_hw
)

# --- Configuration for Thesis Plots ---
plt.rcParams.update({
    "font.family": "serif",
    "font.serif": ["Times New Roman", "Times", "DejaVu Serif", "serif"],
    "mathtext.fontset": "cm",
    "font.size": 12,
    "axes.labelsize": 12,
    "axes.titlesize": 14,
    "legend.fontsize": 10
})

def run_hardware_estimation_step(time_data, fs, S_bins, threshold_db, params):
    """
    Encapsulates the hardware model processing steps for a single iteration.
    """
    # Unpack hardware params
    ACCUM_WIDTH = params['ACCUM_WIDTH']
    ACCUM_FRAC = params['ACCUM_FRAC']
    INPUT_WIDTH_LOG = params['INPUT_WIDTH_LOG']
    POWER_WIDTH = params['POWER_WIDTH']
    POWER_FRAC = params['POWER_FRAC']

    # 1. Streaming DFT
    dft_bins = streaming_dft_processor(time_data, fs, S_bins, window='hann')

    # 2. Convert to HW dB
    freqs_sorted, power_hw_db = convert_to_hardware_db_power(
        dft_bins, INPUT_WIDTH_LOG, INPUT_WIDTH_LOG - (ACCUM_WIDTH - ACCUM_FRAC), POWER_WIDTH, POWER_FRAC
    )

    # 3. Threshold
    max_power_hw, abs_threshold_hw = calc_hardware_threshold(power_hw_db, threshold_db)

    # 4. Left Edge
    f1_left, f2_left, L1_left, L2_left = find_left_edge_hw(
        freqs_sorted, power_hw_db, abs_threshold_hw
    )

    # 5. Right Edge
    f1_right, f2_right, L1_right, L2_right = find_right_edge_points(
        freqs_sorted, power_hw_db, abs_threshold_hw
    )

    # 6. Interpolation
    f_left_final = linear_interpolate_hw(f1_left, f2_left, L1_left, L2_left, abs_threshold_hw)
    f_right_final = linear_interpolate_hw(f1_right, f2_right, L1_right, L2_right, abs_threshold_hw)

    # Pack results for plotting/next step
    results = {
        'dft_bins': dft_bins,
        'freqs_sorted': freqs_sorted,
        'power_hw_db': power_hw_db,
        'max_power_hw': max_power_hw,
        'f_left_final': f_left_final,
        'f_right_final': f_right_final,
        'left_points': (f1_left, f2_left, L1_left, L2_left),
        'right_points': (f1_right, f2_right, L1_right, L2_right)
    }
    return results

def plot_iteration(ax, time_data, fs, results, threshold_db, title_str):
    """
    Helper function to plot one iteration on a specific matplotlib axis.
    """
    nperseg = len(time_data)
    
    # --- Ground Truth (Welch) ---
    freqs_welch, psd_welch = signal.welch(
        time_data, fs=fs, window='hann', nperseg=nperseg, scaling='density'
    )
    freqs_welch_shifted = np.fft.fftshift(freqs_welch)
    psd_welch_shifted = np.fft.fftshift(psd_welch)
    psd_db_welch_norm = 10 * np.log10(psd_welch_shifted + 1e-20)
    psd_db_welch_norm -= np.max(psd_db_welch_norm)

    ax.plot(freqs_welch_shifted / 1e6, psd_db_welch_norm, color='dimgray', alpha=0.6, linewidth=1.5, 
             label='Ground Truth PSD')

    # --- DFT Bins (HW Model) ---
    # Reconstruct normalized dB from DFT bins for plotting
    dft_bins = results['dft_bins']
    freqs1 = np.array(list(dft_bins.keys()))
    powers1 = np.abs(np.array(list(dft_bins.values())))**2
    # HW log2 emulation for plotting consistency
    db1_norm = 3 * np.floor(np.log2(powers1 + 1e-20))
    db1_norm -= np.max(db1_norm)

    ax.plot(freqs1 / 1e6, db1_norm, 'ko', markersize=5, label='DFT Bins (HW)', alpha=0.9)

    # --- Edges & Points ---
    max_p = results['max_power_hw']
    (f1_l, f2_l, L1_l, L2_l) = results['left_points']
    (f1_r, f2_r, L1_r, L2_r) = results['right_points']
    f_l_est = results['f_left_final']
    f_r_est = results['f_right_final']

    # Plot Left Points (Red)
    if f1_l is not None and f2_l is not None:
        ax.plot([f1_l/1e6, f2_l/1e6], [L1_l - max_p, L2_l - max_p], 
                'rs-', markersize=6, linewidth=1.5, label='Left Edge Pts')
    
    # Plot Right Points (Blue)
    if f1_r is not None and f2_r is not None:
        ax.plot([f1_r/1e6, f2_r/1e6], [L1_r - max_p, L2_r - max_p], 
                'bs-', markersize=6, linewidth=1.5, label='Right Edge Pts')

    # Plot Interpolated Lines
    if not np.isnan(f_l_est):
        ax.axvline(x=f_l_est/1e6, color='r', linestyle='--', linewidth=1.5,
                   label=rf'Est: {f_l_est/1e6:.2f} MHz')
    if not np.isnan(f_r_est):
        ax.axvline(x=f_r_est/1e6, color='b', linestyle='--', linewidth=1.5,
                   label=rf'Est: {f_r_est/1e6:.2f} MHz')

    # Threshold Line
    ax.axhline(y=-threshold_db, color='orange', linestyle=':', linewidth=1.5)

    ax.set_title(title_str, fontweight="bold")
    ax.set_ylabel("Power (dB)")
    ax.grid(True, alpha=0.3)
    ax.set_xlim([min(freqs_welch_shifted)/1e6, max(freqs_welch_shifted)/1e6])
    
    # Only adding legend to the first plot to save space, or minimal legend
    ax.legend(loc='lower right', frameon=True, fontsize=9, ncol=2)


if __name__ == '__main__':
    print("--- Iterative Bandwidth Refinement Test ---")

    # --- 1. Load Data ---
    try:
        SIMULATOR_ROOT = Path(__file__).resolve().parent.parent
    except NameError:
        SIMULATOR_ROOT = Path.cwd().parent
    
    # rf_path = SIMULATOR_ROOT / "datasets/in_vivo/carotid_long/carotid_long_expe_dataset_rf.hdf5"
    # iq_path = SIMULATOR_ROOT / "datasets/in_vivo/carotid_long/carotid_long_expe_dataset_iq.hdf5"
    # scan_path = SIMULATOR_ROOT / "datasets/in_vivo/carotid_long/carotid_long_expe_scan.hdf5"

    rf_path = SIMULATOR_ROOT / "datasets/experiments/contrast_speckle/contrast_speckle_expe_dataset_rf.hdf5"
    iq_path = SIMULATOR_ROOT / "datasets/experiments/contrast_speckle/contrast_speckle_expe_dataset_iq.hdf5"
    scan_path = SIMULATOR_ROOT / "datasets/experiments/contrast_speckle/contrast_speckle_expe_scan.hdf5"
    
    adc_rate = 125e6
    baseline_decimation = 4
    
    try:
        rf_data, angles, _, _, fs_picmus, mod_freq, _, _, _ = load_picmus_rf_data(rf_path, iq_path, scan_path)
    except Exception as e:
        print(f"Data load error: {e}")
        exit()

    # --- 2. Virtual AFE Processing ---
    center_angle_index = np.argmin(np.abs(angles))
    baseline_iq_data, _, fs_baseline = run_virtual_afe_processing(
        rf_data=rf_data,
        angle_index=center_angle_index,
        fs_picmus=fs_picmus,
        modulation_frequency=mod_freq,
        decimation_factor=baseline_decimation,
        adc_sample_rate=adc_rate
    )
    
    # --- 3. Setup Windows ---
    nperseg = 256
    channel_to_test = 96
    hop = nperseg // 2
    
    # Define Iteration 1 and Iteration 2 window indices
    # Iteration 2 is "2 windows after" -> 2 * hop shift -> Non-overlapping
    window_idx_1 = 30
    window_idx_2 = window_idx_1 + 2
    
    # Prepare Data Chunks
    start_samp_1 = window_idx_1 * hop
    data_1_raw = baseline_iq_data[start_samp_1 : start_samp_1 + nperseg, channel_to_test]
    
    start_samp_2 = window_idx_2 * hop
    data_2_raw = baseline_iq_data[start_samp_2 : start_samp_2 + nperseg, channel_to_test]

    # --- Add AWGN Noise ---
    # Adds complex noise with a specified noise floor 50dB down from the signal power
    target_snr_db = 45.0 
    sig_power = np.mean(np.abs(data_1_raw)**2)
    noise_power = sig_power / (10**(target_snr_db/10))
    # Split power between Real and Imaginary parts (/2)
    noise_std = np.sqrt(noise_power / 2) 
    noise_1 = (np.random.normal(0, noise_std, data_1_raw.shape) + 
             1j * np.random.normal(0, noise_std, data_1_raw.shape))
    data_1_raw = data_1_raw + noise_1
    noise_2 = (np.random.normal(0, noise_std, data_2_raw.shape) + 
             1j * np.random.normal(0, noise_std, data_2_raw.shape))
    data_2_raw = data_2_raw + noise_2
    # --- END Add AWGN Noise ---

    # Scaling (Normalize input to fit fixed point logic somewhat)
    scale_factor_1 = 1.5 / np.max(np.abs(data_1_raw)) if np.max(np.abs(data_1_raw)) > 0 else 1.0
    data_1 = data_1_raw * scale_factor_1
    
    scale_factor_2 = 1.5 / np.max(np.abs(data_2_raw)) if np.max(np.abs(data_2_raw)) > 0 else 1.0
    data_2 = data_2_raw * scale_factor_2

    # --- Hardware Parameters ---
    hw_params = {
        'ACCUM_WIDTH': 64,
        'ACCUM_FRAC': 56,
        'INPUT_WIDTH_LOG': 32,
        'POWER_WIDTH': 8,
        'POWER_FRAC': 0
    }
    threshold_db = 30.0

    # ==========================================
    # --- ITERATION 1: Initial Coarse Search ---
    # ==========================================
    print(f"\n--- Iteration 1 (Window {window_idx_1}) ---")
    
    delta_f_1 = 0.5e6
    half_bw_est_init = mod_freq / 2
    
    s_coarse = np.linspace(-mod_freq, mod_freq, 8)
    s_fine_left_1 = np.linspace(-half_bw_est_init -0.75e6 - delta_f_1, -half_bw_est_init -0.75e6 + delta_f_1, 8) # the initial estimates are intentionally shifted
    s_fine_right_1 = np.linspace(half_bw_est_init +0.75e6 - delta_f_1, half_bw_est_init + 0.75e6 + delta_f_1, 8) # to demonstrate the iterative refinement process
    S_bins_1 = np.unique(np.concatenate([s_coarse, s_fine_left_1, s_fine_right_1]))
    
    res_1 = run_hardware_estimation_step(data_1, fs_baseline, S_bins_1, threshold_db, hw_params)
    
    print(f"Est Edges: [{res_1['f_left_final']/1e6:.3f}, {res_1['f_right_final']/1e6:.3f}] MHz")
    
    # ==========================================
    # --- ITERATION 2: Refined Fine Search ---
    # ==========================================
    print(f"\n--- Iteration 2 (Window {window_idx_2}) ---")
    
    # Retrieve estimates from Iteration 1 to center the new bins
    prev_left = res_1['f_left_final']
    prev_right = res_1['f_right_final']
    
    # Check if estimates were valid, otherwise fallback (safety)
    if np.isnan(prev_left): prev_left = -half_bw_est_init
    if np.isnan(prev_right): prev_right = half_bw_est_init
    
    delta_f_2 = 0.25e6 # Reduced delta
    
    # Refined Bins
    # Coarse bins usually stay to anchor the spectrum, or could be removed if pure tracking. 
    # Keeping them ensures global context.
    s_fine_left_2 = np.linspace(prev_left - delta_f_2, prev_left + delta_f_2, 8)
    s_fine_right_2 = np.linspace(prev_right - delta_f_2, prev_right + delta_f_2, 8)
    S_bins_2 = np.unique(np.concatenate([s_coarse, s_fine_left_2, s_fine_right_2]))
    
    res_2 = run_hardware_estimation_step(data_2, fs_baseline, S_bins_2, threshold_db, hw_params)
    
    print(f"Est Edges: [{res_2['f_left_final']/1e6:.3f}, {res_2['f_right_final']/1e6:.3f}] MHz")
    print(f"Refined Bandwidth: {(res_2['f_right_final'] - res_2['f_left_final'])/1e6:.3f} MHz")

    # ==========================================
    # --- PLOTTING ---
    # ==========================================
    fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(10, 8), sharex=True)
    
    # Plot Iteration 1
    plot_iteration(
        ax1, data_1, fs_baseline, res_1, threshold_db, 
        rf"Iteration 1: Initial Estimate ($\Delta f=0.5$ MHz, Window $N$)"
    )
    
    # Plot Iteration 2
    plot_iteration(
        ax2, data_2, fs_baseline, res_2, threshold_db, 
        rf"Iteration 2: Refined Estimate ($\Delta f=0.25$ MHz, Window $N+2$)"
    )
    
    ax2.set_xlabel("Frequency (MHz)")
    
    plt.tight_layout()
    
    # Save
    plots_dir = Path(__file__).resolve().parent / "plots"
    plots_dir.mkdir(parents=True, exist_ok=True)
    file_name = "iterative_bw_refinement_thesis.png"
    output_path = plots_dir / file_name
    plt.savefig(output_path, dpi=300, bbox_inches='tight')
    
    print(f"\nSUCCESS: Plot saved to {output_path}")
    plt.close()