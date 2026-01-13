"""
Generate simulation vectors for dft_accumulation.sv module with integrated CORDIC oscillator bank
"""
import numpy as np
from scipy import signal
from pathlib import Path
import sys

# Add parent directory to path to import golden model
SIMULATOR_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SIMULATOR_ROOT / "src"))

from golden_model_floating_point import streaming_dft_processor
from fixed_float_conversions import float_to_fixed_point, fixed_point_to_float

# Import data loading functions
try:
    from afe_interface_rf import load_picmus_rf_data
    from virtual_afe import run_virtual_afe_processing
    PICMUS_AVAILABLE = True
except ImportError:
    print("Warning: PICMUS data loading modules not available. Skipping real data tests.")
    PICMUS_AVAILABLE = False

def generate_test_case(test_name, iq_data, fs, freq_bins, window_type,
                       iq_width, window_width, accum_width, phase_width, num_bins, normalize=False, max_magnitude=1.0):
    """
    Generate a single test case for the DFT accumulator with CORDIC oscillator bank.
    
    Returns:
        Dictionary containing all inputs and expected outputs
    """
    print(f"\n=== Generating test case: {test_name} ===")
    
    N = len(iq_data)
    K = len(freq_bins)
    
    print(f"  Sample length: {N}")
    print(f"  Number of bins: {K}")
    print(f"  Frequency bins: {freq_bins} Hz")
    
    # Run golden model to get expected outputs
    dft_bins = streaming_dft_processor(iq_data, fs, freq_bins, window=window_type)
    
    # Extract results
    freqs = np.array(list(dft_bins.keys()))
    accumulators = np.array(list(dft_bins.values()))
    
    # Sort by frequency for consistent output
    sort_indices = np.argsort(freqs)
    freqs_sorted = freqs[sort_indices]
    accums_sorted = accumulators[sort_indices]    
    
    print(f"  Golden accumulator magnitudes: {np.abs(accums_sorted)}")
    
    # Generate window coefficients
    window_coeffs = signal.windows.get_window(window_type, N)
    
    # # Calculate frequency steps for CORDIC oscillator bank
    # # freq_step = (f_bin / f_sample) * 2^PHASE_WIDTH
    # freq_steps = np.zeros(K, dtype=np.uint32)
    # for k in range(K):
    #     normalized_freq = freqs_sorted[k] / fs
    #     # Map to phase accumulator range (0 to 2^PHASE_WIDTH represents 0 to 2*pi)
    #     step_real = normalized_freq * (2.0 ** phase_width)
    #     # Handle wrap-around for negative frequencies
    #     if step_real < 0:
    #         step_real += (2.0 ** phase_width)
    #     freq_steps[k] = int(step_real) & ((1 << phase_width) - 1)

    # --- Calculate Negative Frequency Steps for Oscillators ---
    freq_steps = []
    for k in range(K):
        normalized_freq = freqs_sorted[k] / fs
        
        # Calculate the positive step magnitude
        raw_step = normalized_freq * (2 ** phase_width)
        
        # Negated: This creates the backward rotation (e^-jtheta)
        neg_step = -round(raw_step) 
        
        # Apply mask to convert the negative number to its unsigned bit representation
        # Python handles the 2's complement wrap-around here automatically
        freq_steps.append(neg_step & ((1 << phase_width) - 1))
    
    print(f"  Frequency steps (hex): {[hex(s) for s in freq_steps]}")
    
    # Convert to fixed point
    # I/Q samples: Q2.14 format
    iq_frac_bits = 14
    iq_int_bits = iq_width - iq_frac_bits

    if normalize:
        # We want 'max_magnitude' (e.g. 2*max_rf) to map to the maximum representable
        # value of the fixed point format.
        # Max value of Q2.14 is approx 2.0 (specifically 2^(int_bits-1))
        # Use a slight safety margin or just map to the boundary.
        target_max_val = 2 ** (iq_int_bits - 1)
        
        scale_factor = target_max_val / max_magnitude
        # print(f"  [Normalization] Max Mag: {max_magnitude:.2e} -> Target: {target_max_val}")
        print(f"  [Normalization] Applying Scale Factor: {scale_factor:.4f}")
    else:
        scale_factor = 1.0

    # --- 3. Scale Data ---
    # We scale the inputs. Since DFT is linear, the Expected Output 
    # is simply Golden_Output * scale_factor.
    
    # Note: We must handle real/imag separately for list comprehension
    i_data_scaled = np.real(iq_data) * scale_factor
    q_data_scaled = np.imag(iq_data) * scale_factor

    # --- 4. Quantize Inputs (I/Q) ---
    i_samples_hw = [float_to_fixed_point(s, iq_int_bits, iq_frac_bits, signed=True) 
                for s in i_data_scaled]
    q_samples_hw = [float_to_fixed_point(s, iq_int_bits, iq_frac_bits, signed=True) 
                for s in q_data_scaled]
    
    # Window coefficients: Q2.14 format
    window_frac_bits = 14
    window_int_bits = window_width - window_frac_bits
    
    window_coeffs_hw = [float_to_fixed_point(w, window_int_bits, window_frac_bits, signed=True) 
                       for w in window_coeffs]
    
    # Expected accumulator outputs:
    accum_frac_bits = 28 
    accum_int_bits = accum_width - accum_frac_bits
    
    # We must scale the expected golden result by the same factor
    # we scaled the input by, otherwise they won't match!
    accums_scaled_real = np.real(accums_sorted) * scale_factor
    accums_scaled_imag = np.imag(accums_sorted) * scale_factor
    
    A_real_hw = [float_to_fixed_point(val, accum_int_bits, accum_frac_bits, signed=True) 
                 for val in accums_scaled_real]
    A_imag_hw = [float_to_fixed_point(val, accum_int_bits, accum_frac_bits, signed=True) 
                 for val in accums_scaled_imag]


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
        'expected_A_real': A_real_hw,
        'expected_A_imag': A_imag_hw,
        'golden_A_real': [np.real(a) for a in accums_sorted],
        'golden_A_imag': [np.imag(a) for a in accums_sorted],
        'golden_A_mag': [np.abs(a) for a in accums_sorted]
    }

def write_vector_file(test_cases, output_path, iq_width, window_width, 
                     accum_width, osc_width, phase_width):
    """
    Write test vectors to file in a format readable by SystemVerilog testbench.
    """
    with open(output_path, 'w') as f:
        # Write header
        f.write("# Simulation vectors for dft_accumulation.sv with CORDIC oscillator bank\n")
        f.write(f"# IQ_WIDTH = {iq_width}\n")
        f.write(f"# WINDOW_WIDTH = {window_width}\n")
        f.write(f"# ACCUM_WIDTH = {accum_width}\n")
        f.write(f"# OSC_WIDTH = {osc_width}\n")
        f.write(f"# PHASE_WIDTH = {phase_width}\n")
        f.write("#\n")
        f.write("# Fixed-point formats:\n")
        f.write(f"# I/Q samples: Q{iq_width-14}.14\n")
        f.write(f"# Window coeffs: Q{window_width-14}.14\n")
        f.write(f"# Accumulators: Q{accum_width-56}.56\n")
        f.write("#\n")
        f.write("# Format per test case:\n")
        f.write("# <test_name>\n")
        f.write("# <num_samples> <num_bins> <fs>\n")
        f.write("# FREQ_BINS <freq0_Hz> <freq1_Hz> ... (reference)\n")
        f.write("# FREQ_STEPS <step0_hex> <step1_hex> ... (for CORDIC phase accumulators)\n")
        f.write("# SAMPLES (per line: I Q window_coeff)\n")
        f.write("# EXPECTED A_real[0..K-1] A_imag[0..K-1] (hex)\n")
        f.write("# GOLDEN A_real[0..K-1] A_imag[0..K-1] |A|[0..K-1] (float reference)\n")
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
                f.write(f"{step:04x}\n")
            f.write("\n")
            
            # Write sample data (one line per sample)
            f.write("SAMPLES\n")
            for n in range(tc['num_samples']):
                # I, Q, window_coeff
                f.write(f"{tc['i_samples'][n]:04x} ")
                f.write(f"{tc['q_samples'][n]:04x} ")
                f.write(f"{tc['window_coeffs'][n]:04x}\n")
            
            # Write expected outputs
            f.write("EXPECTED\n")
            for k in range(tc['num_bins']):
                f.write(f"{tc['expected_A_real'][k]:010x}\n")
            for k in range(tc['num_bins']):
                f.write(f"{tc['expected_A_imag'][k]:010x}\n")
            
            # Write golden reference
            f.write("GOLDEN ")
            for k in range(tc['num_bins']):
                f.write(f"{tc['golden_A_real'][k]:.6e} ")
            for k in range(tc['num_bins']):
                f.write(f"{tc['golden_A_imag'][k]:.6e} ")
            for k in range(tc['num_bins']):
                f.write(f"{tc['golden_A_mag'][k]:.6e} ")
            f.write("\n\n")

def main():
    """
    Main function to generate all test vectors.
    """
    print("=== Generating Simulation Vectors for dft_accumulation.sv with CORDIC ===\n")
    
    # Hardware parameters
    IQ_WIDTH = 16           # Q2.14
    WINDOW_WIDTH = 16       # Q2.14
    ACCUM_WIDTH = 36        
    OSC_WIDTH = 16         
    PHASE_WIDTH = 16        
    NUM_BINS = 24     
    
    test_cases = []

    # ====================================================================
    # Sanity Check 1: 4-point DFT
    # ====================================================================
    print("\n========== Sanity Check 1: 4-point DFT ==========")
    
    fs_sanity = 4.0
    nperseg_sanity = 4
    
    # Simple cosine wave at 1 Hz
    # x[n] = cos(2*pi*1.0*n/4) = cos(pi*n/2)
    # Values: [1, 0, -1, 0]
    t_sanity = np.arange(nperseg_sanity) / fs_sanity
    signal_sanity = np.cos(2 * np.pi * 1.0 * t_sanity)
    
    # All 4 frequency bins: [0, 1, 2, 3] Hz (or [0, 1, -2, -1])
    S_bins_sanity = np.fft.fftfreq(nperseg_sanity, 1/fs_sanity)
    
    tc_sanity = generate_test_case(
        "sanity_check_4pt_dft",
        signal_sanity,
        fs_sanity,
        S_bins_sanity,
        'boxcar',  # Rectangular window
        IQ_WIDTH,
        WINDOW_WIDTH,
        ACCUM_WIDTH,
        PHASE_WIDTH,
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
    
    # Sine wave at 1 Hz
    # x[n] = sin(2*pi*1.0*n/8)
    t_sanity8 = np.arange(nperseg_sanity8) / fs_sanity8
    signal_sanity8 = np.sin(2 * np.pi * 1.0 * t_sanity8)
    
    # All 8 frequency bins
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
        8,
        False
    )
    test_cases.append(tc_sanity8)

    # ====================================================================
    # Sanity Check 3: 24-point DFT (sin + cos)
    # ====================================================================
    print("\n========== Sanity Check 3: 24-point DFT ==========")
    
    fs_sanity24 = 24.0
    nperseg_sanity24 = 24
    
    # Mixed signal: 1 Hz sine + 2 Hz cosine
    t_sanity24 = np.arange(nperseg_sanity24) / fs_sanity24
    sin_comp = np.sin(2 * np.pi * 1.0 * t_sanity24)
    cos_comp = np.cos(2 * np.pi * 2.0 * t_sanity24)
    signal_sanity24 = sin_comp + cos_comp
    
    # All 24 frequency bins
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
        24,
        False
    )
    test_cases.append(tc_sanity24)

    # =================================================================================
    
    
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
            
            rf_data, angles, _, _, fs_picmus, mod_freq, _, _, _ = load_picmus_rf_data(rf_path, iq_path, scan_path)

            # Find max abs val of rf_data to properly quantize the iq data
            max_rf = np.max(np.abs(rf_data)) 
            max_rf_safe = max_rf 

            print(f"max safe rf value for iq normalization before quantization: {max_rf_safe}")
            
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

            print(f"max safe iq value for comparison: {max_iq_safe}")
            
            # DFT parameters
            nperseg = 256
            hop = nperseg // 2
            
            # Define frequency bins of interest
            delta_f = 0.25e6
            half_bw_est = mod_freq / 2
            s_coarse = np.linspace(-mod_freq, mod_freq, 8)
            s_fine_left = np.linspace(-half_bw_est - delta_f, -half_bw_est + delta_f, 8)
            s_fine_right = np.linspace(half_bw_est - delta_f, half_bw_est + delta_f, 8)
            S_bins = np.unique(np.concatenate([s_coarse, s_fine_left, s_fine_right]))
            
            # Test different windows
            test_configs = [
                ("picmus_ch64_win29", 64, 5),
                ("picmus_ch64_win15", 96, 29),
                ("picmus_ch64_win15", 32, 27),
            ]
            
            for test_name, channel, window_num in test_configs:
                print(f"\n--- Processing {test_name}: Channel {channel}, Window {window_num} ---")
                
                start_sample = window_num * hop
                end_sample = start_sample + nperseg
                
                # Extract window data
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
                    OSC_WIDTH,
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
    output_path = output_dir / "dft_cordic_vectors.txt"
    
    write_vector_file(test_cases, output_path, IQ_WIDTH, WINDOW_WIDTH, 
                     ACCUM_WIDTH, OSC_WIDTH, PHASE_WIDTH)
    
    print(f"\n=== Successfully generated {len(test_cases)} test cases ===")
    print(f"Output file: {output_path}")
    print("\nTest cases generated:")
    for tc in test_cases:
        print(f"  - {tc['test_name']}: {tc['num_samples']} samples, {tc['num_bins']} bins")

if __name__ == "__main__":
    main()