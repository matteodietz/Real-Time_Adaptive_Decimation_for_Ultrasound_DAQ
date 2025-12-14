module spectral_power_estimator #(
    // --- DFT Parameters ---
    parameter integer IQ_WIDTH = 16,
    parameter integer IQ_WIDTH_FRAC = 14,
    parameter integer WINDOW_WIDTH = 16,
    parameter integer WINDOW_WIDTH_FRAC = 14,
    parameter integer ACCUM_WIDTH = 64,
    parameter integer ACCUM_WIDTH_FRAC = 56,
    parameter integer NUM_BINS = 24,
    
    // --- Oscillator Parameters ---
    parameter integer OSC_WIDTH = 32,
    parameter integer OSC_WIDTH_FRAC = 30,
    parameter integer PHASE_WIDTH = 32,
    
    // --- Power Conversion Parameters ---
    parameter integer POWER_INPUT_WIDTH = 32,     // Width after clipping accumulator
    parameter integer POWER_WIDTH = 8,
    parameter integer POWER_FRAC = 0,
    
    // --- Timing Parameters ---
    parameter integer WINDOW_SIZE = 256,          // Number of samples in window
    parameter integer OSC_LATENCY = 36,           // CORDIC pipeline depth
    parameter integer COUNTER_WIDTH = 16,
    parameter integer SAMPLE_COUNT_WIDTH = 16
)(
    input  logic clk_i,
    input  logic rst_ni,
    
    // --- Control Interface ---
    input  logic enable_i,                        // Enable the entire pipeline
    input  logic clear_i,                         // Synchronous clear/restart
    input  logic [COUNTER_WIDTH-1:0] delay_cycles_i,  // Variable delay cycles per test
    
    // --- Configuration ---
    input  logic [PHASE_WIDTH-1:0] freq_steps_i[NUM_BINS],
    
    // --- Data Input (IQ samples + window coefficient) ---
    input  logic sample_valid_i,                  // IQ sample valid
    input  logic signed [IQ_WIDTH-1:0] i_sample_i,
    input  logic signed [IQ_WIDTH-1:0] q_sample_i,
    input  logic signed [WINDOW_WIDTH-1:0] window_coeff_i,
    
    // --- Output (dB Power for each bin) ---
    output logic [POWER_WIDTH-1:0] db_power_o[NUM_BINS],
    output logic valid_o,                         // Output valid (all bins computed)
    output logic busy_o                           // Pipeline busy (accumulating)
);

    // =========================================================================
    // Internal Signals
    // =========================================================================
    
    // Counter Controller Outputs
    logic osc_reset_internal;
    logic osc_enable_internal;
    logic osc_phase_tvalid_internal;
    logic start_internal;
    logic sample_valid_internal;
    logic last_sample_internal;
    
    // Counter Controller Inputs
    logic [COUNTER_WIDTH-1:0] X;
    logic [COUNTER_WIDTH-1:0] Y;
    logic [COUNTER_WIDTH-1:0] Z;
    
    // Gated sample valid
    logic sample_valid_gated;
    
    // DFT Accumulation Outputs
    logic signed [ACCUM_WIDTH-1:0] A_real[NUM_BINS];
    logic signed [ACCUM_WIDTH-1:0] A_imag[NUM_BINS];
    logic dft_valid;
    logic dft_busy;
    
    // Clipped/Truncated accumulator values for power conversion
    logic signed [POWER_INPUT_WIDTH-1:0] A_real_clipped[NUM_BINS];
    logic signed [POWER_INPUT_WIDTH-1:0] A_imag_clipped[NUM_BINS];
    
    // Power Conversion Outputs
    logic [POWER_WIDTH-1:0] db_power_internal[NUM_BINS];
    logic power_valid[NUM_BINS];
    
    // Combined valid signal (all bins converted)
    logic all_bins_valid;
    
    // =========================================================================
    // Calculate Counter Controller Parameters
    // =========================================================================
    // X = delay_cycles_i - 35 (accounting for counter implementation offset)
    // Y = OSC_LATENCY + 1 = 37
    // Z = WINDOW_SIZE = number of samples in window
    
    assign X = delay_cycles_i - COUNTER_WIDTH'(OSC_LATENCY - 1);
    assign Y = COUNTER_WIDTH'(OSC_LATENCY);
    assign Z = COUNTER_WIDTH'(WINDOW_SIZE);
    
    // =========================================================================
    // 1. Counter Controller (replaces dft_timing_controller)
    // =========================================================================
    
    counter_controller #(
        .COUNTER_WIDTH_X(COUNTER_WIDTH),
        .COUNTER_WIDTH_Y(COUNTER_WIDTH),
        .COUNTER_WIDTH_Z(COUNTER_WIDTH)
    ) u_counter_ctrl (
        .clk_i              (clk_i),
        .rst_ni             (rst_ni),
        .X                  (X),
        .Y                  (Y),
        .Z                  (Z),
        .clear_i            (clear_i),
        .enable_i           (enable_i),
        .osc_reset          (osc_reset_internal),
        .osc_enable         (osc_enable_internal),
        .osc_phase_tvalid   (osc_phase_tvalid_internal),
        .start              (start_internal),
        .sample_valid       (sample_valid_internal),
        .last_sample        (last_sample_internal)
    );
    
    // =========================================================================
    // 2. Sample Valid Gating
    // =========================================================================
    // Only process samples during the DFT window
    
    assign sample_valid_gated = sample_valid_internal;
    
    // =========================================================================
    // 3. DFT Accumulation with CORDIC Oscillators
    // =========================================================================
    // Computes DFT bins by accumulating windowed samples multiplied by
    // complex exponentials generated by CORDIC oscillators
    
    dft_accumulation_cordic #(
        .IQ_WIDTH           (IQ_WIDTH),
        .IQ_WIDTH_FRAC      (IQ_WIDTH_FRAC),
        .WINDOW_WIDTH       (WINDOW_WIDTH),
        .WINDOW_WIDTH_FRAC  (WINDOW_WIDTH_FRAC),
        .ACCUM_WIDTH        (ACCUM_WIDTH),
        .ACCUM_WIDTH_FRAC   (ACCUM_WIDTH_FRAC),
        .NUM_BINS           (NUM_BINS),
        .OSC_WIDTH          (OSC_WIDTH),
        .OSC_WIDTH_FRAC     (OSC_WIDTH_FRAC),
        .PHASE_WIDTH        (PHASE_WIDTH),
        .SAMPLE_COUNT_WIDTH (SAMPLE_COUNT_WIDTH)
    ) u_dft_accum (
        .clk_i              (clk_i),
        .rst_ni             (rst_ni),
        
        // DFT Control (from counter controller)
        .start_i            (start_internal),
        .sample_valid_i     (sample_valid_gated),      // Gated with DFT window
        .last_sample_i      (last_sample_internal),
        
        // Oscillator Control (from counter controller)
        .osc_reset_i        (osc_reset_internal),
        .osc_enable_i       (osc_enable_internal),
        .osc_phase_tvalid_i (osc_phase_tvalid_internal),
        
        // Configuration
        .freq_steps_i       (freq_steps_i),
        
        // Data Inputs
        .i_sample_i         (i_sample_i),
        .q_sample_i         (q_sample_i),
        .window_coeff_i     (window_coeff_i),
        
        // Outputs
        .A_real_o           (A_real),
        .A_imag_o           (A_imag),
        .valid_o            (dft_valid),
        .busy_o             (dft_busy)
    );
    
    // =========================================================================
    // 4. Accumulator Clipping/Truncation
    // =========================================================================
    // Take upper bits from 64-bit accumulators to feed into power converters
    // This reduces the input width to the log power calculation
    
    genvar j;
    generate
        for (j = 0; j < NUM_BINS; j++) begin : gen_clip_accumulators
            // Take the upper POWER_INPUT_WIDTH bits (MSBs)
            // This preserves the most significant information
            assign A_real_clipped[j] = A_real[j][ACCUM_WIDTH-1 -: POWER_INPUT_WIDTH];
            assign A_imag_clipped[j] = A_imag[j][ACCUM_WIDTH-1 -: POWER_INPUT_WIDTH];
        end
    endgenerate
    
    // =========================================================================
    // 5. Complex to Log Power Conversion (Per Bin)
    // =========================================================================
    // Converts each complex DFT bin to logarithmic power (dB)
    // Instantiate one converter per frequency bin
    
    genvar k;
    generate
        for (k = 0; k < NUM_BINS; k++) begin : gen_power_converters
            
            complex_to_log_power #(
                .INPUT_WIDTH    (POWER_INPUT_WIDTH),
                .OUTPUT_WIDTH   (POWER_WIDTH),
                .OUTPUT_FRAC    (POWER_FRAC)
            ) u_log_power (
                .clk_i          (clk_i),
                .rst_ni         (rst_ni),
                .valid_i        (dft_valid),
                .i_data_i       (A_real_clipped[k]),
                .q_data_i       (A_imag_clipped[k]),
                .valid_o        (power_valid[k]),
                .db_power_o     (db_power_internal[k])
            );
            
            // Connect to output array
            assign db_power_o[k] = db_power_internal[k];
        end
    endgenerate
    
    // =========================================================================
    // 6. Output Logic
    // =========================================================================
    // Valid output when all bins have been converted to dB power
    
    always_comb begin
        all_bins_valid = 1'b1;
        for (int i = 0; i < NUM_BINS; i++) begin
            all_bins_valid = all_bins_valid & power_valid[i];
        end
    end
    
    assign valid_o = all_bins_valid;
    assign busy_o = dft_busy;
    
    // =========================================================================
    // Assertions
    // =========================================================================
    
    // Check that power width is sufficient
    localparam int MAX_LOG_VAL = 3 * $clog2(2 * (2**POWER_INPUT_WIDTH)**2);
    initial begin
        assert (POWER_WIDTH >= $clog2(MAX_LOG_VAL))
            else $warning("POWER_WIDTH (%0d) may be insufficient for max log value (%0d)",
                         POWER_WIDTH, MAX_LOG_VAL);
    end
    
    // Check that clipping is valid (can't clip more bits than we have)
    initial begin
        assert (POWER_INPUT_WIDTH <= ACCUM_WIDTH)
            else $error("POWER_INPUT_WIDTH (%0d) cannot exceed ACCUM_WIDTH (%0d)",
                       POWER_INPUT_WIDTH, ACCUM_WIDTH);
    end
    
    // Check that delay_cycles is large enough for oscillator latency + offset
    always_ff @(posedge clk_i) begin
        if (rst_ni && enable_i) begin
            assert (delay_cycles_i >= (OSC_LATENCY + 35)) else
                $error("delay_cycles_i (%0d) must be >= OSC_LATENCY + 35 (%0d)",
                       delay_cycles_i, OSC_LATENCY + 35);
        end
    end

endmodule