////////////////////////////////////////////////////////////////////////////////
//
//  Module: dft_power_estimator
//
//  Description:
//      Simplified DFT power estimation pipeline without timing controller.
//      Directly processes a single window of samples. Wraps:
//      1. dft_accumulation_cordic - computes DFT bins
//      2. complex_to_log_power - converts bins to dB power
//
//  Usage:
//      - Start oscillators early (35 cycles before DFT start)
//      - Assert start_i for one cycle when ready to begin accumulation
//      - Stream samples with sample_valid_i
//      - Assert last_sample_i on final sample
//      - Wait for valid_o to go high
//
//  Pipeline Flow:
//      samples -> DFT accumulation -> clip to 32-bit -> log power -> dB output
//
////////////////////////////////////////////////////////////////////////////////

module dft_power_estimator #(
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
    parameter integer POWER_INPUT_WIDTH = 32,     // Width after clipping accumulator (Q8.24)
    parameter integer POWER_WIDTH = 8,
    parameter integer POWER_FRAC = 0,
    
    // --- Sample Count ---
    parameter integer SAMPLE_COUNT_WIDTH = 16
)(
    input  logic clk_i,
    input  logic rst_ni,
    
    // --- DFT Control ---
    input  logic start_i,                         // Start DFT accumulation (single pulse)
    input  logic sample_valid_i,                  // IQ sample valid
    input  logic last_sample_i,                   // Last sample of window
    
    // --- Oscillator Control ---
    input  logic osc_reset_i,                     // Reset oscillator phases
    input  logic osc_enable_i,                    // Enable oscillators
    input  logic osc_phase_tvalid_i,              // Phase valid signal
    
    // --- Configuration ---
    input  logic [PHASE_WIDTH-1:0] freq_steps_i[NUM_BINS],
    
    // --- Data Input (IQ samples + window coefficient) ---
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
    
    // DFT Accumulation Outputs
    logic signed [ACCUM_WIDTH-1:0] A_real[NUM_BINS];
    logic signed [ACCUM_WIDTH-1:0] A_imag[NUM_BINS];
    logic dft_valid;
    logic dft_busy;
    
    // Clipped/Truncated accumulator values for power conversion
    // Take upper 32 bits from 64-bit accumulator (Q8.56 -> Q8.24)
    logic signed [POWER_INPUT_WIDTH-1:0] A_real_clipped[NUM_BINS];
    logic signed [POWER_INPUT_WIDTH-1:0] A_imag_clipped[NUM_BINS];
    
    // Power Conversion Outputs
    logic [POWER_WIDTH-1:0] db_power_internal[NUM_BINS];
    logic power_valid[NUM_BINS];
    
    // Combined valid signal (all bins converted)
    logic all_bins_valid;
    
    // =========================================================================
    // 1. DFT Accumulation with CORDIC Oscillators
    // =========================================================================
    
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
        .start_i            (start_i),
        .sample_valid_i     (sample_valid_i),
        .last_sample_i      (last_sample_i),
        
        // Oscillator Control
        .osc_reset_i        (osc_reset_i),
        .osc_enable_i       (osc_enable_i),
        .osc_phase_tvalid_i (osc_phase_tvalid_i),
        
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
    // 2. Accumulator Clipping/Truncation
    // =========================================================================
    // Take upper 32 bits from 64-bit accumulators (Q8.56 -> Q8.24)
    // This implements the hardware clipping behavior
    
    genvar j;
    generate
        for (j = 0; j < NUM_BINS; j++) begin : gen_clip_accumulators
            // Take the upper POWER_INPUT_WIDTH bits (bits [63:32])
            // This gives us Q8.24 format from Q8.56
            assign A_real_clipped[j] = A_real[j][ACCUM_WIDTH-1 -: POWER_INPUT_WIDTH];
            assign A_imag_clipped[j] = A_imag[j][ACCUM_WIDTH-1 -: POWER_INPUT_WIDTH];
        end
    endgenerate
    
    // =========================================================================
    // 3. Complex to Log Power Conversion (Per Bin)
    // =========================================================================
    // Converts each complex DFT bin to logarithmic power (dB)
    
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
    // 4. Output Logic
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
    
    // Check that clipping is valid (can't clip more bits than we have)
    initial begin
        assert (POWER_INPUT_WIDTH <= ACCUM_WIDTH)
            else $error("POWER_INPUT_WIDTH (%0d) cannot exceed ACCUM_WIDTH (%0d)",
                       POWER_INPUT_WIDTH, ACCUM_WIDTH);
    end
    
    // Check that we're taking the upper bits correctly
    initial begin
        assert (POWER_INPUT_WIDTH == 32)
            else $warning("POWER_INPUT_WIDTH is %0d, expected 32 for Q8.24 format",
                         POWER_INPUT_WIDTH);
    end

endmodule