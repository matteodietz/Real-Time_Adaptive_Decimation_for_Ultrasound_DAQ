module find_bw_right_edge_absolute #(
    parameter integer POWER_WIDTH = 8,      // Width of Power signal
    parameter integer IDX_WIDTH = 5,        // Width of Frequency bins
    parameter integer NUM_ACCUMS = 24       // Number of bins
)(
    input  logic clk_i,
    input  logic rst_ni,
    input  logic start_i,

    // Data Inputs
    input  logic [POWER_WIDTH-1:0]      accumulator_val_i[NUM_ACCUMS], // Absolute dB (Unsigned)
    input  logic [IDX_WIDTH-1:0]        freq_bin_i[NUM_ACCUMS],
    
    // Threshold Input (Absolute Value)
    input  logic [POWER_WIDTH-1:0]      abs_threshold_i,

    // Outputs
    output logic [IDX_WIDTH-1:0]        f1_o, // Left bin (Below Threshold)
    output logic [IDX_WIDTH-1:0]        f2_o, // Right bin (Above Threshold)
    output logic [POWER_WIDTH-1:0]      L1_o, // Power at f1
    output logic [POWER_WIDTH-1:0]      L2_o, // Power at f2

    output logic                        valid_o,
    output logic                        busy_o
);

    // -------------------------------------------------------------------------
    // State Machine
    // -------------------------------------------------------------------------
    typedef enum logic [1:0] {
        IDLE = 2'b00,
        PROCESS = 2'b01,
        DONE = 2'b10
    } state_t;

    state_t state_q, state_d;
    logic [$clog2(NUM_ACCUMS)-1:0] idx_q, idx_d;
    
    // -------------------------------------------------------------------------
    // Crossing Logic
    // -------------------------------------------------------------------------
    // Crossing States:
    typedef enum logic [1:0] {
        S0 = 2'b00,  // High, High
        S1 = 2'b01,  // High, Low
        S2 = 2'b10,  // Low, High
        S3 = 2'b11   // Low, Low
    } crossing_state_t;

    crossing_state_t cross_state;
    logic crossing_found;
    
    // Internal signals
    logic [POWER_WIDTH-1:0] L1, L2;
    logic [IDX_WIDTH-1:0] f1, f2;
    logic L1_above_thresh, L2_above_thresh;
    
    // Output registers
    logic [IDX_WIDTH-1:0] f1_q, f1_d;
    logic [IDX_WIDTH-1:0] f2_q, f2_d;
    logic [POWER_WIDTH-1:0] L1_q, L1_d;
    logic [POWER_WIDTH-1:0] L2_q, L2_d;
    logic crossing_valid_q, crossing_valid_d;
    
    // -------------------------------------------------------------------------
    // Sequential Logic
    // -------------------------------------------------------------------------
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            state_q <= IDLE;
            idx_q <= '0;
            f1_q <= '0; 
            f2_q <= '0;
            L1_q <= '0; 
            L2_q <= '0;
            crossing_valid_q <= 1'b0;
        end else begin
            state_q <= state_d;
            idx_q <= idx_d;
            f1_q <= f1_d; 
            f2_q <= f2_d;
            L1_q <= L1_d; 
            L2_q <= L2_d;
            crossing_valid_q <= crossing_valid_d;
        end
    end
    
    // -------------------------------------------------------------------------
    // Threshold Comparison Logic
    // -------------------------------------------------------------------------
    // Assuming inputs are Unsigned Absolute dB
    // We simply compare against the unsigned abs_threshold_i
    assign L1_above_thresh = (L1 >= abs_threshold_i);
    assign L2_above_thresh = (L2 >= abs_threshold_i);
    
    always_comb begin
        case ({L1_above_thresh, L2_above_thresh})
            2'b11: cross_state = S0; // Signal Region
            2'b10: cross_state = S1; // RIGHT EDGE FOUND (High -> Low)
            2'b01: cross_state = S2;
            2'b00: cross_state = S3; // Noise Region
        endcase
    end
    
    assign crossing_found = (cross_state == S1);
    
    // -------------------------------------------------------------------------
    // Next State Logic
    // -------------------------------------------------------------------------
    always_comb begin
        // Defaults
        state_d = state_q;
        idx_d = idx_q;
        f1_d = f1_q; f2_d = f2_q;
        L1_d = L1_q; L2_d = L2_q;
        crossing_valid_d = crossing_valid_q;
        
        // Default internal signals
        L1 = '0; L2 = '0;
        f1 = '0; f2 = '0;
        
        case (state_q)
            IDLE: begin
                crossing_valid_d = 1'b0;
                if (start_i) begin
                    state_d = PROCESS;
                    idx_d = (NUM_ACCUMS / 2);  // start from the middle
                    f1_d = '0;
                    f2_d = '0;
                    L1_d = '0;
                    L2_d = '0;
                    crossing_valid_d = 1'b0;
                end
            end
            
            PROCESS: begin
                // L2 is current (higher), L1 is previous (lower)
                L2 = accumulator_val_i[idx_q];
                L1 = accumulator_val_i[idx_q - 1];
                f2 = freq_bin_i[idx_q];
                f1 = freq_bin_i[idx_q - 1];
                
                // check for crossing
                if (crossing_found) begin
                    f1_d = f1;
                    f2_d = f2;
                    L1_d = L1;
                    L2_d = L2;
                    crossing_valid_d = 1'b1;
                end
                
                // Stop if we just processed the last bin
                if (idx_q == NUM_ACCUMS - 1) begin
                    state_d = DONE;
                end else begin
                    idx_d = idx_q + 1;
                end
            end
            
            DONE: begin
                state_d = IDLE;
            end
            
            default: begin
                state_d = IDLE;
            end
        endcase
    end
    
    // -------------------------------------------------------------------------
    // Output Assignments
    // -------------------------------------------------------------------------
    assign f1_o = f1_q;
    assign f2_o = f2_q;
    assign L1_o = L1_q;
    assign L2_o = L2_q;
    assign valid_o = (state_q == DONE);
    assign busy_o = (state_q == PROCESS);

endmodule