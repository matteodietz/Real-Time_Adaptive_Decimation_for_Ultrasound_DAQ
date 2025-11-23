"""
Generate simulation vectors for dft_accumulation.sv module
"""
import numpy as np
from scipy import signal
from pathlib import Path
import sys

# Add parent directory to path to import golden model
SIMULATOR_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SIMULATOR_ROOT / "src"))

from golden_model_floating_point import streaming_dft_processor
from fixed_float_conversions import float_to_fixed_point, fixed_point_to_float, adc_quantize_signed

# Import data loading functions
try:
    from afe_interface_rf import load_picmus_rf_data
    from virtual_afe import run_virtual_afe_processing
    PICMUS_AVAILABLE = True
except ImportError:
    print("Warning: PICMUS data loading modules not available. Skipping real data tests.")
    PICMUS_AVAILABLE = False

def generate_test_case(test_name, iq_data, fs, freq_bins, window_type,
                       iq_width, window_width, accum_width, osc_width, num_bins, normalize=False, max_magnitude=1.0):
    """
    Generate a single test case for the DFT accumulator.
    
    Returns:
        Dictionary containing all inputs and expected outputs
    """
    print(f"\n=== Generating test case: {test_name} ===")
    
    N = len(iq_data)
    K = len(freq_bins)
    
    print(f"  Sample length: {N}")
    print(f"  Number of bins: {K}")
    print(f"  Frequency bins: {freq_bins/1e6} MHz")
    
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

    window_max = np.max(np.abs(window_coeffs))
    
    # Generate complex oscillator values W[n,k] = exp(-j*2*pi*k*n/fs)
    # W starts at 1+0j and is multiplied by E each sample
    E = np.exp(-1j * 2 * np.pi * freqs_sorted / fs) 
    
    # Pre-compute all W values for all samples and all bins
    W_values = np.zeros((N, K), dtype=np.complex128)
    W_values[0, :] = 1.0 + 0j  # Initial value
    for n in range(1, N):
        W_values[n, :] = W_values[n-1, :] * E
    
    # Convert to fixed point
    # I/Q samples: Use Q(iq_width-8).8 format (8 fractional bits)
    iq_frac_bits = 14
    iq_int_bits = iq_width - iq_frac_bits

    if normalize:
        # We want 'max_magnitude' (e.g. 2*max_rf) to map to the maximum representable
        # value of the fixed point format.
        # Max value of Q2.14 is approx 2.0 (specifically 2^(int_bits-1))
        # We use a slight safety margin or just map to the boundary.
        target_max_val = 2 ** (iq_int_bits - 1)
        
        scale_factor = target_max_val / max_magnitude
        print(f"  [Normalization] Max Mag: {max_magnitude:.2e} -> Target: {target_max_val}")
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

    
    # Window coefficients: Use Q(window_width-16).16 format (16 fractional bits)
    # Window values are between 0 and 1
    window_frac_bits = 14
    window_int_bits = window_width - window_frac_bits
    
    window_coeffs_hw = [float_to_fixed_point(w, window_int_bits, window_frac_bits, signed=True) 
                       for w in window_coeffs]
    
    # Oscillator values W: Use Q(osc_width-16).16 format (16 fractional bits)
    # W values are complex with magnitude ~1
    osc_frac_bits = 28
    osc_int_bits = osc_width - osc_frac_bits
    
    W_real_hw = np.zeros((N, K), dtype=int)
    W_imag_hw = np.zeros((N, K), dtype=int)
    
    for n in range(N):
        for k in range(K):
            W_real_hw[n, k] = float_to_fixed_point(np.real(W_values[n, k]), 
                                                    osc_int_bits, osc_frac_bits, signed=True)
            W_imag_hw[n, k] = float_to_fixed_point(np.imag(W_values[n, k]), 
                                                    osc_int_bits, osc_frac_bits, signed=True)
    
    # Expected accumulator outputs width: 48 bits
    accum_frac_bits = 56
    accum_int_bits = accum_width - accum_frac_bits
    
    # Scale expected outputs to match hardware scaling
    # The hardware shifts the products: SHIFT_AMOUNT = IQ_WIDTH + WINDOW_WIDTH + OSC_WIDTH - ACCUM_WIDTH
    # shift_amount = iq_width + window_width + osc_width - accum_width
    
    # Calculate scaling factor for expected values
    # Products are scaled by: 2^(iq_frac + window_frac + osc_frac)
    # Then shifted right by shift_amount
    # total_frac_bits = iq_frac_bits + window_frac_bits + osc_frac_bits
    # effective_scale = 2 ** (total_frac_bits - shift_amount - accum_frac_bits)

    # CORRECTED VERSION OF BITSHIFTS:
    # shift_amount = iq_frac_bits + window_frac_bits + osc_frac_bits - accum_frac_bits
    # effective_scale = 2 ** shift_amount

    # the stimuli do not need to get shifted. since a already corresponds to the true golden floating point solution. 
    # if i just transform this to the correct format directly, i don't have any scaling issue

    # IMPORTANT: We must scale the expected golden result by the same factor
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
        'i_samples': i_samples_hw,
        'q_samples': q_samples_hw,
        'window_coeffs': window_coeffs_hw,
        'W_real': W_real_hw,
        'W_imag': W_imag_hw,
        'expected_A_real': A_real_hw,
        'expected_A_imag': A_imag_hw,
        'golden_A_real': [np.real(a) for a in accums_sorted],
        'golden_A_imag': [np.imag(a) for a in accums_sorted],
        'golden_A_mag': [np.abs(a) for a in accums_sorted]
    }

def write_vector_file(test_cases, output_path, iq_width, window_width, 
                     accum_width, osc_width):
    """
    Write test vectors to file in a format readable by SystemVerilog testbench.
    """
    with open(output_path, 'w') as f:
        # Write header
        f.write("# Simulation vectors for dft_accumulation.sv\n")
        f.write(f"# IQ_WIDTH = {iq_width}\n")
        f.write(f"# WINDOW_WIDTH = {window_width}\n")
        f.write(f"# ACCUM_WIDTH = {accum_width}\n")
        f.write(f"# OSC_WIDTH = {osc_width}\n")
        f.write("#\n")
        f.write("# Fixed-point formats:\n")
        f.write(f"# I/Q samples: Q{iq_width-8}.8\n")
        f.write(f"# Window coeffs: Q{window_width-16}.16\n")
        f.write(f"# Oscillator W: Q{osc_width-16}.16\n")
        f.write(f"# Accumulators: Q{accum_width-8}.8\n")
        f.write("#\n")
        f.write("# Format per test case:\n")
        f.write("# <test_name>\n")
        f.write("# <num_samples> <num_bins> <fs>\n")
        f.write("# FREQ_BINS <freq0_MHz> <freq1_MHz> ... (reference)\n")
        f.write("# SAMPLES (per line: I Q window_coeff W_real[0..K-1] W_imag[0..K-1])\n")
        f.write("# EXPECTED A_real[0..K-1] A_imag[0..K-1] (hex)\n")
        f.write("# GOLDEN A_real[0..K-1] A_imag[0..K-1] |A|[0..K-1] (float reference)\n")
        f.write("#\n\n")
        
        for tc in test_cases:
            f.write(f"{tc['test_name']}\n")
            f.write(f"{tc['num_samples']} {tc['num_bins']} {tc['fs']:.6e}\n")
            
            # Write frequency bins (reference)
            f.write("FREQ_BINS ")
            for freq in tc['freq_bins']:
                f.write(f"{freq/1e6:.6f} ")
            f.write("\n")
            
            # Write sample data (one line per sample)
            f.write("SAMPLES\n")
            for n in range(tc['num_samples']):
                # I, Q, window_coeff
                f.write(f"{tc['i_samples'][n]:05x} ")
                f.write(f"{tc['q_samples'][n]:05x} ")
                f.write(f"{tc['window_coeffs'][n]:05x} ")
                
                # W_real[0..K-1]
                for k in range(tc['num_bins']):
                    f.write(f"{tc['W_real'][n, k]:05x} ")
                
                # W_imag[0..K-1]
                for k in range(tc['num_bins']):
                    f.write(f"{tc['W_imag'][n, k]:05x} ")
                
                f.write("\n")
            
            # Write expected outputs
            f.write("EXPECTED\n")
            for k in range(tc['num_bins']):
                f.write(f"{tc['expected_A_real'][k]:05x}\n")
            for k in range(tc['num_bins']):
                f.write(f"{tc['expected_A_imag'][k]:05x}\n")
            f.write("\n")
            
            # Write golden reference
            f.write("GOLDEN ")
            for k in range(tc['num_bins']):
                f.write(f"{tc['golden_A_real'][k]:.6e} ")
            for k in range(tc['num_bins']):
                f.write(f"{tc['golden_A_imag'][k]:.6e} ")
            for k in range(tc['num_bins']):
                f.write(f"{tc['golden_A_mag'][k]:.6e} ")
            f.write("\n")
            
            f.write("\n")  # Blank line between test cases

def main():
    """
    Main function to generate all test vectors.
    """
    print("=== Generating Simulation Vectors for dft_accumulation.sv ===\n")
    
    # Hardware parameters
    IQ_WIDTH = 16           # Q2.14
    WINDOW_WIDTH = 16       # Q2.14
    ACCUM_WIDTH = 64        # Q8.40 Needs to be large to avoid overflow
    OSC_WIDTH = 32          # Q3.24
    NUM_BINS = 24           # Maximum
    
    test_cases = []

    # ====================================================================
    # --- NEW: Sanity Check Test Case (4-point DFT) ---
    # ====================================================================
    print("\n========== Sanity Check 1 Test Case (4-point DFT) ==========")
    
    # Use simple parameters for easy manual verification
    fs_sanity = 4.0 # 4 Hz sample rate
    nperseg_sanity = 4 # 4-point DFT
    
    # A simple real-valued cosine wave at 1 Hz. 
    # With fs=4 and N=4, this 1 Hz signal is perfectly on-bin.
    # x[n] = cos(2*pi*1.0*n/4) = cos(pi*n/2)
    # The values will be: [1, 0, -1, 0]
    t_sanity = np.arange(nperseg_sanity) / fs_sanity
    signal_sanity = np.cos(2 * np.pi * 1.0 * t_sanity)
    
    # For this test, we will calculate ALL 4 frequency bins
    # Frequencies will be: [0, 1, -2, -1] Hz (for fs=4, N=4)
    S_bins_sanity = np.fft.fftfreq(nperseg_sanity, 1/fs_sanity)
    
    print("\n--- Test Case: 4-point DFT of a 1 Hz Cosine ---")
    tc_sanity = generate_test_case(
        "sanity_check_4pt_dft",
        signal_sanity,
        fs_sanity,
        S_bins_sanity,
        'rect', # Use a rectangular window (all 1s) for simplicity
        IQ_WIDTH,
        WINDOW_WIDTH,
        ACCUM_WIDTH,
        OSC_WIDTH,
        4, # Actual number of bins for this test
        False
    )
    test_cases.append(tc_sanity)



    print("\n========== Sanity Check 2 Test Case (8-point DFT) ==========")

    # Use simple parameters for easy manual verification
    fs_sanity8 = 8.0    # 8 Hz sample rate
    nperseg_sanity8 = 8 # 8-point DFT

    # A simple real-valued cosine wave at 1 Hz.
    # x[n] = sin(2*pi*1.0*n/8) = cos(pi*n/4)
    t_sanity8 = np.arange(nperseg_sanity8) / fs_sanity8
    signal_sanity8 = np.sin(2 * np.pi * 1.0 * t_sanity8)

    # For this test, calculate ALL 8 frequency bins
    # Frequencies: [0,1,2,3,-4,-3,-2,-1] Hz (fs=8, N=8)
    S_bins_sanity8 = np.fft.fftfreq(nperseg_sanity8, 1/fs_sanity8)

    print("\n--- Test Case: 8-point DFT of a 1 Hz Cosine ---")
    tc_sanity8 = generate_test_case(
        "sanity_check_8pt_dft",
        signal_sanity8,
        fs_sanity8,
        S_bins_sanity8,
        'rect',        # Rectangular window
        IQ_WIDTH,
        WINDOW_WIDTH,
        ACCUM_WIDTH,
        OSC_WIDTH,
        8,              # Actual number of bins for this test
        False
    )
    test_cases.append(tc_sanity8)



    print("\n========== Sanity Check 3 Test Case (24-point DFT: sin + cos) ==========")

    # Use parameters for a 24-point DFT
    fs_sanity24 = 24.0   # 24 Hz sample rate (to keep integer frequencies simple)
    nperseg_sanity24 = 24 # 24-point DFT

    # A mixed signal: 1 Hz sine wave + 2 Hz cosine wave.
    # x[n] = sin(2*pi*1.0*n/fs) + cos(2*pi*2.0*n/fs)
    # The time vector covers one segment (N=24 samples)
    t_sanity24 = np.arange(nperseg_sanity24) / fs_sanity24

    # Generate the mixed signal
    # 1.0 Hz sine component
    sin_comp = np.sin(2 * np.pi * 1.0 * t_sanity24)
    # 2.0 Hz cosine component
    cos_comp = np.cos(2 * np.pi * 2.0 * t_sanity24)

    # Combined signal
    signal_sanity24 = sin_comp + cos_comp

    # For this test, calculate ALL 24 frequency bins
    # Frequencies: [0, 1, ..., 11, -12, -11, ..., -1] Hz (fs=24, N=24)
    S_bins_sanity24 = np.fft.fftfreq(nperseg_sanity24, 1/fs_sanity24)

    print("\n--- Test Case: 24-point DFT of (1 Hz Sine + 2 Hz Cosine) ---")
    tc_sanity24 = generate_test_case(
        "sanity_check_24pt_dft_sin_cos",
        signal_sanity24,
        fs_sanity24,
        S_bins_sanity24,
        'rect',        # Rectangular window
        IQ_WIDTH,
        WINDOW_WIDTH,
        ACCUM_WIDTH,
        OSC_WIDTH,
        24,             # Actual number of bins for this test
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

            # find max abs val of rf_data to properly quantize the iq data
            max_rf = np.max(np.abs(rf_data))
            max_rf_safe = 2 * max_rf
            
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
            
            # STFT parameters
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
                    max_magnitude=max_rf_safe
                )
                test_cases.append(tc)
                
        except Exception as e:
            print(f"Error loading PICMUS data: {e}")
            import traceback
            traceback.print_exc()
            print("Skipping PICMUS test cases.")
    
    # # ===== Synthetic Test Cases =====
    # print("\n========== Synthetic Test Cases ==========")
    
    # fs_synth = 31.25e6
    # nperseg_synth = 256
    # mod_freq_synth = 6.8125e6
    
    # # Define sparse frequency bins
    # delta_f = 0.25e6
    # half_bw_est = mod_freq_synth / 2
    # s_coarse = np.linspace(-mod_freq_synth, mod_freq_synth, 8)
    # s_fine_left = np.linspace(-half_bw_est - delta_f, -half_bw_est + delta_f, 8)
    # s_fine_right = np.linspace(half_bw_est - delta_f, half_bw_est + delta_f, 8)
    # S_bins_synth = np.unique(np.concatenate([s_coarse, s_fine_left, s_fine_right]))
    
    # t = np.arange(nperseg_synth) / fs_synth
    
    # # Test Case 1: Simple sine wave
    # print("\n--- Test Case: Simple sine wave at 2 MHz ---")
    # signal_1 = np.exp(1j * 2 * np.pi * 2e6 * t)
    
    # tc1 = generate_test_case(
    #     "synth_sine_2mhz",
    #     signal_1,
    #     fs_synth,
    #     S_bins_synth,
    #     'hann',
    #     IQ_WIDTH,
    #     WINDOW_WIDTH,
    #     ACCUM_WIDTH,
    #     OSC_WIDTH,
    #     NUM_BINS
    # )
    # test_cases.append(tc1)
    
    # # Test Case 2: DC signal (0 Hz)
    # print("\n--- Test Case: DC signal ---")
    # signal_2 = 0.5 * np.ones(nperseg_synth, dtype=np.complex128)
    
    # tc2 = generate_test_case(
    #     "synth_dc",
    #     signal_2,
    #     fs_synth,
    #     S_bins_synth,
    #     'hann',
    #     IQ_WIDTH,
    #     WINDOW_WIDTH,
    #     ACCUM_WIDTH,
    #     OSC_WIDTH,
    #     NUM_BINS
    # )
    # test_cases.append(tc2)
    
    # Write to file
    output_dir = SIMULATOR_ROOT.parent / "rtl" / "simvectors"
    output_dir.mkdir(parents=True, exist_ok=True)
    output_path = output_dir / "dft_accumulation_vectors.txt"
    
    write_vector_file(test_cases, output_path, IQ_WIDTH, WINDOW_WIDTH, 
                     ACCUM_WIDTH, OSC_WIDTH)
    
    print(f"\n=== Successfully generated {len(test_cases)} test cases ===")
    print(f"Output file: {output_path}")
    print("\nTest cases generated:")
    for tc in test_cases:
        print(f"  - {tc['test_name']}: {tc['num_samples']} samples, {tc['num_bins']} bins")

if __name__ == "__main__":
    main()