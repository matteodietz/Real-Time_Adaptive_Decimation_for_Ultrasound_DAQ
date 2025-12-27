import numpy as np
import matplotlib.pyplot as plt
from scipy import signal
import sys
from scipy.optimize import leastsq

# ==============================================================================
# 0. Setup and Helpers
# ==============================================================================

def read_coeffs(filename, skip_lines):
    """Reads filter coefficients from a text file."""
    coeffs = []
    try:
        with open(filename, 'r') as f:
            lines = f.readlines()
            data_lines = lines[skip_lines:]
            for line in data_lines:
                line = line.strip()
                if line and not line.startswith('%'):
                    try:
                        coeffs.append(float(line))
                    except ValueError:
                        pass
        return np.array(coeffs)
    except FileNotFoundError:
        print(f"Error: {filename} not found.")
        sys.exit(1)

def quantize_to_int16(signal_float):
    """
    Simulates rounding to 16-bit integer range [-32768, 32767].
    Input is assumed to be normalized such that 1.0 = Full Scale.
    """
    scale_factor = 32767.0
    val_scaled = signal_float * scale_factor
    val_int = np.round(val_scaled)
    
    # Check for clipping
    clip_mask = (val_int > 32767) | (val_int < -32768)
    if np.any(clip_mask):
        print(f"  WARNING: {np.sum(clip_mask)} samples clipped during quantization!")

    val_int = np.clip(val_int, -32768, 32767)
    return val_int

def calculate_sqnr(signal_power, noise_power):
    """Your original simple SQNR calculation."""
    if noise_power == 0: return float('inf')
    return 10 * np.log10(signal_power / noise_power)

def calculate_ieee_sinad(data_record, fs, freq_estimate):
    """
    Calculates SNR using Sine Wave Fitting (IEEE Std 1241).
    Fits y = A*cos(wt) + B*sin(wt) + C to the data.
    """
    N = len(data_record)
    t = np.arange(N) / fs
    w = 2 * np.pi * freq_estimate
    
    # Create design matrix for linear least squares
    # D = [cos(wt), sin(wt), 1]
    D = np.column_stack([np.cos(w*t), np.sin(w*t), np.ones(N)])
    
    # Solve D * [A, B, C]^T = data_record
    # We use lstsq to minimize the L2 norm of the residual
    coeffs, residuals, rank, s = np.linalg.lstsq(D, data_record, rcond=None)
    
    # Reconstruct the fitted sine wave
    fitted_sine = D @ coeffs
    
    # Calculate Residuals (Noise + Distortion)
    noise_residual = data_record - fitted_sine
    
    # Calculate RMS values
    # Note: fitted_sine includes DC offset (coeffs[2]). 
    # For signal power, we strictly want the AC component RMS.
    # AC Amplitude = sqrt(A^2 + B^2)
    # AC RMS = Amplitude / sqrt(2)
    A, B, C = coeffs
    signal_rms = np.sqrt(A**2 + B**2) / np.sqrt(2)
    noise_rms = np.sqrt(np.mean(noise_residual**2))
    
    if noise_rms == 0: return float('inf')
    
    sinad_db = 20 * np.log10(signal_rms / noise_rms)
    return sinad_db

# ==============================================================================
# 1. Configuration & Loading
# ==============================================================================

FS_HIGH = 125e6       # 125 MHz
DECIMATION = 4
FS_LOW = FS_HIGH / DECIMATION # 31.25 MHz

# Frequency of interest (Bandwidth Edge)
F_CUTOFF = 3e6 

print("Loading Filter Coefficients...")
# Filter A: Generic LPF
coeffs_generic = read_coeffs('generic_lpf_coeffs.txt', skip_lines=6)
# Filter B: Boost Filter
coeffs_boost   = read_coeffs('boost_filter_coeffs.txt', skip_lines=7)

print(f"  Generic LPF: {len(coeffs_generic)} taps")
print(f"  Boost Filter: {len(coeffs_boost)} taps")

# Calculate precise gain of each filter at the cutoff frequency
w, h_A = signal.freqz(coeffs_generic, 1, worN=[F_CUTOFF], fs=FS_HIGH)
gain_A_linear = np.abs(h_A[0])

w, h_B = signal.freqz(coeffs_boost, 1, worN=[F_CUTOFF], fs=FS_HIGH)
gain_B_linear = np.abs(h_B[0])

print(f"  Gain A at {F_CUTOFF/1e6:.1f} MHz: {gain_A_linear:.4f} ({20*np.log10(gain_A_linear):.2f} dB)")
print(f"  Gain B at {F_CUTOFF/1e6:.1f} MHz: {gain_B_linear:.4f} ({20*np.log10(gain_B_linear):.2f} dB)")

# ==============================================================================
# 2. Signal Generation (The Physical World)
# ==============================================================================
n_samples = 4096
t = np.arange(n_samples) / FS_HIGH

# Channel Model: -6dB Attenuation at Cutoff
channel_atten_db = -6.0
channel_gain_linear = 10**(channel_atten_db/20.0) # 0.5

# Input Thermal Noise (-50dB SNR relative to full scale)
noise_db_fs = -35.0 
noise_std = 10**(noise_db_fs/20.0)
input_noise = np.random.normal(0, noise_std, n_samples)

# Signal: 0.9 Amplitude (Headroom) * Channel Attenuation
original_signal = 0.9 * np.sin(2 * np.pi * F_CUTOFF * t)
analog_input = (original_signal * channel_gain_linear) + input_noise

print(f"\nSignal Generation:")
print(f"  Input Peak: {np.max(np.abs(analog_input)):.4f} (Relative to FS 1.0)")

# ==============================================================================
# 3. ADC Quantization (First Quantization)
# ==============================================================================
adc_output_int = quantize_to_int16(analog_input)

# ==============================================================================
# 4. DSP Processing (High Precision Internal)
# ==============================================================================
# Filter A (Generic)
internal_A = signal.lfilter(coeffs_generic, 1.0, adc_output_int)
internal_A_dec = internal_A[::DECIMATION]

# Filter B (Boosted)
internal_B = signal.lfilter(coeffs_boost, 1.0, adc_output_int)
internal_B_dec = internal_B[::DECIMATION]

# ==============================================================================
# 5. Output Re-Quantization (Second Quantization)
# ==============================================================================
# Output A
output_A_int = np.clip(np.round(internal_A_dec), -32768, 32767)

# Output B
output_B_int = np.clip(np.round(internal_B_dec), -32768, 32767)

# ==============================================================================
# 6. Error Analysis
# ==============================================================================

# --- Method 1: Component SQNR (Your Method) ---
error_A_out = internal_A_dec - output_A_int
error_B_out = internal_B_dec - output_B_int

error_A_in = error_A_out / gain_A_linear
error_B_in = error_B_out / gain_B_linear

signal_power = np.mean(adc_output_int[::DECIMATION]**2)
noise_power_A = np.mean(error_A_in**2)
noise_power_B = np.mean(error_B_in**2)

sqnr_A = calculate_sqnr(signal_power, noise_power_A)
sqnr_B = calculate_sqnr(signal_power, noise_power_B)

# --- Method 2: IEEE 1241 Sine Wave Fitting SNR ---
# We calculate SNR on the FINAL output (output_A_int, output_B_int).
# Note: This will include Input Thermal Noise + Quantization Noise.
# To be fair to IEEE, we should convert the int16 output back to float/input referred units first
# OR just fit the int16 directly (IEEE allows units to be anything as long as consistent).
# We fit directly to the output codes.

# We discard the first few samples to avoid filter transient effects on the fit
fit_start_idx = 100 
sinad_ieee_A = calculate_ieee_sinad(output_A_int[fit_start_idx:], FS_LOW, F_CUTOFF)
sinad_ieee_B = calculate_ieee_sinad(output_B_int[fit_start_idx:], FS_LOW, F_CUTOFF)

print("\n=== Results: Comparison of Metrics ===")
print(f"{'Metric':<25} | {'Scenario A (Std)':<15} | {'Scenario B (Boost)':<15} | {'Diff':<10}")
print("-" * 75)
print(f"{'Re-Quant SQNR (Yours)':<25} | {sqnr_A:>12.2f} dB | {sqnr_B:>12.2f} dB | {sqnr_B - sqnr_A:>+7.2f} dB")
print(f"{'IEEE 1241 SINAD (Total)':<25} | {sinad_ieee_A:>12.2f} dB | {sinad_ieee_B:>12.2f} dB | {sinad_ieee_B - sinad_ieee_A:>+7.2f} dB")
print("-" * 75)
print(f"Effective Bits Gained SQNR Method: {(sqnr_B - sqnr_A)/6.02:.2f} bits\n")
print("Note: IEEE SINAD is lower because it includes input thermal noise (-35dBFS).")
print("      SQNR isolates purely the digital re-quantization step.")


# ==============================================================================
# 7. Plotting Setup (Alignment & Styling)
# ==============================================================================

# --- A. Style Settings (LaTeX-like) ---
plt.rcParams.update({
    "font.family": "serif",
    "font.serif": ["Times New Roman", "Times", "DejaVu Serif", "serif"],
    "mathtext.fontset": "cm",  # Computer Modern for math
    "font.size": 12,
    "axes.labelsize": 12,
    "axes.titlesize": 14
})

# --- B. Automatic Peak Alignment ---
# We want both plots to start exactly at a signal peak to look aligned.

# 1. High Rate Alignment (Analog Input)
# Skip first 2 periods to avoid filter transients in the digital comparison later
samples_per_period_hi = int(FS_HIGH / F_CUTOFF)
search_start_hi = 3 * samples_per_period_hi 

# Find the first peak index in the search region
# We search one full period to find the local max
search_region_hi = analog_input[search_start_hi : search_start_hi + samples_per_period_hi]
peak_offset_hi = np.argmax(search_region_hi)
idx_start_hi = search_start_hi + peak_offset_hi

# Determine how many samples to show (e.g. 6 periods)
show_periods = 6
idx_end_hi = idx_start_hi + int(show_periods * samples_per_period_hi)

# Create zero-referenced time vector for plotting
t_plot_hi = (np.arange(idx_end_hi - idx_start_hi) / FS_HIGH) * 1e6 # in us

# 2. Low Rate Alignment (Digital Output)
# We align based on the Boosted signal (B) because it's cleaner
samples_per_period_lo = int(FS_LOW / F_CUTOFF)
search_start_lo = 3 * samples_per_period_lo

search_region_lo = output_B_int[search_start_lo : search_start_lo + samples_per_period_lo]
peak_offset_lo = np.argmax(search_region_lo)
idx_start_lo = search_start_lo + peak_offset_lo

idx_end_lo = idx_start_lo + int(show_periods * samples_per_period_lo)

# Create zero-referenced time vector for plotting
t_plot_lo = (np.arange(idx_end_lo - idx_start_lo) / FS_LOW) * 1e6 # in us

# ==============================================================================
# 8. Plotting
# ==============================================================================
plt.figure(figsize=(12, 14)) # Slightly adjusted aspect ratio

# --- Plot 1: Original Analog Signal ---
plt.subplot(4, 1, 1)
# Plot the slice starting exactly at the peak
plt.plot(t_plot_hi, analog_input[idx_start_hi:idx_end_hi], 'k', linewidth=1.5, label='Analog Input')
plt.title(r"a) Original Analog Signal (Input to ADC)", fontweight="bold")
plt.ylabel("Amplitude (Normalized)")
plt.xlabel(r"Time ($\mu$s)")
plt.legend(loc='upper right', frameon=True)
plt.grid(True, alpha=0.3)
plt.xlim(0, t_plot_hi[-1])

# --- Plot 2: Filter Frequency Responses (Symmetric) ---
plt.subplot(4, 1, 2)
# Calculate response over full unit circle [0, 2pi) to get negative frequencies via fftshift
w_A, h_A = signal.freqz(coeffs_generic, 1, worN=4096, fs=FS_HIGH, whole=True)
w_B, h_B = signal.freqz(coeffs_boost, 1, worN=4096, fs=FS_HIGH, whole=True)

# Shift zero frequency to center
freqs_shifted = np.fft.fftshift(np.fft.fftfreq(4096, d=1/FS_HIGH))
h_A_shifted = np.fft.fftshift(h_A)
h_B_shifted = np.fft.fftshift(h_B)

plt.plot(freqs_shifted/1e6, 20*np.log10(np.abs(h_A_shifted) + 1e-12), 'r', linewidth=1.5, label='Generic LPF')
plt.plot(freqs_shifted/1e6, 20*np.log10(np.abs(h_B_shifted) + 1e-12), 'b', linewidth=1.5, label='Boost Filter')

# Mark cutoff
plt.axvline(F_CUTOFF/1e6, color='k', linestyle='--', label='Signal Freq')
plt.axvline(-F_CUTOFF/1e6, color='k', linestyle='--')

plt.title(r"b) Filter Frequency Responses", fontweight="bold")
plt.xlabel("Frequency (MHz)")
plt.ylabel("Gain (dB)")
plt.legend(loc='upper right', frameon=True, ncol=1) # Moved legend to avoid covering curve
plt.grid(True)
plt.xlim(-FS_LOW/1e6, FS_LOW/1e6) 
plt.ylim(-80, 20) # Adjusted ylim to look cleaner

# --- Plot 3: Digital Output Signals ---
plt.subplot(4, 1, 3)
plt.step(t_plot_lo, output_B_int[idx_start_lo:idx_end_lo], 'b', where='mid', linewidth=1.5,
         label=f'Boosted Output')
plt.step(t_plot_lo, output_A_int[idx_start_lo:idx_end_lo], 'r', where='mid', linewidth=1.5,
         label=f'Generic Output')

plt.title(r"c) Digital Output Codes (16-bit) at %.2f MHz" % (FS_LOW/1e6), fontweight="bold")
plt.ylabel("Integer Value")
plt.xlabel(r"Time ($\mu$s)")
plt.legend(loc='upper right', frameon=True)
plt.grid(True, alpha=0.3)
plt.xlim(0, t_plot_lo[-1])

# --- Plot 4: Input-Referred Error ---
plt.subplot(4, 1, 4)
plt.plot(t_plot_lo, error_A_in[idx_start_lo:idx_end_lo], 'r', linewidth=1.2, label='Error A (Input Ref)')
plt.plot(t_plot_lo, error_B_in[idx_start_lo:idx_end_lo], 'b', linewidth=1.2, label='Error B (Input Ref)')
plt.title(r"d) Effective Quantization Noise Referred to Filter Input", fontweight="bold")
plt.ylabel("Error (ADC LSBs)")
plt.xlabel(r"Time ($\mu$s)")
plt.legend(loc='upper right', frameon=True)
plt.grid(True, alpha=0.3)
plt.xlim(0, t_plot_lo[-1])

plt.tight_layout(h_pad=2.0)
plt.savefig('afe_filter_comparison.png', dpi=300) # Increased DPI for thesis quality
print("\nPlot saved to afe_filter_comparison.png")
plt.show()