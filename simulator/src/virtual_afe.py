import numpy as np
from scipy import signal
import matplotlib.pyplot as plt
from pathlib import Path

# data loader for RF data
from afe_interface_rf import load_picmus_rf_data
from ancient.quick_spectrogram_test import load_picmus_iq_data

def run_virtual_afe_processing(rf_data, angle_index, fs_picmus, modulation_frequency, decimation_factor, adc_sample_rate=125e6, snr_db=None, transducer_bw_percent=67):
    """
    Performs the virtual AFE simulation on pre-loaded PICMUS RF data.

    This function simulates the full pipeline:
    1. Upsamples the RF data for a specific angle to the target ADC rate.
    2. Performs I/Q demodulation on the high-rate RF data.
    3. Decimates the resulting I/Q data by the specified factor.
    
    Args:
        rf_data (np.ndarray): The full, low-rate PICMUS RF data array (angles, channels, samples).
        angle_index (int): The index of the angle from the dataset to process.
        fs_picmus (float): The original sample rate of the PICMUS RF data.
        modulation_frequency (float): The center frequency of the transducer for demodulation.
        decimation_factor (int): The integer decimation factor to apply.
        adc_sample_rate (float): The target sample rate of the virtual ADC in Hz.

    Returns:
        tuple: A tuple containing:
            - decimated_iq (np.ndarray): The final decimated I/Q data.
            - high_rate_iq (np.ndarray): The intermediate high-rate I/Q data (before decimation).
            - fs_new (float): The sample rate of the decimated_iq data.
    """
    
    # Upsample RF data for the chosen angle
    data_for_one_angle_rf = rf_data[angle_index, :, :].T
    
    upsample_factor_num = int(adc_sample_rate)
    upsample_factor_den = int(fs_picmus)
    
    high_rate_rf = signal.resample_poly(data_for_one_angle_rf, up=upsample_factor_num, down=upsample_factor_den, axis=0)
    # print(f"Upsampled RF data to shape: {high_rate_rf.shape}")

    # Add AWGN to the high-rate RF signal
    if snr_db is not None:
        # print(f"Adding AWGN to achieve an SNR of {snr_db} dB...")
        # Calculate the power of the signal
        signal_power = np.var(high_rate_rf)
        
        # Calculate the required noise power for the target SNR
        snr_linear = 10**(snr_db / 10)
        noise_power = signal_power / snr_linear
        
        # Generate gaussian noise with the required power (std dev = sqrt(power))
        noise_std = np.sqrt(noise_power)
        noise = np.random.normal(loc=0.0, scale=noise_std, size=high_rate_rf.shape)
        
        # Add the noise to the signal
        high_rate_rf = high_rate_rf + noise
        # print("Noise addition complete.")

    # --- MATHEMATICALLY IDEAL BPF ---
    # print("Applying ideal FFT-based band-pass filter to RF signal...")
    
    # Define the passband based on transducer specs
    center_freq = modulation_frequency
    bandwidth = center_freq * (87 / 100.0)
    low_cutoff = center_freq - (bandwidth / 2)
    high_cutoff = center_freq + (bandwidth / 2)
    # print(f"Ideal BPF Passband: [{low_cutoff/1e6:.2f}, {high_cutoff/1e6:.2f}] MHz")
    
    # Go to the frequency domain
    spectrum_rf = np.fft.fft(high_rate_rf, axis=0)
    
    # Create the frequency bins vector and the filter mask
    num_samples_high_rate = high_rate_rf.shape[0]
    freqs = np.fft.fftfreq(num_samples_high_rate, 1/adc_sample_rate)
    mask = np.where((np.abs(freqs) >= low_cutoff) & (np.abs(freqs) <= high_cutoff), 1, 0)
    
    # Apply the filter mask
    filtered_spectrum_rf = spectrum_rf * mask[:, np.newaxis]
    
    # Go back to time domain
    filtered_high_rate_rf = np.fft.ifft(filtered_spectrum_rf, axis=0).real 
    # print("Band-pass filtering complete.")
    # --- END OF MATHEMATICALLY IDEAL BPF ---
    
    # I/Q Demodulation 
    # Time vector for the high-rate RF signal
    # print(f"Performing I/Q Demodulation...")
    num_samples_high_rate = filtered_high_rate_rf.shape[0]
    t = np.arange(num_samples_high_rate) / adc_sample_rate
    
    # Complex local oscillator signal
    # Multiply by 2 to get the analytic signal (I + jQ) after filtering
    local_oscillator = 2 * np.exp(-1j * 2 * np.pi * modulation_frequency * t)
    
    # Demodulate by multiplying the RF signal by the complex oscillator
    # Reshape the local_oscillator to multiply it with each channel
    analytic_signal_passband = filtered_high_rate_rf * local_oscillator[:, np.newaxis]
    
    # Low-pass filter the result to remove the 2*f_c component and keep the baseband signal
    # Simple low-pass filter for this purpose
    # Cutoff should be less than the modulation frequency

    # --- MATHEMATICALLY IDEAL LPF ---
    
    # Go to the frequency domain
    spectrum = np.fft.fft(analytic_signal_passband, axis=0)
    # Absolute cutoff frequency in Hz
    abs_cutoff_hz = (modulation_frequency * (91 / 100.0)) / 2.0
    # print(f"Ideal LPF cutoff frequency: {abs_cutoff_hz / 1e6:.2f} MHz")
    # Create the frequency bins vector for this FFT
    freqs = np.fft.fftfreq(num_samples_high_rate, 1/adc_sample_rate)
    # Filter is 1 inside the passband and 0 outside
    # Two-sided spectrum (positive and negative frequencies)
    mask = np.where(np.abs(freqs) <= abs_cutoff_hz, 1, 0)
    # Multiply the spectrum by the filter for each channel
    filtered_spectrum = spectrum * mask[:, np.newaxis]
    # Go back to the time domain
    high_rate_iq = np.fft.ifft(filtered_spectrum, axis=0)
    # print(f"I/Q Demodulation complete. High-rate IQ shape: {high_rate_iq.shape}")
    
    # --- END OF MATHEMATICALLY IDEAL LPF ---

    # Add AWGN noise a second time
    if snr_db is not None:
        print(f"Adding AWGN to achieve an SNR of {snr_db} dB...")
        high_rate_iq = high_rate_iq + noise
        print("Noise addition complete.")

    # Decimate the high-rate I/Q data
    if decimation_factor < 1:
        raise ValueError("Decimation factor must be >= 1.")
    if decimation_factor == 1:
        decimated_iq = high_rate_iq.copy()
    else:
        # The decimate function includes its own anti-aliasing filter
        decimated_iq = signal.decimate(high_rate_iq, q=decimation_factor, axis=0)
    
    fs_new = adc_sample_rate / decimation_factor
    
    return decimated_iq, high_rate_iq, fs_new