module complex_to_log_power #(
    parameter int INPUT_WIDTH   = 18,
    parameter int OUTPUT_WIDTH  = 8,
    parameter int OUTPUT_FRAC   = 0
) (
    input  logic                            clk_i,
    input  logic                            rst_ni,
    input  logic                            valid_i,
    input  logic signed [INPUT_WIDTH-1:0]   i_data_i,
    input  logic signed [INPUT_WIDTH-1:0]   q_data_i,
    
    output logic                            valid_o,
    output logic [OUTPUT_WIDTH-1:0]         db_power_o
);

    // ---------------------------------------------------------
    // Stage 1a: Square I and Q (separate from addition)
    // ---------------------------------------------------------
    localparam int SQ_WIDTH = (2 * INPUT_WIDTH) + 1;
    localparam int INDEX_WIDTH = $clog2(SQ_WIDTH);
    localparam int SINGLE_SQ_WIDTH = 2 * INPUT_WIDTH;
    
    logic signed [SINGLE_SQ_WIDTH-1:0] i_squared_d, q_squared_d;
    logic signed [SINGLE_SQ_WIDTH-1:0] i_squared_q, q_squared_q;
    logic s1a_valid_d, s1a_valid_q;
    
    always_comb begin
        s1a_valid_d = valid_i;
        i_squared_d = i_data_i * i_data_i;
        q_squared_d = q_data_i * q_data_i;
    end
    
    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            i_squared_q <= '0;
            q_squared_q <= '0;
            s1a_valid_q <= 1'b0;
        end else begin
            s1a_valid_q <= s1a_valid_d;
            if (s1a_valid_d) begin
                i_squared_q <= i_squared_d;
                q_squared_q <= q_squared_d;
            end
        end
    end

    // ---------------------------------------------------------
    // Stage 1b: Add I^2 + Q^2 (Mag Squared)
    // ---------------------------------------------------------
    
    logic signed [SQ_WIDTH-1:0] p_mag_sq_d;
    logic signed [SQ_WIDTH-1:0] p_mag_sq_q;
    logic s1b_valid_d, s1b_valid_q;
    
    always_comb begin
        s1b_valid_d = s1a_valid_q;
        p_mag_sq_d = i_squared_q + q_squared_q;
    end
    
    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            p_mag_sq_q <= '0;
            s1b_valid_q <= 1'b0;
        end else begin
            s1b_valid_q <= s1b_valid_d;
            if (s1b_valid_d) begin
                p_mag_sq_q <= p_mag_sq_d;
            end
        end
    end

    // ---------------------------------------------------------
    // Stage 2: Priority Encoder (Integer Log2)
    // ---------------------------------------------------------
    
    logic [INDEX_WIDTH-1:0] msb_index_d;
    logic is_zero_d;
    
    logic [INDEX_WIDTH-1:0] msb_index_q;
    logic is_zero_q;
    logic s2_valid_d, s2_valid_q;
    
    always_comb begin
        msb_index_d = '0;
        is_zero_d   = 1'b1;
        s2_valid_d = s1b_valid_q;
        
        // Find the highest '1' bit (priority encoder)
        for (int i = SQ_WIDTH-1; i >= 0; i--) begin
            if (p_mag_sq_q[i] == 1'b1) begin
                msb_index_d = i[INDEX_WIDTH-1:0];
                is_zero_d   = 1'b0;
                break;
            end
        end
    end
    
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
    
    logic [OUTPUT_WIDTH-1:0] db_power_d;
    logic valid_d;
    
    always_comb begin
        valid_d = s2_valid_q;
        
        if (is_zero_q) begin
            // Log(0) is -inf. Clamp to minimal value
            db_power_d = '0;
        end else begin
            // Scale integer log2 by 3: x * 3 = (x << 1) + x
            logic [OUTPUT_WIDTH-1:0] log2_val;
            log2_val = msb_index_q << OUTPUT_FRAC;
            db_power_d = (log2_val << 1) + log2_val;
        end
    end
    
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