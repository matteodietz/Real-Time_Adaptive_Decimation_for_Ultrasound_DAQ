////////////////////////////////////////////////////////////////////////////////
//
//  Module: top
//
//  Description:
//      Top-level module that combines spectral power estimation and bandwidth
//      edge detection. Takes I/Q samples and window coefficients as input,
//      computes DFT power spectrum, then finds bandwidth edges.
//
//  Structure:
//      1. spectral_power_estimator: Counter controller + DFT + Power conversion
//      2. bandwidth_edge_detector: Max finder + Threshold calc + Edge detection
//
////////////////////////////////////////////////////////////////////////////////

module top #(
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
    parameter integer POWER_INPUT_WIDTH = 32,
    parameter integer POWER_WIDTH = 8,
    parameter integer POWER_FRAC = 0,
    
    // --- Timing Parameters ---
    parameter integer WINDOW_SIZE = 256,
    parameter integer OSC_LATENCY = 36,
    parameter integer COUNTER_WIDTH = 16,
    parameter integer SAMPLE_COUNT_WIDTH = 16,
    
    // --- Bandwidth Detection Parameters ---
    parameter integer FREQ_BIN_WIDTH = 16,
    parameter logic [POWER_WIDTH-1:0] THRESHOLD_DROP = 8'h1E  // 30dB
)(
    input  logic clk_i,
    input  logic rst_ni,
    
    // --- Control Interface ---
    input  logic enable_i,
    input  logic clear_i,
    input  logic [COUNTER_WIDTH-1:0] delay_cycles_i,
    
    // --- Configuration ---
    input  logic [PHASE_WIDTH-1:0] freq_steps_i[NUM_BINS],
    input  logic [FREQ_BIN_WIDTH-1:0] freq_bin_i[NUM_BINS],
    
    // --- Data Input (IQ samples + window coefficient) ---
    input  logic sample_valid_i,
    input  logic signed [IQ_WIDTH-1:0] i_sample_i,
    input  logic signed [IQ_WIDTH-1:0] q_sample_i,
    input  logic signed [WINDOW_WIDTH-1:0] window_coeff_i,
    
    // --- Outputs ---
    // DFT busy status
    output logic dft_busy_o,
    
    // Threshold status
    output logic threshold_ok_o,
    
    // Left edge outputs
    output logic [FREQ_BIN_WIDTH-1:0] f1_left_o,
    output logic [FREQ_BIN_WIDTH-1:0] f2_left_o,
    output logic [POWER_WIDTH-1:0] L1_left_o,
    output logic [POWER_WIDTH-1:0] L2_left_o,
    
    // Right edge outputs
    output logic [FREQ_BIN_WIDTH-1:0] f1_right_o,
    output logic [FREQ_BIN_WIDTH-1:0] f2_right_o,
    output logic [POWER_WIDTH-1:0] L1_right_o,
    output logic [POWER_WIDTH-1:0] L2_right_o,
    
    // Valid output (bandwidth detection complete)
    output logic valid_o,
    
    // Busy output (entire pipeline busy)
    output logic busy_o
);

    //--------------------------------------------------------------------------
    // Internal Signals
    //--------------------------------------------------------------------------
    
    // Spectral Power Estimator Outputs
    logic [POWER_WIDTH-1:0] db_power[NUM_BINS];
    logic dft_valid;
    logic dft_busy;
    
    // Bandwidth Edge Detector Outputs
    logic [FREQ_BIN_WIDTH-1:0] f1_left;
    logic [FREQ_BIN_WIDTH-1:0] f2_left;
    logic [POWER_WIDTH-1:0] L1_left;
    logic [POWER_WIDTH-1:0] L2_left;
    logic [FREQ_BIN_WIDTH-1:0] f1_right;
    logic [FREQ_BIN_WIDTH-1:0] f2_right;
    logic [POWER_WIDTH-1:0] L1_right;
    logic [POWER_WIDTH-1:0] L2_right;
    logic bw_valid;
    logic bw_busy;
    logic threshold_ok;
    
    //--------------------------------------------------------------------------
    // Module Instantiations
    //--------------------------------------------------------------------------
    
    // 1. Spectral Power Estimator
    spectral_power_estimator #(
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
        .POWER_INPUT_WIDTH  (POWER_INPUT_WIDTH),
        .POWER_WIDTH        (POWER_WIDTH),
        .POWER_FRAC         (POWER_FRAC),
        .WINDOW_SIZE        (WINDOW_SIZE),
        .OSC_LATENCY        (OSC_LATENCY),
        .COUNTER_WIDTH      (COUNTER_WIDTH),
        .SAMPLE_COUNT_WIDTH (SAMPLE_COUNT_WIDTH)
    ) u_spectral_power_estimator (
        .clk_i          (clk_i),
        .rst_ni         (rst_ni),
        .enable_i       (enable_i),
        .clear_i        (clear_i),
        .delay_cycles_i (delay_cycles_i),
        .freq_steps_i   (freq_steps_i),
        .sample_valid_i (sample_valid_i),
        .i_sample_i     (i_sample_i),
        .q_sample_i     (q_sample_i),
        .window_coeff_i (window_coeff_i),
        .db_power_o     (db_power),
        .valid_o        (dft_valid),
        .busy_o         (dft_busy)
    );
    
    // 2. Bandwidth Edge Detector
    bandwidth_edge_detector #(
        .POWER_WIDTH        (POWER_WIDTH),
        .POWER_FRAC         (POWER_FRAC),
        .THRESHOLD_DROP     (THRESHOLD_DROP),
        .FREQ_BIN_WIDTH     (FREQ_BIN_WIDTH),
        .NUM_BINS           (NUM_BINS)
    ) u_bandwidth_edge_detector (
        .clk_i          (clk_i),
        .rst_ni         (rst_ni),
        .valid_i        (dft_valid),
        .db_power_i     (db_power),
        .freq_bin_i     (freq_bin_i),
        .f1_left_o      (f1_left),
        .f2_left_o      (f2_left),
        .L1_left_o      (L1_left),
        .L2_left_o      (L2_left),
        .f1_right_o     (f1_right),
        .f2_right_o     (f2_right),
        .L1_right_o     (L1_right),
        .L2_right_o     (L2_right),
        .valid_o        (bw_valid),
        .threshold_ok_o (threshold_ok),
        .busy_o         (bw_busy)
    );
    
    //--------------------------------------------------------------------------
    // Output Assignments
    //--------------------------------------------------------------------------
    
    assign dft_busy_o = dft_busy;
    assign threshold_ok_o = threshold_ok;
    
    assign f1_left_o = f1_left;
    assign f2_left_o = f2_left;
    assign L1_left_o = L1_left;
    assign L2_left_o = L2_left;
    
    assign f1_right_o = f1_right;
    assign f2_right_o = f2_right;
    assign L1_right_o = L1_right;
    assign L2_right_o = L2_right;
    
    assign valid_o = bw_valid;
    assign busy_o = dft_busy || bw_busy;

endmodule