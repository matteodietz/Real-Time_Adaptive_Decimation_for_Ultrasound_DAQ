////////////////////////////////////////////////////////////////////////////////
//
//  Module: top_with_config_loader
//
//  Description:
//      Top-level module with AXI-Stream configuration loading interface.
//      Reduces I/O requirements by loading freq_steps and freq_bin arrays
//      serially instead of requiring them all in parallel.
//
//  Configuration Loading:
//      1. Send NUM_BINS freq_steps values via AXI-Stream
//      2. Send NUM_BINS freq_bin values via AXI-Stream
//      3. Wait for config_valid_o to assert
//      4. Assert enable_i to start processing
//
////////////////////////////////////////////////////////////////////////////////

module top_with_config_loader #(
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
    parameter integer PHASE_WIDTH = 16, //32
    
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
    parameter logic [POWER_WIDTH-1:0] THRESHOLD_DROP = 8'h1E,  // 30dB
    
    // --- Config Loader Parameters ---
    parameter integer CONFIG_DATA_WIDTH = 16  // Max(PHASE_WIDTH, FREQ_BIN_WIDTH) //32
)(
    input  logic clk_i,
    input  logic rst_ni,
    
    // --- Configuration Loading Interface ---
    input  logic [CONFIG_DATA_WIDTH-1:0] s_axis_config_tdata_i,
    input  logic s_axis_config_tvalid_i,
    output logic s_axis_config_tready_o,
    output logic config_valid_o,         // Configuration loaded and ready
    
    // --- Control Interface ---
    input  logic enable_i,
    input  logic clear_i,
    input  logic [COUNTER_WIDTH-1:0] delay_cycles_i,
    
    // --- Data Input (IQ samples + window coefficient) ---
    input  logic sample_valid_i,
    input  logic signed [IQ_WIDTH-1:0] i_sample_i,
    input  logic signed [IQ_WIDTH-1:0] q_sample_i,
    input  logic signed [WINDOW_WIDTH-1:0] window_coeff_i,
    
    // --- Outputs ---
    // DFT busy status
    // output logic dft_busy_o,
    
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
    output logic valid_o
);

    //--------------------------------------------------------------------------
    // Internal Signals
    //--------------------------------------------------------------------------
    
    // Configuration arrays from config_loader
    logic [PHASE_WIDTH-1:0] freq_steps[NUM_BINS];
    logic [FREQ_BIN_WIDTH-1:0] freq_bin[NUM_BINS];
    logic config_valid;
    
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
    
    // 0. Configuration Loader
    config_loader #(
        .PHASE_WIDTH     (PHASE_WIDTH),
        .FREQ_BIN_WIDTH  (FREQ_BIN_WIDTH),
        .NUM_BINS        (NUM_BINS),
        .DATA_WIDTH      (CONFIG_DATA_WIDTH)
    ) u_config_loader (
        .clk_i               (clk_i),
        .rst_ni              (rst_ni),
        .clear_i             (clear_i),
        .s_axis_tdata_i      (s_axis_config_tdata_i),
        .s_axis_tvalid_i     (s_axis_config_tvalid_i),
        .s_axis_tready_o     (s_axis_config_tready_o),
        .freq_steps_o        (freq_steps),
        .freq_bin_o          (freq_bin),
        .config_valid_o      (config_valid)
    );
    
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
        .freq_steps_i   (freq_steps),
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
        .freq_bin_i     (freq_bin),
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
    
    assign config_valid_o = config_valid;

    // assign dft_busy_o = dft_busy;
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

endmodule