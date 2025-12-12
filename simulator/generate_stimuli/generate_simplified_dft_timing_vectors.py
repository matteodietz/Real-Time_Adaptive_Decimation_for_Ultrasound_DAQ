"""
Generate simulation vectors for dft_estimator.sv module (timing controller + DFT accumulation)
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

def generate_test_case(test_name, iq_data, fs, freq_bins, window_type,
                       iq_width, window_width, accum_width, phase_width, num_bins,
                       delay_cycles, window_size):
    """
    Generate a single test case for the DFT estimator with timing controller.
    
    Args:
        delay_cycles: Number of cycles to wait before DFT window starts
        window_size: Number of samples in DFT window (should match iq_data length)
    
    Returns:
        Dictionary containing all inputs and expected outputs
    """
    print(f"\n=== Generating test case: {test_name} ===")
    
    N = len(iq_data)
    K = len(freq_bins)
    
    print(f"  Sample length: {N}")
    print(f"  Number of bins: {K}")
    print(f"  Delay cycles: {delay_cycles}")
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
    
    # Calculate frequency steps for CORDIC oscillator bank
    freq_steps = np.zeros(K, dtype=np.uint32)
    for k in range(K):
        normalized_freq = freqs_sorted[k] / fs
        step_real = normalized_freq * (2.0 ** phase_width)
        if step_real < 0:
            step_real += (2.0 ** phase_width)
        freq_steps[k] = int(step_real) & ((1 << phase_width) - 1)
    
    print(f"  Frequency steps (hex): {[hex(s) for s in freq_steps]}")
    
    # Convert to fixed point
    iq_frac_bits = 14
    iq_int_bits = iq_width - iq_frac_bits
    
    # Create padding samples (negative maximum values: 0xF000 for Q2.14)
    # This represents approximately -2.0 in Q2.14 format
    padding_i = 0xF000  # -2.0 in Q2.14
    padding_q = 0xF000  # -2.0 in Q2.14
    padding_window = 0x4000  # 1.0 in Q2.14 (no windowing effect on padding)
    
    # Quantize actual signal
    i_samples_hw = [float_to_fixed_point(np.real(s), iq_int_bits, iq_frac_bits, signed=True) 
                    for s in iq_data]
    q_samples_hw = [float_to_fixed_point(np.imag(s), iq_int_bits, iq_frac_bits, signed=True) 
                    for s in iq_data]
    
    # Window coefficients
    window_frac_bits = 14
    window_int_bits = window_width - window_frac_bits
    window_coeffs_hw = [float_to_fixed_point(w, window_int_bits, window_frac_bits, signed=True) 
                        for w in window_coeffs]
    
    # Build complete sample arrays: padding + actual signal
    # Total samples = delay_cycles + N
    total_samples = delay_cycles + N
    
    i_samples_full = [padding_i] * delay_cycles + i_samples_hw
    q_samples_full = [padding_q] * delay_cycles + q_samples_hw
    
    # Window coefficients: padding gets 1.0 (no effect), signal gets proper window
    window_coeffs_full = [padding_window] * delay_cycles + window_coeffs_hw
    
    # Expected accumulator outputs: Q8.56 format
    accum_frac_bits = 56
    accum_int_bits = accum_width - accum_frac_bits
    
    accums_scaled_real = np.real(accums_sorted)
    accums_scaled_imag = np.imag(accums_sorted)
    
    A_real_hw = [float_to_fixed_point(val, accum_int_bits, accum_frac_bits, signed=True) 
                 for val in accums_scaled_real]
    A_imag_hw = [float_to_fixed_point(val, accum_int_bits, accum_frac_bits, signed=True) 
                 for val in accums_scaled_imag]

    return {
        'test_name': test_name,
        'num_samples': total_samples,  # Total including padding
        'num_bins': K,
        'window_size': window_size,
        'delay_cycles': delay_cycles,
        'osc_latency': 35,  # Fixed CORDIC latency
        'fs': fs,
        'freq_bins': freqs_sorted,
        'freq_steps': freq_steps,
        'i_samples': i_samples_full,
        'q_samples': q_samples_full,
        'window_coeffs': window_coeffs_full,
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
        f.write("# Simulation vectors for dft_estimator.sv (timing controller + DFT)\n")
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
        f.write("# <num_bins> <num_samples> <window_size> <delay_cycles> <osc_latency>\n")
        f.write("# FREQ_STEPS (newline separated hex values)\n")
        f.write("# WINDOW_COEFFS (space-separated hex values)\n")
        f.write("# I_SAMPLES (space-separated hex values - includes padding + signal)\n")
        f.write("# Q_SAMPLES (space-separated hex values - includes padding + signal)\n")
        f.write("# EXPECTED_A_REAL (newline separated hex values)\n")
        f.write("# EXPECTED_A_IMAG (newline separated hex values)\n")
        f.write("#\n\n")
        
        for tc in test_cases:
            f.write(f"{tc['test_name']}\n")
            f.write(f"{tc['num_bins']} {tc['num_samples']} {tc['window_size']} ")
            f.write(f"{tc['delay_cycles']} {tc['osc_latency']}\n")
            
            # Write frequency steps (newline separated)
            for step in tc['freq_steps']:
                f.write(f"{step:08x}\n")
            
            # Write window coefficients (space-separated)
            for coeff in tc['window_coeffs']:
                f.write(f"{coeff:04x} ")
            f.write("\n")
            
            # Write I samples (space-separated)
            for sample in tc['i_samples']:
                f.write(f"{sample:04x} ")
            f.write("\n")
            
            # Write Q samples (space-separated)
            for sample in tc['q_samples']:
                f.write(f"{sample:04x} ")
            f.write("\n")
            
            # Write expected A_real (newline separated)
            for val in tc['expected_A_real']:
                f.write(f"{val:016x}\n")
            
            # Write expected A_imag (newline separated)
            for val in tc['expected_A_imag']:
                f.write(f"{val:016x}\n")
            
            f.write("\n")

def main():
    """
    Main function to generate all test vectors.
    """
    print("=== Generating Simulation Vectors for dft_estimator.sv ===\n")
    
    # Hardware parameters
    IQ_WIDTH = 16           # Q2.14
    WINDOW_WIDTH = 16       # Q2.14
    ACCUM_WIDTH = 64        # Q8.56
    OSC_WIDTH = 32          # CORDIC output width
    PHASE_WIDTH = 32        # Phase accumulator width
    NUM_BINS = 24           # Maximum
    
    test_cases = []

    # ====================================================================
    # Sanity Check 1: 4-point DFT with 64 cycles padding
    # ====================================================================
    print("\n========== Sanity Check 1: 4-point DFT ==========")
    
    fs_sanity = 4.0
    nperseg_sanity = 4
    delay_cycles_sanity = 64
    
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
        4,
        delay_cycles_sanity,
        nperseg_sanity
    )
    test_cases.append(tc_sanity)

    # ====================================================================
    # Sanity Check 2: 8-point DFT with 64 cycles padding
    # ====================================================================
    print("\n========== Sanity Check 2: 8-point DFT ==========")
    
    fs_sanity8 = 8.0
    nperseg_sanity8 = 8
    delay_cycles_sanity8 = 64
    
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
        8,
        delay_cycles_sanity8,
        nperseg_sanity8
    )
    test_cases.append(tc_sanity8)

    # ====================================================================
    # Sanity Check 3: 24-point DFT with 64 cycles padding
    # ====================================================================
    print("\n========== Sanity Check 3: 24-point DFT ==========")
    
    fs_sanity24 = 24.0
    nperseg_sanity24 = 24
    delay_cycles_sanity24 = 64
    
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
        24,
        delay_cycles_sanity24,
        nperseg_sanity24
    )
    test_cases.append(tc_sanity24)
    
    # Write to file
    output_dir = SIMULATOR_ROOT.parent / "rtl" / "simvectors"
    output_dir.mkdir(parents=True, exist_ok=True)
    output_path = output_dir / "simplified_dft_timing_vectors.txt"
    
    write_vector_file(test_cases, output_path, IQ_WIDTH, WINDOW_WIDTH, 
                     ACCUM_WIDTH, OSC_WIDTH, PHASE_WIDTH)
    
    print(f"\n=== Successfully generated {len(test_cases)} test cases ===")
    print(f"Output file: {output_path}")
    print("\nTest cases generated:")
    for tc in test_cases:
        print(f"  - {tc['test_name']}: {tc['num_samples']} total samples ")
        print(f"    ({tc['delay_cycles']} padding + {tc['window_size']} signal), {tc['num_bins']} bins")

if __name__ == "__main__":
    main()