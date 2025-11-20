////////////////////////////////////////////////////////////////////////////////
//
//              Given two frequency points (f1, f2) and their corresponding
//              dB levels (L1, L2), calculates:
//              f_star = f1 + (f2 - f1) * (threshold_db - L1) / (L2 - L1)
//
// Parameters:
//
//   FREQ_WIDTH       - Total bit width for frequency values (f1, f2, f_star)
//   FREQ_FRAC_BITS   - Number of fractional bits in frequency values
//   ACCUM_DB_WIDTH   - Total bit width for dB accumulator values (L1, L2)
//   ACCUM_DB_FRAC    - Number of fractional bits in dB values
//   THRESHOLD_DB     - Fixed threshold value in same format as L1, L2
//
// Inputs:
//
//   clk_i       - System clock
//   rst_ni      - Asynchronous reset (active low)
//   valid_i     - Input valid strobe
//   f1_i        - First frequency point (fixed point)
//   f2_i        - Second frequency point (fixed point)
//   L1_i        - dB level at f1 (fixed point, signed)
//   L2_i        - dB level at f2 (fixed point, signed)
//
// Outputs:
//
//   ready_o     - Output ready/valid strobe
//   f_star_o    - Interpolated crossing frequency (fixed point)
//   invalid_o   - High if inputs were invalid (division by zero, etc.)
//
////////////////////////////////////////////////////////////////////////////////

module linear_interp_crossing #(
    parameter int FREQ_WIDTH = 32,
    parameter int FREQ_FRAC_BITS = 16,
    parameter int ACCUM_DB_WIDTH = 32,
    parameter int ACCUM_DB_FRAC = 16,
    parameter signed [ACCUM_DB_WIDTH-1:0] THRESHOLD_DB = -20 << ACCUM_DB_FRAC
) (
    input  logic                                clk_i,
    input  logic                                rst_ni,
    input  logic                                valid_i,
    input  logic [FREQ_WIDTH-1:0]               f1_i,
    input  logic [FREQ_WIDTH-1:0]               f2_i,
    input  logic signed [ACCUM_DB_WIDTH-1:0]    L1_i,
    input  logic signed [ACCUM_DB_WIDTH-1:0]    L2_i,
    output logic                                ready_o,
    output logic [FREQ_WIDTH-1:0]               f_star_o,
    output logic                                invalid_o
);

    // Pipeline stages for calculation
    // Stage 1: Calculate differences
    // Stage 2: Calculate numerator (threshold - L1)
    // Stage 3: Multiply (f2 - f1) * (threshold - L1)
    // Stage 4: Divide by (L2 - L1)
    // Stage 5: Add f1 + result
    
    localparam int PIPE_DEPTH = 5;
    
    // Extended widths for intermediate calculations
    localparam int DIFF_WIDTH = FREQ_WIDTH + 1;
    localparam int DB_DIFF_WIDTH = ACCUM_DB_WIDTH + 1;
    localparam int MULT_WIDTH = DIFF_WIDTH + DB_DIFF_WIDTH;
    
    // Pipeline valid signals
    logic [PIPE_DEPTH-1:0] valid_pipe;
    logic [PIPE_DEPTH-1:0] invalid_pipe;
    
    // Stage 1: Calculate differences
    logic signed [DIFF_WIDTH-1:0]     s1_f_diff;      // f2 - f1
    logic signed [DB_DIFF_WIDTH-1:0]  s1_L_diff;      // L2 - L1
    logic signed [DB_DIFF_WIDTH-1:0]  s1_threshold_diff; // threshold - L1
    logic [FREQ_WIDTH-1:0]            s1_f1;
    logic                             s1_div_by_zero;
    
    // Stage 2: Store values (register stage for timing)
    logic signed [DIFF_WIDTH-1:0]     s2_f_diff;
    logic signed [DB_DIFF_WIDTH-1:0]  s2_L_diff;
    logic signed [DB_DIFF_WIDTH-1:0]  s2_threshold_diff;
    logic [FREQ_WIDTH-1:0]            s2_f1;
    
    // Stage 3: Multiply (f2-f1) * (threshold-L1)
    logic signed [MULT_WIDTH-1:0]     s3_numerator;
    logic signed [DB_DIFF_WIDTH-1:0]  s3_L_diff;
    logic [FREQ_WIDTH-1:0]            s3_f1;
    
    // Stage 4: Divide numerator by (L2-L1)
    // Result has ACCUM_DB_FRAC fractional bits removed
    logic signed [MULT_WIDTH-1:0]     s4_quotient;
    logic [FREQ_WIDTH-1:0]            s4_f1;
    
    // Stage 5: Add f1 + scaled_result
    // (output registered)
    
    ////////////////////////////////////////////////////////////////////////////
    // Stage 1: Calculate all differences
    ////////////////////////////////////////////////////////////////////////////
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            s1_f_diff <= '0;
            s1_L_diff <= '0;
            s1_threshold_diff <= '0;
            s1_f1 <= '0;
            s1_div_by_zero <= 1'b0;
            valid_pipe[0] <= 1'b0;
            invalid_pipe[0] <= 1'b0;
        end else begin
            valid_pipe[0] <= valid_i;
            
            if (valid_i) begin
                // Calculate frequency difference (unsigned -> signed)
                s1_f_diff <= signed'({1'b0, f2_i}) - signed'({1'b0, f1_i});
                
                // Calculate dB differences (already signed)
                s1_L_diff <= signed'({L2_i[ACCUM_DB_WIDTH-1], L2_i}) - 
                            signed'({L1_i[ACCUM_DB_WIDTH-1], L1_i});
                s1_threshold_diff <= signed'({THRESHOLD_DB[ACCUM_DB_WIDTH-1], THRESHOLD_DB}) - 
                                    signed'({L1_i[ACCUM_DB_WIDTH-1], L1_i});
                
                // Store f1 for final addition
                s1_f1 <= f1_i;
                
                // Check for division by zero
                s1_div_by_zero <= (L2_i == L1_i);
                invalid_pipe[0] <= (L2_i == L1_i);
            end else begin
                invalid_pipe[0] <= 1'b0;
            end
        end
    end
    
    ////////////////////////////////////////////////////////////////////////////
    // Stage 2: Pipeline register for timing
    ////////////////////////////////////////////////////////////////////////////
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            s2_f_diff <= '0;
            s2_L_diff <= '0;
            s2_threshold_diff <= '0;
            s2_f1 <= '0;
            valid_pipe[1] <= 1'b0;
            invalid_pipe[1] <= 1'b0;
        end else begin
            valid_pipe[1] <= valid_pipe[0];
            invalid_pipe[1] <= invalid_pipe[0];
            
            s2_f_diff <= s1_f_diff;
            s2_L_diff <= s1_L_diff;
            s2_threshold_diff <= s1_threshold_diff;
            s2_f1 <= s1_f1;
        end
    end
    
    ////////////////////////////////////////////////////////////////////////////
    // Stage 3: Multiply (f2-f1) * (threshold-L1)
    ////////////////////////////////////////////////////////////////////////////
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            s3_numerator <= '0;
            s3_L_diff <= '0;
            s3_f1 <= '0;
            valid_pipe[2] <= 1'b0;
            invalid_pipe[2] <= 1'b0;
        end else begin
            valid_pipe[2] <= valid_pipe[1];
            invalid_pipe[2] <= invalid_pipe[1];
            
            if (valid_pipe[1]) begin
                s3_numerator <= s2_f_diff * s2_threshold_diff;
                s3_L_diff <= s2_L_diff;
                s3_f1 <= s2_f1;
            end
        end
    end
    
    ////////////////////////////////////////////////////////////////////////////
    // Stage 4: Divide by (L2-L1) and scale
    ////////////////////////////////////////////////////////////////////////////
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            s4_quotient <= '0;
            s4_f1 <= '0;
            valid_pipe[3] <= 1'b0;
            invalid_pipe[3] <= 1'b0;
        end else begin
            valid_pipe[3] <= valid_pipe[2];
            invalid_pipe[3] <= invalid_pipe[2];
            
            if (valid_pipe[2] && !invalid_pipe[2]) begin
                // Divide and remove ACCUM_DB_FRAC fractional bits
                // Result will be in frequency units with FREQ_FRAC_BITS
                s4_quotient <= (s3_numerator / s3_L_diff);
                s4_f1 <= s3_f1;
            end else if (valid_pipe[2]) begin
                // Invalid input, propagate zeros
                s4_quotient <= '0;
                s4_f1 <= s3_f1;
            end
        end
    end
    
    ////////////////////////////////////////////////////////////////////////////
    // Stage 5: Final addition f1 + scaled_quotient
    ////////////////////////////////////////////////////////////////////////////
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            f_star_o <= '0;
            ready_o <= 1'b0;
            invalid_o <= 1'b0;
            valid_pipe[4] <= 1'b0;
            invalid_pipe[4] <= 1'b0;
        end else begin
            valid_pipe[4] <= valid_pipe[3];
            invalid_pipe[4] <= invalid_pipe[3];
            ready_o <= valid_pipe[3];
            invalid_o <= invalid_pipe[3];
            
            if (valid_pipe[3] && !invalid_pipe[3]) begin
                // Scale quotient back to frequency format
                // quotient has (FREQ_FRAC_BITS + ACCUM_DB_FRAC) fractional bits
                // We need FREQ_FRAC_BITS fractional bits
                // Add with rounding
                logic signed [MULT_WIDTH-1:0] scaled_quotient;
                logic signed [FREQ_WIDTH:0] result_extended;
                
                // Round by adding 0.5 in the bit position we're truncating
                if (ACCUM_DB_FRAC > 0) begin
                    scaled_quotient = s4_quotient + (1 << (ACCUM_DB_FRAC - 1));
                    scaled_quotient = scaled_quotient >>> ACCUM_DB_FRAC;
                end else begin
                    scaled_quotient = s4_quotient;
                end
                
                // Add to f1 (extend to handle overflow)
                result_extended = signed'({1'b0, s4_f1}) + scaled_quotient[FREQ_WIDTH:0];
                
                // Saturate if needed
                if (result_extended > {1'b0, {FREQ_WIDTH{1'b1}}}) begin
                    f_star_o <= {FREQ_WIDTH{1'b1}};
                end else if (result_extended < '0) begin
                    f_star_o <= '0;
                end else begin
                    f_star_o <= result_extended[FREQ_WIDTH-1:0];
                end
            end else if (valid_pipe[3]) begin
                // Invalid input, output zero
                f_star_o <= '0;
            end
        end
    end

endmodule
