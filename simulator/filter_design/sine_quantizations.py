import numpy as np
import matplotlib.pyplot as plt

def float_to_fixed_point(value, total_bits, frac_bits, signed=True):
    """
    Simulates the AFE Quantizer (ADC).
    Converts float to integer representation of fixed point.
    """
    scale = 2 ** frac_bits
    
    # 1. Scale
    scaled = value * scale
    
    # 2. Round (This is where information is lost!)
    fixed_val = int(np.round(scaled))
    
    # 3. Saturation / Clipping logic
    if signed:
        max_val = 2 ** (total_bits - 1) - 1
        min_val = -(2 ** (total_bits - 1))
    else:
        max_val = 2 ** total_bits - 1
        min_val = 0
        
    fixed_val = max(min_val, min(max_val, fixed_val))
    
    # 4. Convert to unsigned integer for "wire" format (SystemVerilog compatibility)
    if signed and fixed_val < 0:
        fixed_val = (1 << total_bits) + fixed_val
        
    return fixed_val

def fixed_point_to_float(fixed_val, total_bits, frac_bits, signed=True):
    """
    Simulates the FPGA reading the integer and interpreting it as a voltage.
    """
    if not signed:
        return float(fixed_val) / (2**frac_bits)

    sign_bit_mask = 1 << (total_bits - 1)
    
    if (fixed_val & sign_bit_mask):
        signed_int = fixed_val - (1 << total_bits)
    else:
        signed_int = fixed_val
        
    return float(signed_int) / (2**frac_bits)

def run_simulation():
    # --- Configuration ---
    FS_HIGH = 125e6
    DECIMATION = 4
    FS = FS_HIGH / DECIMATION  # 31.25 MHz
    
    FREQ = 3e6 
    
    # Bit Configuration (16-bit output, Q2.14 format)
    TOTAL_BITS = 16
    FRAC_BITS = 14
    
    # Simulation Window
    num_samples = 100
    t = np.arange(num_samples) / FS
    
    # 1. Ideal Input Signal (Magnitude 1.0)
    ideal_signal = 1.0 * np.sin(2 * np.pi * FREQ * t)

    # --- Scenario A: The "Generic" Path (Attenuated) ---
    # Logic: Transducer (-6dB) + Filter (-3dB) = -9dB Total Attenuation
    atten_db = -9.0
    atten_gain = 10**(atten_db / 20.0) # ~0.355
    
    print(f"Scenario A Attenuation: {atten_db} dB (Linear: {atten_gain:.4f})")
    
    # A1. Apply Analog Attenuation
    sig_a_analog = ideal_signal * atten_gain
    
    # A2. Quantize (ADC Step) -> This creates the "Staircase"
    # We apply the quantization to the weak signal
    sig_a_digital_int = [float_to_fixed_point(x, TOTAL_BITS, FRAC_BITS) for x in sig_a_analog]
    
    # A3. Reconstruct (FPGA Step)
    sig_a_recon_raw = np.array([fixed_point_to_float(x, TOTAL_BITS, FRAC_BITS) for x in sig_a_digital_int])
    
    # A4. Digital Correction (The Comparison Step)
    # To compare with the original, we must digitally boost it back up
    # This amplifies the quantization error!
    sig_a_final = sig_a_recon_raw / atten_gain

    # --- Scenario B: The "Boosted" Path ---
    # Logic: We apply analog gain to counteract the -9dB BEFORE quantization.
    # So the signal entering the ADC is approx Magnitude 1.0
    
    # B1. Apply Boost (effectively canceling attenuation)
    sig_b_analog = ideal_signal * 1.0 
    
    # B2. Quantize (ADC Step)
    sig_b_digital_int = [float_to_fixed_point(x, TOTAL_BITS, FRAC_BITS) for x in sig_b_analog]
    
    # B3. Reconstruct (FPGA Step)
    sig_b_final = np.array([fixed_point_to_float(x, TOTAL_BITS, FRAC_BITS) for x in sig_b_digital_int])
    
    # B4. No Digital Correction needed (Signal is already at correct scale)

    # --- Analysis ---
    error_a = ideal_signal - sig_a_final
    error_b = ideal_signal - sig_b_final
    
    sqnr_a = 10 * np.log10(np.mean(ideal_signal**2) / np.mean(error_a**2))
    sqnr_b = 10 * np.log10(np.mean(ideal_signal**2) / np.mean(error_b**2))
    
    print(f"\n--- Results ---")
    print(f"SQNR Scenario A (Attenuated then Digitally Boosted): {sqnr_a:.2f} dB")
    print(f"SQNR Scenario B (Analog Boosted then Quantized):     {sqnr_b:.2f} dB")
    print(f"Improvement: {sqnr_b - sqnr_a:.2f} dB (Expected: ~9 dB)")

    # --- Plotting ---
    plt.figure(figsize=(12, 8))
    
    plt.subplot(2,1,1)
    plt.title(f"Reconstructed Signals (Target Magnitude 1.0)")
    plt.plot(t*1e6, ideal_signal, 'k', label='Ideal Input', linewidth=1, alpha=0.5)
    plt.step(t*1e6, sig_a_final, 'r', label=f'Scenario A (SQNR {sqnr_a:.1f}dB)', where='mid')
    plt.step(t*1e6, sig_b_final, 'g--', label=f'Scenario B (SQNR {sqnr_b:.1f}dB)', where='mid')
    plt.legend()
    plt.ylabel("Amplitude")
    plt.grid(True, alpha=0.3)
    
    plt.subplot(2,1,2)
    plt.title("Quantization Error (Residuals)")
    plt.plot(t*1e6, error_a, 'r', label='Error A (Digital Boost noise)', linewidth=1.5)
    plt.plot(t*1e6, error_b, 'g', label='Error B (Analog Boost noise)', linewidth=1.5)
    plt.legend()
    plt.xlabel("Time (us)")
    plt.ylabel("Error Magnitude")
    plt.grid(True, alpha=0.3)
    
    plt.tight_layout()
    plt.show()

if __name__ == "__main__":
    run_simulation()
