////////////////////////////////////////////////////////////////////////////////
//
//  Module: find_max_power
//
//  Description:
//      Finds the maximum power value among NUM_BINS accumulator values.
//      Refactored to separate Combinational (Next State) and Sequential Logic.
//
//  Latency: ceil(log2(NUM_BINS)) + 1 clock cycles
//
////////////////////////////////////////////////////////////////////////////////

module find_max_power #(
    parameter int NUM_BINS = 24,
    parameter int POWER_WIDTH = 32
) (
    input  logic                        clk_i,
    input  logic                        rst_ni,
    input  logic                        valid_i,
    input  logic [POWER_WIDTH-1:0]      power_values_i[NUM_BINS],
    
    output logic                        valid_o,
    output logic [POWER_WIDTH-1:0]      max_power_o
);

    // Calculate pipeline depth: Need log2(N) stages for reduction + 1 input stage
    // Example: 4 inputs -> Stage 0 (Reg) -> Stage 1 (2 items) -> Stage 2 (1 item)
    localparam int PIPELINE_DEPTH = $clog2(NUM_BINS) + 1;

    // -------------------------------------------------------------------------
    // Helper: Pre-calculate active counts per stage at Compile Time
    // -------------------------------------------------------------------------
    typedef int count_array_t[PIPELINE_DEPTH];
    
    function automatic count_array_t calc_stage_counts(int n_bins);
        count_array_t counts;
        counts[0] = n_bins;
        for (int s = 1; s < PIPELINE_DEPTH; s++) begin
            counts[s] = (counts[s-1] + 1) / 2;
        end
        return counts;
    endfunction

    localparam count_array_t STAGE_COUNTS = calc_stage_counts(NUM_BINS);

    // -------------------------------------------------------------------------
    // Registers (State _q and Next State _d)
    // -------------------------------------------------------------------------
    // We use a 2D array. Note: Lower stages use fewer indices, unused ones optimized away.
    logic [POWER_WIDTH-1:0] stage_values_q[PIPELINE_DEPTH][NUM_BINS];
    logic [POWER_WIDTH-1:0] stage_values_d[PIPELINE_DEPTH][NUM_BINS];
    
    logic [PIPELINE_DEPTH-1:0] stage_valid_q, stage_valid_d;

    // -------------------------------------------------------------------------
    // Combinational Logic (Next State Calculation)
    // -------------------------------------------------------------------------
    always_comb begin
        // Defaults to prevent latches
        stage_valid_d = '0;
        stage_values_d = stage_values_q; 

        // --- Stage 0: Input Registration ---
        stage_valid_d[0] = valid_i;
        for (int i = 0; i < NUM_BINS; i++) begin
            stage_values_d[0][i] = power_values_i[i];
        end

        // --- Subsequent Stages: Tree Reduction ---
        for (int s = 1; s < PIPELINE_DEPTH; s++) begin
            // Valid signal propagates through pipeline
            stage_valid_d[s] = stage_valid_q[s-1];

            // Pairwise Comparisons
            // Loop bounds use the pre-calculated constant STAGE_COUNTS
            for (int i = 0; i < STAGE_COUNTS[s-1]/2; i++) begin
                // Compare pair from previous stage (q)
                logic [POWER_WIDTH-1:0] val_a = stage_values_q[s-1][2*i];
                logic [POWER_WIDTH-1:0] val_b = stage_values_q[s-1][2*i+1];

                // Assign max to current stage next state (d)
                // Using $signed comparison as per original specification
                if (val_a > val_b) begin
                    stage_values_d[s][i] = val_a;
                end else begin
                    stage_values_d[s][i] = val_b;
                end
            end

            // Handle Odd Number of Elements (Carry over the last one)
            if ((STAGE_COUNTS[s-1] % 2) != 0) begin
                int last_idx = STAGE_COUNTS[s-1] - 1;
                int target_idx = STAGE_COUNTS[s-1] / 2; // Integer division
                stage_values_d[s][target_idx] = stage_values_q[s-1][last_idx];
            end
        end
    end

    // -------------------------------------------------------------------------
    // Sequential Logic (State Updates)
    // -------------------------------------------------------------------------
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            stage_valid_q <= '0;
            for (int s = 0; s < PIPELINE_DEPTH; s++) begin
                for (int i = 0; i < NUM_BINS; i++) begin
                    stage_values_q[s][i] <= '0;
                end
            end
        end else begin
            stage_valid_q <= stage_valid_d;
            stage_values_q <= stage_values_d;
        end
    end

    // -------------------------------------------------------------------------
    // Output Assignment
    // -------------------------------------------------------------------------
    // The result is the single element remaining in the last stage
    assign valid_o     = stage_valid_q[PIPELINE_DEPTH-1];
    assign max_power_o = stage_values_q[PIPELINE_DEPTH-1][0];

endmodule