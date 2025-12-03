////////////////////////////////////////////////////////////////////////////////
//
//  Module: bandwidth_estimation_top
//
//  Description:
//      Complete bandwidth estimation pipeline that:
//      1. Counts samples until window size is reached
//      2. Starts oscillator bank (35 cycles early for CORDIC latency)
//      3. Performs streaming DFT accumulation
//      4. Converts complex accumulators to log power (dB)
//      5. Finds left and right bandwidth edges via threshold crossing
//      6. Interpolates precise edge frequencies
//
//  Pipeline Flow:
//      Sample Counter -> DFT Accumulation (CORDIC) -> Log Power Conversion ->
//      Edge Detection (L/R) -> Linear Interpolation (L/R) -> Final Edges
//
////////////////////////////////////////////////////////////////////////////////

module bandwidth_estimation_top #(
    // Sample and window parameters
    parameter int SAMPLES_PER_WINDOW = 256,
    parameter int SAMPLE_COUNT_WIDTH = 16,
    
    // DFT accumulation parameters
    parameter int IQ_WIDTH = 16,
    parameter int IQ_WIDTH_FRAC = 14,
    parameter int WINDOW_WIDTH = 16,
    parameter int WINDOW_WIDTH_FRAC = 14,
    parameter int ACCUM_WIDTH = 64,
    parameter int ACCUM_WIDTH_FRAC = 56,
    parameter int OSC_WIDTH = 32,
    parameter int OSC_WIDTH_FRAC = 30,
    parameter int PHASE_WIDTH = 32,
    parameter int NUM_BINS = 24,
    
    // Power conversion parameters
    parameter int POWER_DB_WIDTH = 32,
    parameter int POWER_DB_FRAC = 16,
    
    // Edge detection parameters
    parameter int FREQ_BIN_WIDTH = 9,
    parameter int THRESHOLD_DB = 30,  // Positive value (will be negated)
    
    // Interpolation parameters
    parameter int FREQ_WIDTH = 32,
    parameter int FREQ_FRAC_BITS = 16
) (
    input  logic clk_i,
    input  logic rst_ni,
    
    // Control
    input  logic enable_i,           // Enable processing
    input  logic sample_valid_i,     // New sample available
    
    // Sample inputs
    input  logic signed [IQ_WIDTH-1:0] i_sample_i,
    input  logic signed [IQ_WIDTH-1:0] q_sample_i,
    input  logic signed [WINDOW_WIDTH-1:0] window_coeff_i,
    
    // Frequency configuration
    input  logic [PHASE_WIDTH-1:0] freq_steps_i[NUM_BINS],
    input  logic [FREQ_BIN_WIDTH-1:0] freq_bins_i[NUM_BINS],
    
    // Outputs
    output logic [FREQ_WIDTH-1:0] left_edge_freq_o,
    output logic [FREQ_WIDTH-1:0] right_edge_freq_o,
    output logic valid_o,
    output logic invalid_left_o,
    output logic invalid_right_o,
    output logic busy_o
);

    // Timing constants
    localparam int CORDIC_LATENCY = 36;
    localparam int WINDOWING_LATENCY = 1;
    localparam int OSC_EARLY_START = CORDIC_LATENCY - WINDOWING_LATENCY; // 35

    ////////////////////////////////////////////////////////////////////////////
    // State Machine
    ////////////////////////////////////////////////////////////////////////////
    typedef enum logic [2:0] {
        IDLE            = 3'b000,
        OSC_STARTUP     = 3'b001,
        DFT_PROCESSING  = 3'b010,
        POWER_CONVERT   = 3'b011,
        EDGE_DETECT     = 3'b100,
        INTERPOLATE     = 3'b101,
        DONE            = 3'b110
    } state_t;
    
    state_t state_q, state_d;
    
    ////////////////////////////////////////////////////////////////////////////
    // Sample Counter
    ////////////////////////////////////////////////////////////////////////////
    logic [SAMPLE_COUNT_WIDTH-1:0] sample_count_q, sample_count_d;
    logic [SAMPLE_COUNT_WIDTH-1:0] osc_delay_count_q, osc_delay_count_d;
    logic sample_window_complete;
    logic osc_delay_complete;
    
    assign sample_window_complete = (sample_count_q >= SAMPLES_PER_WINDOW);
    assign osc_delay_complete = (osc_delay_count_q >= OSC_EARLY_START);
    
    ////////////////////////////////////////////////////////////////////////////
    // DFT Accumulation Signals
    ////////////////////////////////////////////////////////////////////////////
    logic dft_start;
    logic dft_sample_valid;
    logic dft_last_sample;
    logic dft_osc_reset;
    logic dft_osc_enable;
    logic dft_osc_phase_tvalid;
    
    logic signed [ACCUM_WIDTH-1:0] dft_A_real[NUM_BINS];
    logic signed [ACCUM_WIDTH-1:0] dft_A_imag[NUM_BINS];
    logic dft_valid;
    logic dft_busy;
    
    ////////////////////////////////////////////////////////////////////////////
    // Power Conversion Signals
    ////////////////////////////////////////////////////////////////////////////
    logic [NUM_BINS-1:0] power_valid;
    logic [POWER_DB_WIDTH-1:0] power_db[NUM_BINS];
    logic power_conv_start;
    logic [5:0] power_conv_count_q, power_conv_count_d;
    logic all_powers_valid;
    
    assign all_powers_valid = &power_valid;
    
    ////////////////////////////////////////////////////////////////////////////
    // Edge Detection Signals
    ////////////////////////////////////////////////////////////////////////////
    logic edge_detect_start;
    
    // Left edge
    logic [FREQ_BIN_WIDTH-1:0] left_f1, left_f2;
    logic [POWER_DB_WIDTH-1:0] left_L1, left_L2;
    logic left_edge_valid;
    logic left_edge_busy;
    
    // Right edge
    logic [FREQ_BIN_WIDTH-1:0] right_f1, right_f2;
    logic [POWER_DB_WIDTH-1:0] right_L1, right_L2;
    logic right_edge_valid;
    logic right_edge_busy;
    
    logic both_edges_valid;
    assign both_edges_valid = left_edge_valid & right_edge_valid;
    
    ////////////////////////////////////////////////////////////////////////////
    // Interpolation Signals
    ////////////////////////////////////////////////////////////////////////////
    logic interp_start;
    
    // Left interpolation
    logic left_interp_valid;
    logic left_interp_ready;
    logic left_interp_invalid;
    logic [FREQ_WIDTH-1:0] left_f_star;
    
    // Right interpolation
    logic right_interp_valid;
    logic right_interp_ready;
    logic right_interp_invalid;
    logic [FREQ_WIDTH-1:0] right_f_star;
    
    logic both_interp_ready;
    assign both_interp_ready = left_interp_ready & right_interp_ready;
    
    ////////////////////////////////////////////////////////////////////////////
    // State Machine Logic
    ////////////////////////////////////////////////////////////////////////////
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            state_q <= IDLE;
            sample_count_q <= '0;
            osc_delay_count_q <= '0;
            power_conv_count_q <= '0;
        end else begin
            state_q <= state_d;
            sample_count_q <= sample_count_d;
            osc_delay_count_q <= osc_delay_count_d;
            power_conv_count_q <= power_conv_count_d;
        end
    end
    
    always_comb begin
        // Default: maintain state
        state_d = state_q;
        sample_count_d = sample_count_q;
        osc_delay_count_d = osc_delay_count_q;
        power_conv_count_d = power_conv_count_q;
        
        // Control signals (default inactive)
        dft_start = 1'b0;
        dft_sample_valid = 1'b0;
        dft_last_sample = 1'b0;
        dft_osc_reset = 1'b0;
        dft_osc_enable = 1'b0;
        dft_osc_phase_tvalid = 1'b0;
        power_conv_start = 1'b0;
        edge_detect_start = 1'b0;
        interp_start = 1'b0;
        
        case (state_q)
            IDLE: begin
                sample_count_d = '0;
                osc_delay_count_d = '0;
                power_conv_count_d = '0;
                
                if (enable_i && sample_valid_i) begin
                    state_d = OSC_STARTUP;
                    // Reset oscillator on first sample
                    dft_osc_reset = 1'b1;
                    sample_count_d = 1;
                end
            end
            
            OSC_STARTUP: begin
                // Start oscillator bank
                dft_osc_enable = 1'b1;
                dft_osc_phase_tvalid = 1'b1;
                
                // Count samples and delay
                if (sample_valid_i && !sample_window_complete) begin
                    sample_count_d = sample_count_q + 1;
                end
                
                if (sample_valid_i) begin
                    osc_delay_count_d = osc_delay_count_q + 1;
                end
                
                // After 35 cycles, start DFT accumulation
                if (osc_delay_complete) begin
                    state_d = DFT_PROCESSING;
                    dft_start = 1'b1;
                end
            end
            
            DFT_PROCESSING: begin
                // Keep oscillator running
                dft_osc_enable = 1'b1;
                dft_osc_phase_tvalid = 1'b1;
                
                // Stream samples
                if (sample_valid_i && !sample_window_complete) begin
                    dft_sample_valid = 1'b1;
                    sample_count_d = sample_count_q + 1;
                    
                    // Check if this is the last sample
                    if (sample_count_q == SAMPLES_PER_WINDOW - 1) begin
                        dft_last_sample = 1'b1;
                    end
                end
                
                // Wait for DFT completion
                if (dft_valid) begin
                    state_d = POWER_CONVERT;
                    power_conv_start = 1'b1;
                end
            end
            
            POWER_CONVERT: begin
                // Power conversion happens automatically via instantiated modules
                // Wait for all conversions to complete (3 cycle latency each)
                power_conv_count_d = power_conv_count_q + 1;
                
                if (all_powers_valid) begin
                    state_d = EDGE_DETECT;
                    edge_detect_start = 1'b1;
                end
            end
            
            EDGE_DETECT: begin
                // Edge detection happens in parallel for left and right
                if (both_edges_valid) begin
                    state_d = INTERPOLATE;
                    interp_start = 1'b1;
                end
            end
            
            INTERPOLATE: begin
                // Linear interpolation (5 cycle latency each)
                if (both_interp_ready) begin
                    state_d = DONE;
                end
            end
            
            DONE: begin
                // Hold result for one cycle, then return to IDLE
                state_d = IDLE;
            end
            
            default: state_d = IDLE;
        endcase
    end
    
    ////////////////////////////////////////////////////////////////////////////
    // DFT Accumulation Module
    ////////////////////////////////////////////////////////////////////////////
    dft_accumulation_cordic #(
        .IQ_WIDTH(IQ_WIDTH),
        .IQ_WIDTH_FRAC(IQ_WIDTH_FRAC),
        .WINDOW_WIDTH(WINDOW_WIDTH),
        .WINDOW_WIDTH_FRAC(WINDOW_WIDTH_FRAC),
        .ACCUM_WIDTH(ACCUM_WIDTH),
        .ACCUM_WIDTH_FRAC(ACCUM_WIDTH_FRAC),
        .NUM_BINS(NUM_BINS),
        .OSC_WIDTH(OSC_WIDTH),
        .OSC_WIDTH_FRAC(OSC_WIDTH_FRAC),
        .PHASE_WIDTH(PHASE_WIDTH),
        .SAMPLE_COUNT_WIDTH(SAMPLE_COUNT_WIDTH)
    ) dft_inst (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .start_i(dft_start),
        .sample_valid_i(dft_sample_valid),
        .last_sample_i(dft_last_sample),
        .osc_reset_i(dft_osc_reset),
        .osc_enable_i(dft_osc_enable),
        .osc_phase_tvalid_i(dft_osc_phase_tvalid),
        .freq_steps_i(freq_steps_i),
        .i_sample_i(i_sample_i),
        .q_sample_i(q_sample_i),
        .window_coeff_i(window_coeff_i),
        .A_real_o(dft_A_real),
        .A_imag_o(dft_A_imag),
        .valid_o(dft_valid),
        .busy_o(dft_busy)
    );
    
    ////////////////////////////////////////////////////////////////////////////
    // Power Conversion Modules (one per bin)
    ////////////////////////////////////////////////////////////////////////////
    genvar k;
    generate
        for (k = 0; k < NUM_BINS; k++) begin : gen_power_converters
            // Convert ACCUM_WIDTH to fit INPUT_WIDTH of complex_to_log_power
            // Truncate to reasonable size for power calculation
            localparam int POWER_INPUT_WIDTH = 32;
            logic signed [POWER_INPUT_WIDTH-1:0] i_truncated, q_truncated;
            
            // Truncate from MSB side (keep dynamic range)
            assign i_truncated = dft_A_real[k][ACCUM_WIDTH-1 -: POWER_INPUT_WIDTH];
            assign q_truncated = dft_A_imag[k][ACCUM_WIDTH-1 -: POWER_INPUT_WIDTH];
            
            complex_to_log_power #(
                .INPUT_WIDTH(POWER_INPUT_WIDTH),
                .OUTPUT_WIDTH(POWER_DB_WIDTH),
                .OUTPUT_FRAC(POWER_DB_FRAC)
            ) power_conv_inst (
                .clk_i(clk_i),
                .rst_ni(rst_ni),
                .valid_i(power_conv_start),
                .i_data_i(i_truncated),
                .q_data_i(q_truncated),
                .valid_o(power_valid[k]),
                .db_power_o(power_db[k])
            );
        end
    endgenerate
    
    ////////////////////////////////////////////////////////////////////////////
    // Left Edge Detection Module
    ////////////////////////////////////////////////////////////////////////////
    find_bw_left_edge #(
        .ACCUM_WIDTH(POWER_DB_WIDTH),
        .FREQ_BIN_WIDTH(FREQ_BIN_WIDTH),
        .THRESHOLD_DB(THRESHOLD_DB),
        .NUM_ACCUMS(NUM_BINS)
    ) left_edge_inst (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .start_i(edge_detect_start),
        .accumulator_val_i(power_db),
        .freq_bin_i(freq_bins_i),
        .f1_o(left_f1),
        .f2_o(left_f2),
        .L1_o(left_L1),
        .L2_o(left_L2),
        .valid_o(left_edge_valid),
        .busy_o(left_edge_busy)
    );
    
    ////////////////////////////////////////////////////////////////////////////
    // Right Edge Detection Module
    ////////////////////////////////////////////////////////////////////////////
    find_bw_right_edge #(
        .ACCUM_WIDTH(POWER_DB_WIDTH),
        .FREQ_BIN_WIDTH(FREQ_BIN_WIDTH),
        .THRESHOLD_DB(THRESHOLD_DB),
        .NUM_ACCUMS(NUM_BINS)
    ) right_edge_inst (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .start_i(edge_detect_start),
        .accumulator_val_i(power_db),
        .freq_bin_i(freq_bins_i),
        .f1_o(right_f1),
        .f2_o(right_f2),
        .L1_o(right_L1),
        .L2_o(right_L2),
        .valid_o(right_edge_valid),
        .busy_o(right_edge_busy)
    );
    
    ////////////////////////////////////////////////////////////////////////////
    // Left Edge Interpolation Module
    ////////////////////////////////////////////////////////////////////////////
    // Convert frequency bins to actual frequencies (scale appropriately)
    logic [FREQ_WIDTH-1:0] left_f1_scaled, left_f2_scaled;
    assign left_f1_scaled = left_f1 << FREQ_FRAC_BITS;
    assign left_f2_scaled = left_f2 << FREQ_FRAC_BITS;
    
    linear_interp_crossing #(
        .FREQ_WIDTH(FREQ_WIDTH),
        .FREQ_FRAC_BITS(FREQ_FRAC_BITS),
        .ACCUM_DB_WIDTH(POWER_DB_WIDTH),
        .ACCUM_DB_FRAC(POWER_DB_FRAC),
        .THRESHOLD_DB(-THRESHOLD_DB <<< POWER_DB_FRAC)
    ) left_interp_inst (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .valid_i(interp_start),
        .f1_i(left_f1_scaled),
        .f2_i(left_f2_scaled),
        .L1_i(left_L1),
        .L2_i(left_L2),
        .ready_o(left_interp_ready),
        .f_star_o(left_f_star),
        .invalid_o(left_interp_invalid)
    );
    
    ////////////////////////////////////////////////////////////////////////////
    // Right Edge Interpolation Module
    ////////////////////////////////////////////////////////////////////////////
    logic [FREQ_WIDTH-1:0] right_f1_scaled, right_f2_scaled;
    assign right_f1_scaled = right_f1 << FREQ_FRAC_BITS;
    assign right_f2_scaled = right_f2 << FREQ_FRAC_BITS;
    
    linear_interp_crossing #(
        .FREQ_WIDTH(FREQ_WIDTH),
        .FREQ_FRAC_BITS(FREQ_FRAC_BITS),
        .ACCUM_DB_WIDTH(POWER_DB_WIDTH),
        .ACCUM_DB_FRAC(POWER_DB_FRAC),
        .THRESHOLD_DB(-THRESHOLD_DB <<< POWER_DB_FRAC)
    ) right_interp_inst (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .valid_i(interp_start),
        .f1_i(right_f1_scaled),
        .f2_i(right_f2_scaled),
        .L1_i(right_L1),
        .L2_i(right_L2),
        .ready_o(right_interp_ready),
        .f_star_o(right_f_star),
        .invalid_o(right_interp_invalid)
    );
    
    ////////////////////////////////////////////////////////////////////////////
    // Output Registers
    ////////////////////////////////////////////////////////////////////////////
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            left_edge_freq_o <= '0;
            right_edge_freq_o <= '0;
            valid_o <= 1'b0;
            invalid_left_o <= 1'b0;
            invalid_right_o <= 1'b0;
        end else begin
            if (state_q == DONE) begin
                left_edge_freq_o <= left_f_star;
                right_edge_freq_o <= right_f_star;
                valid_o <= 1'b1;
                invalid_left_o <= left_interp_invalid;
                invalid_right_o <= right_interp_invalid;
            end else begin
                valid_o <= 1'b0;
            end
        end
    end
    
    assign busy_o = (state_q != IDLE) && (state_q != DONE);

endmodule