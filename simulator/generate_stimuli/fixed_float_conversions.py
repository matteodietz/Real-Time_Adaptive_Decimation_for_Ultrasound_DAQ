def float_to_fixed_point(value, int_bits, frac_bits, signed=True):
    """
    Convert floating point to fixed point representation.
    
    Args:
        value: floating point value
        int_bits: number of integer bits
        frac_bits: number of fractional bits
        signed: whether the number is signed
    
    Returns:
        Integer representation of fixed point number
    """
    total_bits = int_bits + frac_bits
    scale = 2 ** frac_bits
    fixed_val = int(round(value * scale))
    
    if signed:
        max_val = 2 ** (total_bits - 1) - 1
        min_val = -(2 ** (total_bits - 1))
    else:
        max_val = 2 ** total_bits - 1
        min_val = 0
    
    # Saturate
    fixed_val = max(min_val, min(max_val, fixed_val))
    
    # Convert to unsigned representation for output
    if signed and fixed_val < 0:
        fixed_val = (1 << total_bits) + fixed_val
    
    return fixed_val

def fixed_point_to_float(fixed_val, total_bits, frac_bits, signed=True):
    """
    Convert a fixed-point integer (potentially in unsigned two's complement format)
    back to a floating point number.
    """
    if not signed:
        return float(fixed_val) / (2**frac_bits)

    # Determine the sign bit
    sign_bit_mask = 1 << (total_bits - 1)
    
    # If the sign bit is set, it's a negative number
    if (fixed_val & sign_bit_mask):
        # Convert from two's complement to negative integer
        signed_int = fixed_val - (1 << total_bits)
    else:
        signed_int = fixed_val
        
    return float(signed_int) / (2**frac_bits)

# --- example usage ---
if __name__ == '__main__':
    val1_float = fixed_point_to_float(0x4000, 16, 14)
    val2_float = fixed_point_to_float(0x0000, 16, 14)
    val3_float = fixed_point_to_float(0xC000, 16, 14)

    val4_float = fixed_point_to_float(0x1000000, 27, 24)
    val5_float = fixed_point_to_float(0x0000000, 27, 24)
    val6_float = fixed_point_to_float(0x7000000, 27, 24)

    val7_float = fixed_point_to_float(0x008000000000, 48, 40)
    val8_float = fixed_point_to_float(0x000000000000, 48, 40)
    val9_float = fixed_point_to_float(0x010000000000, 48, 40)

    
    print("Values of input signal x[n]")
    print(f"0x4000 (Q16.14) = {val1_float}")
    print(f"0x0000 (Q16.14) = {val2_float}")
    print(f"0xC000 (Q16.14) = {val3_float}")


    print("\nValues for oscillator w[n,k]")
    print(f"0x1000000 (Q27.24) = {val4_float}")
    print(f"0x0000000 (Q27.24) = {val5_float}")
    print(f"0x7000000 (Q27.24) = {val6_float}")


    print("\nValues for accumulators A[k]")
    print(f"0x008000000000 (Q48.40) = {val7_float}")
    print(f"0x000000000000 (Q48.40) = {val8_float}")
    print(f"0x010000000000 (Q48.40) = {val9_float}")

    
    # # Verify the reverse calculation
    # neg_val_hex = 0xFFFFA0
    # neg_val_float = fixed_point_to_float(neg_val_hex, 24, 6)
    # print(f"0xFFFFA0 (Q18.6) = {neg_val_float}")