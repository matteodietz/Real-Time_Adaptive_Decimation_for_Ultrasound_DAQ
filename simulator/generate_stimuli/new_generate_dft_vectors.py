"""
Generate simulation vectors for dft_accumulation.sv module
Refactored to handle dynamic range of PICMUS data via pre-scaling.
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
                       iq_width, window_width, accum_width, osc_width, num_bins, 
                       normalize=False, max_magnitude=1.0):
    """
    Generate a single test case for the DFT accumulator.
    
    Args:
        ...
        normalize (bool): If True, scales input data so max_magnitude fits in IQ_WIDTH.
        max_magnitude (float): The absolute voltage value that should map to the 
                               maximum fixed-point integer (used if normalize=True).
    """
    print(f"\n=== Generating test case: {test_name} ===")
    
    N = len(iq_data)
    K = len(freq_bins)
    
    print(f"  Sample length: {N}")
    print(f"  Number of bins: {K}")
    print(f"  Frequency bins: {freq_bins/1e6} MHz")
    
    # --- 1. Run Golden Model (on original small floats) ---
    dft_bins = streaming_dft_processor(iq_data, fs, freq_bins, window=window_type)
    
    # Extract results
    freqs = np.array(list(dft_bins.keys()))
    accumulators = np.array(list(dft_bins.values()))
    
    # Sort by frequency for consistent output
    sort_indices = np.argsort(freqs)
    freqs_sorted = freqs[sort_indices]
    accums_sorted = accumulators[sort_indices]    
    
    print(f"  Golden accumulator magnitudes (unscaled): {np.abs(accums_sorted)}")
    
    # --- 2. Calculate Scaling Factor ---
    # I/Q samples: Use Q(iq_width-8).8 format (8 fractional bits) -> Wait, user defined Q2.14 elsewhere
    # Let's assume IQ_WIDTH=16 implies Q2.14 based on previous context, 
    # or strictly follow the widths defined below:
    
    iq_frac_bits = 14
    iq_int_bits = iq_width - iq_frac_bits # e.g., 16 - 14 = 2 bits (range -2 to +1.99)
    
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
    
    # --- 5. Generate & Quantize Window Coeffs ---
    window_coeffs = signal.windows.get_window(window_type, N)
    window_frac_bits = 14
    window_int_bits = window_width - window_frac_bits
    
    window_coeffs_hw = [float_to_fixed_point(w, window_int_bits, window_frac_bits, signed=True) 
                       for w in window_coeffs]
    
    # --- 6. Generate & Quantize Oscillator (W) ---
    E = np.exp(-1j * 2 * np.pi * freqs_sorted / fs) 
    W_values = np.zeros((N, K), dtype=np.complex128)
    W_values[0, :] = 1.0 + 0j
    for n in range(1, N):
        W_values[n, :] = W_values[n-1, :] * E
        
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
    
    # --- 7. Quantize Expected Outputs (Accumulators) ---
    # Expected accumulator outputs width: 64 bits (Q8.56)
    accum_frac_bits = 56
    accum_int_bits = accum_width - accum_frac_bits
    
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
        # Store unscaled golden floats for reference if needed
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
        f.write("# Simulation vectors for dft_accumulation.sv\n")
        f.write(f"# IQ_WIDTH = {iq_width}\n")
        f.write(f"# WINDOW_WIDTH = {window_width}\n")
        f.write(f"# ACCUM_WIDTH = {accum_width}\n")
        f.write(f"# OSC_WIDTH = {osc_width}\n")
        f.write("#\n")
        
        for tc in test_cases:
            f.write(f"{tc['test_name']}\n")
            f.write(f"{tc['num_samples']} {tc['num_bins']} {tc['fs']:.6e}\n")
            
            f.write("FREQ_BINS ")
            for freq in tc['freq_bins']:
                f.write(f"{freq/1e6:.6f} ")
            f.write("\n")
            
            f.write("SAMPLES\n")
            for n in range(tc['num_samples']):
                f.write(f"{tc['i_samples'][n]:05x} ")
                f.write(f"{tc['q_samples'][n]:05x} ")
                f.write(f"{tc['window_coeffs'][n]:05x} ")
                
                for k in range(tc['num_bins']):
                    f.write(f"{tc['W_real'][n, k]:05x} ")
                for k in range(tc['num_bins']):
                    f.write(f"{tc['W_imag'][n, k]:05x} ")
                f.write("\n")
            
            f.write("EXPECTED\n")
            for k in range(tc['num_bins']):
                f.write(f"{tc['expected_A_real'][k]:05x}\n")
            for k in range(tc['num_bins']):
                f.write(f"{tc['expected_A_imag'][k]:05x}\n")
            f.write("\n")
            
            f.write("GOLDEN ")
            for k in range(tc['num_bins']):
                f.write(f"{tc['golden_A_real'][k]:.6e} ")
            for k in range(tc['num_bins']):
                f.write(f"{tc['golden_A_imag'][k]:.6e} ")
            for k in range(tc['num_bins']):
                f.write(f"{tc['golden_A_mag'][k]:.6e} ")
            f.write("\n\n")

def main():
    print("=== Generating Simulation Vectors for dft_accumulation.sv ===\n")
    
    # Hardware parameters
    IQ_WIDTH = 16           # Q2.14
    WINDOW_WIDTH = 16       # Q2.14
    ACCUM_WIDTH = 64        # Q8.56
    OSC_WIDTH = 32          # Q3.24?? Adjusted based on fractional bits in function
    NUM_BINS = 24
    
    test_cases = []

    # --- Sanity Checks (Synthetic) ---
    # NOTE: Synthetic cases usually span [-1, 1], which fits in Q2.14. 
    # So normalize=False is fine, or normalize=True with max_magnitude=1.0 works too.
    
    # 1. Sanity Check 4-point
    fs_sanity = 4.0 
    nperseg_sanity = 4 
    t_sanity = np.arange(nperseg_sanity) / fs_sanity
    signal_sanity = np.cos(2 * np.pi * 1.0 * t_sanity)
    S_bins_sanity = np.fft.fftfreq(nperseg_sanity, 1/fs_sanity)
    
    tc_sanity = generate_test_case(
        "sanity_check_4pt_dft", signal_sanity, fs_sanity, S_bins_sanity, 'rect',
        IQ_WIDTH, WINDOW_WIDTH, ACCUM_WIDTH, OSC_WIDTH, 4, 
        normalize=False # Signal is already within [-1, 1] range
    )
    test_cases.append(tc_sanity)

    # 2. Sanity Check 8-point
    fs_sanity8 = 8.0
    nperseg_sanity8 = 8
    t_sanity8 = np.arange(nperseg_sanity8) / fs_sanity8
    signal_sanity8 = np.sin(2 * np.pi * 1.0 * t_sanity8)
    S_bins_sanity8 = np.fft.fftfreq(nperseg_sanity8, 1/fs_sanity8)

    tc_sanity8 = generate_test_case(
        "sanity_check_8pt_dft", signal_sanity8, fs_sanity8, S_bins_sanity8, 'rect',
        IQ_WIDTH, WINDOW_WIDTH, ACCUM_WIDTH, OSC_WIDTH, 8,
        normalize=False
    )
    test_cases.append(tc_sanity8)

    # 3. Sanity Check 24-point (Sin + Cos)
    fs_sanity24 = 24.0
    nperseg_sanity24 = 24
    t_sanity24 = np.arange(nperseg_sanity24) / fs_sanity24
    signal_sanity24 = np.sin(2 * np.pi * 1.0 * t_sanity24) + np.cos(2 * np.pi * 2.0 * t_sanity24)
    # Note: Max amplitude here is ~1.414. Q2.14 can handle up to ~2.0. So normalize=False is still safe.
    S_bins_sanity24 = np.fft.fftfreq(nperseg_sanity24, 1/fs_sanity24)

    tc_sanity24 = generate_test_case(
        "sanity_check_24pt_dft_sin_cos", signal_sanity24, fs_sanity24, S_bins_sanity24, 'rect',
        IQ_WIDTH, WINDOW_WIDTH, ACCUM_WIDTH, OSC_WIDTH, 24,
        normalize=False
    )
    test_cases.append(tc_sanity24)

    # --- PICMUS Real Data Test Cases ---
    if PICMUS_AVAILABLE:
        print("\n========== PICMUS Real Data Test Cases ==========")
        try:
            # Adjust paths as per your structure
            rf_path = SIMULATOR_ROOT.parent / "simulator/datasets/experiments/contrast_speckle/contrast_speckle_expe_dataset_rf.hdf5"
            iq_path = SIMULATOR_ROOT.parent / "simulator/datasets/experiments/contrast_speckle/contrast_speckle_expe_dataset_iq.hdf5"
            scan_path = SIMULATOR_ROOT.parent / "simulator/datasets/experiments/contrast_speckle/contrast_speckle_expe_scan.hdf5"
            
            adc_rate = 125e6
            baseline_decimation = 4
            
            rf_data, angles, _, _, fs_picmus, mod_freq, _, _, _ = load_picmus_rf_data(rf_path, iq_path, scan_path)

            # Determine Dynamic Range limit
            max_rf = np.max(np.abs(rf_data))
            max_rf_safe = 2 * max_rf
            
            center_angle_index = np.argmin(np.abs(angles))
            baseline_iq_data, _, fs_baseline = run_virtual_afe_processing(
                rf_data=rf_data, angle_index=center_angle_index, fs_picmus=fs_picmus,
                modulation_frequency=mod_freq, decimation_factor=baseline_decimation, adc_sample_rate=adc_rate
            )
            
            nperseg = 256
            hop = nperseg // 2
            
            delta_f = 0.25e6
            half_bw_est = mod_freq / 2
            s_coarse = np.linspace(-mod_freq, mod_freq, 8)
            s_fine_left = np.linspace(-half_bw_est - delta_f, -half_bw_est + delta_f, 8)
            s_fine_right = np.linspace(half_bw_est - delta_f, half_bw_est + delta_f, 8)
            S_bins = np.unique(np.concatenate([s_coarse, s_fine_left, s_fine_right]))
            
            test_configs = [
                ("picmus_ch64_win29", 64, 5),
                ("picmus_ch64_win15", 96, 29),
                ("picmus_ch64_win15", 32, 27),
            ]
            
            for test_name, channel, window_num in test_configs:
                print(f"\n--- Processing {test_name}: Channel {channel}, Window {window_num} ---")
                
                start_sample = window_num * hop
                end_sample = start_sample + nperseg
                time_window_data = baseline_iq_data[start_sample:end_sample, channel]
                
                # HERE we pass normalize=True and the safe max magnitude
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

    # Write to file
    output_dir = SIMULATOR_ROOT.parent / "rtl" / "simvectors"
    output_dir.mkdir(parents=True, exist_ok=True)
    output_path = output_dir / "dft_accumulation_vectors.txt"
    
    write_vector_file(test_cases, output_path, IQ_WIDTH, WINDOW_WIDTH, 
                     ACCUM_WIDTH, OSC_WIDTH)
    
    print(f"\n=== Successfully generated {len(test_cases)} test cases ===")
    print(f"Output file: {output_path}")

if __name__ == "__main__":
    main()