// ////////////////////////////////////////////////////////////////////////////////
// //
// //  Module: dft_estimator
// //
// //  Description:
// //      Simplified DFT estimator wrapper that combines timing controller with
// //      DFT accumulation. This module handles all internal timing automatically.
// //
// //  Pipeline Flow:
// //      1. dft_timing_controller generates timing signals
// //      2. dft_accumulation_cordic computes DFT bins (I/Q accumulators)
// //
// //  Usage:
// //      - Set delay_cycles_i to specify when DFT window should start
// //      - Assert enable_i and clear_i to start the timing sequence
// //      - Stream samples continuously with sample_valid_i
// //      - DFT will automatically process the correct window
// //      - Wait for valid_o to go high for results
// //
// ////////////////////////////////////////////////////////////////////////////////

// module simplified_dft_timing_wrapper #(
//     // --- DFT Parameters ---
//     parameter integer IQ_WIDTH = 16,
//     parameter integer IQ_WIDTH_FRAC = 14,
//     parameter integer WINDOW_WIDTH = 16,
//     parameter integer WINDOW_WIDTH_FRAC = 14,
//     parameter integer ACCUM_WIDTH = 64,
//     parameter integer ACCUM_WIDTH_FRAC = 56,
//     parameter integer NUM_BINS = 24,
    
//     // --- Oscillator Parameters ---
//     parameter integer OSC_WIDTH = 32,
//     parameter integer OSC_WIDTH_FRAC = 30,
//     parameter integer PHASE_WIDTH = 32,
    
//     // --- Timing Parameters ---
//     parameter integer WINDOW_SIZE = 4,          // Number of samples in window
//     parameter integer OSC_LATENCY = 35,           // CORDIC pipeline depth
//     parameter integer COUNTER_WIDTH = 16,
//     parameter integer SAMPLE_COUNT_WIDTH = 16
// )(
//     input  logic clk_i,
//     input  logic rst_ni,
    
//     // --- Control Interface ---
//     input  logic enable_i,                              // Enable timing controller
//     input  logic clear_i,                               // Clear/restart timing controller
//     input  logic [COUNTER_WIDTH-1:0] delay_cycles_i,   // Delay before DFT window starts
    
//     // --- Configuration ---
//     input  logic [PHASE_WIDTH-1:0] freq_steps_i[NUM_BINS],
    
//     // --- Data Input (IQ samples + window coefficient) ---
//     input  logic sample_valid_i,                  // IQ sample valid (continuous stream)
//     input  logic signed [IQ_WIDTH-1:0] i_sample_i,
//     input  logic signed [IQ_WIDTH-1:0] q_sample_i,
//     input  logic signed [WINDOW_WIDTH-1:0] window_coeff_i,
    
//     // --- Output (Complex DFT bins) ---
//     output logic signed [ACCUM_WIDTH-1:0] A_real_o[NUM_BINS],
//     output logic signed [ACCUM_WIDTH-1:0] A_imag_o[NUM_BINS],
//     output logic valid_o,                         // Output valid (DFT complete)
//     output logic busy_o                           // DFT busy (accumulating)
// );

//     // =========================================================================
//     // Internal Signals
//     // =========================================================================
    
//     // Timing Controller Outputs
//     logic start_osc_internal;       // Oscillator enable (continuous during accumulation)
//     logic start_dft_internal;       // DFT start pulse (single cycle)
//     logic last_sample_internal;     // Last sample pulse (single cycle)
//     logic osc_reset_internal;       // Oscillator reset pulse (single cycle, before osc starts)
//     logic dft_sample_valid_internal;// Sample valid during DFT window
    
//     // Gated sample valid
//     logic sample_valid_gated;
    
//     // =========================================================================
//     // 1. Timing Controller
//     // =========================================================================
//     // Generates properly timed control signals accounting for CORDIC latency
    
//     dft_timing_controller #(
//         .OSC_LATENCY    (OSC_LATENCY),
//         .WINDOW_SIZE    (WINDOW_SIZE),
//         .COUNTER_WIDTH  (COUNTER_WIDTH)
//     ) u_timing_ctrl (
//         .clk_i              (clk_i),
//         .rst_ni             (rst_ni),
//         .enable_i           (enable_i),
//         .clear_i            (clear_i),
//         .delay_cycles_i     (delay_cycles_i),
//         .start_osc_o        (start_osc_internal),
//         .start_dft_o        (start_dft_internal),
//         .last_sample_o      (last_sample_internal),
//         .osc_reset_o        (osc_reset_internal),
//         .dft_sample_valid_o (dft_sample_valid_internal)
//     );
    
//     // =========================================================================
//     // 2. Sample Valid Gating
//     // =========================================================================
//     // Only process samples during the DFT window
    
//     assign sample_valid_gated = sample_valid_i & dft_sample_valid_internal;
    
//     // =========================================================================
//     // 3. DFT Accumulation with CORDIC Oscillators
//     // =========================================================================
//     // Computes DFT bins by accumulating windowed samples
    
//     dft_accumulation_cordic #(
//         .IQ_WIDTH           (IQ_WIDTH),
//         .IQ_WIDTH_FRAC      (IQ_WIDTH_FRAC),
//         .WINDOW_WIDTH       (WINDOW_WIDTH),
//         .WINDOW_WIDTH_FRAC  (WINDOW_WIDTH_FRAC),
//         .ACCUM_WIDTH        (ACCUM_WIDTH),
//         .ACCUM_WIDTH_FRAC   (ACCUM_WIDTH_FRAC),
//         .NUM_BINS           (NUM_BINS),
//         .OSC_WIDTH          (OSC_WIDTH),
//         .OSC_WIDTH_FRAC     (OSC_WIDTH_FRAC),
//         .PHASE_WIDTH        (PHASE_WIDTH),
//         .SAMPLE_COUNT_WIDTH (SAMPLE_COUNT_WIDTH)
//     ) u_dft_accum (
//         .clk_i              (clk_i),
//         .rst_ni             (rst_ni),
        
//         // DFT Control (from timing controller)
//         .start_i            (start_dft_internal),
//         .sample_valid_i     (sample_valid_gated),      // Gated with DFT window
//         .last_sample_i      (last_sample_internal),
        
//         // Oscillator Control (from timing controller)
//         .osc_reset_i        (osc_reset_internal),
//         .osc_enable_i       (start_osc_internal),
//         .osc_phase_tvalid_i (start_osc_internal),      // Same as enable
        
//         // Configuration
//         .freq_steps_i       (freq_steps_i),
        
//         // Data Inputs
//         .i_sample_i         (i_sample_i),
//         .q_sample_i         (q_sample_i),
//         .window_coeff_i     (window_coeff_i),
        
//         // Outputs
//         .A_real_o           (A_real_o),
//         .A_imag_o           (A_imag_o),
//         .valid_o            (valid_o),
//         .busy_o             (busy_o)
//     );
    
//     // =========================================================================
//     // Assertions
//     // =========================================================================
    
//     // Check that delay_cycles is large enough for oscillator latency
//     always_ff @(posedge clk_i) begin
//         if (rst_ni && enable_i) begin
//             assert (delay_cycles_i >= OSC_LATENCY) else
//                 $error("delay_cycles_i (%0d) must be >= OSC_LATENCY (%0d)",
//                        delay_cycles_i, OSC_LATENCY);
//         end
//     end

// endmodule

////////////////////////////////////////////////////////////////////////////////
//
//  Module: simplified_dft_timing_wrapper
//
//  Description:
//      Simplified DFT estimator wrapper that combines timing controller with
//      DFT accumulation. This module handles all internal timing automatically.
//
//  Pipeline Flow:
//      1. counter_controller generates timing signals
//      2. dft_accumulation_cordic computes DFT bins (I/Q accumulators)
//
//  Usage:
//      - Set delay_cycles_i to specify when DFT window should start
//      - Assert enable_i and clear_i to start the timing sequence
//      - Stream samples continuously with sample_valid_i
//      - DFT will automatically process the correct window
//      - Wait for valid_o to go high for results
//
////////////////////////////////////////////////////////////////////////////////

module simplified_dft_timing_wrapper #(
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
    
    // --- Timing Parameters ---
    parameter integer WINDOW_SIZE = 8,          // Number of samples in window
    parameter integer OSC_LATENCY = 36,         // CORDIC pipeline depth
    parameter integer COUNTER_WIDTH = 16,
    parameter integer SAMPLE_COUNT_WIDTH = 16
)(
    input  logic clk_i,
    input  logic rst_ni,
    
    // --- Control Interface ---
    input  logic enable_i,                              // Enable timing controller
    input  logic clear_i,                               // Clear/restart timing controller
    input  logic [COUNTER_WIDTH-1:0] delay_cycles_i,   // Delay before DFT window starts
    
    // --- Configuration ---
    input  logic [PHASE_WIDTH-1:0] freq_steps_i[NUM_BINS],
    
    // --- Data Input (IQ samples + window coefficient) ---
    input  logic sample_valid_i,                  // IQ sample valid (continuous stream)
    input  logic signed [IQ_WIDTH-1:0] i_sample_i,
    input  logic signed [IQ_WIDTH-1:0] q_sample_i,
    input  logic signed [WINDOW_WIDTH-1:0] window_coeff_i,
    
    // --- Output (Complex DFT bins) ---
    output logic signed [ACCUM_WIDTH-1:0] A_real_o[NUM_BINS],
    output logic signed [ACCUM_WIDTH-1:0] A_imag_o[NUM_BINS],
    output logic valid_o,                         // Output valid (DFT complete)
    output logic busy_o                           // DFT busy (accumulating)
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
    
    // =========================================================================
    // Calculate Counter Controller Parameters
    // =========================================================================
    // X = delay_cycles_i - 18 (accounting for counter implementation offset)
    // Y = OSC_LATENCY = 36
    // Z = WINDOW_SIZE = number of samples in window
    
    assign X = delay_cycles_i - 16'd35;
    assign Y = COUNTER_WIDTH'(OSC_LATENCY + 1);
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
    
    assign sample_valid_gated = sample_valid_internal; // removed_sample_valid_i &
    
    // =========================================================================
    // 3. DFT Accumulation with CORDIC Oscillators
    // =========================================================================
    // Computes DFT bins by accumulating windowed samples
    
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
        .A_real_o           (A_real_o),
        .A_imag_o           (A_imag_o),
        .valid_o            (valid_o),
        .busy_o             (busy_o)
    );
    
    // =========================================================================
    // Assertions
    // =========================================================================
    
    // Check that delay_cycles is large enough for oscillator latency + offset
    always_ff @(posedge clk_i) begin
        if (rst_ni && enable_i) begin
            assert (delay_cycles_i >= (OSC_LATENCY + 18)) else
                $error("delay_cycles_i (%0d) must be >= OSC_LATENCY + 18 (%0d)",
                       delay_cycles_i, OSC_LATENCY + 18);
        end
    end

endmodule