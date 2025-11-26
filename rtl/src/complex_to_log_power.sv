////////////////////////////////////////////////////////////////////////////////
//
//  Module: complex_to_log_power
//
//  Function: Calculates Power_dB ~= 3 * log2(I^2 + Q^2)
//
//  Details:
//      1. Calculates Magnitude Squared: P = I^2 + Q^2
//      2. Finds the Leading One (MSB) of P. This is the Integer Log2.
//      3. Multiplies by 3 to approximate 10*log10 conversion.
//
//  Latency: 3 Clock Cycles (Pipelined for timing closure)
//
////////////////////////////////////////////////////////////////////////////////

module complex_to_log_power #(
    parameter int INPUT_WIDTH   = 16, // Width of I and Q
    parameter int OUTPUT_WIDTH  = 32, // Width of result
    parameter int OUTPUT_FRAC   = 16  // Fractional bits in result (unused in integer-only version)
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
    localparam int SQ_WIDTH = (2 * INPUT_WIDTH) + 1;
    
    // Stage 1 - Combinational
    logic signed [SQ_WIDTH-1:0] p_mag_sq_d;
    
    // Stage 1 - Sequential
    logic signed [SQ_WIDTH-1:0] p_mag_sq_q;
    logic                       s1_valid_d, s1_valid_q;
    
    // Stage 1 combinational logic
    always_comb begin
        s1_valid_d = valid_i;
        p_mag_sq_d = (i_data_i * i_data_i) + (q_data_i * q_data_i);
    end
    
    // Stage 1 sequential logic
    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            p_mag_sq_q <= '0;
            s1_valid_q <= 1'b0;
        end else begin
            s1_valid_q <= s1_valid_d;
            if (s1_valid_d) begin
                p_mag_sq_q <= p_mag_sq_d;
            end
        end
    end

    // ---------------------------------------------------------
    // Stage 2: Priority Encoder (Integer Log2)
    // ---------------------------------------------------------
    
    // Stage 2 - Combinational
    logic [5:0]  msb_index_d;
    logic        is_zero_d;
    
    // Stage 2 - Sequential
    logic [5:0]  msb_index_q;
    logic        is_zero_q;
    logic        s2_valid_d, s2_valid_q;
    
    // Stage 2 combinational logic - Priority encoder
    always_comb begin
        msb_index_d = '0;
        is_zero_d   = 1'b1;
        s2_valid_d = s1_valid_q;
        
        // Find the highest '1' bit (priority encoder)
        for (int i = SQ_WIDTH-1; i >= 0; i--) begin
            if (p_mag_sq_q[i] == 1'b1) begin
                msb_index_d = i[5:0];  // This is the integer log2
                is_zero_d   = 1'b0;
                break;
            end
        end
    end
    
    // Stage 2 sequential logic
    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            msb_index_q <= '0;
            is_zero_q   <= 1'b0;
            s2_valid_q  <= 1'b0;
        end else begin
            s2_valid_q  <= s2_valid_d;
            msb_index_q <= msb_index_d;
            is_zero_q   <= is_zero_d;
        end
    end

    // ---------------------------------------------------------
    // Stage 3: Scaling by 3
    // ---------------------------------------------------------
    
    // Stage 3 - Combinational
    logic [OUTPUT_WIDTH-1:0] db_power_d;
    logic                    valid_d;
    
    // Stage 3 combinational logic
    always_comb begin
        valid_d = s2_valid_q;
        
        if (is_zero_q) begin
            // Log(0) is -inf. Clamp to minimal value
            db_power_d = '0;
        end else begin
            // Scale integer log2 by 3: x * 3 = (x << 1) + x
            // Shift left by OUTPUT_FRAC to maintain fixed-point format
            logic [OUTPUT_WIDTH-1:0] log2_val;
            log2_val = msb_index_q << OUTPUT_FRAC;
            db_power_d = (log2_val << 1) + log2_val;
        end
    end
    
    // Stage 3 sequential logic
    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            db_power_o <= '0;
            valid_o    <= 1'b0;
        end else begin
            valid_o    <= valid_d;
            db_power_o <= db_power_d;
        end
    end

endmodule