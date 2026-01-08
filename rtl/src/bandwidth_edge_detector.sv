module bandwidth_edge_detector #(
    // Power and Threshold Parameters
    parameter int POWER_WIDTH = 8,
    parameter int POWER_FRAC = 0,
    parameter logic [POWER_WIDTH-1:0] THRESHOLD_DROP = 8'h1E,
    
    // Frequency and Bin Parameters
    parameter int FREQ_BIN_WIDTH = 16,
    parameter int NUM_BINS = 24
)(
    input  logic                        clk_i,
    input  logic                        rst_ni,
    
    // Input: dB power values for all frequency bins
    input  logic                        valid_i,
    input  logic [POWER_WIDTH-1:0]      db_power_i[NUM_BINS],
    input  logic [FREQ_BIN_WIDTH-1:0]   freq_bin_i[NUM_BINS],
    
    // Outputs: Left edge crossing points
    output logic [FREQ_BIN_WIDTH-1:0]   f1_left_o,      // Lower frequency bin
    output logic [FREQ_BIN_WIDTH-1:0]   f2_left_o,      // Higher frequency bin
    output logic [POWER_WIDTH-1:0]      L1_left_o,
    output logic [POWER_WIDTH-1:0]      L2_left_o,
    
    // Outputs: Right edge crossing points
    output logic [FREQ_BIN_WIDTH-1:0]   f1_right_o,     // Lower frequency bin
    output logic [FREQ_BIN_WIDTH-1:0]   f2_right_o,     // Higher frequency bin
    output logic [POWER_WIDTH-1:0]      L1_right_o,
    output logic [POWER_WIDTH-1:0]      L2_right_o,
    output logic [POWER_WIDTH-1:0]      abs_threshold_o,
    
    // Status outputs
    output logic                        valid_o,        // Output valid (both edges found)
    output logic                        threshold_ok_o, // Threshold calculation valid
    output logic                        busy_o          // Processing in progress
);

    //--------------------------------------------------------------------------
    // Internal Signals
    //--------------------------------------------------------------------------
    
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
    logic [POWER_WIDTH-1:0] L1_left;
    logic [POWER_WIDTH-1:0] L2_left;
    logic left_edge_valid;
    logic left_edge_busy;
    
    // Right Edge Finder Outputs
    logic [FREQ_BIN_WIDTH-1:0] f1_right;
    logic [FREQ_BIN_WIDTH-1:0] f2_right;
    logic [POWER_WIDTH-1:0] L1_right;
    logic [POWER_WIDTH-1:0] L2_right;
    logic right_edge_valid;
    logic right_edge_busy;
    
    //--------------------------------------------------------------------------
    // Module Instantiations
    //--------------------------------------------------------------------------
    
    // 1. Find Maximum Power
    find_max_power #(
        .NUM_BINS       (NUM_BINS),
        .POWER_WIDTH    (POWER_WIDTH)
    ) u_find_max (
        .clk_i              (clk_i),
        .rst_ni             (rst_ni),
        .valid_i            (valid_i),
        .power_values_i     (db_power_i),
        .valid_o            (max_power_valid),
        .max_power_o        (max_power)
    );
    
    // 2. Calculate Absolute Threshold
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
    
    // 3. Find Left Bandwidth Edge
    find_bw_left_edge_absolute #(
        .POWER_WIDTH        (POWER_WIDTH),
        .IDX_WIDTH     (FREQ_BIN_WIDTH),
        .NUM_ACCUMS         (NUM_BINS)
    ) u_left_edge (
        .clk_i              (clk_i),
        .rst_ni             (rst_ni),
        .start_i            (threshold_valid),
        .accumulator_val_i  (db_power_i),
        .freq_bin_i         (freq_bin_i),
        .abs_threshold_i    (abs_threshold),
        .f1_o               (f1_left),
        .f2_o               (f2_left),
        .L1_o               (L1_left),
        .L2_o               (L2_left),
        .valid_o            (left_edge_valid),
        .busy_o             (left_edge_busy)
    );
    
    // 4. Find Right Bandwidth Edge
    find_bw_right_edge_absolute #(
        .POWER_WIDTH        (POWER_WIDTH),
        .IDX_WIDTH     (FREQ_BIN_WIDTH),
        .NUM_ACCUMS         (NUM_BINS)
    ) u_right_edge (
        .clk_i              (clk_i),
        .rst_ni             (rst_ni),
        .start_i            (threshold_valid),
        .accumulator_val_i  (db_power_i),
        .freq_bin_i         (freq_bin_i),
        .abs_threshold_i    (abs_threshold),
        .f1_o               (f1_right),
        .f2_o               (f2_right),
        .L1_o               (L1_right),
        .L2_o               (L2_right),
        .valid_o            (right_edge_valid),
        .busy_o             (right_edge_busy)
    );
    
    //--------------------------------------------------------------------------
    // Output Logic
    //--------------------------------------------------------------------------
    
    // Valid output when both edge finders complete
    assign valid_o = left_edge_valid && right_edge_valid;
    
    // Busy when either edge finder is busy
    assign busy_o = left_edge_busy || right_edge_busy;

    // Assign outputs
    assign f1_left_o  = f1_left;
    assign f2_left_o  = f2_left;
    assign L1_left_o  = L1_left;
    assign L2_left_o  = L2_left;
                
    assign f1_right_o = f1_right;
    assign f2_right_o = f2_right;
    assign L1_right_o = L1_right;
    assign L2_right_o = L2_right;
    assign abs_threshold_o = abs_threshold;
    
    // Threshold status output
    assign threshold_ok_o = threshold_ok;

endmodule