module top_top (
    input  logic clk_i,
    input  logic rst_ni,
    output logic valid_o
);

    // --- Internal parameter definitions (matching wrapper defaults) ---
    localparam integer IQ_WIDTH = 16;
    localparam integer IQ_WIDTH_FRAC = 14;
    localparam integer WINDOW_WIDTH = 16;
    localparam integer WINDOW_WIDTH_FRAC = 14;
    localparam integer ACCUM_WIDTH = 36;
    localparam integer ACCUM_WIDTH_FRAC = 28;
    localparam integer NUM_BINS = 24;
    localparam integer OSC_WIDTH = 16;
    localparam integer OSC_WIDTH_FRAC = 14;
    localparam integer PHASE_WIDTH = 16;
    localparam integer POWER_INPUT_WIDTH = 18;
    localparam integer POWER_WIDTH = 8;
    localparam integer POWER_FRAC = 0;
    localparam integer WINDOW_SIZE = 256;
    localparam integer OSC_LATENCY = 20;
    localparam integer COUNTER_WIDTH = 16;
    localparam integer SAMPLE_COUNT_WIDTH = 16;
    localparam integer FREQ_BIN_WIDTH = 16;
    localparam logic [POWER_WIDTH-1:0] THRESHOLD_DROP = 8'h1E;
    localparam integer CONFIG_DATA_WIDTH = 24;

    // --- Internal wires for wrapper I/O ---
    // Configuration Loading Interface
    logic [CONFIG_DATA_WIDTH-1:0] s_axis_config_tdata;
    logic s_axis_config_tvalid;
    logic s_axis_config_tready;
    logic config_valid;
    
    // Control Interface
    logic clear;
    logic [COUNTER_WIDTH-1:0] delay_cycles;
    
    // Data Input
    logic sample_valid;
    logic signed [IQ_WIDTH-1:0] i_sample;
    logic signed [IQ_WIDTH-1:0] q_sample;
    logic signed [WINDOW_WIDTH-1:0] window_coeff;
    
    // Outputs
    logic threshold_ok;
    logic [FREQ_BIN_WIDTH-1:0] f1_left;
    logic [FREQ_BIN_WIDTH-1:0] f2_left;
    logic [POWER_WIDTH-1:0] L1_left;
    logic [POWER_WIDTH-1:0] L2_left;
    logic [FREQ_BIN_WIDTH-1:0] f1_right;
    logic [FREQ_BIN_WIDTH-1:0] f2_right;
    logic [POWER_WIDTH-1:0] L1_right;
    logic [POWER_WIDTH-1:0] L2_right;
    logic valid_internal;

    // --- Drive internal signals with default values ---
    assign s_axis_config_tdata = '0;
    assign s_axis_config_tvalid = 1'b0;
    assign clear = 1'b0;
    assign delay_cycles = '0;
    assign sample_valid = 1'b0;
    assign i_sample = '0;
    assign q_sample = '0;
    assign window_coeff = '0;
    
    // Connect internal valid to output
    assign valid_o = valid_internal;

    // --- Instantiate wrapper with DONT_TOUCH attribute ---
    (* DONT_TOUCH = "true" *)
    top_with_config_loader #(
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
        .POWER_INPUT_WIDTH(POWER_INPUT_WIDTH),
        .POWER_WIDTH(POWER_WIDTH),
        .POWER_FRAC(POWER_FRAC),
        .WINDOW_SIZE(WINDOW_SIZE),
        .OSC_LATENCY(OSC_LATENCY),
        .COUNTER_WIDTH(COUNTER_WIDTH),
        .SAMPLE_COUNT_WIDTH(SAMPLE_COUNT_WIDTH),
        .FREQ_BIN_WIDTH(FREQ_BIN_WIDTH),
        .THRESHOLD_DROP(THRESHOLD_DROP),
        .CONFIG_DATA_WIDTH(CONFIG_DATA_WIDTH)
    ) u_top_with_config_loader (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        // Configuration Loading Interface
        .s_axis_config_tdata_i(s_axis_config_tdata),
        .s_axis_config_tvalid_i(s_axis_config_tvalid),
        .s_axis_config_tready_o(s_axis_config_tready),
        .config_valid_o(config_valid),
        // Control Interface
        .enable_i(enable_i),
        .clear_i(clear),
        .delay_cycles_i(delay_cycles),
        // Data Input
        .sample_valid_i(sample_valid),
        .i_sample_i(i_sample),
        .q_sample_i(q_sample),
        .window_coeff_i(window_coeff),
        // Outputs
        .threshold_ok_o(threshold_ok),
        .f1_left_o(f1_left),
        .f2_left_o(f2_left),
        .L1_left_o(L1_left),
        .L2_left_o(L2_left),
        .f1_right_o(f1_right),
        .f2_right_o(f2_right),
        .L1_right_o(L1_right),
        .L2_right_o(L2_right),
        .valid_o(valid_internal)
    );

endmodule