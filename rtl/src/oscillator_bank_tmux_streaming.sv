////////////////////////////////////////////////////////////////////////////////
//
//  Module: oscillator_bank_tmux_streaming
//
//  Function: Generates complex oscillators using 2 time-multiplexed CORDICs
//            Outputs are streamed directly (no storage) for immediate use
//
////////////////////////////////////////////////////////////////////////////////

module oscillator_bank_tmux_streaming #(
    parameter int NUM_BINS = 24,
    parameter int OSC_WIDTH = 16,
    parameter int PHASE_WIDTH = 16,
    parameter int COUNTER_WIDTH = 5,
    parameter int CORDIC_LATENCY = 20
)(
    input  logic clk_i,
    input  logic rst_ni,
    
    // Phase accumulator control
    input  logic phase_acc_enable_i,
    input  logic phase_acc_sync_reset_i,
    
    // CORDIC control
    input  logic cordic_phase_tvalid_i,
    input  logic [COUNTER_WIDTH-1:0] counter_i,
    
    // Configuration
    input  logic [PHASE_WIDTH-1:0] freq_steps_i[NUM_BINS],
    
    // Streaming outputs - current CORDIC results
    output logic signed [OSC_WIDTH-1:0] cos_out_0_o,  // CORDIC_0 cosine
    output logic signed [OSC_WIDTH-1:0] sin_out_0_o,  // CORDIC_0 sine (negated for DFT)
    output logic signed [OSC_WIDTH-1:0] cos_out_1_o,  // CORDIC_1 cosine
    output logic signed [OSC_WIDTH-1:0] sin_out_1_o,  // CORDIC_1 sine (negated for DFT)
    output logic [COUNTER_WIDTH-1:0] output_bin_0_o,  // Which bin (0-11) output of cordic 0 belongs to
    output logic [COUNTER_WIDTH-1:0] output_bin_1_o,  // Which bin (12-13) ouput of cordic 1 belongs to
    output logic sincos_tvalid_o                      // Outputs valid
);

    localparam int BINS_PER_CORDIC = NUM_BINS / 2;  // 12

    // =========================================================================
    // Phase Accumulators (24 total, updated once every 12 cycles)
    // =========================================================================
    logic [PHASE_WIDTH-1:0] phase_acc_d[NUM_BINS];
    logic [PHASE_WIDTH-1:0] phase_acc_q[NUM_BINS];
    
    always_comb begin
        // Default: hold values
        for (int k = 0; k < NUM_BINS; k++) begin
            phase_acc_d[k] = phase_acc_q[k];
        end
        
        if (phase_acc_sync_reset_i) begin
            for (int k = 0; k < NUM_BINS; k++) begin
                phase_acc_d[k] = '0;
            end
        end else if (phase_acc_enable_i) begin
            // Update the two bins corresponding to current counter value
            phase_acc_d[counter_i] = phase_acc_q[counter_i] + freq_steps_i[counter_i];
            phase_acc_d[counter_i + BINS_PER_CORDIC] = 
                phase_acc_q[counter_i + BINS_PER_CORDIC] + freq_steps_i[counter_i + BINS_PER_CORDIC];
        end
    end
    
    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            for (int k = 0; k < NUM_BINS; k++) begin
                phase_acc_q[k] <= '0;
            end
        end else begin
            for (int k = 0; k < NUM_BINS; k++) begin
                phase_acc_q[k] <= phase_acc_d[k];
            end
        end
    end

    // =========================================================================
    // CORDIC 0: Handles bins 0-11
    // =========================================================================
    logic [PHASE_WIDTH-1:0] phase_scaled_0;
    logic signed [OSC_WIDTH-1:0] cos_raw_0, sin_raw_0;
    logic [2*OSC_WIDTH-1:0] cordic_dout_0;
    logic tvalid_0;
    
    assign phase_scaled_0 = { 
        {2{phase_acc_q[counter_i][PHASE_WIDTH-1]}}, 
        phase_acc_q[counter_i][PHASE_WIDTH-1:2] 
    };
    
    cordic_0 cordic_inst_0 (
        .aclk(clk_i),
        .s_axis_phase_tvalid(cordic_phase_tvalid_i),
        .s_axis_phase_tdata(phase_scaled_0),
        .m_axis_dout_tvalid(tvalid_0),
        .m_axis_dout_tdata(cordic_dout_0)
    );
    
    assign cos_raw_0 = cordic_dout_0[OSC_WIDTH-1:0];
    assign sin_raw_0 = cordic_dout_0[2*OSC_WIDTH-1:OSC_WIDTH];
    
    // =========================================================================
    // CORDIC 1: Handles bins 12-23
    // =========================================================================
    logic [PHASE_WIDTH-1:0] phase_scaled_1;
    logic signed [OSC_WIDTH-1:0] cos_raw_1, sin_raw_1;
    logic [2*OSC_WIDTH-1:0] cordic_dout_1;
    logic tvalid_1;
    
    assign phase_scaled_1 = { 
        {2{phase_acc_q[counter_i + BINS_PER_CORDIC][PHASE_WIDTH-1]}}, 
        phase_acc_q[counter_i + BINS_PER_CORDIC][PHASE_WIDTH-1:2] 
    };
    
    cordic_0 cordic_inst_1 (
        .aclk(clk_i),
        .s_axis_phase_tvalid(cordic_phase_tvalid_i),
        .s_axis_phase_tdata(phase_scaled_1),
        .m_axis_dout_tvalid(tvalid_1),
        .m_axis_dout_tdata(cordic_dout_1)
    );
    
    assign cos_raw_1 = cordic_dout_1[OSC_WIDTH-1:0];
    assign sin_raw_1 = cordic_dout_1[2*OSC_WIDTH-1:OSC_WIDTH];

    // =========================================================================
    // Counter Pipeline - Track which bins the outputs correspond to
    // =========================================================================
    logic [COUNTER_WIDTH-1:0] counter_pipe[CORDIC_LATENCY];
    logic [COUNTER_WIDTH-1:0] output_bin_0, output_bin_1;
    
    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            for (int i = 0; i < CORDIC_LATENCY; i++) begin
                counter_pipe[i] <= '0;
            end
        end else if (cordic_phase_tvalid_i) begin
            counter_pipe[0] <= counter_i;
            for (int i = 1; i < CORDIC_LATENCY; i++) begin
                counter_pipe[i] <= counter_pipe[i-1];
            end
        end
    end
    
    // CORDIC outputs correspond to bin output_bin_0 and output_bin_0 + 12
    assign output_bin_0 = counter_pipe[CORDIC_LATENCY-1];
    assign output_bin_1 = counter_pipe[CORDIC_LATENCY-1] + COUNTER_WIDTH'(BINS_PER_CORDIC);

    // =========================================================================
    // Output Assignments - Stream directly with DFT negation applied
    // =========================================================================
    // Note: Negation is combinational but very fast (invert + add 1)
    // The multiplication that follows will absorb this delay
    assign cos_out_0_o = cos_raw_0;
    assign sin_out_0_o = sin_raw_0;  // DFT requires -j*sin // removed negation
    assign cos_out_1_o = cos_raw_1;
    assign sin_out_1_o = sin_raw_1;  // DFT requires -j*sin // removed negation
    
    assign output_bin_0_o = output_bin_0;
    assign output_bin_1_o = output_bin_1;
    assign sincos_tvalid_o = tvalid_0 && tvalid_1;

endmodule