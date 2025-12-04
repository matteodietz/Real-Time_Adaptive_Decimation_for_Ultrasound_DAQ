"""
Generate simulation vectors for dft_accumulation.sv module using only PICMUS data.
"""
import numpy as np
from scipy import signal
from pathlib import Path
import sys

# Add parent directory to path to import golden model
SIMULATOR_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SIMULATOR_ROOT / "src"))

from golden_model_floating_point import streaming_dft_processor
from fixed_float_conversions import float_to_fixed_point

# Import data loading functions
try:
    from afe_interface_rf import load_picmus_rf_data
    from virtual_afe import run_virtual_afe_processing
    PICMUS_AVAILABLE = True
except ImportError:
    print("Error: PICMUS data loading modules not available.")
    PICMUS_AVAILABLE = False

def generate_test_case_data(test_name, iq_data_raw, fs, freq_bins, window_type,
                            iq_width, window_width, accum_width, osc_width, num_bins):
    """
    Takes raw (small magnitude) IQ data, scales it to full-scale fixed-point range,
    runs the Golden Model, and generates hex strings for the testbench.
    """
    print(f"\n=== Generating test case: {test_name} ===")
    
    N = len(iq_data_raw)
    K = len(freq_bins)
    
    # -------------------------------------------------------------------------
    # 1. Determine Scaling Factor
    # -------------------------------------------------------------------------
    # We want to map the maximum absolute value of the input signal to the 
    # maximum representable value of the Fixed-Point format (Q2.14).
    # Q2.14 range is [-2.0, 1.999...]. We target ~1.0 to ~1.8 for safety.
    
    iq_frac_bits = 14
    iq_int_bits = iq_width - iq_frac_bits # 2 bits
    
    # Find peak in the current window
    max_val = np.max(np.abs(iq_data_raw))
    
    # Target value (e.g., 1.5 to leave some headroom, or full 2.0)
    # Using 1.0 is safe and standard for normalized logic.
    target_peak = 1.5 
    
    if max_val > 0:
        scale_factor = target_peak / max_val
    else:
        scale_factor = 1.0
        
    print(f"  Input Peak: {max_val:.2e}")
    print(f"  Scaling Factor: {scale_factor:.2f}")
    
    # -------------------------------------------------------------------------
    # 2. Scale Data & Run Golden Model
    # -------------------------------------------------------------------------
    # Apply scaling to input BEFORE processing
    # This emulates the Analog/Digital Gain that makes the signal audible/visible
    iq_data_scaled = iq_data_raw * scale_factor
    
    print(f"  Scaled Peak: {np.max(np.abs(iq_data_scaled)):.2f}")
    
    # Run Golden Model on SCALED data
    dft_bins = streaming_dft_processor(iq_data_scaled, fs, freq_bins, window=window_type)
    
    # Extract results (Sorted)
    freqs = np.array(list(dft_bins.keys()))
    accumulators = np.array(list(dft_bins.values()))
    sort_indices = np.argsort(freqs)
    freqs_sorted = freqs[sort_indices]
    accums_sorted = accumulators[sort_indices]
    
    # -------------------------------------------------------------------------
    # 3. Generate Hardware Coefficients (Window & W)
    # -------------------------------------------------------------------------
    # Window
    window_coeffs = signal.windows.get_window(window_type, N)
    
    # Oscillator W[n,k]
    # W starts at 1+0j and rotates by exp(-j*2*pi*f/fs)
    E = np.exp(-1j * 2 * np.pi * freqs_sorted / fs) 
    W_values = np.zeros((N, K), dtype=np.complex128)
    W_values[0, :] = 1.0 + 0j
    for n in range(1, N):
        W_values[n, :] = W_values[n-1, :] * E

    # -------------------------------------------------------------------------
    # 4. Quantize Everything to Fixed Point (Hex)
    # -------------------------------------------------------------------------
    
    # A. Inputs (Scaled I/Q)
    i_samples_hw = [float_to_fixed_point(np.real(s), iq_int_bits, iq_frac_bits, signed=True) 
                    for s in iq_data_scaled]
    q_samples_hw = [float_to_fixed_point(np.imag(s), iq_int_bits, iq_frac_bits, signed=True) 
                    for s in iq_data_scaled]
                    
    # B. Window Coeffs
    # Q2.14 (matches window width)
    win_frac = 14
    win_int = window_width - win_frac
    window_coeffs_hw = [float_to_fixed_point(w, win_int, win_frac, signed=True) 
                        for w in window_coeffs]
                        
    # C. Oscillator W
    # Q3.24 (27 bits usually, here customized by osc_width)
    # Assuming OSC_WIDTH=32 -> Q8.24 or Q4.28? 
    # Let's match the param: OSC_WIDTH_FRAC = 24? 
    # NOTE: User param OSC_WIDTH=32. Let's assume Q2.30 for high precision or Q4.28.
    # The snippet used: osc_frac_bits = 28
    osc_frac_bits = 28
    osc_int_bits = osc_width - osc_frac_bits
    
    W_real_hw = np.zeros((N, K), dtype=object) # Use object to hold large ints
    W_imag_hw = np.zeros((N, K), dtype=object)
    
    for n in range(N):
        for k in range(K):
            W_real_hw[n, k] = float_to_fixed_point(np.real(W_values[n, k]), osc_int_bits, osc_frac_bits, signed=True)
            W_imag_hw[n, k] = float_to_fixed_point(np.imag(W_values[n, k]), osc_int_bits, osc_frac_bits, signed=True)

    # D. Expected Accumulators
    # Q8.40 (48 bits) or similar.
    # The accumulator results from the golden model are already "scaled" 
    # because we fed it scaled inputs. We just convert them directly.
    accum_frac_bits = 40 # 56 in previous, 40 in recent module. Let's use 40.
    accum_int_bits = accum_width - accum_frac_bits
    
    A_real_hw = [float_to_fixed_point(np.real(a), accum_int_bits, accum_frac_bits, signed=True) 
                 for a in accums_sorted]
    A_imag_hw = [float_to_fixed_point(np.imag(a), accum_int_bits, accum_frac_bits, signed=True) 
                 for a in accums_sorted]

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
        # Save floats for debugging if needed
        'golden_A_mag': [np.abs(a) for a in accums_sorted]
    }

def write_vector_file(test_cases, output_path, iq_width, window_width, accum_width, osc_width):
    """
    Writes the test vectors to the specified file.
    """
    with open(output_path, 'w') as f:
        # Header
        f.write("# Simulation vectors for dft_accumulation.sv\n")
        f.write(f"# IQ_WIDTH = {iq_width}\n")
        f.write(f"# WINDOW_WIDTH = {window_width}\n")
        f.write(f"# ACCUM_WIDTH = {accum_width}\n")
        f.write(f"# OSC_WIDTH = {osc_width}\n")
        f.write("#\n")
        f.write("# Format per test case:\n")
        f.write("# <test_name>\n")
        f.write("# <num_samples> <num_bins> <fs>\n")
        f.write("# FREQ_BINS <freq0> <freq1> ...\n")
        f.write("# SAMPLES (per line: I Q window_coeff W_real[0..K-1] W_imag[0..K-1])\n")
        f.write("# EXPECTED A_real[0..K-1] A_imag[0..K-1]\n")
        f.write("# GOLDEN_MAG (float reference)\n")
        f.write("#\n\n")
        
        for tc in test_cases:
            f.write(f"{tc['test_name']}\n")
            f.write(f"{tc['num_samples']} {tc['num_bins']} {tc['fs']:.6e}\n")
            
            f.write("FREQ_BINS ")
            for freq in tc['freq_bins']:
                f.write(f"{freq/1e6:.6f} ") # Write in MHz
            f.write("\n")
            
            f.write("SAMPLES\n")
            for n in range(tc['num_samples']):
                # I, Q, Window
                f.write(f"{tc['i_samples'][n]:04x} ") # Adjust hex width if needed
                f.write(f"{tc['q_samples'][n]:04x} ")
                f.write(f"{tc['window_coeffs'][n]:04x} ")
                
                # W values
                for k in range(tc['num_bins']):
                    f.write(f"{tc['W_real'][n, k]:08x} ")
                for k in range(tc['num_bins']):
                    f.write(f"{tc['W_imag'][n, k]:08x} ")
                f.write("\n")
            
            f.write("EXPECTED\n")
            for k in range(tc['num_bins']):
                f.write(f"{tc['expected_A_real'][k]:012x}\n") # 48 bits = 12 hex chars
            for k in range(tc['num_bins']):
                f.write(f"{tc['expected_A_imag'][k]:012x}\n")
            f.write("\n")
            
            f.write("GOLDEN_MAG ")
            for val in tc['golden_A_mag']:
                f.write(f"{val:.4e} ")
            f.write("\n\n")

def main():
    print("=== Generating Simulation Vectors for dft_accumulation.sv ===\n")
    
    # Hardware parameters (Must match SystemVerilog)
    IQ_WIDTH = 16           
    WINDOW_WIDTH = 16       
    ACCUM_WIDTH = 48        # Changed to 48 as per recent modules
    OSC_WIDTH = 32          # Changed to 32 as per recent modules
    NUM_BINS = 24           
    
    # Parameters for Logic
    NPERSEG = 256
    HOP = NPERSEG // 2
    
    test_cases = []
    
    if PICMUS_AVAILABLE:
        try:
            # 1. Load Data
            print("Loading PICMUS Dataset...")
            rf_path = SIMULATOR_ROOT.parent / "simulator/datasets/experiments/contrast_speckle/contrast_speckle_expe_dataset_rf.hdf5"
            iq_path = SIMULATOR_ROOT.parent / "simulator/datasets/experiments/contrast_speckle/contrast_speckle_expe_dataset_iq.hdf5"
            scan_path = SIMULATOR_ROOT.parent / "simulator/datasets/experiments/contrast_speckle/contrast_speckle_expe_scan.hdf5"
            
            rf_data, angles, _, _, fs_picmus, mod_freq, _, _, _ = load_picmus_rf_data(rf_path, iq_path, scan_path)
            
            # 2. Virtual AFE Processing (Get full I/Q Lines)
            # We process specific angles of interest here
            adc_rate = 125e6
            baseline_decimation = 4
            
            # Define Test Configurations: (TestName, Channel, AngleIndex, WindowIndex)
            # Note: WindowIndex refers to the temporal window inside the A-line
            configs = [
                ("picmus_ang0_ch64_win29", 64, np.argmin(np.abs(angles)), 29),
                ("picmus_ang0_ch32_win15", 32, np.argmin(np.abs(angles)), 15),
                ("picmus_ang0_ch96_win30", 96, np.argmin(np.abs(angles)), 30),
                # Add an angle 10 degrees if desired, finding index for ~10 deg
                # ("picmus_ang10_ch64_win29", 64, 10, 29) 
            ]
            
            # Define Frequency Bins (Fixed for all tests usually)
            delta_f = 0.25e6
            half_bw_est = mod_freq / 2
            s_coarse = np.linspace(-mod_freq, mod_freq, 8)
            s_fine_left = np.linspace(-half_bw_est - delta_f, -half_bw_est + delta_f, 8)
            s_fine_right = np.linspace(half_bw_est - delta_f, half_bw_est + delta_f, 8)
            S_bins = np.unique(np.concatenate([s_coarse, s_fine_left, s_fine_right]))
            
            # Cache processed angles to avoid re-running AFE for same angle
            processed_angles = {} 

            for name, ch, ang_idx, win_idx in configs:
                print(f"\nProcessing Config: {name} (AngIdx: {ang_idx}, Ch: {ch}, Win: {win_idx})")
                
                # Retrieve or Compute AFE data for this angle
                if ang_idx not in processed_angles:
                    print("  Running Virtual AFE for Angle Index", ang_idx)
                    iq_data_angle, _, fs_base = run_virtual_afe_processing(
                        rf_data=rf_data, angle_index=ang_idx, fs_picmus=fs_picmus,
                        modulation_frequency=mod_freq, decimation_factor=baseline_decimation,
                        adc_sample_rate=adc_rate
                    )
                    processed_angles[ang_idx] = (iq_data_angle, fs_base)
                
                baseline_iq_data, fs_baseline = processed_angles[ang_idx]
                
                # Extract specific STFT window
                start_sample = win_idx * HOP
                end_sample = start_sample + NPERSEG
                
                # Check bounds
                if end_sample > baseline_iq_data.shape[0]:
                    print(f"  Warning: Window {win_idx} out of bounds. Skipping.")
                    continue
                    
                time_window_data = baseline_iq_data[start_sample:end_sample, ch]
                
                # Generate Test Case Data
                tc = generate_test_case_data(
                    name, 
                    time_window_data, 
                    fs_baseline, 
                    S_bins, 
                    'hann',
                    IQ_WIDTH, WINDOW_WIDTH, ACCUM_WIDTH, OSC_WIDTH, NUM_BINS
                )
                test_cases.append(tc)
                
        except Exception as e:
            print(f"Error processing PICMUS data: {e}")
            import traceback
            traceback.print_exc()
            
    # 3. Write Output
    output_dir = SIMULATOR_ROOT.parent / "rtl" / "simvectors"
    output_dir.mkdir(parents=True, exist_ok=True)
    output_path = output_dir / "dft_accumulation_vectors.txt"
    
    write_vector_file(test_cases, output_path, IQ_WIDTH, WINDOW_WIDTH, ACCUM_WIDTH, OSC_WIDTH)
    
    print(f"\n=== Successfully generated {len(test_cases)} test cases ===")
    print(f"Output file: {output_path}")

if __name__ == "__main__":
    main()