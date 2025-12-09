////////////////////////////////////////////////////////////////////////////////
//
//  Module: spectral_power_estimator
//
//  Description:
//      Complete pipeline for spectral power estimation. Wraps the DFT timing
//      controller, DFT accumulation with CORDIC oscillators, and log power
//      conversion into a single cohesive module.
//
//  Pipeline Flow:
//      1. dft_timing_controller generates timing signals
//      2. dft_accumulation_cordic computes DFT bins (I/Q accumulators)
//      3. complex_to_log_power converts each bin to dB power
//
//  Latency:
//      - OSC_LATENCY cycles for oscillator to produce valid W values
//      - WINDOW_SIZE cycles for DFT accumulation
//      - 3 cycles for log power conversion per bin
//      Total: OSC_LATENCY + WINDOW_SIZE + 3 cycles
//
////////////////////////////////////////////////////////////////////////////////

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
    parameter integer DELAY_CYCLES = 1000,        // Startup delay before first window
    parameter integer OSC_LATENCY = 35,           // CORDIC pipeline depth
    parameter integer COUNTER_WIDTH = 16,
    parameter integer SAMPLE_COUNT_WIDTH = 16
)(
    input  logic clk_i,
    input  logic rst_ni,
    
    // --- Control Interface ---
    input  logic enable_i,                        // Enable the entire pipeline
    input  logic clear_i,                         // Synchronous clear/restart
    
    // --- Configuration ---
    input  logic [PHASE_WIDTH-1:0] freq_steps_i[NUM_BINS],
    
    // --- Data Input (IQ samples + window coefficient) ---
    input  logic sample_valid_i,                  // IQ sample valid
    input  logic signed [IQ_WIDTH-1:0] i_sample_i,
    input  logic signed [IQ_WIDTH-1:0] q_sample_i,
    input  logic signed [WINDOW_WIDTH-1:0] window_coeff_i,
    input  logic last_sample_i,                   // Indicates last sample of window
    
    // --- Output (dB Power for each bin) ---
    output logic [POWER_WIDTH-1:0] db_power_o[NUM_BINS],
    output logic valid_o,                         // Output valid (all bins computed)
    output logic busy_o                           // Pipeline busy (accumulating)
);

    // =========================================================================
    // Internal Signals
    // =========================================================================
    
    // Timing Controller Outputs
    logic start_osc_continuous;  // Oscillator enable (continuous during accumulation)
    logic start_dft_pulse;       // DFT start pulse (single cycle)
    
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
    // 1. Timing Controller
    // =========================================================================
    // Generates properly timed start signals accounting for CORDIC latency
    
    dft_timing_controller #(
        .DELAY_CYCLES   (DELAY_CYCLES),
        .OSC_LATENCY    (OSC_LATENCY),
        .WINDOW_SIZE    (WINDOW_SIZE),
        .COUNTER_WIDTH  (COUNTER_WIDTH)
    ) u_timing_ctrl (
        .clk_i          (clk_i),
        .rst_ni         (rst_ni),
        .enable_i       (enable_i),
        .clear_i        (clear_i),
        .start_osc_o    (start_osc_continuous),  // Continuous enable
        .start_dft_o    (start_dft_pulse)        // Single pulse
    );
    
    // =========================================================================
    // 2. DFT Accumulation with CORDIC Oscillators
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
        
        // DFT Control
        .start_i            (start_dft_pulse),
        .sample_valid_i     (sample_valid_i),
        .last_sample_i      (last_sample_i),
        
        // Oscillator Control
        .osc_reset_i        (start_dft_pulse),      // Reset phase at start
        .osc_enable_i       (start_osc_continuous), // Continuous enable during operation
        .osc_phase_tvalid_i (start_osc_continuous), // Phase valid when enabled
        
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
    // 3. Accumulator Clipping/Truncation
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
    // 4. Complex to Log Power Conversion (Per Bin)
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
    // 5. Output Logic
    // =========================================================================
    // Valid output when all bins have been converted to dB power
    
    always_comb begin
        all_bins_valid = 1'b1;
        for (int i = 0; i < NUM_BINS; i++) begin
            all_bins_valid = all_bins_valid && power_valid[i];
        end
    end
    
    assign valid_o = all_bins_valid;
    assign busy_o = dft_busy;
    
    // =========================================================================
    // Assertions
    // =========================================================================
    
    // Check that oscillator latency doesn't exceed delay
    initial begin
        assert (DELAY_CYCLES >= OSC_LATENCY)
            else $error("DELAY_CYCLES (%0d) must be >= OSC_LATENCY (%0d)",
                       DELAY_CYCLES, OSC_LATENCY);
    end
    
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

endmodule