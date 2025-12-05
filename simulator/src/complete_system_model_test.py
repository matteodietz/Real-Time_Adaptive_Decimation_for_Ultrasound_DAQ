import numpy as np
from scipy import signal
import matplotlib.pyplot as plt
from pathlib import Path
import sys

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
from fixed_float_conversions import float_to_fixed_point

# --- Main Test Script ---
if __name__ == '__main__':
    print("--- Running Hardware-Accurate System Model Test on REAL PICMUS Data ---")

    # --- 1. Load PICMUS Data ---
    try:
        SIMULATOR_ROOT = Path(__file__).resolve().parent.parent
    except NameError:
        SIMULATOR_ROOT = Path.cwd().parent
    
    rf_path = SIMULATOR_ROOT / "datasets/experiments/contrast_speckle/contrast_speckle_expe_dataset_rf.hdf5"
    iq_path = SIMULATOR_ROOT / "datasets/experiments/contrast_speckle/contrast_speckle_expe_dataset_iq.hdf5"
    scan_path = SIMULATOR_ROOT / "datasets/experiments/contrast_speckle/contrast_speckle_expe_scan.hdf5"
    
    adc_rate = 125e6
    baseline_decimation = 4

    try:
        rf_data, angles, _, _, fs_picmus, mod_freq, _, _, _ = load_picmus_rf_data(rf_path, iq_path, scan_path)
    except Exception as e:
        print(f"Test failed: Could not load data. Error: {e}")
        exit()

    # --- 2. Get High-Fidelity Baseline I/Q Data ---
    center_angle_index = np.argmin(np.abs(angles))
    baseline_iq_data, _, fs_baseline = run_virtual_afe_processing(
        rf_data=rf_data,
        angle_index=center_angle_index,
        fs_picmus=fs_picmus,
        modulation_frequency=mod_freq,
        decimation_factor=baseline_decimation,
        adc_sample_rate=adc_rate
    )
    
    # --- 3. Select ONE STFT Window to Analyze ---
    nperseg = 256
    channel_to_test = 64
    window_num_to_test = 29 
    hop = nperseg // 2

    total_samples = baseline_iq_data.shape[0]
    num_windows_total = int(np.floor((total_samples - nperseg) / hop)) + 1
    
    print(f"\n--- STFT Analysis Setup ---")
    print(f"Total samples in A-line: {total_samples}")
    print(f"Window size (nperseg):   {nperseg}")
    print(f"Hop size:                {hop}")
    print(f"Total number of STFT windows available: {num_windows_total}")
    
    start_sample = window_num_to_test * hop
    end_sample = start_sample + nperseg
    
    time_window_data_raw = baseline_iq_data[start_sample:end_sample, channel_to_test]
    print(f"\n--- Analyzing STFT window #{window_num_to_test} from real data ---")

    # Scaling
    max_val = np.max(np.abs(time_window_data_raw))
    scale_factor = 1.5 / max_val if max_val > 0 else 1.0
    time_window_data = time_window_data_raw * scale_factor

    # --- 4. Define Analysis Parameters ---
    delta_f = 0.25e6 
    half_bw_est = mod_freq / 2

    s_coarse = np.linspace(-mod_freq, mod_freq, 8)
    s_fine_left = np.linspace(-half_bw_est - delta_f, -half_bw_est + delta_f, 8) 
    s_fine_right = np.linspace(half_bw_est - delta_f, half_bw_est + delta_f, 8) 
    S_bins = np.unique(np.concatenate([s_coarse, s_fine_left, s_fine_right]))

    print(f"Bins to calculate: {S_bins}")

    # Hardware parameters (must match your RTL)
    ACCUM_WIDTH = 64
    ACCUM_FRAC = 56
    POWER_WIDTH = 32
    POWER_FRAC = 16
    threshold_db = 30.0  # dB drop from peak

    # --- 5. Run the Hardware-Accurate Processing Pipeline ---
    
    # Step 1: Core Streaming DFT Processor
    print("\n--- Step 1: Streaming DFT ---")
    dft_bins = streaming_dft_processor(time_window_data, fs_baseline, S_bins, window='hann')
    print(f"DFT computed for {len(dft_bins)} bins")

    # Step 2: Convert to Hardware dB Power (using integer log2)
    print("\n--- Step 2: Convert to Hardware dB Power ---")
    freqs_sorted, power_hw_db = convert_to_hardware_db_power(
        dft_bins, ACCUM_WIDTH, ACCUM_FRAC, POWER_WIDTH, POWER_FRAC
    )
    print(f"Power values (dB): {power_hw_db}")
    
    # Step 3: Calculate Hardware Threshold
    print("\n--- Step 3: Calculate Threshold ---")
    threshold_drop_fixed = float_to_fixed_point(
        threshold_db, POWER_WIDTH - POWER_FRAC, POWER_FRAC, signed=False
    )
    max_power_hw, abs_threshold_hw = calc_hardware_threshold(
        power_hw_db, threshold_db
    )
    print(f"Max power: {max_power_hw} (fixed-point)")
    print(f"Absolute threshold: {abs_threshold_hw} (fixed-point)")
    
    # Step 4: Find Left Edge Points
    print("\n--- Step 4: Find Left Edge ---")
    f1_left, f2_left, L1_left, L2_left = find_left_edge_hw(
        freqs_sorted, power_hw_db, abs_threshold_hw
    )
    print(f"Left edge: f1={f1_left/1e6:.4f} MHz, f2={f2_left/1e6:.4f} MHz")
    print(f"           L1={L1_left:.2f} dB, L2={L2_left:.2f} dB")
    
    # Step 5: Find Right Edge Points
    print("\n--- Step 5: Find Right Edge ---")
    f1_right, f2_right, L1_right, L2_right = find_right_edge_points(
        freqs_sorted, power_hw_db, abs_threshold_hw
    )
    print(f"Right edge: f1={f1_right/1e6:.4f} MHz, f2={f2_right/1e6:.4f} MHz")
    print(f"            L1={L1_right:.2f} dB, L2={L2_right:.2f} dB")

    # Step 6: Interpolate to find final edges (this would be done by APU)
    print("\n--- Step 6: Linear Interpolation ---")
    f_left_final = linear_interpolate_hw(f1_left, f2_left, L1_left, L2_left, abs_threshold_hw)
    f_right_final = linear_interpolate_hw(f1_right, f2_right, L1_right, L2_right, abs_threshold_hw)
    
    print(f"Hardware-Accurate Estimated Edges: [{f_left_final/1e6:.3f}, {f_right_final/1e6:.3f}] MHz")
    print(f"Estimated Bandwidth: {(f_right_final - f_left_final)/1e6:.3f} MHz")
    
    # --- 6. Ground Truth and Visual Confirmation ---
    print("\n--- Step 7: Generate Ground Truth for Comparison ---")
    freqs_welch, psd_welch = signal.welch(
        time_window_data, 
        fs=fs_baseline, 
        window='hann', 
        nperseg=nperseg,
        return_onesided=False, 
        scaling='density'
    )
    freqs_welch_shifted = np.fft.fftshift(freqs_welch)
    psd_welch_shifted = np.fft.fftshift(psd_welch)
    psd_db_welch_norm = 10 * np.log10(psd_welch_shifted + 1e-20)
    psd_db_welch_norm -= np.max(psd_db_welch_norm)

    # --- 7. Plotting ---
    plt.figure(figsize=(14, 7))
    
    # Ground truth PSD
    plt.plot(freqs_welch_shifted / 1e6, psd_db_welch_norm, 'k-', 
             label=f'Ground Truth PSD ({nperseg}-pt Welch)', alpha=0.6, linewidth=2)

    # Calculate normalized PSD from DFT bins for plotting
    win = signal.windows.get_window('hann', nperseg)
    enbw_scaling = fs_baseline * np.sum(win**2)
    
    freqs1 = np.array(list(dft_bins.keys()))
    powers1 = np.abs(np.array(list(dft_bins.values())))**2
    psd1 = powers1 / enbw_scaling
    db1_norm = 10 * np.log10(psd1 + 1e-20)
    db1_norm = db1_norm - np.max(10 * np.log10(psd_welch_shifted + 1e-20))
    
    # Plot DFT bins
    plt.plot(freqs1 / 1e6, db1_norm, 'bo', markersize=6, 
             label=f'DFT Bins (PSD, |S|={len(S_bins)})', alpha=0.7)
    
    # Plot edge detection points
    if f1_left is not None and f2_left is not None:
        plt.plot([f1_left/1e6, f2_left/1e6], 
                [L1_left - max_power_hw, L2_left - max_power_hw], 
                'rs-', markersize=8, linewidth=2, 
                label='Left Edge Points', alpha=0.8)
    
    if f1_right is not None and f2_right is not None:
        plt.plot([f1_right/1e6, f2_right/1e6], 
                [L1_right - max_power_hw, L2_right - max_power_hw], 
                'gs-', markersize=8, linewidth=2, 
                label='Right Edge Points', alpha=0.8)
    
    # Plot final interpolated edges
    if not np.isnan(f_left_final):
        plt.axvline(x=f_left_final/1e6, color='r', linestyle='--', linewidth=2,
                   label=f'Est. Lower Edge ({f_left_final/1e6:.3f} MHz)')
    
    if not np.isnan(f_right_final):
        plt.axvline(x=f_right_final/1e6, color='g', linestyle='--', linewidth=2,
                   label=f'Est. Upper Edge ({f_right_final/1e6:.3f} MHz)')
    
    # Plot threshold line
    threshold_normalized = threshold_db
    plt.axhline(y=threshold_normalized, color='orange', linestyle=':', linewidth=2,
               label=f'{threshold_db} dB Threshold')
    
    plt.title(f'Hardware-Accurate Bandwidth Estimation (Window #{window_num_to_test}, Channel {channel_to_test})')
    plt.xlabel('Frequency (MHz)')
    plt.ylabel('Power (dB relative to peak)')
    plt.legend(loc='best')
    plt.grid(True, alpha=0.3)
    plt.xlim([min(freqs_welch_shifted)/1e6, max(freqs_welch_shifted)/1e6])
    plt.tight_layout()
    plt.show()
    
    print("\n--- Test Complete ---")