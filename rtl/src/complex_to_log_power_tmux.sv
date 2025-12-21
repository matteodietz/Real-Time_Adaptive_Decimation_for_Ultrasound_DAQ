module complex_to_log_power_tmux #(
    parameter integer NUM_BINS = 24,
    parameter integer POWER_INPUT_WIDTH = 32,
    parameter integer POWER_WIDTH = 8,
    parameter integer POWER_FRAC = 0,
    parameter integer LATENCY = 3  // Fixed latency of complex_to_log_power
)(
    input  logic clk_i,
    input  logic rst_ni,
    
    // Input: All accumulator values (clipped)
    input  logic valid_i,  // Start conversion (dft_valid)
    input  logic signed [POWER_INPUT_WIDTH-1:0] A_real_clipped_i[NUM_BINS],
    input  logic signed [POWER_INPUT_WIDTH-1:0] A_imag_clipped_i[NUM_BINS],
    
    // Output: All power values
    output logic [POWER_WIDTH-1:0] db_power_o[NUM_BINS],
    output logic valid_o
);

    // =========================================================================
    // State Machine
    // =========================================================================
    typedef enum logic [1:0] {
        IDLE       = 2'b00,
        PROCESSING = 2'b01,
        DRAINING   = 2'b10,
        DONE       = 2'b11
    } state_t;
    
    state_t state_q, state_d;
    
    // =========================================================================
    // Counters
    // =========================================================================
    localparam int BIN_COUNTER_WIDTH = $clog2(NUM_BINS + LATENCY);
    
    // Counter for which bin we're currently feeding to the converter
    logic [BIN_COUNTER_WIDTH-1:0] input_counter_q, input_counter_d;
    
    // Counter for which bin the output currently corresponds to
    // This is input_counter delayed by LATENCY cycles
    logic [BIN_COUNTER_WIDTH-1:0] output_counter_q, output_counter_d;
    
    // =========================================================================
    // Single Complex to Log Power Instance
    // =========================================================================
    logic converter_valid_i;
    logic signed [POWER_INPUT_WIDTH-1:0] converter_i_data;
    logic signed [POWER_INPUT_WIDTH-1:0] converter_q_data;
    logic converter_valid_o;
    logic [POWER_WIDTH-1:0] converter_db_power;
    
    complex_to_log_power #(
        .INPUT_WIDTH    (POWER_INPUT_WIDTH),
        .OUTPUT_WIDTH   (POWER_WIDTH),
        .OUTPUT_FRAC    (POWER_FRAC)
    ) u_log_power (
        .clk_i      (clk_i),
        .rst_ni     (rst_ni),
        .valid_i    (converter_valid_i),
        .i_data_i   (converter_i_data),
        .q_data_i   (converter_q_data),
        .valid_o    (converter_valid_o),
        .db_power_o (converter_db_power)
    );
    
    // =========================================================================
    // Output Storage Registers
    // =========================================================================
    logic [POWER_WIDTH-1:0] db_power_q[NUM_BINS], db_power_d[NUM_BINS];
    
    // =========================================================================
    // State Machine & Control Logic
    // =========================================================================
    always_comb begin
        // Defaults
        state_d = state_q;
        input_counter_d = input_counter_q;
        output_counter_d = output_counter_q;
        converter_valid_i = 1'b0;
        
        // Default: hold all outputs
        for (int k = 0; k < NUM_BINS; k++) begin
            db_power_d[k] = db_power_q[k];
        end
        
        case (state_q)
            IDLE: begin
                if (valid_i) begin
                    state_d = PROCESSING;
                    input_counter_d = '0;
                    output_counter_d = '0;
                end
            end
            
            PROCESSING: begin
                if (input_counter_q < NUM_BINS) begin
                    // Still feeding bins into the converter
                    converter_valid_i = 1'b1;
                    input_counter_d = input_counter_q + 1;
                    
                    // Increment output counter when converter produces valid output
                    if (converter_valid_o) begin
                        output_counter_d = output_counter_q + 1;
                    end
                    
                    // Check if we've fed all bins
                    if (input_counter_q == NUM_BINS - 1) begin
                        state_d = DRAINING;
                    end
                end
            end
            
            DRAINING: begin
                // No more inputs, just wait for remaining outputs
                converter_valid_i = 1'b0;
                
                if (converter_valid_o) begin
                    output_counter_d = output_counter_q + 1;
                    
                    // Check if we've received all outputs
                    if (output_counter_q == NUM_BINS - 1) begin
                        state_d = DONE;
                    end
                end
            end
            
            DONE: begin
                // One cycle to assert valid_o, then back to IDLE
                state_d = IDLE;
            end
        endcase
        
        // Store converter output when valid
        if (converter_valid_o && output_counter_q < NUM_BINS) begin
            db_power_d[output_counter_q] = converter_db_power;
        end
    end
    
    // =========================================================================
    // Input Multiplexing - Select which bin to feed
    // =========================================================================
    always_comb begin
        if (input_counter_q < NUM_BINS) begin
            converter_i_data = A_real_clipped_i[input_counter_q];
            converter_q_data = A_imag_clipped_i[input_counter_q];
        end else begin
            converter_i_data = '0;
            converter_q_data = '0;
        end
    end
    
    // =========================================================================
    // Sequential Logic
    // =========================================================================
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            state_q <= IDLE;
            input_counter_q <= '0;
            output_counter_q <= '0;
            
            for (int k = 0; k < NUM_BINS; k++) begin
                db_power_q[k] <= '0;
            end
        end else begin
            state_q <= state_d;
            input_counter_q <= input_counter_d;
            output_counter_q <= output_counter_d;
            
            for (int k = 0; k < NUM_BINS; k++) begin
                db_power_q[k] <= db_power_d[k];
            end
        end
    end
    
    // =========================================================================
    // Output Assignments
    // =========================================================================
    assign valid_o = (state_q == DONE);
    
    always_comb begin
        for (int k = 0; k < NUM_BINS; k++) begin
            db_power_o[k] = db_power_q[k];
        end
    end

endmodule