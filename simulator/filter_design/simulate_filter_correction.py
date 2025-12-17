import numpy as np
import matplotlib.pyplot as plt
from scipy import signal
import os

# ==============================================================================
# 0. Setup and Helper Functions
# ==============================================================================

def read_coeffs(filename, skip_lines):
    """Reads filter coefficients from a text file, skipping header lines."""
    coeffs = []
    try:
        with open(filename, 'r') as f:
            lines = f.readlines()
            # robustly find numbers after header
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
        return np.zeros(64) # Fallback

# ==============================================================================
# 1. Configuration
# ==============================================================================

FS_HIGH = 125e6       # Input Sampling Rate (125 MHz)
DECIMATION = 4        # Decimation Factor
FS_LOW = FS_HIGH / DECIMATION # 31.25 MHz
NYQUIST = FS_HIGH / 2

# Define the "Cutoff" frequency where the signal drops to -6dB
# This is used to generate the test signal.
F_CUTOFF = 3e6 

# ==============================================================================
# 2. Load Coefficients
# ==============================================================================

print("Loading Filter Coefficients...")
# Filter A: Generic LPF (Standard roll-off)
coeffs_generic = read_coeffs('generic_lpf_coeffs.txt', skip_lines=6)
# Filter B: Boost Filter ("Smile" shape)
coeffs_boost   = read_coeffs('filter_coefficients.txt', skip_lines=7)

print(f"  Generic LPF: {len(coeffs_generic)} taps loaded.")
print(f"  Boost Filter: {len(coeffs_boost)} taps loaded.")

# ==============================================================================
# 3. Signal Generation (High Sample Rate)
# ==============================================================================

num_samples = 4096
t = np.arange(num_samples) / FS_HIGH

# --- A. Frequency Domain Channel Model (Broadband) ---
# Create a broadband noise signal that mimics the transducer response
# Flat at DC, rolling off to -6dB at F_CUTOFF
noise_white = np.random.normal(0, 1, num_samples)

# We create a "Channel Filter" to shape this noise
# Simple 1st order rolloff approximation
channel_cutoff = F_CUTOFF / np.sqrt(3) # adjust so it's -6dB at F_CUTOFF roughly
b_chan, a_chan = signal.butter(1, channel_cutoff / NYQUIST, btype='low')
broadband_signal = signal.lfilter(b_chan, a_chan, noise_white)

# --- B. Single Tone Test (At Cutoff) ---
# Generate pure sine at cutoff
# Calculate theoretical attenuation of the channel at this freq
w, h_chan = signal.freqz(b_chan, a_chan, worN=[F_CUTOFF], fs=FS_HIGH)
channel_gain_linear = np.abs(h_chan[0])
channel_gain_db = 20 * np.log10(channel_gain_linear)

print(f"\nGenerating Signal at {F_CUTOFF/1e6:.2f} MHz")
print(f"  Channel Attenuation: {channel_gain_db:.2f} dB (Linear: {channel_gain_linear:.4f})")

# Generate the pre-attenuated sine wave (representing the weak signal coming from AFE ADC)
# Amplitude is 1.0 * attenuation
# Add some AWGN (Additive White Gaussian Noise)
awgn_level = 0.05
sine_wave_input = (channel_gain_linear * np.sin(2 * np.pi * F_CUTOFF * t)) + \
                  np.random.normal(0, awgn_level, num_samples)

# ==============================================================================
# 4. Apply Filters (Processing & Decimation)
# ==============================================================================

# Filter A: Generic LPF
# 1. Filter at High Rate
filtered_A = signal.lfilter(coeffs_generic, 1.0, sine_wave_input)
# 2. Decimate (Keep every Ith sample)
output_A = filtered_A[::DECIMATION]

# Filter B: Boost Filter
# 1. Filter at High Rate
filtered_B = signal.lfilter(coeffs_boost, 1.0, sine_wave_input)
# 2. Decimate
output_B = filtered_B[::DECIMATION]

# Create Time axis for output (Low Sample Rate)
t_out = np.arange(len(output_A)) / FS_LOW

# ==============================================================================
# 5. Analysis & Plotting
# ==============================================================================

plt.figure(figsize=(14, 10))

# --- Plot 1: Filter Responses ---
plt.subplot(2, 2, 1)
w, h_A = signal.freqz(coeffs_generic, 1, worN=2048, fs=FS_HIGH)
w, h_B = signal.freqz(coeffs_boost, 1, worN=2048, fs=FS_HIGH)
plt.plot(w/1e6, 20*np.log10(np.abs(h_A)), 'b', label='Generic LPF')
plt.plot(w/1e6, 20*np.log10(np.abs(h_B)), 'r', label='Boost Filter')
plt.axvline(F_CUTOFF/1e6, color='k', linestyle='--', label='Cutoff Freq')
plt.title("Filter Frequency Responses")
plt.xlabel("Frequency (MHz)")
plt.ylabel("Gain (dB)")
plt.legend()
plt.grid(True)
plt.xlim(0, FS_LOW/1e6) # Plot up to output sample rate

# --- Plot 2: Time Domain Comparison ---
plt.subplot(2, 1, 2)
# Plot a zoom in of the waves
zoom_samples = 100
plt.plot(t_out[:zoom_samples]*1e6, output_A[:zoom_samples], 'b-o', label='Output A (Generic)', alpha=0.7)
plt.plot(t_out[:zoom_samples]*1e6, output_B[:zoom_samples], 'r-o', label='Output B (Boosted)', alpha=0.7)
plt.axhline(channel_gain_linear, color='gray', linestyle=':', label='Attenuated Input Level')
plt.axhline(1.0, color='k', linestyle='--', label='Original Ideal Level (1.0)')

plt.title(f"Time Domain Output (Sampled at {FS_LOW/1e6} MHz)")
plt.xlabel("Time (us)")
plt.ylabel("Amplitude")
plt.legend()
plt.grid(True)

# Measure RMS amplitudes to verify boost
rms_A = np.sqrt(np.mean(output_A**2))
rms_B = np.sqrt(np.mean(output_B**2))
print(f"\nResults:")
print(f"  Output A RMS: {rms_A:.4f}")
print(f"  Output B RMS: {rms_B:.4f}")
print(f"  Gain Recovered: {20*np.log10(rms_B/rms_A):.2f} dB")

plt.tight_layout()
plt.show()