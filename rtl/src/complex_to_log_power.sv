////////////////////////////////////////////////////////////////////////////////
//
//  Module: complex_to_log_power
//
//  Function: Calculates Power_dB ~= 3 * log2(I^2 + Q^2)
//
//  Details:
//      1. Calculates Magnitude Squared: P = I^2 + Q^2
//      2. Finds the Leading One (MSB) of P. This is the Integer Log2.
//      3. Takes the bits immediately after the MSB. This is the Fractional Log2.
//      4. Multiplies by 3 to approximate 10*log10 conversion.
//
//  Latency: 3 Clock Cycles (Pipelined for timing closure)
//
////////////////////////////////////////////////////////////////////////////////

module complex_to_log_power #(
    parameter int INPUT_WIDTH   = 16, // Width of I and Q
    parameter int OUTPUT_WIDTH  = 32, // Width of result
    parameter int OUTPUT_FRAC   = 16  // Fractional bits in result
) (
    input  logic                    clk_i,
    input  logic                    rst_ni,
    input  logic                    valid_i,
    input  logic signed [INPUT_WIDTH-1:0] i_data_i,
    input  logic signed [INPUT_WIDTH-1:0] q_data_i,
    
    output logic                    valid_o,
    output logic [OUTPUT_WIDTH-1:0] db_power_o
);

    // ---------------------------------------------------------
    // Stage 1: Square and Add (Mag Squared)
    // ---------------------------------------------------------
    // Result width is 2*Input + 1 bit for addition
    localparam int SQ_WIDTH = (2 * INPUT_WIDTH) + 1;
    
    logic signed [SQ_WIDTH-1:0] p_mag_sq;
    logic                       s1_valid;
    
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            p_mag_sq <= '0;
            s1_valid <= 1'b0;
        end else begin
            s1_valid <= valid_i;
            if (valid_i) begin
                // Standard signed multiplication inferred DSPs
                p_mag_sq <= (i_data_i * i_data_i) + (q_data_i * q_data_i);
            end
        end
    end

    // ---------------------------------------------------------
    // Stage 2: Priority Encoder (Dynamic Log2)
    // ---------------------------------------------------------
    // We need to find the position of the highest '1' bit.
    // Since p_mag_sq is always positive (sum of squares), we treat as unsigned.
    
    logic [5:0]  msb_index;   // Enough to count up to 64 bits (SQ_WIDTH)
    logic [OUTPUT_FRAC-1:0] frac_part;
    logic        is_zero;
    logic        s2_valid;
    
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            msb_index <= '0;
            frac_part <= '0;
            is_zero   <= 1'b0;
            s2_valid  <= 1'b0;
        end else begin
            s2_valid <= s1_valid;
            
            if (s1_valid) begin
                // SystemVerilog synthesis-friendly Leading One Detector
                // We loop from top bit down to find the first 1.
                msb_index = 0;
                is_zero   = 1; 
                frac_part = 0;
                
                for (int i = SQ_WIDTH-1; i >= 0; i--) begin
                    if (p_mag_sq[i] == 1'b1) begin
                        msb_index = i[5:0]; // The Integer Log2 value
                        is_zero   = 0;
                        
                        // Extract Fractional Part:
                        // Take the bits immediately following the MSB.
                        // Use shifting to align them to OUTPUT_FRAC.
                        // If we don't have enough bits below, shift left.
                        if (i >= OUTPUT_FRAC)
                            frac_part = p_mag_sq[i-1 -: OUTPUT_FRAC];
                        else
                            frac_part = p_mag_sq[i-1 : 0] << (OUTPUT_FRAC - i);
                            
                        break; // Stop after finding the first 1
                    end
                end
            end
        end
    end

    // ---------------------------------------------------------
    // Stage 3: Log Construction and Scaling
    // ---------------------------------------------------------
    // Formula: result = 3 * (integer_part.fractional_part)
    
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            db_power_o <= '0;
            valid_o    <= 1'b0;
        end else begin
            valid_o <= s2_valid;
            
            if (s2_valid) begin
                if (is_zero) begin
                    // Log(0) is -inf. We clamp to a minimal value (e.g. 0 or min int)
                    db_power_o <= '0; 
                end else begin
                    // 1. Construct Fixed Point Log2 value
                    //    Format: [Integer Index] . [Fractional Part]
                    logic [OUTPUT_WIDTH-1:0] log2_val;
                    
                    // Place integer part in upper bits, fraction in lower bits
                    log2_val = (msb_index << OUTPUT_FRAC) | frac_part;
                    
                    // 2. Scale by 3 (Approximation of x * 3.0103)
                    //    x * 3 = (x << 1) + x
                    //    We assume the output width is large enough to hold this sum.
                    db_power_o <= (log2_val << 1) + log2_val;
                end
            end else begin
                valid_o <= 1'b0; // Clear valid if pipe is empty
            end
        end
    end

endmodule