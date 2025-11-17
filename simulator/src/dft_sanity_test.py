import numpy as np

def simplify_exponent(k, n, N):
    """
    Simplifies the fraction -2*k*n/N for the exponent of e.
    Returns a simplified string representation.
    """
    # Use Fraction for exact simplification of the fraction
    from fractions import Fraction
    
    if k == 0 or n == 0:
        return "e^(0)"
        
    fraction = Fraction(-2 * k * n, N).limit_denominator()
    num = fraction.numerator
    den = fraction.denominator
    
    if den == 1:
        if num == 0:
            return "e^(0)"
        else:
            return f"e^({num}πi)"
    else:
        return f"e^({num}πi/{den})"

# --- Main Script ---
if __name__ == '__main__':
    print("--- DFT Sanity Check Value Generator ---")

    N = 8 # The size of our DFT

    # --- 1. Calculate and Print the Time-Domain Signal x[n] ---
    # Your signal is x(n) = cos(2*pi*n). In a discrete context, this is always 1.
    # cos(2*pi*integer) = 1 for all integer n.
    x_n = np.zeros(N)
    print("\n--- Time-Domain Signal x[n] = cos(2*pi*n) ---")
    print(" n | x[n]")
    print("---|------")
    for n in range(N):
        x_n[n] = np.cos(2 * np.pi * n / 8)
        print(f" {n} | {x_n[n]:.2f}")
    
    # --- 2. Calculate and Print the Complex Oscillator Values W_N^kn ---
    # W_N^kn = exp(-j * 2*pi*k*n / N)
    
    # Pre-calculate the float values for reference
    k = np.arange(N)
    n = np.arange(N)
    nk = np.outer(k, n) # Create the k*n matrix
    W_kn_float = np.exp(-1j * 2 * np.pi * nk / N)

    print("\n\n--- Complex Oscillator W_N^kn = e^(-2*pi*i*k*n/N) for N=8 ---")
    
    # --- Print the Symbolic Table ---
    # Header
    header = "k \\ n |" + "".join([f"{i:>10}" for i in range(N)])
    print(header)
    print("-" * len(header))
    
    # Table rows
    for k_idx in range(N):
        row_str = f"  {k_idx}  |"
        for n_idx in range(N):
            symbolic_val = simplify_exponent(k_idx, n_idx, N)
            row_str += f"{symbolic_val:>10}"
        print(row_str)

    # --- Print the Numerical (Real + j*Imag) Table for verification ---
    print("\n\n--- Numerical Values (Real + j*Imag) for Verification ---")
    # Header
    header_num = "k \\ n |" + "".join([f"{i:^9}" for i in range(N)])
    print(header_num)
    print("-" * len(header_num))
    
    # Table rows
    for k_idx in range(N):
        row_str_num = f"  {k_idx}  |"
        for n_idx in range(N):
            val = W_kn_float[k_idx, n_idx]
            row_str_num += f" {val.real:5.2f}{val.imag:+.2f}j"
        print(row_str_num)