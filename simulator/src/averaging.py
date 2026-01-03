import numpy as np
from scipy import signal
import matplotlib.pyplot as plt
from pathlib import Path
import sys
import warnings

# Use the formatting logic from your previous scripts
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

# Suppress warnings about complex data in welch
warnings.filterwarnings('ignore', message='Input data is complex')

# --- Plotting Configuration ---
plt.rcParams.update({
    "font.family": "serif",
    "font.serif": ["Times New Roman", "Times", "DejaVu Serif", "serif"],
    "mathtext.fontset": "cm",
    "font.size": 12,
    "axes.labelsize": 12,
    "axes.titlesize": 14,
    "legend.fontsize": 10
})

def add_awgn(signal_data, snr_db):
    """
    Adds independent complex Gaussian noise to the signal to achieve target SNR.
    """
    sig_power = np.mean(np.abs(signal_data)**2)
    noise_power = sig_power / (10**(snr_db/10))
    noise_std = np.sqrt(noise_power / 2)
    noise = (np.random.normal(0, noise_std, signal_data.shape) + 
             1j * np.random.normal(0, noise_std, signal_data.shape))
    return signal_data + noise

def run_hardware_estimation(time_data, fs, S_bins, threshold_db, hw_params):
    """
    Runs the complete hardware processing pipeline on a given time-domain signal.
    """
    # Unpack hardware params
    ACCUM_WIDTH = hw_params['ACCUM_WIDTH']
    ACCUM_FRAC = hw_params['ACCUM_FRAC']
    INPUT_WIDTH_LOG = hw_params['INPUT_WIDTH_LOG']
    POWER_WIDTH = hw_params['POWER_WIDTH']
    POWER_FRAC = hw_params['POWER_FRAC']

    # 1. DFT
    dft_bins = streaming_dft_processor(time_data, fs, S_bins, window='hann')

    # 2. Power Conversion
    freqs_sorted, power_hw_db = convert_to_hardware_db_power(
        dft_bins, INPUT_WIDTH_LOG, INPUT_WIDTH_LOG - (ACCUM_WIDTH - ACCUM_FRAC), POWER_WIDTH, POWER_FRAC
    )

    # 3. Threshold
    max_power_hw, abs_threshold_hw = calc_hardware_threshold(power_hw_db, threshold_db)

    # 4. Edges
    f1_l, f2_l, L1_l, L2_l = find_left_edge_hw(freqs_sorted, power_hw_db, abs_threshold_hw)
    f1_r, f2_r, L1_r, L2_r = find_right_edge_points(freqs_sorted, power_hw_db, abs_threshold_hw)

    # 5. Interpolation
    f_left_final = linear_interpolate_hw(f1_l, f2_l, L1_l, L2_l, abs_threshold_hw)
    f_right_final = linear_interpolate_hw(f1_r, f2_r, L1_r, L2_r, abs_threshold_hw)

    return {
        'dft_bins': dft_bins,
        'power_hw_db': power_hw_db,
        'max_power_hw': max_power_hw,
        'f_left': f_left_final,
        'f_right': f_right_final,
        'left_pts': (f1_l, f2_l, L1_l, L2_l),
        'right_pts': (f1_r, f2_r, L1_r, L2_r)
    }

def plot_averaging_result(ax, time_data, fs, res, threshold_db, title_str):
    """
    Helper to plot a single subplot.
    """
    # Ground Truth PSD
    freqs_w, psd_w = signal.welch(time_data, fs=fs, window='hann', nperseg=len(time_data), scaling='density')
    psd_w_shifted = np.fft.fftshift(psd_w)
    freqs_w_shifted = np.fft.fftshift(freqs_w)
    psd_db = 10 * np.log10(psd_w_shifted + 1e-20)
    psd_db -= np.max(psd_db)

    ax.plot(freqs_w_shifted / 1e6, psd_db, color='dimgray', alpha=0.6, linewidth=1.5, label='Ground Truth')

    # Hardware DFT Bins
    dft_bins = res['dft_bins']
    freqs1 = np.array(list(dft_bins.keys()))
    powers1 = np.abs(np.array(list(dft_bins.values())))**2
    db1_norm = 3 * np.floor(np.log2(powers1 + 1e-20))
    db1_norm -= np.max(db1_norm)
    ax.plot(freqs1 / 1e6, db1_norm, 'ko', markersize=5, label='DFT Bins', alpha=0.9)

    # Edges
    mp = res['max_power_hw']
    f1_l, f2_l, L1_l, L2_l = res['left_pts']
    f1_r, f2_r, L1_r, L2_r = res['right_pts']
    
    if f1_l is not None:
        ax.plot([f1_l/1e6, f2_l/1e6], [L1_l - mp, L2_l - mp], 'rs-', markersize=6)
    if f1_r is not None:
        ax.plot([f1_r/1e6, f2_r/1e6], [L1_r - mp, L2_r - mp], 'bs-', markersize=6)

    # if not np.isnan(res['f_left']):
    #     ax.axvline(x=res['f_left']/1e6, color='r', linestyle='--', linewidth=1.5,
    #                label=rf'Est: {res['f_left']/1e6:.2f} MHz')
    # if not np.isnan(res['f_right']):
    #     ax.axvline(x=res['f_right']/1e6, color='b', linestyle='--', linewidth=1.5,
    #                label=rf'Est: {res['f_right']/1e6:.2f} MHz')

    ax.axhline(y=-threshold_db, color='orange', linestyle=':', linewidth=1.5, label='Threshold')
    
    ax.set_title(title_str, fontweight="bold")
    ax.set_ylabel("Power (dB)")
    ax.grid(True, alpha=0.3)
    ax.set_xlim([np.min(freqs_w_shifted)/1e6, np.max(freqs_w_shifted)/1e6])
    
    # Legend only on top plot to save space
    if "2 Channels" in title_str:
        ax.legend(loc='lower right', frameon=True, ncol=2, fontsize=9)


if __name__ == '__main__':
    print("--- Running Spatial Averaging Test ---")

    # --- 1. Load Data ---
    try:
        SIMULATOR_ROOT = Path(__file__).resolve().parent.parent
    except NameError:
        SIMULATOR_ROOT = Path.cwd().parent
    
    rf_path = SIMULATOR_ROOT / "datasets/experiments/contrast_speckle/contrast_speckle_expe_dataset_rf.hdf5"
    iq_path = SIMULATOR_ROOT / "datasets/experiments/contrast_speckle/contrast_speckle_expe_dataset_iq.hdf5"
    scan_path = SIMULATOR_ROOT / "datasets/experiments/contrast_speckle/contrast_speckle_expe_scan.hdf5"
    
    try:
        rf_data, angles, _, _, fs_picmus, mod_freq, _, _, _ = load_picmus_rf_data(rf_path, iq_path, scan_path)
    except Exception as e:
        print(f"Test failed: Could not load data. Error: {e}")
        exit()

    # --- 2. Virtual AFE ---
    center_angle_index = np.argmin(np.abs(angles))
    baseline_iq_data, _, fs_baseline = run_virtual_afe_processing(
        rf_data=rf_data,
        angle_index=center_angle_index,
        fs_picmus=fs_picmus,
        modulation_frequency=mod_freq,
        decimation_factor=4,
        adc_sample_rate=125e6
    )

    # --- 3. Prepare Data & Average ---
    nperseg = 256
    start_ch = 37
    window_num = 34
    hop = nperseg // 2
    
    start_sample = window_num * hop
    end_sample = start_sample + nperseg
    
    print(f"Analyzing Window {window_num}, Channels starting at {start_ch}")

    # Extract raw data for 4 neighboring channels
    # We slice [start:end, start_ch : start_ch + 4]
    raw_block = baseline_iq_data[start_sample:end_sample, start_ch : start_ch + 4]
    
    # Add Independent Noise to EACH channel BEFORE averaging
    # This is critical to demonstrate SNR improvement
    target_snr = 50.0
    noisy_block = np.zeros_like(raw_block, dtype=complex)
    
    for i in range(4):
        noisy_block[:, i] = add_awgn(raw_block[:, i], target_snr)

    # Create the two scenarios
    # 1. Average of 2 channels (Channel 0 and 1 of the block)
    avg_2_channels = np.mean(noisy_block[:, 0:2], axis=1)
    
    # 2. Average of 4 channels (Channel 0, 1, 2, 3 of the block)
    avg_4_channels = np.mean(noisy_block[:, 0:4], axis=1)

    # Scale signals (normalize max to ~1.0 for fixed point logic safety)
    scale_factor_2 = 1.5 / np.max(np.abs(avg_2_channels))
    data_scenario_1 = avg_2_channels * scale_factor_2
    
    scale_factor_4 = 1.5 / np.max(np.abs(avg_4_channels))
    data_scenario_2 = avg_4_channels * scale_factor_4

    # --- 4. Define Search Bins (Same for both) ---
    delta_f = 0.5e6 
    half_bw_est = mod_freq / 2
    s_coarse = np.linspace(-mod_freq, mod_freq, 8)
    s_fine_left = np.linspace(-half_bw_est - delta_f, -half_bw_est + delta_f, 8) 
    s_fine_right = np.linspace(half_bw_est - delta_f, half_bw_est + delta_f, 8) 
    S_bins = np.unique(np.concatenate([s_coarse, s_fine_left, s_fine_right]))

    # --- 5. Hardware Parameters (Updated from prompt) ---
    hw_params = {
        'ACCUM_WIDTH': 36,
        'ACCUM_FRAC': 28,
        'INPUT_WIDTH_LOG': 18,
        'POWER_WIDTH': 8,
        'POWER_FRAC': 0
    }
    threshold_db = 30.0

    # --- 6. Run Estimation ---
    print("\n--- Running Scenario 1: 2-Channel Average ---")
    res_2ch = run_hardware_estimation(data_scenario_1, fs_baseline, S_bins, threshold_db, hw_params)
    bw_2ch = (res_2ch['f_right'] - res_2ch['f_left']) / 1e6
    print(f"Est Bandwidth: {bw_2ch:.3f} MHz")

    print("\n--- Running Scenario 2: 4-Channel Average ---")
    res_4ch = run_hardware_estimation(data_scenario_2, fs_baseline, S_bins, threshold_db, hw_params)
    bw_4ch = (res_4ch['f_right'] - res_4ch['f_left']) / 1e6
    print(f"Est Bandwidth: {bw_4ch:.3f} MHz")

    # --- 7. Plotting ---
    fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(10, 8), sharex=True)
    
    plot_averaging_result(ax1, data_scenario_1, fs_baseline, res_2ch, threshold_db,
                          r"Scenario A: Spatial Averaging over 2 Channels")
    
    plot_averaging_result(ax2, data_scenario_2, fs_baseline, res_4ch, threshold_db,
                          r"Scenario B: Spatial Averaging over 4 Channels")

    ax2.set_xlabel("Frequency (MHz)")
    plt.tight_layout()

    # Save
    plots_dir = Path(__file__).resolve().parent / "plots"
    plots_dir.mkdir(parents=True, exist_ok=True)
    output_path = plots_dir / "averaging_comparison_thesis.png"
    plt.savefig(output_path, dpi=300, bbox_inches='tight')
    
    print(f"\nSUCCESS: Plot saved to {output_path}")
    plt.close()