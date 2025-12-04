////////////////////////////////////////////////////////////////////////////////
//
//  Module: dft_bandwidth_analysis_top
//
//  Function: Top-level module integrating DFT accumulation, power calculation,
//            threshold detection, and bandwidth edge finding with linear
//            interpolation for precise frequency estimation.
//
//  Pipeline: 
//    1. Timing Controller triggers DFT accumulation
//    2. DFT computes complex bins
//    3. Complex-to-log-power converts to dB
//    4. Find max power for threshold calculation
//    5. Calculate absolute threshold
//    6. Find left and right bandwidth edges
//    7. Linear interpolation for precise crossing frequencies
//
////////////////////////////////////////////////////////////////////////////////

module top #(
    // Timing Parameters
    parameter int DELAY_CYCLES = 1000,
    parameter int OSC_LATENCY  = 35,
    parameter int COUNTER_WIDTH = 16,
    
    // DFT Parameters
    parameter int IQ_WIDTH = 16,
    parameter int IQ_WIDTH_FRAC = 14,
    parameter int WINDOW_WIDTH = 16,
    parameter int WINDOW_WIDTH_FRAC = 14,
    parameter int ACCUM_WIDTH = 48,
    parameter int ACCUM_WIDTH_FRAC = 40,
    parameter int NUM_BINS = 16,
    parameter int OSC_WIDTH = 32,
    parameter int OSC_WIDTH_FRAC = 30,
    parameter int PHASE_WIDTH = 32,
    parameter int SAMPLE_COUNT_WIDTH = 16,
    
    // Power and Threshold Parameters
    parameter int POWER_WIDTH = 32,
    parameter int POWER_FRAC = 16,
    parameter logic [POWER_WIDTH-1:0] THRESHOLD_DROP = 32'h001E_0000,
    
    // Frequency Parameters
    parameter int FREQ_BIN_WIDTH = 16,
    parameter int FREQ_WIDTH = 32,
    parameter int FREQ_FRAC_BITS = 16
)(
    input  logic clk_i,
    input  logic rst_ni,
    
    // Top-Level Controls
    input  logic enable_i,              // Enable timing controller
    input  logic clear_i,               // Clear timing controller
    input  logic sample_valid_i,        // Valid sample indicator
    input  logic last_sample_i,         // Last sample in window
    input  logic osc_reset_i,           // Reset oscillator phase
    input  logic osc_phase_tvalid_i,    // Oscillator phase valid
    
    // Configuration
    input  logic [PHASE_WIDTH-1:0] freq_steps_i[NUM_BINS],
    input  logic [FREQ_BIN_WIDTH-1:0] freq_bin_i[NUM_BINS],
    
    // Data Inputs
    input  logic signed [IQ_WIDTH-1:0] i_sample_i,
    input  logic signed [IQ_WIDTH-1:0] q_sample_i,
    input  logic signed [WINDOW_WIDTH-1:0] window_coeff_i,
    
    // Outputs
    output logic [FREQ_WIDTH-1:0] f_star_left_o,
    output logic [FREQ_WIDTH-1:0] f_star_right_o,
    output logic valid_o,
    output logic invalid_left_o,
    output logic invalid_right_o,

    output logic [FREQ_WIDTH-1:0] f1_left_o,
    output logic [FREQ_WIDTH-1:0] f2_left_o,
    output logic [ACCUM_WIDTH-1:0] L1_left_o,
    output logic [ACCUM_WIDTH-1:0] L2_left_o,

    output logic [FREQ_WIDTH-1:0] f1_right_o,
    output logic [FREQ_WIDTH-1:0] f2_right_o,
    output logic [ACCUM_WIDTH-1:0] L1_right_o,
    output logic [ACCUM_WIDTH-1:0] L2_right_o,
    
    // Status Outputs
    output logic dft_busy_o,
    output logic threshold_ok_o
);

    //--------------------------------------------------------------------------
    // Internal Signals
    //--------------------------------------------------------------------------
    
    // Timing Controller Outputs
    logic start_osc;
    logic start_dft;
    
    // DFT Accumulation Outputs
    logic signed [ACCUM_WIDTH-1:0] A_real[NUM_BINS];
    logic signed [ACCUM_WIDTH-1:0] A_imag[NUM_BINS];
    logic dft_valid;
    logic dft_busy;
    
    // Complex-to-Log-Power Outputs
    logic [POWER_WIDTH-1:0] db_power[NUM_BINS];
    logic power_valid;
    
    // Find Max Power Outputs
    logic [POWER_WIDTH-1:0] max_power;
    logic max_power_valid;
    
    // Threshold Calculation Outputs
    logic [POWER_WIDTH-1:0] abs_threshold;
    logic threshold_valid;
    logic threshold_ok;
    
    // Left Edge Finder Outputs
    logic [FREQ_BIN_WIDTH-1:0] f1_left;
    logic [FREQ_BIN_WIDTH-1:0] f2_left;
    logic [ACCUM_WIDTH-1:0] L1_left;
    logic [ACCUM_WIDTH-1:0] L2_left;
    logic left_edge_valid;
    logic left_edge_busy;
    
    // Right Edge Finder Outputs
    logic [FREQ_BIN_WIDTH-1:0] f1_right;
    logic [FREQ_BIN_WIDTH-1:0] f2_right;
    logic [ACCUM_WIDTH-1:0] L1_right;
    logic [ACCUM_WIDTH-1:0] L2_right;
    logic right_edge_valid;
    logic right_edge_busy;
    
    // Linear Interpolation Outputs
    logic [FREQ_WIDTH-1:0] f_star_left;
    logic [FREQ_WIDTH-1:0] f_star_right;
    logic left_interp_ready;
    logic right_interp_ready;
    logic left_invalid;
    logic right_invalid;
    
    // Combined Valid Signal
    logic both_interp_valid;
    
    //--------------------------------------------------------------------------
    // Module Instantiations
    //--------------------------------------------------------------------------
    
    // 1. Timing Controller
    dft_timing_controller #(
        .DELAY_CYCLES   (DELAY_CYCLES),
        .OSC_LATENCY    (OSC_LATENCY),
        .COUNTER_WIDTH  (COUNTER_WIDTH)
    ) u_timing_ctrl (
        .clk_i          (clk_i),
        .rst_ni         (rst_ni),
        .enable_i       (enable_i),
        .clear_i        (clear_i),
        .start_osc_o    (start_osc),
        .start_dft_o    (start_dft)
    );
    
    // 2. DFT Accumulation with CORDIC
    dft_accumulation_cordic #(
        .IQ_WIDTH               (IQ_WIDTH),
        .IQ_WIDTH_FRAC          (IQ_WIDTH_FRAC),
        .WINDOW_WIDTH           (WINDOW_WIDTH),
        .WINDOW_WIDTH_FRAC      (WINDOW_WIDTH_FRAC),
        .ACCUM_WIDTH            (ACCUM_WIDTH),
        .ACCUM_WIDTH_FRAC       (ACCUM_WIDTH_FRAC),
        .NUM_BINS               (NUM_BINS),
        .OSC_WIDTH              (OSC_WIDTH),
        .OSC_WIDTH_FRAC         (OSC_WIDTH_FRAC),
        .PHASE_WIDTH            (PHASE_WIDTH),
        .SAMPLE_COUNT_WIDTH     (SAMPLE_COUNT_WIDTH)
    ) u_dft_accum (
        .clk_i                  (clk_i),
        .rst_ni                 (rst_ni),
        .start_i                (start_dft),
        .sample_valid_i         (sample_valid_i),
        .last_sample_i          (last_sample_i),
        .osc_reset_i            (osc_reset_i),
        .osc_enable_i           (start_osc),
        .osc_phase_tvalid_i     (osc_phase_tvalid_i),
        .freq_steps_i           (freq_steps_i),
        .i_sample_i             (i_sample_i),
        .q_sample_i             (q_sample_i),
        .window_coeff_i         (window_coeff_i),
        .A_real_o               (A_real),
        .A_imag_o               (A_imag),
        .valid_o                (dft_valid),
        .busy_o                 (dft_busy)
    );
    
    // 3. Complex-to-Log-Power Converters (One per bin)
    generate
        for (genvar i = 0; i < NUM_BINS; i++) begin : gen_power_calc
            complex_to_log_power #(
                .INPUT_WIDTH    (ACCUM_WIDTH),
                .OUTPUT_WIDTH   (POWER_WIDTH),
                .OUTPUT_FRAC    (POWER_FRAC)
            ) u_power_calc (
                .clk_i          (clk_i),
                .rst_ni         (rst_ni),
                .valid_i        (dft_valid),
                .i_data_i       (A_real[i]),
                .q_data_i       (A_imag[i]),
                .valid_o        (power_valid),  // All instances share same valid
                .db_power_o     (db_power[i])
            );
        end
    endgenerate
    
    // 4. Find Maximum Power
    find_max_power #(
        .NUM_BINS       (NUM_BINS),
        .POWER_WIDTH    (POWER_WIDTH)
    ) u_find_max (
        .clk_i              (clk_i),
        .rst_ni             (rst_ni),
        .valid_i            (power_valid),
        .power_values_i     (db_power),
        .valid_o            (max_power_valid),
        .max_power_o        (max_power)
    );
    
    // 5. Calculate Absolute Threshold
    calc_abs_threshold #(
        .POWER_WIDTH        (POWER_WIDTH),
        .THRESHOLD_DROP     (THRESHOLD_DROP)
    ) u_calc_threshold (
        .clk_i              (clk_i),
        .rst_ni             (rst_ni),
        .max_power_i        (max_power),
        .max_power_valid_i  (max_power_valid),
        .abs_threshold_o    (abs_threshold),
        .valid_o            (threshold_valid),
        .threshold_ok_o     (threshold_ok)
    );
    
    // 6. Find Left Bandwidth Edge
    find_bw_left_edge_absolute #(
        .ACCUM_WIDTH        (POWER_WIDTH),
        .FREQ_BIN_WIDTH     (FREQ_BIN_WIDTH),
        .NUM_ACCUMS         (NUM_BINS)
    ) u_left_edge (
        .clk_i              (clk_i),
        .rst_ni             (rst_ni),
        .start_i            (threshold_valid),
        .accumulator_val_i  (db_power),
        .freq_bin_i         (freq_bin_i),
        .abs_threshold_i    (abs_threshold),
        .f1_o               (f1_left),
        .f2_o               (f2_left),
        .L1_o               (L1_left),
        .L2_o               (L2_left),
        .valid_o            (left_edge_valid),
        .busy_o             (left_edge_busy)
    );
    
    // 7. Find Right Bandwidth Edge
    find_bw_right_edge_absolute #(
        .ACCUM_WIDTH        (POWER_WIDTH),
        .FREQ_BIN_WIDTH     (FREQ_BIN_WIDTH),
        .NUM_ACCUMS         (NUM_BINS)
    ) u_right_edge (
        .clk_i              (clk_i),
        .rst_ni             (rst_ni),
        .start_i            (threshold_valid),
        .accumulator_val_i  (db_power),
        .freq_bin_i         (freq_bin_i),
        .abs_threshold_i    (abs_threshold),
        .f1_o               (f1_right),
        .f2_o               (f2_right),
        .L1_o               (L1_right),
        .L2_o               (L2_right),
        .valid_o            (right_edge_valid),
        .busy_o             (right_edge_busy)
    );
    
    // 8. Linear Interpolation for Left Edge
    linear_interp_crossing #(
        .FREQ_WIDTH         (FREQ_WIDTH),
        .FREQ_FRAC_BITS     (FREQ_FRAC_BITS),
        .ACCUM_DB_WIDTH     (POWER_WIDTH),
        .ACCUM_DB_FRAC      (POWER_FRAC),
        .THRESHOLD_DB       (THRESHOLD_DROP)
    ) u_left_interp (
        .clk_i              (clk_i),
        .rst_ni             (rst_ni),
        .valid_i            (left_edge_valid),
        .f1_i               (f1_left),
        .f2_i               (f2_left),
        .L1_i               (L1_left),
        .L2_i               (L2_left),
        .ready_o            (left_interp_ready),
        .f_star_o           (f_star_left),
        .invalid_o          (left_invalid)
    );
    
    // 9. Linear Interpolation for Right Edge
    linear_interp_crossing #(
        .FREQ_WIDTH         (FREQ_WIDTH),
        .FREQ_FRAC_BITS     (FREQ_FRAC_BITS),
        .ACCUM_DB_WIDTH     (POWER_WIDTH),
        .ACCUM_DB_FRAC      (POWER_FRAC),
        .THRESHOLD_DB       (THRESHOLD_DROP)
    ) u_right_interp (
        .clk_i              (clk_i),
        .rst_ni             (rst_ni),
        .valid_i            (right_edge_valid),
        .f1_i               (f1_right),
        .f2_i               (f2_right),
        .L1_i               (L1_right),
        .L2_i               (L2_right),
        .ready_o            (right_interp_ready),
        .f_star_o           (f_star_right),
        .invalid_o          (right_invalid)
    );
    
    //--------------------------------------------------------------------------
    // Output Logic
    //--------------------------------------------------------------------------
    
    // Valid output when both interpolators are ready
    assign both_interp_valid = left_interp_ready && right_interp_ready;
    
    // Register final outputs for clean timing
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            f_star_left_o   <= '0;
            f_star_right_o  <= '0;
            valid_o         <= 1'b0;
            invalid_left_o  <= 1'b0;
            invalid_right_o <= 1'b0;
        end else begin
            if (both_interp_valid) begin
                f_star_left_o   <= f_star_left;
                f_star_right_o  <= f_star_right;
                valid_o         <= 1'b1;
                invalid_left_o  <= left_invalid;
                invalid_right_o <= right_invalid;
            end else begin
                valid_o <= 1'b0;
            end
        end
    end
    
    // Status outputs
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

endmodule