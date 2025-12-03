////////////////////////////////////////////////////////////////////////////////
//
//  Module: find_max_power_optimized
//
//  Description:
//      Optimized version that decomposes non-power-of-2 NUM_BINS into
//      optimal power-of-2 subtrees at compile time, then merges results.
//      This provides better timing than the simple approach above.
//
//  This version is more complex but generates more efficient logic.
//
////////////////////////////////////////////////////////////////////////////////

module find_max_power_optimized #(
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

    // Find largest power of 2 <= NUM_BINS
    function automatic int largest_pow2(int n);
        int result = 1;
        while (result * 2 <= n) begin
            result = result * 2;
        end
        return result;
    endfunction
    
    // Calculate log2 ceiling
    function automatic int clog2(int n);
        int result = 0;
        int temp = n - 1;
        while (temp > 0) begin
            result = result + 1;
            temp = temp >> 1;
        end
        return result;
    endfunction
    
    localparam int LARGEST_POW2 = largest_pow2(NUM_BINS);
    localparam int REMAINDER = NUM_BINS - LARGEST_POW2;
    localparam int MAIN_TREE_DEPTH = clog2(LARGEST_POW2);
    localparam int REM_TREE_DEPTH = (REMAINDER > 0) ? clog2(REMAINDER) : 0;
    localparam int TOTAL_DEPTH = (REMAINDER > 0) ? 
                                  ((MAIN_TREE_DEPTH > REM_TREE_DEPTH) ? MAIN_TREE_DEPTH + 1 : REM_TREE_DEPTH + 1) :
                                  MAIN_TREE_DEPTH;
    
    ////////////////////////////////////////////////////////////////////////////
    // Main tree (processes first LARGEST_POW2 elements)
    ////////////////////////////////////////////////////////////////////////////
    logic [POWER_WIDTH-1:0] main_tree[MAIN_TREE_DEPTH+1][LARGEST_POW2];
    logic [MAIN_TREE_DEPTH:0] main_valid;
    
    // Stage 0: Input
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            main_valid[0] <= 1'b0;
            for (int i = 0; i < LARGEST_POW2; i++) begin
                main_tree[0][i] <= '0;
            end
        end else begin
            main_valid[0] <= valid_i;
            if (valid_i) begin
                for (int i = 0; i < LARGEST_POW2; i++) begin
                    main_tree[0][i] <= power_values_i[i];
                end
            end
        end
    end
    
    // Tree stages
    genvar stage, idx;
    generate
        for (stage = 0; stage < MAIN_TREE_DEPTH; stage++) begin : gen_main_tree_stages
            localparam int CURR_SIZE = LARGEST_POW2 >> stage;
            localparam int NEXT_SIZE = CURR_SIZE >> 1;
            
            always_ff @(posedge clk_i or negedge rst_ni) begin
                if (!rst_ni) begin
                    main_valid[stage+1] <= 1'b0;
                    for (int i = 0; i < NEXT_SIZE; i++) begin
                        main_tree[stage+1][i] <= '0;
                    end
                end else begin
                    main_valid[stage+1] <= main_valid[stage];
                    
                    if (main_valid[stage]) begin
                        for (int i = 0; i < NEXT_SIZE; i++) begin
                            if ($signed(main_tree[stage][2*i]) > $signed(main_tree[stage][2*i+1])) begin
                                main_tree[stage+1][i] <= main_tree[stage][2*i];
                            end else begin
                                main_tree[stage+1][i] <= main_tree[stage][2*i+1];
                            end
                        end
                    end
                end
            end
        end
    endgenerate
    
    ////////////////////////////////////////////////////////////////////////////
    // Remainder tree (processes remaining elements if any)
    ////////////////////////////////////////////////////////////////////////////
    generate
        if (REMAINDER > 0) begin : gen_remainder_tree
            logic [POWER_WIDTH-1:0] rem_tree[REM_TREE_DEPTH+1][REMAINDER];
            logic [REM_TREE_DEPTH:0] rem_valid;
            
            // Stage 0: Input
            always_ff @(posedge clk_i or negedge rst_ni) begin
                if (!rst_ni) begin
                    rem_valid[0] <= 1'b0;
                    for (int i = 0; i < REMAINDER; i++) begin
                        rem_tree[0][i] <= '0;
                    end
                end else begin
                    rem_valid[0] <= valid_i;
                    if (valid_i) begin
                        for (int i = 0; i < REMAINDER; i++) begin
                            rem_tree[0][i] <= power_values_i[LARGEST_POW2 + i];
                        end
                    end
                end
            end
            
            // Tree stages - handle non-power-of-2 remainder
            for (stage = 0; stage < REM_TREE_DEPTH; stage++) begin : gen_rem_tree_stages
                // Calculate how many elements at this stage
                automatic int elements_at_stage = REMAINDER >> stage;
                if (elements_at_stage < (REMAINDER >> stage)) elements_at_stage++;
                automatic int next_elements = (elements_at_stage + 1) >> 1;
                
                always_ff @(posedge clk_i or negedge rst_ni) begin
                    if (!rst_ni) begin
                        rem_valid[stage+1] <= 1'b0;
                        for (int i = 0; i < next_elements; i++) begin
                            rem_tree[stage+1][i] <= '0;
                        end
                    end else begin
                        rem_valid[stage+1] <= rem_valid[stage];
                        
                        if (rem_valid[stage]) begin
                            // Pairwise comparisons
                            for (int i = 0; i < elements_at_stage/2; i++) begin
                                if ($signed(rem_tree[stage][2*i]) > $signed(rem_tree[stage][2*i+1])) begin
                                    rem_tree[stage+1][i] <= rem_tree[stage][2*i];
                                end else begin
                                    rem_tree[stage+1][i] <= rem_tree[stage][2*i+1];
                                end
                            end
                            
                            // Handle odd element
                            if (elements_at_stage % 2 == 1) begin
                                rem_tree[stage+1][elements_at_stage/2] <= rem_tree[stage][elements_at_stage-1];
                            end
                        end
                    end
                end
            end
            
            ////////////////////////////////////////////////////////////////////////////
            // Final merge stage (combine main tree and remainder tree results)
            ////////////////////////////////////////////////////////////////////////////
            logic merge_valid;
            logic [POWER_WIDTH-1:0] merged_result;
            
            // Align the two trees (add delay to shorter one)
            logic main_result_valid;
            logic rem_result_valid;
            logic [POWER_WIDTH-1:0] main_result;
            logic [POWER_WIDTH-1:0] rem_result;
            
            if (MAIN_TREE_DEPTH > REM_TREE_DEPTH) begin : gen_delay_rem
                logic [POWER_WIDTH-1:0] rem_delay[MAIN_TREE_DEPTH - REM_TREE_DEPTH];
                logic [MAIN_TREE_DEPTH - REM_TREE_DEPTH - 1:0] rem_valid_delay;
                
                always_ff @(posedge clk_i or negedge rst_ni) begin
                    if (!rst_ni) begin
                        for (int i = 0; i < MAIN_TREE_DEPTH - REM_TREE_DEPTH; i++) begin
                            rem_delay[i] <= '0;
                            if (i < MAIN_TREE_DEPTH - REM_TREE_DEPTH - 1) begin
                                rem_valid_delay[i] <= 1'b0;
                            end
                        end
                    end else begin
                        rem_delay[0] <= rem_tree[REM_TREE_DEPTH][0];
                        rem_valid_delay[0] <= rem_valid[REM_TREE_DEPTH];
                        
                        for (int i = 1; i < MAIN_TREE_DEPTH - REM_TREE_DEPTH; i++) begin
                            rem_delay[i] <= rem_delay[i-1];
                            if (i < MAIN_TREE_DEPTH - REM_TREE_DEPTH - 1) begin
                                rem_valid_delay[i] <= rem_valid_delay[i-1];
                            end
                        end
                    end
                end
                
                assign main_result = main_tree[MAIN_TREE_DEPTH][0];
                assign main_result_valid = main_valid[MAIN_TREE_DEPTH];
                assign rem_result = rem_delay[MAIN_TREE_DEPTH - REM_TREE_DEPTH - 1];
                assign rem_result_valid = rem_valid_delay[MAIN_TREE_DEPTH - REM_TREE_DEPTH - 2];
                
            end else if (REM_TREE_DEPTH > MAIN_TREE_DEPTH) begin : gen_delay_main
                logic [POWER_WIDTH-1:0] main_delay[REM_TREE_DEPTH - MAIN_TREE_DEPTH];
                logic [REM_TREE_DEPTH - MAIN_TREE_DEPTH - 1:0] main_valid_delay;
                
                always_ff @(posedge clk_i or negedge rst_ni) begin
                    if (!rst_ni) begin
                        for (int i = 0; i < REM_TREE_DEPTH - MAIN_TREE_DEPTH; i++) begin
                            main_delay[i] <= '0;
                            if (i < REM_TREE_DEPTH - MAIN_TREE_DEPTH - 1) begin
                                main_valid_delay[i] <= 1'b0;
                            end
                        end
                    end else begin
                        main_delay[0] <= main_tree[MAIN_TREE_DEPTH][0];
                        main_valid_delay[0] <= main_valid[MAIN_TREE_DEPTH];
                        
                        for (int i = 1; i < REM_TREE_DEPTH - MAIN_TREE_DEPTH; i++) begin
                            main_delay[i] <= main_delay[i-1];
                            if (i < REM_TREE_DEPTH - MAIN_TREE_DEPTH - 1) begin
                                main_valid_delay[i] <= main_valid_delay[i-1];
                            end
                        end
                    end
                end
                
                assign main_result = main_delay[REM_TREE_DEPTH - MAIN_TREE_DEPTH - 1];
                assign main_result_valid = main_valid_delay[REM_TREE_DEPTH - MAIN_TREE_DEPTH - 2];
                assign rem_result = rem_tree[REM_TREE_DEPTH][0];
                assign rem_result_valid = rem_valid[REM_TREE_DEPTH];
                
            end else begin : gen_no_delay
                assign main_result = main_tree[MAIN_TREE_DEPTH][0];
                assign main_result_valid = main_valid[MAIN_TREE_DEPTH];
                assign rem_result = rem_tree[REM_TREE_DEPTH][0];
                assign rem_result_valid = rem_valid[REM_TREE_DEPTH];
            end
            
            // Final comparison
            always_ff @(posedge clk_i or negedge rst_ni) begin
                if (!rst_ni) begin
                    merge_valid <= 1'b0;
                    merged_result <= '0;
                end else begin
                    merge_valid <= main_result_valid & rem_result_valid;
                    
                    if (main_result_valid & rem_result_valid) begin
                        if ($signed(main_result) > $signed(rem_result)) begin
                            merged_result <= main_result;
                        end else begin
                            merged_result <= rem_result;
                        end
                    end
                end
            end
            
            assign valid_o = merge_valid;
            assign max_power_o = merged_result;
            
        end else begin : gen_no_remainder
            // No remainder, just use main tree result
            assign valid_o = main_valid[MAIN_TREE_DEPTH];
            assign max_power_o = main_tree[MAIN_TREE_DEPTH][0];
        end
    endgenerate

endmodule