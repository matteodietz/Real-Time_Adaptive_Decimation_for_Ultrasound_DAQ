"""
Generate simulation vectors for dft_power_estimator.sv module
Includes DFT accumulation with CORDIC oscillators + power conversion to dB
"""
import numpy as np
from scipy import signal
from pathlib import Path
import sys

# Add parent directory to path to import golden model
SIMULATOR_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SIMULATOR_ROOT / "src"))

from complete_system_model import streaming_dft_processor, convert_to_hardware_db_power
from fixed_float_conversions import float_to_fixed_point, fixed_point_to_float

# Import data loading functions
try:
    from afe_interface_rf import load_picmus_rf_data
    from virtual_afe import run_virtual_afe_processing
    PICMUS_AVAILABLE = True
except ImportError:
    print("Warning: PICMUS data loading modules not available. Skipping real data tests.")
    PICMUS_AVAILABLE = False

def clip_accumulator_to_32bit(accum_val_64bit, accum_frac_64=56):
    """
    Clip 64-bit accumulator (Q8.56) to 32-bit representation (Q8.24).
    The hardware takes the upper 32 bits [63:32], which gives us Q8.24 format.
    Values too small to be represented in 24 fractional bits get clamped to 0.
    
    Args:
        accum_val_64bit: Complex value in Q8.56 format (as float)
        accum_frac_64: Fractional bits in 64-bit format (56)
    
    Returns:
        Complex value clamped to Q8.24 representable range
    """
    # The minimum absolute value representable in Q8.24 is 2^(-24)
    # When we take upper 32 bits from Q8.56, we lose the lower 32 bits
    # This means we lose precision below 2^(-24) in the final Q8.24 format
    min_representable = 2.0 ** (-24)
    
    # Clamp real and imaginary parts separately
    real_part = accum_val_64bit.real
    imag_part = accum_val_64bit.imag
    
    # Clamp to zero if magnitude too small
    if abs(real_part) < min_representable:
        real_part = 0.0
    if abs(imag_part) < min_representable:
        imag_part = 0.0
    
    return complex(real_part, imag_part)

def generate_test_case(test_name, iq_data, fs, freq_bins, window_type,
                       iq_width, window_width, accum_width, phase_width, 
                       power_input_width, power_width, power_frac,
                       num_bins, normalize=False, max_magnitude=1.0):
    """
    Generate a single test case for the DFT power estimator.
    
    Returns:
        Dictionary containing all inputs and expected outputs
    """
    print(f"\n=== Generating test case: {test_name} ===")
    
    N = len(iq_data)
    K = len(freq_bins)
    
    print(f"  Sample length: {N}")
    print(f"  Number of bins: {K}")
    print(f"  Frequency bins: {freq_bins} Hz")
    
    # Run golden model to get DFT bins
    dft_bins = streaming_dft_processor(iq_data, fs, freq_bins, window=window_type)
    
    # Generate window coefficients
    window_coeffs = signal.windows.get_window(window_type, N)
    
    # Calculate frequency steps for CORDIC oscillator bank
    freq_steps = np.zeros(K, dtype=np.uint32)
    freqs_list = list(dft_bins.keys())
    for k, freq in enumerate(freqs_list):
        normalized_freq = freq / fs
        step_real = normalized_freq * (2.0 ** phase_width)
        if step_real < 0:
            step_real += (2.0 ** phase_width)
        freq_steps[k] = int(step_real) & ((1 << phase_width) - 1)
    
    print(f"  Frequency steps (hex): {[hex(s) for s in freq_steps]}")
    
    # --- Normalization and Scaling ---
    iq_frac_bits = 14
    iq_int_bits = iq_width - iq_frac_bits

    if normalize:
        target_max_val = 2 ** (iq_int_bits - 1)
        scale_factor = target_max_val / max_magnitude
        print(f"  [Normalization] Applying Scale Factor: {scale_factor:.4f}")
    else:
        scale_factor = 1.0

    i_data_scaled = np.real(iq_data) * scale_factor
    q_data_scaled = np.imag(iq_data) * scale_factor

    # --- Quantize Inputs ---
    i_samples_hw = [float_to_fixed_point(s, iq_int_bits, iq_frac_bits, signed=True) 
                    for s in i_data_scaled]
    q_samples_hw = [float_to_fixed_point(s, iq_int_bits, iq_frac_bits, signed=True) 
                    for s in q_data_scaled]
    
    # Window coefficients: Q2.14 format
    window_frac_bits = 14
    window_int_bits = window_width - window_frac_bits
    window_coeffs_hw = [float_to_fixed_point(w, window_int_bits, window_frac_bits, signed=True) 
                        for w in window_coeffs]
    
    # --- Scale Golden Output ---
    # Scale the DFT bins by the same factor we scaled inputs
    dft_bins_scaled = {freq: val * scale_factor for freq, val in dft_bins.items()}
    
    # --- Clip Accumulator Values to 32-bit (Q8.24) ---
    print("  Clipping accumulator values from 64-bit (Q8.56) to 32-bit (Q8.24)...")
    accum_frac = 56
    dft_bins_clipped = {}
    for freq, complex_val in dft_bins_scaled.items():
        clipped_val = clip_accumulator_to_32bit(complex_val, accum_frac)
        dft_bins_clipped[freq] = clipped_val
    
    # --- Convert to Hardware dB Power ---
    print("  Converting to hardware dB power...")
    input_width_log = power_input_width
    input_frac_log = power_input_width - (accum_width - accum_frac)  # Q8.24 has 24 frac bits
    
    freqs_sorted, power_hw_db = convert_to_hardware_db_power(
        dft_bins_clipped, 
        input_width_log, 
        input_frac_log, 
        power_width, 
        power_frac
    )
    
    print(f"  Power values (dB): min={np.min(power_hw_db):.2f}, max={np.max(power_hw_db):.2f}")
    
    # For golden reference, also store the magnitudes
    accums_sorted = [dft_bins_clipped[f] for f in freqs_sorted]
    golden_power_linear = [abs(a)**2 for a in accums_sorted]
    golden_power_db = [10*np.log10(p) if p > 1e-20 else -200 for p in golden_power_linear]

    return {
        'test_name': test_name,
        'num_samples': N,
        'num_bins': K,
        'fs': fs,
        'freq_bins': freqs_sorted,
        'freq_steps': freq_steps,
        'i_samples': i_samples_hw,
        'q_samples': q_samples_hw,
        'window_coeffs': window_coeffs_hw,
        'expected_power_db': power_hw_db,
        'golden_power_db': golden_power_db,
        'golden_power_linear': golden_power_linear
    }

def write_vector_file(test_cases, output_path, iq_width, window_width, 
                     accum_width, osc_width, phase_width, power_width):
    """
    Write test vectors to file in a format readable by SystemVerilog testbench.
    """
    with open(output_path, 'w') as f:
        # Write header
        f.write("# Simulation vectors for dft_power_estimator.sv\n")
        f.write(f"# IQ_WIDTH = {iq_width}\n")
        f.write(f"# WINDOW_WIDTH = {window_width}\n")
        f.write(f"# ACCUM_WIDTH = {accum_width}\n")
        f.write(f"# OSC_WIDTH = {osc_width}\n")
        f.write(f"# PHASE_WIDTH = {phase_width}\n")
        f.write(f"# POWER_WIDTH = {power_width}\n")
        f.write("#\n")
        f.write("# Fixed-point formats:\n")
        f.write(f"# I/Q samples: Q{iq_width-14}.14\n")
        f.write(f"# Window coeffs: Q{window_width-14}.14\n")
        f.write(f"# Accumulators: Q{accum_width-56}.56 -> clipped to Q8.24\n")
        f.write(f"# Power output: {power_width}-bit unsigned dB\n")
        f.write("#\n")
        f.write("# Format per test case:\n")
        f.write("# <test_name>\n")
        f.write("# <num_samples> <num_bins> <fs>\n")
        f.write("# FREQ_BINS <freq0_Hz> <freq1_Hz> ... (reference)\n")
        f.write("# FREQ_STEPS <step0_hex> <step1_hex> ... (for CORDIC phase accumulators)\n")
        f.write("# SAMPLES (per line: I Q window_coeff)\n")
        f.write("# EXPECTED_POWER <power0_hex> <power1_hex> ... (dB values)\n")
        f.write("# GOLDEN <power0_dB> <power1_dB> ... (float reference)\n")
        f.write("#\n\n")
        
        for tc in test_cases:
            f.write(f"{tc['test_name']}\n")
            f.write(f"{tc['num_samples']} {tc['num_bins']} {tc['fs']:.6e}\n")
            
            # Write frequency bins (reference)
            f.write("FREQ_BINS ")
            for freq in tc['freq_bins']:
                f.write(f"{freq:.6f} ")
            f.write("\n")
            
            # Write frequency steps (for CORDIC)
            f.write("FREQ_STEPS\n")
            for step in tc['freq_steps']:
                f.write(f"{step:08x}\n")
            f.write("\n")
            
            # Write sample data
            f.write("SAMPLES\n")
            for n in range(tc['num_samples']):
                f.write(f"{tc['i_samples'][n]:04x} ")
                f.write(f"{tc['q_samples'][n]:04x} ")
                f.write(f"{tc['window_coeffs'][n]:04x}\n")
            
            # Write expected power outputs
            f.write("EXPECTED_POWER\n")
            for k in range(tc['num_bins']):
                f.write(f"{tc['expected_power_db'][k]:02x}\n")
            
            # Write golden reference
            f.write("GOLDEN ")
            for k in range(tc['num_bins']):
                f.write(f"{tc['golden_power_db'][k]:.6e} ")
            f.write("\n\n")

def main():
    """
    Main function to generate all test vectors.
    """
    print("=== Generating Simulation Vectors for dft_power_estimator.sv ===\n")
    
    # Hardware parameters
    IQ_WIDTH = 16           # Q2.14
    WINDOW_WIDTH = 16       # Q2.14
    ACCUM_WIDTH = 64        # Q8.56
    OSC_WIDTH = 32          # CORDIC output width
    PHASE_WIDTH = 32        # Phase accumulator width
    POWER_INPUT_WIDTH = 32  # Q8.24 after clipping
    POWER_WIDTH = 8         # 8-bit dB output
    POWER_FRAC = 0          # Integer dB values
    NUM_BINS = 24
    
    test_cases = []

    # ====================================================================
    # Sanity Check 1: 4-point DFT
    # ====================================================================
    print("\n========== Sanity Check 1: 4-point DFT ==========")
    
    fs_sanity = 4.0
    nperseg_sanity = 4
    t_sanity = np.arange(nperseg_sanity) / fs_sanity
    signal_sanity = np.cos(2 * np.pi * 1.0 * t_sanity)
    S_bins_sanity = np.fft.fftfreq(nperseg_sanity, 1/fs_sanity)
    
    tc_sanity = generate_test_case(
        "sanity_check_4pt_dft",
        signal_sanity,
        fs_sanity,
        S_bins_sanity,
        'boxcar',
        IQ_WIDTH,
        WINDOW_WIDTH,
        ACCUM_WIDTH,
        PHASE_WIDTH,
        POWER_INPUT_WIDTH,
        POWER_WIDTH,
        POWER_FRAC,
        4,
        False
    )
    test_cases.append(tc_sanity)

    # ====================================================================
    # Sanity Check 2: 8-point DFT
    # ====================================================================
    print("\n========== Sanity Check 2: 8-point DFT ==========")
    
    fs_sanity8 = 8.0
    nperseg_sanity8 = 8
    t_sanity8 = np.arange(nperseg_sanity8) / fs_sanity8
    signal_sanity8 = np.sin(2 * np.pi * 1.0 * t_sanity8)
    S_bins_sanity8 = np.fft.fftfreq(nperseg_sanity8, 1/fs_sanity8)
    
    tc_sanity8 = generate_test_case(
        "sanity_check_8pt_dft",
        signal_sanity8,
        fs_sanity8,
        S_bins_sanity8,
        'boxcar',
        IQ_WIDTH,
        WINDOW_WIDTH,
        ACCUM_WIDTH,
        PHASE_WIDTH,
        POWER_INPUT_WIDTH,
        POWER_WIDTH,
        POWER_FRAC,
        8,
        False
    )
    test_cases.append(tc_sanity8)

    # ====================================================================
    # Sanity Check 3: 24-point DFT
    # ====================================================================
    print("\n========== Sanity Check 3: 24-point DFT ==========")
    
    fs_sanity24 = 24.0
    nperseg_sanity24 = 24
    t_sanity24 = np.arange(nperseg_sanity24) / fs_sanity24
    sin_comp = np.sin(2 * np.pi * 1.0 * t_sanity24)
    cos_comp = np.cos(2 * np.pi * 2.0 * t_sanity24)
    signal_sanity24 = sin_comp + cos_comp
    S_bins_sanity24 = np.fft.fftfreq(nperseg_sanity24, 1/fs_sanity24)
    
    tc_sanity24 = generate_test_case(
        "sanity_check_24pt_dft_sin_cos",
        signal_sanity24,
        fs_sanity24,
        S_bins_sanity24,
        'boxcar',
        IQ_WIDTH,
        WINDOW_WIDTH,
        ACCUM_WIDTH,
        PHASE_WIDTH,
        POWER_INPUT_WIDTH,
        POWER_WIDTH,
        POWER_FRAC,
        24,
        False
    )
    test_cases.append(tc_sanity24)

    # ===== Test Cases from PICMUS Data =====
    if PICMUS_AVAILABLE:
        print("\n========== PICMUS Real Data Test Cases ==========")
        
        try:
            # Load PICMUS data
            rf_path = SIMULATOR_ROOT.parent / "simulator/datasets/experiments/contrast_speckle/contrast_speckle_expe_dataset_rf.hdf5"
            iq_path = SIMULATOR_ROOT.parent / "simulator/datasets/experiments/contrast_speckle/contrast_speckle_expe_dataset_iq.hdf5"
            scan_path = SIMULATOR_ROOT.parent / "simulator/datasets/experiments/contrast_speckle/contrast_speckle_expe_scan.hdf5"
            
            adc_rate = 125e6
            baseline_decimation = 4
            
            rf_data, angles, _, _, fs_picmus, mod_freq, _, _, _ = load_picmus_rf_data(
                rf_path, iq_path, scan_path)

            max_rf = np.max(np.abs(rf_data))
            max_rf_safe = max_rf
            print(f"max safe rf value: {max_rf_safe}")
            
            # Get baseline I/Q data
            center_angle_index = np.argmin(np.abs(angles))
            baseline_iq_data, _, fs_baseline = run_virtual_afe_processing(
                rf_data=rf_data,
                angle_index=center_angle_index,
                fs_picmus=fs_picmus,
                modulation_frequency=mod_freq,
                decimation_factor=baseline_decimation,
                adc_sample_rate=adc_rate
            )

            max_iq = np.max(np.abs(baseline_iq_data))
            max_iq_safe = max_iq
            print(f"max safe iq value: {max_iq_safe}")
            
            # STFT parameters
            nperseg = 256
            hop = nperseg // 2
            
            # Define frequency bins
            delta_f = 0.25e6
            half_bw_est = mod_freq / 2
            s_coarse = np.linspace(-mod_freq, mod_freq, 8)
            s_fine_left = np.linspace(-half_bw_est - delta_f, -half_bw_est + delta_f, 8)
            s_fine_right = np.linspace(half_bw_est - delta_f, half_bw_est + delta_f, 8)
            S_bins = np.unique(np.concatenate([s_coarse, s_fine_left, s_fine_right]))
            
            # Test configurations
            test_configs = [
                ("picmus_ch64_win5", 64, 5),
                ("picmus_ch96_win29", 96, 29),
                ("picmus_ch32_win27", 32, 27),
            ]
            
            for test_name, channel, window_num in test_configs:
                print(f"\n--- Processing {test_name}: Channel {channel}, Window {window_num} ---")
                
                start_sample = window_num * hop
                end_sample = start_sample + nperseg
                time_window_data = baseline_iq_data[start_sample:end_sample, channel]
                
                tc = generate_test_case(
                    test_name,
                    time_window_data,
                    fs_baseline,
                    S_bins,
                    'hann',
                    IQ_WIDTH,
                    WINDOW_WIDTH,
                    ACCUM_WIDTH,
                    PHASE_WIDTH,
                    POWER_INPUT_WIDTH,
                    POWER_WIDTH,
                    POWER_FRAC,
                    NUM_BINS,
                    normalize=True,
                    max_magnitude=max_iq_safe
                )
                test_cases.append(tc)
                
        except Exception as e:
            print(f"Error loading PICMUS data: {e}")
            import traceback
            traceback.print_exc()
            print("Skipping PICMUS test cases.")
    
    # Write to file
    output_dir = SIMULATOR_ROOT.parent / "rtl" / "simvectors"
    output_dir.mkdir(parents=True, exist_ok=True)
    output_path = output_dir / "dft_power_vectors.txt"
    
    write_vector_file(test_cases, output_path, IQ_WIDTH, WINDOW_WIDTH, 
                     ACCUM_WIDTH, OSC_WIDTH, PHASE_WIDTH, POWER_WIDTH)
    
    print(f"\n=== Successfully generated {len(test_cases)} test cases ===")
    print(f"Output file: {output_path}")
    print("\nTest cases generated:")
    for tc in test_cases:
        print(f"  - {tc['test_name']}: {tc['num_samples']} samples, {tc['num_bins']} bins")

if __name__ == "__main__":
    main()