////////////////////////////////////////////////////////////////////////////////
//
//  Module: oscillator_bank_tmux (Time-Multiplexed Oscillator Bank)
//
//  Function: Generates N complex oscillators using 2 CORDIC blocks time-multiplexed
//            CORDIC_0 handles bins 0-11, CORDIC_1 handles bins 12-23
//            Outputs are stored in registers for each bin
//
////////////////////////////////////////////////////////////////////////////////

module oscillator_bank_tmux #(
    parameter int NUM_BINS = 24,           // MUST BE EVEN
    parameter int OSC_WIDTH = 32,
    parameter int PHASE_WIDTH = 32,
    parameter int COUNTER_WIDTH = 5        // clog2(NUM_BINS)
)(
    input  logic clk_i,
    input  logic rst_ni,
    
    // Phase accumulator control
    input  logic phase_acc_enable_i,       // Enable phase accumulator updates
    input  logic phase_acc_sync_reset_i,   // Reset all phase accumulators
    
    // CORDIC control
    input  logic cordic_phase_tvalid_i,    // CORDIC input valid
    input  logic [COUNTER_WIDTH-1:0] counter_i,  // Bin select counter (0 to NUM_BINS/2-1)
    
    // Configuration
    input  logic [PHASE_WIDTH-1:0] freq_steps_i[NUM_BINS],
    
    // Outputs - stored values for ALL bins
    output logic signed [OSC_WIDTH-1:0] W_real_o[NUM_BINS],
    output logic signed [OSC_WIDTH-1:0] W_imag_o[NUM_BINS],
    output logic sincos_tvalid_o
);

    localparam int BINS_PER_CORDIC = NUM_BINS / 2;
    // CORDIC Latency changes when changing the i/o widths of the CORDIC IP!
    localparam int CORDIC_LATENCY = 20; //28

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
    // CORDIC Instantiations (2 blocks)
    // =========================================================================
    
    // CORDIC 0: Handles bins 0-11
    logic [PHASE_WIDTH-1:0] phase_scaled_0;
    logic signed [OSC_WIDTH-1:0] cos_out_0, sin_out_0;
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
    
    assign cos_out_0 = cordic_dout_0[OSC_WIDTH-1:0];
    assign sin_out_0 = cordic_dout_0[2*OSC_WIDTH-1:OSC_WIDTH];
    
    // CORDIC 1: Handles bins 12-23
    logic [PHASE_WIDTH-1:0] phase_scaled_1;
    logic signed [OSC_WIDTH-1:0] cos_out_1, sin_out_1;
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
    
    assign cos_out_1 = cordic_dout_1[OSC_WIDTH-1:0];
    assign sin_out_1 = cordic_dout_1[2*OSC_WIDTH-1:OSC_WIDTH];

    // =========================================================================
    // Pipeline to track which bins the outputs correspond to
    // Now stores 4-bit counter values (0-11) instead of just 1 bit
    // =========================================================================
    logic [COUNTER_WIDTH-1:0] counter_pipe[CORDIC_LATENCY];
    logic [COUNTER_WIDTH-1:0] output_bin_0;  // Bin index for CORDIC_0 output
    logic [COUNTER_WIDTH-1:0] output_bin_1;  // Bin index for CORDIC_1 output
    
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
    
    // CORDIC_0 output corresponds to bin output_bin_0 (0-11)
    // CORDIC_1 output corresponds to bin output_bin_0 + 12 (12-23)
    assign output_bin_0 = counter_pipe[CORDIC_LATENCY-1];
    assign output_bin_1 = counter_pipe[CORDIC_LATENCY-1] + COUNTER_WIDTH'(BINS_PER_CORDIC);

    // =========================================================================
    // Output Storage FFs - Store latest value for each bin
    // =========================================================================
    logic signed [OSC_WIDTH-1:0] W_real_q[NUM_BINS], W_real_d[NUM_BINS];
    logic signed [OSC_WIDTH-1:0] W_imag_q[NUM_BINS], W_imag_d[NUM_BINS];
    
    always_comb begin
        // Default: hold values
        for (int k = 0; k < NUM_BINS; k++) begin
            W_real_d[k] = W_real_q[k];
            W_imag_d[k] = W_imag_q[k];
        end
        
        // When CORDIC outputs are valid, store to appropriate bins
        if (tvalid_0 && tvalid_1) begin
            // CORDIC 0 output goes to bin output_bin_0 (0-11)
            W_real_d[output_bin_0] = cos_out_0;
            W_imag_d[output_bin_0] = -sin_out_0;  // DFT requires -j*sin
            
            // CORDIC 1 output goes to bin output_bin_1 (12-23)
            W_real_d[output_bin_1] = cos_out_1;
            W_imag_d[output_bin_1] = -sin_out_1;  // DFT requires -j*sin
        end
    end
    
    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            for (int k = 0; k < NUM_BINS; k++) begin
                W_real_q[k] <= '0;
                W_imag_q[k] <= '0;
            end
        end else begin
            for (int k = 0; k < NUM_BINS; k++) begin
                W_real_q[k] <= W_real_d[k];
                W_imag_q[k] <= W_imag_d[k];
            end
        end
    end

    // =========================================================================
    // Output Assignments
    // =========================================================================
    always_comb begin
        for (int k = 0; k < NUM_BINS; k++) begin
            W_real_o[k] = W_real_q[k];
            W_imag_o[k] = W_imag_q[k];
        end
    end
    
    assign sincos_tvalid_o = tvalid_0 && tvalid_1;

endmodule