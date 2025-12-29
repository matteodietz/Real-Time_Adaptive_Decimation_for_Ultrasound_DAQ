////////////////////////////////////////////////////////////////////////////////
//
//  Module: config_loader
//
//  Description:
//      AXI-Stream interface module for loading configuration arrays into
//      parallel registers. Receives freq_steps and freq_bin values serially
//      via AXI-Stream and stores them in internal registers for use by the
//      main processing pipeline.
//
//  Protocol:
//      - First NUM_BINS transfers carry freq_steps_i values
//      - Next NUM_BINS transfers carry freq_bin_i values
//      - Total of 2*NUM_BINS transfers required
//      - After all values loaded, config_valid_o asserts
//
////////////////////////////////////////////////////////////////////////////////

module config_loader #(
    parameter integer PHASE_WIDTH = 16,
    parameter integer FREQ_BIN_WIDTH = 5,
    parameter integer NUM_BINS = 24,
    parameter integer DATA_WIDTH = 16  // Max of PHASE_WIDTH and FREQ_BIN_WIDTH
)(
    input  logic clk_i,
    input  logic rst_ni,
    
    // --- Control Interface ---
    input  logic clear_i,            // Clear configuration
    
    // --- AXI-Stream Slave Interface ---
    input  logic [DATA_WIDTH-1:0] s_axis_tdata_i,
    input  logic s_axis_tvalid_i,
    output logic s_axis_tready_o,
    
    // --- Configuration Outputs ---
    output logic [PHASE_WIDTH-1:0] freq_steps_o[NUM_BINS],
    output logic [FREQ_BIN_WIDTH-1:0] freq_bin_o[NUM_BINS],
    output logic config_valid_o     // All configuration loaded
);

    //--------------------------------------------------------------------------
    // Local Parameters
    //--------------------------------------------------------------------------
    
    localparam integer TOTAL_TRANSFERS = 2 * NUM_BINS;
    localparam integer COUNTER_WIDTH = $clog2(TOTAL_TRANSFERS + 1);
    
    //--------------------------------------------------------------------------
    // Type Definitions
    //--------------------------------------------------------------------------
    
    typedef enum logic [1:0] {
        LOAD_FREQ_STEPS,
        LOAD_FREQ_BINS,
        DONE
    } state_t;
    
    //--------------------------------------------------------------------------
    // Internal Signals
    //--------------------------------------------------------------------------
    
    // State registers
    state_t state_q, state_d;
    
    // Counter registers
    logic [COUNTER_WIDTH-1:0] transfer_count_q, transfer_count_d;
    
    // Configuration registers
    logic [PHASE_WIDTH-1:0] freq_steps_q[NUM_BINS], freq_steps_d[NUM_BINS];
    logic [FREQ_BIN_WIDTH-1:0] freq_bin_q[NUM_BINS], freq_bin_d[NUM_BINS];
    
    // Valid flag registers
    logic config_valid_q, config_valid_d;
    
    // Handshake signals
    logic transfer_accepted;
    
    //--------------------------------------------------------------------------
    // AXI-Stream Handshake
    //--------------------------------------------------------------------------
    
    assign transfer_accepted = s_axis_tvalid_i && s_axis_tready_o;
    
    //--------------------------------------------------------------------------
    // Combinational Logic - Next State and Output Logic
    //--------------------------------------------------------------------------
    always_comb begin
        // Default assignments - hold current values
        state_d = state_q;
        transfer_count_d = transfer_count_q;
        config_valid_d = config_valid_q;
        freq_steps_d = freq_steps_q;
        freq_bin_d = freq_bin_q;
        s_axis_tready_o = 1'b0;
        
        // State machine logic
        case (state_q)
            LOAD_FREQ_STEPS: begin
                s_axis_tready_o = 1'b1;  // Ready to accept data
                config_valid_d = 1'b0;   // Not valid while loading
                
                if (transfer_accepted) begin
                    // Store the incoming freq_steps value
                    freq_steps_d[transfer_count_q] = s_axis_tdata_i[PHASE_WIDTH-1:0];
                    
                    // Check if we've received all freq_steps
                    if (transfer_count_q == NUM_BINS - 1) begin
                        state_d = LOAD_FREQ_BINS;
                        transfer_count_d = '0;
                    end else begin
                        transfer_count_d = transfer_count_q + 1'b1;
                    end
                end
            end
            
            LOAD_FREQ_BINS: begin
                s_axis_tready_o = 1'b1;  // Ready to accept data
                config_valid_d = 1'b0;   // Not valid while loading
                
                if (transfer_accepted) begin
                    // Store the incoming freq_bin value
                    freq_bin_d[transfer_count_q] = s_axis_tdata_i[FREQ_BIN_WIDTH-1:0];
                    
                    // Check if we've received all freq_bins
                    if (transfer_count_q == NUM_BINS - 1) begin
                        state_d = DONE;
                        transfer_count_d = '0;
                        config_valid_d = 1'b1;
                    end else begin
                        transfer_count_d = transfer_count_q + 1'b1;
                    end
                end
            end
            
            DONE: begin
                // Configuration complete, not accepting new data
                s_axis_tready_o = 1'b0;
                config_valid_d = 1'b1;
            end
            
            default: begin
                state_d = LOAD_FREQ_STEPS;
            end
        endcase
        
        // Clear overrides everything - restart loading process
        if (clear_i) begin
            state_d = LOAD_FREQ_STEPS;
            transfer_count_d = '0;
            config_valid_d = 1'b0;
            
            // Clear all configuration arrays
            for (int i = 0; i < NUM_BINS; i++) begin
                freq_steps_d[i] = '0;
                freq_bin_d[i] = '0;
            end
        end
    end
    
    //--------------------------------------------------------------------------
    // Sequential Logic - Register Updates
    //--------------------------------------------------------------------------
    
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            state_q <= LOAD_FREQ_STEPS;
            transfer_count_q <= '0;
            config_valid_q <= 1'b0;
            
            // Initialize arrays to zero
            for (int i = 0; i < NUM_BINS; i++) begin
                freq_steps_q[i] <= '0;
                freq_bin_q[i] <= '0;
            end
        end else begin
            // Update all state registers
            state_q <= state_d;
            transfer_count_q <= transfer_count_d;
            config_valid_q <= config_valid_d;
            freq_steps_q <= freq_steps_d;
            freq_bin_q <= freq_bin_d;
        end
    end
    
    //--------------------------------------------------------------------------
    // Output Assignments
    //--------------------------------------------------------------------------
    
    assign freq_steps_o = freq_steps_q;
    assign freq_bin_o = freq_bin_q;
    assign config_valid_o = config_valid_q;

endmodule