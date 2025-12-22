import numpy as np
import matplotlib.pyplot as plt

def quantize_to_int16(signal_float):
    """
    Simulates rounding to 16-bit integer range [-32768, 32767].
    """
    scale_factor = 32767.0
    val_scaled = signal_float * scale_factor
    val_int = np.round(val_scaled)
    
    # Check for clipping before applying it
    clip_mask = (val_int > 32767) | (val_int < -32768)
    if np.any(clip_mask):
        print(f"  WARNING: {np.sum(clip_mask)} samples clipped during quantization!")

    val_int = np.clip(val_int, -32768, 32767)
    return val_int, scale_factor

def calculate_sqnr(signal_power, noise_power):
    """Calculates SQNR in dB given raw powers."""
    if noise_power == 0: return float('inf')
    return 10 * np.log10(signal_power / noise_power)

def run_simulation():
    print("=== AFE Filter Gain Staging Proof ===\n")
    
    # -------------------------------------------------------------------------
    # 1. The Physical World (Analog Input)
    # -------------------------------------------------------------------------
    n_samples = 200
    # Signal spans 4 full cycles (0 to 8pi)
    t = np.linspace(0, 8*np.pi, n_samples)
    
    # FIX: Reduce Amplitude to 0.8 (-2 dBFS) to prevent clipping in Scenario B
    # This leaves headroom for the noise and rounding at the top of the range.
    original_physics_signal = 0.8 * np.sin(t)
    
    # Signal attenuation by tissue (-6dB) 
    tissue_atten_db = -6.0
    tissue_gain = 10**(tissue_atten_db/20.0) # ~0.501
    
    # Input Thermal Noise (-80dB, low enough to see quantization effects clearly)
    snr_input = -35
    input_noise = np.random.normal(0, 10**(snr_input/20), n_samples)

    analog_input_total = (original_physics_signal * tissue_gain) + input_noise
    
    print(f"Input Signal Peak: {np.max(np.abs(analog_input_total)):.4f} (relative to FS=1.0)")

    # -------------------------------------------------------------------------
    # 2. First Quantization (The ADC)
    # -------------------------------------------------------------------------
    print("\n--- ADC Conversion ---")
    adc_output_int, scale_factor = quantize_to_int16(analog_input_total)
    
    # -------------------------------------------------------------------------
    # 3. The Processing Fork (Internal High Precision)
    # -------------------------------------------------------------------------
    
    # Scenario A: Standard Filter (Attenuates -3dB)
    filter_gain_A_db = -3.0
    gain_A = 10**(filter_gain_A_db/20.0) # ~0.707
    internal_A = adc_output_int * gain_A
    
    # Scenario B: Boost Filter (Boosts +6dB)
    filter_gain_B_db = 6.0
    gain_B = 10**(filter_gain_B_db/20.0) # ~1.995
    internal_B = adc_output_int * gain_B

    # -------------------------------------------------------------------------
    # 4. Second Quantization (Output to FPGA)
    # -------------------------------------------------------------------------
    
    print("\n--- Re-Quantization (to 16-bit) ---")
    # Output A
    output_A_int = np.round(internal_A)
    # Check clipping A
    if np.any((output_A_int > 32767) | (output_A_int < -32768)):
        print("  Scenario A Clipped!")
    output_A_int = np.clip(output_A_int, -32768, 32767)
    
    # Output B
    output_B_int = np.round(internal_B)
    # Check clipping B
    if np.any((output_B_int > 32767) | (output_B_int < -32768)):
        print("  Scenario B Clipped! (Results will be invalid)")
    output_B_int = np.clip(output_B_int, -32768, 32767)

    # -------------------------------------------------------------------------
    # 5. Analysis: Input-Referred Noise
    # -------------------------------------------------------------------------
    
    # Error introduced by the rounding step (Output Domain LSBs)
    error_A_out = internal_A - output_A_int
    error_B_out = internal_B - output_B_int
    
    # Refer error back to the Input Domain (divide by the gain applied)
    error_A_in = error_A_out / gain_A
    error_B_in = error_B_out / gain_B
    
    # Calculate Powers
    # We compare noise against the theoretical signal power in the ADC domain
    signal_power_adc = np.mean(adc_output_int**2)
    noise_power_A = np.mean(error_A_in**2)
    noise_power_B = np.mean(error_B_in**2)
    
    sqnr_A = calculate_sqnr(signal_power_adc, noise_power_A)
    sqnr_B = calculate_sqnr(signal_power_adc, noise_power_B)
    
    print("\n=== Results: Re-Quantization SQNR ===")
    print(f"Scenario A (Attenuated): {sqnr_A:.2f} dB")
    print(f"Scenario B (Boosted):    {sqnr_B:.2f} dB")
    
    diff = sqnr_B - sqnr_A
    print(f"\nImprovement:          {diff:.2f} dB")
    print(f"Effective Bits Gained: {diff/6.02:.2f} bits")
    print(f"Theoretical Gain Diff: {filter_gain_B_db - filter_gain_A_db:.2f} dB")

    # -------------------------------------------------------------------------
    # 6. Plotting
    # -------------------------------------------------------------------------
    plt.figure(figsize=(10, 10))
    
    # DYNAMIC PLOT LIMIT: Always show exactly 1 cycle for clarity
    samples_to_plot = int(n_samples)
    
    # Plot 1: Original Analog Signal
    plt.subplot(3, 1, 1)
    plt.plot(t[:samples_to_plot], analog_input_total[:samples_to_plot], 'k', label='Analog Input (Attenuated + Noise)')
    plt.title(f"1. Original Analog Signal (Input to ADC) - First {samples_to_plot} samples")
    plt.ylabel("Amplitude (Normalized)")
    plt.legend(loc='upper right')
    plt.grid(True, alpha=0.3)
    
    # Plot 2: Filtered Digital Signals
    plt.subplot(3, 1, 2)
    plt.plot(output_B_int[:samples_to_plot], 'b', label=f'Scenario B: Boosted (Used Range: {np.max(np.abs(output_B_int))})')
    plt.plot(output_A_int[:samples_to_plot], 'r', label=f'Scenario A: Attenuated (Used Range: {np.max(np.abs(output_A_int))})')
    plt.title("2. Digital Output Codes (16-bit)")
    plt.ylabel("16-bit Integer Code")
    plt.legend(loc='upper right')
    plt.grid(True, alpha=0.3)
    
    # Plot 3: Input-Referred Error
    plt.subplot(3, 1, 3)
    plt.plot(error_A_in[:samples_to_plot], 'r', label='Error A (Input Ref)', alpha=0.6)
    plt.plot(error_B_in[:samples_to_plot], 'b', label='Error B (Input Ref)', alpha=0.6)
    plt.title("3. Effective Noise Referred to Input")
    plt.ylabel("Error (ADC LSBs)")
    plt.legend(loc='upper right')
    plt.grid(True, alpha=0.3)
    
    plt.tight_layout()
    plt.show()

if __name__ == "__main__":
    run_simulation()