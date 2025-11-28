import numpy as np

def float_to_fixed_point(value, int_bits, frac_bits, signed=True, zero_threshold=1e-10):
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

    # Implement a "dead zone" around zero to handle floating point noise
    if abs(value) < zero_threshold:
        return 0

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



def adc_quantize_signed(value, bit_width=16, max_magnitude=1.0, return_as_unsigned_bit_representation=True):
    """
    Quantizes a float (or array of floats) to a signed fixed-point integer 
    relative to a maximum absolute magnitude.
    
    This function behaves like an ADC that maps:
      +max_magnitude  ->  +Max Integer (e.g., +32767 for 16-bit)
      -max_magnitude  ->  -Max Integer (e.g., -32767 for 16-bit)
       0.0            ->   0
       
    Args:
        value (float or np.ndarray): The input value(s) to quantize.
        bit_width (int): The total number of bits (including sign bit). Default 16.
        max_magnitude (float): The absolute value that corresponds to the full-scale 
                               positive integer range.
        return_as_unsigned_bit_representation (bool): 
            If False (default), returns standard signed integers (e.g., -5, 10).
            If True, returns the unsigned 2's complement bit representation 
            (e.g., for -1 in 16-bit, returns 65535). Use this for writing to FPGA files.

    Returns:
        np.ndarray or int: The quantized values.
    """
    
    # 1. Calculate the maximum representable positive integer.
    # For 16-bit signed: 2^(15) - 1 = 32767
    max_int = (2 ** (bit_width - 1)) - 1
    
    # 2. Calculate the minimum representable negative integer.
    # For 16-bit signed: -(2^15) = -32768
    min_int = -(2 ** (bit_width - 1))
    
    # 3. Determine the Scale Factor
    # We map 'max_magnitude' to 'max_int'. 
    # value_int = value_float * (Max_Int / Max_Volts)
    scale_factor = max_int / max_magnitude
    
    # 4. Scale and Round
    # We use np.round to handle arrays efficiently
    val_scaled = value * scale_factor
    val_rounded = np.round(val_scaled)
    
    # 5. Saturate / Clip
    # This ensures values outside [-max_magnitude, +max_magnitude] don't overflow/wrap
    val_clipped = np.clip(val_rounded, min_int, max_int)
    
    # 6. Convert to integer type
    val_int = val_clipped.astype(int)
    
    # 7. Convert to unsigned 2's complement bit representation
    # This matches the behavior of 'float_to_fixed_point' where negative numbers
    # are converted to their large unsigned equivalent (e.g. -1 becomes 0xFFFF).
    if return_as_unsigned_bit_representation:
        # We need to handle this differently for arrays vs scalars
        if isinstance(val_int, np.ndarray):
            # Add 2^N to negative numbers only
            mask = val_int < 0
            val_int[mask] = val_int[mask] + (1 << bit_width)
        else:
            if val_int < 0:
                val_int = val_int + (1 << bit_width)
                
    return val_int, scale_factor

# # --- Example Usage / Sanity Check ---
# if __name__ == "__main__":
#     # Example Parameters
#     my_max_mag = 100e-6  # Signal is +/- 100 microvolts
#     my_bits = 16
    
#     # Test values: 0, Positive Max, Negative Max, Overflow, Small Value
#     test_inputs = np.array([0, 100e-6, -100e-6, 150e-6, -1.5e-6])
    
#     print(f"Max Magnitude Setting: {my_max_mag}")
#     print(f"Input Floats: {test_inputs}")
    
#     # Standard Signed Output (Math mode)
#     quantized_signed = adc_quantize_signed(test_inputs, my_bits, my_max_mag, False)
#     print(f"Signed Output: {quantized_signed}") 
#     # Expected: [0, 32767, -32767, 32767, -491]
    
#     # Hardware/File Output (Bit pattern mode)
#     quantized_bits = adc_quantize_signed(test_inputs, my_bits, my_max_mag, True)
#     print(f"Hex/Bit Output: {quantized_bits}")
#     # Expected: [0, 32767, 32769, 32767, 65045] 

# --- example usage ---
if __name__ == '__main__':
    # val1_float = fixed_point_to_float(0x4000, 16, 14)
    # val2_float = fixed_point_to_float(0x0000, 16, 14)
    # val3_float = fixed_point_to_float(0xC000, 16, 14)

    # val4_float = fixed_point_to_float(0x1000000, 27, 24)
    # val5_float = fixed_point_to_float(0x0000000, 27, 24)
    # val6_float = fixed_point_to_float(0x7000000, 27, 24)

    # val7_float = fixed_point_to_float(0x008000000000, 48, 40)
    # val8_float = fixed_point_to_float(0x000000000000, 48, 40)
    # val9_float = fixed_point_to_float(0x010000000000, 48, 40)

    
    # print("Values of input signal x[n]")
    # print(f"0x4000 (Q16.14) = {val1_float}")
    # print(f"0x0000 (Q16.14) = {val2_float}")
    # print(f"0xC000 (Q16.14) = {val3_float}")


    # print("\nValues for oscillator w[n,k]")
    # print(f"0x1000000 (Q27.24) = {val4_float}")
    # print(f"0x0000000 (Q27.24) = {val5_float}")
    # print(f"0x7000000 (Q27.24) = {val6_float}")


    # print("\nValues for accumulators A[k]")
    # print(f"0x008000000000 (Q48.40) = {val7_float}")
    # print(f"0x000000000000 (Q48.40) = {val8_float}")
    # print(f"0x010000000000 (Q48.40) = {val9_float}")

    
    # # Verify the reverse calculation
    # neg_val_hex = 0xFFFFA0
    # neg_val_float = fixed_point_to_float(neg_val_hex, 24, 6)
    # print(f"0xFFFFA0 (Q18.6) = {neg_val_float}")

    # val1_fixed = float_to_fixed_point(10e-6, 8, 56)
    # val10_float = fixed_point_to_float(val1_fixed, 64, 56)
    # print(f"10e-6 = {val1_fixed}")
    # print(f"10e-6 = {val10_float}")

    # val11_float =  fixed_point_to_float(0x0c00000000000080, 64, 56)
    # val12_float =  fixed_point_to_float(0xf3fffffffffffd80, 64, 56)
    # val13_float =  fixed_point_to_float(0x0c00000000000280, 64, 56)
    # # val14_float =  fixed_point_to_float(0x03fffd5012f30000, 64, 56)

    # print(f"{val11_float}")
    # print(f"{val12_float}")
    # print(f"{val13_float}")
    # # print(f"{val14_float}")

    pi_fixed_3q29 = float_to_fixed_point(np.pi, 3, 29)
    pi_neg_fixed_3q29 = float_to_fixed_point(-np.pi, 3, 29)

    print(f"Q3.29 pi = {pi_fixed_3q29}")
    print(f"Q3.29 -pi = {pi_neg_fixed_3q29}")