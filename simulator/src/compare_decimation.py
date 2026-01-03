import numpy as np
import matplotlib.pyplot as plt
from pathlib import Path
import sys

# Ensure simulator src is in path
try:
    SIMULATOR_ROOT = Path(__file__).resolve().parent.parent
except NameError:
    SIMULATOR_ROOT = Path.cwd().parent

sys.path.append(str(SIMULATOR_ROOT / "simulator" / "src"))

from afe_interface_rf import load_picmus_rf_data
from virtual_afe import run_virtual_afe_processing

# --- CONFIGURATION ---
DECIMATION_BASELINE = 4   # Standard fixed decimation
DECIMATION_MAX = 10       # Max allowable decimation for this test case

# Dataset selection
DATASET_TYPE = "in_vivo" # 'experiments' or 'in_vivo'
DATASET_NAME = "carotid_long" # 'contrast_speckle' or 'carotid_long'

def get_dataset_paths(root, type_str, name_str):
    base = root / "datasets" / type_str / name_str
    return (
        base / f"{name_str}_expe_dataset_rf.hdf5",
        base / f"{name_str}_expe_dataset_iq.hdf5",
        base / f"{name_str}_expe_scan.hdf5"
    )

if __name__ == '__main__':
    print("--- Comparing Baseline vs Max Decimation ---")

    # 1. Load Data
    rf_path, iq_path, scan_path = get_dataset_paths(SIMULATOR_ROOT, DATASET_TYPE, DATASET_NAME)
    
    adc_rate = 125e6

    try:
        rf_data, angles, _, _, fs_picmus, mod_freq, _, _, _ = load_picmus_rf_data(rf_path, iq_path, scan_path)
    except Exception as e:
        print(f"Error loading data: {e}")
        exit()

    # 2. Select Test Case (Single Channel/Angle)
    # Using specific indices for consistency, or random
    angle_idx = np.argmin(np.abs(angles)) # Center angle
    channel_idx = 64 # Middle channel
    
    print(f"Test Case: Angle Index {angle_idx}, Channel {channel_idx}")

    # 3. Run Virtual AFE - Case A: Baseline
    print(f"Running Baseline (M={DECIMATION_BASELINE})...")
    iq_baseline, _, fs_baseline = run_virtual_afe_processing(
        rf_data=rf_data,
        angle_index=angle_idx,
        fs_picmus=fs_picmus,
        modulation_frequency=mod_freq,
        decimation_factor=DECIMATION_BASELINE,
        adc_sample_rate=adc_rate
    )
    
    # 4. Run Virtual AFE - Case B: Max Decimation
    print(f"Running Max Decimation (M={DECIMATION_MAX})...")
    iq_max, _, fs_max = run_virtual_afe_processing(
        rf_data=rf_data,
        angle_index=angle_idx,
        fs_picmus=fs_picmus,
        modulation_frequency=mod_freq,
        decimation_factor=DECIMATION_MAX,
        adc_sample_rate=adc_rate
    )

    # Extract single A-lines
    sig_base = iq_baseline[:, channel_idx]
    t_base = np.arange(len(sig_base)) / fs_baseline

    sig_max = iq_max[:, channel_idx]
    t_max = np.arange(len(sig_max)) / fs_max

    # 5. Interpolate Max Decimation onto Baseline Grid for Error Calc
    # (We interpolate the coarser signal up to the finer grid)
    sig_max_interp_real = np.interp(t_base, t_max, sig_max.real)
    sig_max_interp_imag = np.interp(t_base, t_max, sig_max.imag)
    sig_max_interp = sig_max_interp_real + 1j * sig_max_interp_imag
    
    # Calculate Error
    err = np.abs(sig_base - sig_max_interp)
    max_val = np.max(np.abs(sig_base))
    avg_err_norm = np.mean(err) / max_val * 100
    
    print(f"Average Interpolation Error: {avg_err_norm:.2f}% (relative to peak)")

    # # 6. Plotting
    # plt.rcParams.update({
    #     "font.family": "serif",
    #     "font.serif": ["Times New Roman", "Times", "DejaVu Serif", "serif"],
    #     "mathtext.fontset": "cm",
    #     "font.size": 12
    # })

    # fig, (ax1, ax2, ax3) = plt.subplots(3, 1, figsize=(10, 12), sharex=True)

    # # Plot 1: Baseline
    # ax1.plot(t_base * 1e6, sig_base.real, 'b-', label='I (Real)')
    # ax1.plot(t_base * 1e6, np.abs(sig_base), 'k-', linewidth=1.0, alpha=0.7, label='Envelope')
    # ax1.set_title(f"Baseline Decimation (M={DECIMATION_BASELINE}, $f_s$={fs_baseline/1e6:.2f} MHz)", fontweight='bold')
    # ax1.set_ylabel("Amplitude")
    # ax1.legend(loc='upper right', fontsize=10)
    # ax1.grid(True, alpha=0.3)

    # # Plot 2: Max Decimation
    # ax2.plot(t_max * 1e6, sig_max.real, 'r-', label='I (Real)')
    # ax2.plot(t_max * 1e6, np.abs(sig_max), 'k-', linewidth=1.0, alpha=0.7, label='Envelope')
    # # Mark the actual sample points to show scarcity
    # ax2.plot(t_max * 1e6, sig_max.real, 'r.', markersize=4, alpha=0.5, label='Samples') 
    # ax2.set_title(f"Max Allowable Decimation (M={DECIMATION_MAX}, $f_s$={fs_max/1e6:.2f} MHz)", fontweight='bold')
    # ax2.set_ylabel("Amplitude")
    # ax2.legend(loc='upper right', fontsize=10)
    # ax2.grid(True, alpha=0.3)

    # # Plot 3: Overlay / Comparison (Zoomed on a segment if long)
    # # Plotting Baseline as a solid line
    # ax3.plot(t_base * 1e6, sig_base.real, 'b-', linewidth=1.5, alpha=0.6, label=f'Baseline (M={DECIMATION_BASELINE})')
    # # Plotting Interpolated Max as dashed
    # ax3.plot(t_base * 1e6, sig_max_interp.real, 'r--', linewidth=1.5, label=f'Max Decim (M={DECIMATION_MAX})')
    
    # ax3.set_title("Direct Comparison (Real Component)", fontweight='bold')
    # ax3.set_xlabel("Time (µs)")
    # ax3.set_ylabel("Amplitude")
    # ax3.legend(loc='upper right', fontsize=10)
    # ax3.grid(True, alpha=0.3)
    
    # plt.tight_layout()

    # # Save
    # plots_dir = Path(__file__).resolve().parent / "plots"
    # plots_dir.mkdir(parents=True, exist_ok=True)
    # out_path = plots_dir / "decimation_comparison.png"
    # plt.savefig(out_path, dpi=300, bbox_inches='tight')
    
    # print(f"Plot saved to {out_path}")
    # plt.close()

    # 6. Plotting
    plt.rcParams.update({
        "font.family": "serif",
        "font.serif": ["Times New Roman", "Times", "DejaVu Serif", "serif"],
        "mathtext.fontset": "cm",
        "font.size": 11,
        "axes.titlesize": 12
    })

    # Create 3 rows, 2 columns
    fig, axes = plt.subplots(3, 2, figsize=(16, 12), sharex=True, sharey=True)
    
    # Unpack axes for easier reference
    # Row 0: Baseline, Row 1: Max Decim, Row 2: Comparison
    # Col 0: Real, Col 1: Imag
    ax_real_base, ax_imag_base = axes[0]
    ax_real_max,  ax_imag_max  = axes[1]
    ax_real_comp, ax_imag_comp = axes[2]

    # --- ROW 1: BASELINE (M=4) ---
    
    # Real
    ax_real_base.plot(t_base * 1e6, sig_base.real, 'b-', label='I (Real)')
    ax_real_base.plot(t_base * 1e6, np.abs(sig_base), 'k-', linewidth=0.8, alpha=0.5, label='Envelope')
    ax_real_base.set_title(f"Baseline Real (M={DECIMATION_BASELINE})", fontweight='bold')
    ax_real_base.set_ylabel("Amplitude")
    ax_real_base.legend(loc='upper right', fontsize=9)
    ax_real_base.grid(True, alpha=0.3)
    
    # Imag
    ax_imag_base.plot(t_base * 1e6, sig_base.imag, 'g-', label='Q (Imag)')
    ax_imag_base.plot(t_base * 1e6, np.abs(sig_base), 'k-', linewidth=0.8, alpha=0.5, label='Envelope')
    ax_imag_base.set_title(f"Baseline Imaginary (M={DECIMATION_BASELINE})", fontweight='bold')
    ax_imag_base.legend(loc='upper right', fontsize=9)
    ax_imag_base.grid(True, alpha=0.3)

    # --- ROW 2: MAX DECIMATION (M=10) ---
    
    # Real
    ax_real_max.plot(t_max * 1e6, sig_max.real, 'r-', label='I (Real)')
    ax_real_max.plot(t_max * 1e6, sig_max.real, 'r.', markersize=4, alpha=0.5) # Dots
    ax_real_max.plot(t_max * 1e6, np.abs(sig_max), 'k-', linewidth=0.8, alpha=0.5, label='Envelope')
    ax_real_max.set_title(f"Max Decimation Real (M={DECIMATION_MAX})", fontweight='bold')
    ax_real_max.set_ylabel("Amplitude")
    ax_real_max.legend(loc='upper right', fontsize=9)
    ax_real_max.grid(True, alpha=0.3)
    
    # Imag
    ax_imag_max.plot(t_max * 1e6, sig_max.imag, 'm-', label='Q (Imag)')
    ax_imag_max.plot(t_max * 1e6, sig_max.imag, 'm.', markersize=4, alpha=0.5) # Dots
    ax_imag_max.plot(t_max * 1e6, np.abs(sig_max), 'k-', linewidth=0.8, alpha=0.5, label='Envelope')
    ax_imag_max.set_title(f"Max Decimation Imaginary (M={DECIMATION_MAX})", fontweight='bold')
    ax_imag_max.legend(loc='upper right', fontsize=9)
    ax_imag_max.grid(True, alpha=0.3)

    # --- ROW 3: DIRECT COMPARISON (Overlay) ---
    
    # Real
    ax_real_comp.plot(t_base * 1e6, sig_base.real, 'b-', linewidth=1.5, alpha=0.6, label=f'Base (M={DECIMATION_BASELINE})')
    ax_real_comp.plot(t_base * 1e6, sig_max_interp.real, 'r--', linewidth=1.5, label=f'Max (M={DECIMATION_MAX})')
    ax_real_comp.set_title("Real Component Comparison", fontweight='bold')
    ax_real_comp.set_ylabel("Amplitude")
    ax_real_comp.set_xlabel("Time (µs)")
    ax_real_comp.legend(loc='upper right', fontsize=9)
    ax_real_comp.grid(True, alpha=0.3)
    
    # Imag
    ax_imag_comp.plot(t_base * 1e6, sig_base.imag, 'g-', linewidth=1.5, alpha=0.6, label=f'Base (M={DECIMATION_BASELINE})')
    ax_imag_comp.plot(t_base * 1e6, sig_max_interp.imag, 'm--', linewidth=1.5, label=f'Max (M={DECIMATION_MAX})')
    ax_imag_comp.set_title("Imaginary Component Comparison", fontweight='bold')
    ax_imag_comp.set_xlabel("Time (µs)")
    ax_imag_comp.legend(loc='upper right', fontsize=9)
    ax_imag_comp.grid(True, alpha=0.3)

    plt.tight_layout()

    # Save
    plots_dir = Path(__file__).resolve().parent / "plots"
    plots_dir.mkdir(parents=True, exist_ok=True)
    out_path = plots_dir / "decimation_comparison_complex.png"
    plt.savefig(out_path, dpi=300, bbox_inches='tight')
    
    print(f"Plot saved to {out_path}")
    plt.close()